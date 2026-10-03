# Requested Host operations (draft reference)

> **Draft for a candidate revision, not published.** This is the page a
> candidate revision would publish once #76 implements it. It is not part of
> Plugin API Level 1 or of any published candidate, and no Host behaves this
> way yet. The rationale is in [`design.md`](design.md).

A Plugin that declares the [Candidate Contract](../../candidates/README.md)
`host_operations` at revision 1 may ask the Host to perform an operation
*after* its script has answered. It names the operation by its ID in the
namespace catalogue ([`namespaces`](../namespaces/reference.md)), whose
revision this one requires, and declares both in its manifest, beside the
stable Level it builds on:

```json
{
  "api_level": 1,
  "candidate_contracts": [
    {"name": "host_operations", "revision": 1},
    {"name": "namespaces", "revision": 1}
  ]
}
```

The revision's metadata, in draft, is [`candidate.json`](candidate.json). The
Host checks the declaration as it checks every candidate: a Host that does
not provide exactly this revision refuses the Plugin.

The Host commits the request with the rest of the answer, checks authority again, asks for its own
confirmation when the kind of operation needs one, resolves the target,
performs it, and shows the outcome. None of this happens inside the script's
four-second invocation, so a confirmation can wait for the user without
holding a helper.
[`host-operations.schema.json`](host-operations.schema.json) publishes the
shapes and [`host-operations.d.ts`](host-operations.d.ts) the types.

## Requesting an operation

An answer may carry one `operation`:

```js
const ui = spinnet.ui;
if (event?.type === "submitted") {
  const emoji = firstMatch(event.values.query);
  ui.show(searchView(event.values.query), {
    state: { recent: [emoji, ...state.recent].slice(0, 24) },
    operation: spinnet.selection.replace.operation({ text: emoji }, { closesView: true })
  });
}
```

- Only an answer to a **gesture** may request one: the Action's start
  (`event` is `null`), `submitted` and `action_chosen`. An answer to any other
  event that carries `operation` is a protocol violation and ends the View
  Session.
- An answer requests at most one operation. It may come with a view, a
  toast, both, or neither (`ui.request(operation)`), but not with
  `close: true`; to close the view after the operation succeeds, set
  `closes_view`.
- An operation is `{perform, input, id?, closes_view?, notify?}`: `perform`
  is a catalogue ID the catalogue offers as a request, `input` is that
  operation's input as a call or a page action gives it, and `id`, of at most
  64 characters, comes back in `operation_finished`. The IDs offered in this
  revision are `selection.replace`, `clipboard.write`, `open.url`,
  `open.path`, `open.application`, `apps.perform`, `apps.openDeepLink`,
  `host.showPluginSettings` and `clipboardHistory.show`.

## Commit

The Host applies an answer as a whole or not at all: view, state, toast and
operation. Before applying it, it checks that the operation's shape is valid,
that the answer answers a gesture, and that the Command that produced the
answer declares the operation's Capability, the user has granted it, and macOS
grants the System Permission it needs. A shape or gesture problem is a
protocol violation. A refused Capability or System Permission refuses the
whole answer, as a refused Host Service refuses an invocation: the view keeps
its last good view and state, shows the refusal and the way to repair it, and
nothing is requested.

What the script already did during its invocation, such as a Plugin Storage
write or a synchronous `selection.replace`, is not undone when an answer is refused.
Prefer requesting an operation when its effect should depend on the answer
being accepted.

## What happens next

| Outcome | Meaning |
| --- | --- |
| `succeeded` | The operation completed as it defines |
| `refused` | A check at execution failed, such as a revoked Capability or a changed target; nothing was done |
| `declined` | The user declined the Host's confirmation, or closed the view while it showed |
| `expired` | The confirmation went unanswered for 60 seconds |
| `cancelled` | The user cancelled an execution the operation lets them cancel |
| `failed` | The effect failed after the Host began it |

- The Host checks the Capability, the System Permission and the target again
  when it starts the operation.
- The Host shows every outcome other than success in the view, with a repair
  route where there is one, or near the pointer when there is no view.
- `closes_view` closes the view on `succeeded` only.
- Nothing is retried. A retry is a new gesture.

### `operation_finished`

With `notify: true` the script hears the outcome as a View Event:

```json
{"type": "operation_finished", "operation": "insert", "perform": "selection.replace",
 "outcome": "refused", "reason": "target_changed"}
```

It is delivered only while the View Session exists and the Command and
configuration that requested the operation still handle it. It runs before
any gesture that waited for the operation, behind other earlier events, and
has the usual four-second deadline. It is not a gesture,
so its answer may update the view and state but may not request another
operation. `reason` is present for `refused` and `failed` only; it never
names the App, its bundle ID, process or window.

## Busy

A Plugin has at most one operation outstanding: waiting, being confirmed,
running, or, with `notify`, having its `operation_finished` answered. While it
is, `submitted`, `action_chosen` and explicit calls wait in
order and run when it finishes. Field changes, setting changes and section
deliveries go on as usual, so typing never waits for an insertion. After
500 ms of running, the view shows the operation's own busy state, with Cancel
for an operation that can be cancelled.

## Ending

Closing the view, updating, disabling or removing the Plugin, revoking a
Capability it uses, or quitting Spinnet cancels an operation that has not
started. One that has started finishes; its outcome is shown by the Host and
not delivered. No operation is ever replayed.

## Host confirmation

Some operations always ask the user first, in a confirmation the Host
draws inside the Plugin's view (or near the pointer without one) without
bringing Spinnet forward. Its words and the target it names are the Host's
own; a Plugin cannot add to, reword or skip it. A Plugin's own "Are you
sure?" is an ordinary view and authorizes nothing. `selection.replace` needs no
confirmation.

## Insertion

### `selection.replace` requested

`{perform: "selection.replace", input: {text}}` (or `input: text`) inserts
`text`, at most 128 KiB, in place of the selection of the focused element of
the App that is frontmost when the Host inserts. It needs
`insert_into_focused_app` and Accessibility, and never uses the clipboard or
a paste. The Host delivers the text as Unicode keyboard events to that App,
as Level 1's `insert_text` does since P3 (2026-10-03); see
`PluginAPI/reference/host-services.md`.

### Where text goes

In a View Session of a Plugin that declares the candidate, every way of
inserting follows the same rule:

| Path | Compared with |
| --- | --- |
| A `selection.replace` page action, or Level 1's standard `insert_text` in a Level 1 view | The App its button named when it was pressed |
| A requested `selection.replace` | The App the view named when the user made the gesture |
| A synchronous `selection.replace` call | The App the view named when the user made the gesture that started this invocation |

The Host inserts only if the App it named is the App in front at that moment
and the element focused in that App is the one that was focused when the
user acted. Otherwise it writes nothing, refuses with `target_changed` (or, for a
synchronous call, fails the invocation with `insertion_target_changed`), and
updates the name it shows. There is no fallback to the App the view came from
or to any other App.

The Host names the App on each inserting button and, when the
view sets `shows_insertion_target: true`, in a line it draws in the view. It
keeps the name current while the view is open. The name is shown to the user
only: no view, event, result or environment value carries it. A view whose
gestures lead to a requested or synchronous `selection.replace` must set
`shows_insertion_target`; otherwise the insertion is refused with
`target_not_shown`.

An insertion is also refused when Spinnet or no App is in front
(`no_target`), when the App has no focused element that accepts text
(`no_text_input`), when the element is a secure text field (`secure_input`),
and fails when the App rejects the text (`text_rejected`) or does not answer
within one second (`target_unresponsive`). This list is provisional until the
Accessibility evidence of #69 is recorded.

The Host shows the App, but it compares the focused element too: moving focus
to another field or window of the same App between the gesture and the
insertion refuses it with `target_changed`, and the user acts again to insert
into the element now focused. Whether Accessibility elements compare
reliably enough for this in every App is still being recorded (#69).

### Without a view

A Command that shows no view has nowhere to show a target, so an
`selection.replace` it requests, or a synchronous `selection.replace` call it
makes, is refused with `target_not_shown` and nothing is written. The Host
shows the refusal near the pointer. To insert, a Plugin shows a view that
names the target first.

### Level 1 Plugins

A Plugin that does not declare the candidate keeps Level 1 exactly: its
standard `insert_text` inserts into the App the view came from, and its
`insert_text` Host Service into the system-wide focused element. It cannot
use `operation`, `operation_finished` or `shows_insertion_target`, which are
unknown members at Level 1.

## Limits

| Limit | Value | Status |
| --- | --- | --- |
| Operations per answer | 1 | Proposed |
| Outstanding operations per Plugin | 1 | Proposed |
| `id` | 64 characters | Proposed |
| Inserted text | 128 KiB of UTF-8 | Level 1's limit |
| Confirmation expiry | 60 s | Proposed, product choice P8 |
| Target App coming to the front for an insertion | 1 s | Level 1's bound since P3 (2026-10-03) |
| Script invocation, gesture or `operation_finished` | 4 s from when the script starts | Level 1 |

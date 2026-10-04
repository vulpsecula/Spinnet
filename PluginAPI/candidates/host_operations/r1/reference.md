# Requested Host Operations (candidate `host_operations` r1)

> **Candidate Contract, not a stable Level.** This is revision 1 of the
> `host_operations` Candidate Contract ([`candidate.json`](candidate.json)),
> which this Host provides; nothing here is part of Plugin API Level 1, and a
> Plugin that does not declare it is unaffected. A published revision never
> changes ([Candidate Contracts](../../README.md)). The rationale is the
> design record in
> [`proposals/bounded-host-operations/design.md`](../../../proposals/bounded-host-operations/design.md).

A Plugin that declares this revision may ask the Host to perform an
operation *after* its script has answered a user's gesture. It names the
operation by its ID in the namespace catalogue
([`namespaces` r1](../../namespaces/r1/reference.md)), which this revision
requires, and declares both beside the stable Level it builds on:

```json
{
  "api_level": 1,
  "candidate_contracts": [
    {"name": "host_operations", "revision": 1},
    {"name": "namespaces", "revision": 1}
  ]
}
```

The Host commits the request with the rest of the answer, checks authority
again, resolves the target, performs it, and shows the outcome. None of this
happens inside the script's four-second invocation, and no helper is kept
alive for it. [`host-operations.schema.json`](host-operations.schema.json)
publishes the shapes, [`fixtures/`](fixtures/index.json) valid and invalid
answers and events, [`host_operations.js`](host_operations.js) the SDK
additions and [`host-operations.d.ts`](host-operations.d.ts) their types.

## Requesting an operation

An answer may carry one `operation`:

```js
const ui = spinnet.ui;
if (event?.type === "submitted") {
  const emoji = firstMatch(event.values.query);
  return ui.show(searchView(event.values.query), {
    state: { recent: [emoji, ...state.recent].slice(0, 24) },
    operation: spinnet.selection.replace.operation({ text: emoji }, { closesView: true })
  });
}
```

- Only an answer to a **gesture** may request one: the Action's start
  (`event` is `null`), `submitted` and `action_chosen`. An answer to any other
  event that carries `operation` is a protocol violation and ends the View
  Session, so typing, fetched sections and results never cause an effect,
  and a script cannot loop by answering its result with another request.
- An answer requests at most one operation. It may come with a view, a
  toast, both, or neither (`ui.request(operation)`), but not with
  `close: true`; to close the view after the operation succeeds, set
  `closes_view`.
- An operation is `{perform, input, id?, closes_view?, notify?}`: `perform`
  is a catalogue ID offered as a request, `input` that operation's input as a
  call gives it (a bare string stands for its primary member), and `id`, of
  at most 64 characters, comes back in `operation_finished`. `notify` asks to
  hear the outcome.

| ID | Input | Needs |
| --- | --- | --- |
| `selection.replace` | `text`, at most 128 KiB, tabs and line breaks but no other control character | `insert_into_focused_app`, Accessibility |
| `clipboard.write` | `text` | `write_clipboard` |
| `clipboardHistory.show` | none | `read_clipboard_history` |
| `open.url` | `url`, http or https with a host | `open_url` |
| `open.path` | `path`, absolute or `~/` | `open_local_path` |
| `open.application` | `application`, a path or bundle identifier | `open_local_path` |
| `apps.perform` | `{bundle_id, operation, arguments?}` | `control_external_app`; macOS asks for Automation |
| `apps.openDeepLink` | `{template, parameters?}` | `control_external_app` |
| `host.showPluginSettings` | none, and no `closes_view` | nothing |

The SDK builds each request from its operation:
`spinnet.<id>.operation(input, { id, closesView, notify })`, such as
`spinnet.clipboard.write.operation("😀")` or
`spinnet.host.showPluginSettings.operation()`. An operation a script can also
call stays callable: `spinnet.selection.replace("😀")` still inserts at once.
`ui.show(view, { state, toast, operation })` commits an operation with a
view, `ui.request(operation, { toast })` without one, and
`ui.view({ ..., showsInsertionTarget: true })` asks for the target line.
Page actions, `.action(...)`, belong to the `collections` candidate.

## Commit

The Host applies an answer as a whole or not at all: view, state, toast and
operation. Before applying it, it checks that the answer and operation have
a valid shape for what the Plugin declares, that the answer answers a
gesture, and what needs no target: the text limit and its characters, a
link's scheme and host, a path's form. A problem with any of these is a
protocol violation. It then checks that the Command that produced the answer
declares the operation's Capability, the user has granted it, and macOS
grants the System Permission it needs. A refusal refuses the whole answer,
as a refused Host Service refuses an invocation: the view keeps its last
good view and state, shows the refusal and the way to repair it, the toast
is not shown, and nothing is requested. For the Action's own first answer,
the Action fails with the refusal.

What the script already did during its invocation, such as a Plugin Storage
write or a synchronous `selection.replace`, is not undone when an answer is
refused. Prefer requesting an operation when its effect should depend on the
answer being accepted.

## What happens next

| Outcome | Meaning |
| --- | --- |
| `succeeded` | The operation completed as it defines |
| `refused` | A check at execution failed, such as a revoked Capability or a changed target; nothing was done |
| `failed` | The effect failed after the Host began it |
| `cancelled` | The request's owner ended before it ran: its view closed, or the Plugin was updated, disabled, removed or lost a Capability |
| `declined`, `expired` | A Host Confirmation was declined or went unanswered; no operation of this revision asks for one |

- The Host checks the Capability, the System Permission, the Plugin and its
  Command, and the target again when it starts the operation.
- The Host shows every outcome other than success in the view, with a repair
  route where there is one, or near the pointer when there is no view or it
  has closed.
- `closes_view` closes the view on `succeeded` only.
- Nothing is retried. A retry is a new gesture.
- A `reason` is the category the same operation fails with wherever it is
  named (`capability_denied`, `system_permission_denied`,
  `automation_permission_denied`, `external_app_missing`,
  `external_app_operation_unsupported` or `host_service_failed`),
  `command_unavailable` when the Plugin or Command is missing, disabled or
  changed, or for `selection.replace` one of the target reasons below. No
  reason names the App.

### `operation_finished`

With `notify: true` the script hears the outcome as a View Event:

```json
{"type": "operation_finished", "operation": "insert", "perform": "selection.replace",
 "outcome": "refused", "reason": "target_changed"}
```

It is delivered only while the View Session exists and the Command and
configuration that requested the operation still handle it; otherwise the
Host shows the outcome and the Plugin does not hear it. It runs before any
gesture that waited for the operation, behind other earlier events, and has
the usual four-second deadline. It is not a gesture, so its answer may update
the view and state but may not request another operation. A result not yet
dispatched when the same Command presents the view again is delivered to
the new view; one already being answered is not delivered again. `reason`
is present for `refused` and `failed` only.

## Busy

A Plugin has at most one operation outstanding: waiting, running, or, with
`notify`, having its `operation_finished` answered. While it is, `submitted`,
`action_chosen` and the Action's start from the Menu wait in order and run
when it finishes, with the state the previous answer committed: two quick
Returns insert twice, in order. Field changes, setting changes and section
deliveries go on as usual, so typing never waits for an insertion. Once an
operation has run for 0.5 seconds, the view shows the operation's own busy
state. No operation of this revision can be cancelled once it has started.

## Ending

Closing the view, updating, disabling or removing the Plugin, revoking a
Capability it uses, or quitting Spinnet cancels an operation that has not
started; the Host says so unless the user closed the view. One that has
started finishes; its outcome is shown by the Host and not delivered. No
operation is ever replayed, and none survives its owner.

## Host Confirmation

Some operations will always ask the user first, in a confirmation the Host
draws with its own words and the target it resolved; a Plugin can neither
skip nor word it, and a Plugin's own "Are you sure?" is an ordinary view
that authorizes nothing. No operation of this revision needs one, and
`host.confirm` stays reserved.

## Insertion

### `selection.replace`

`selection.replace` types its text into the App that is frontmost when the
Host inserts, in place of the selection of that App's focused element. The
Host brings the App to the front (waiting at most one second), waits until
no Spinnet window holds the keyboard, refuses a focused password field, and
posts the text to the App's process as Unicode keyboard events, line breaks
as Shift-Return and tabs as Tab. It never uses the clipboard or a paste.
`succeeded` means every keystroke was posted to that App, not that the Host
read the text back. A line break typed into a terminal runs the line, as
pasting it would.

### Where text goes

In a View Session of a Plugin that declares this revision, every way of
inserting follows the same rule:

| Path | Compared with |
| --- | --- |
| Level 1's standard `insert_text` action in the view | The App its button named when it was pressed |
| A requested `selection.replace` | The App the view named when the user made the gesture |
| A synchronous `selection.replace` call | The App the view named when the user made the gesture that started this invocation |

The Host inserts only if the App it named is the App in front at that
moment. Where Accessibility exposed the element focused in that App when the
user acted, the Host also inserts only if that element is still the one
focused; where it exposed none, as in many web and Electron Apps, the App
alone is compared. Otherwise it writes nothing, refuses with
`target_changed` (a synchronous call fails the invocation with
`insertion_target_changed`, which the script cannot catch), and the name it
shows follows the App now in front. There is no fallback to the App the view
came from or to any other App.

The Host names the App beside each standard insert action and, when the view
sets `shows_insertion_target: true`, in a line it draws in the view, and
keeps the name current while the view is open. The name is shown to the
user only: no view, event, result, failure or environment value given to the
Plugin carries it. A requested or synchronous `selection.replace` goes ahead
only after a gesture made in a view that sets `shows_insertion_target`;
otherwise it is refused with `target_not_shown`.

| Reason | When |
| --- | --- |
| `target_changed` | Another App is in front than the one shown, focus moved to another element of it, or it left the front while the text was typed (then `failed`, with part of the text typed) |
| `target_not_shown` | Nothing showed where the text would go: the Action's start, an event that is no gesture, a view without the target line, or an Action without a view |
| `no_target` | Spinnet or no App is in front, or the App shown has quit |
| `secure_input` | The focused element is a password field |
| `target_unresponsive` | The App did not come to the front within one second (`failed`; nothing was typed) |
| `system_permission_denied`, `capability_denied` | Accessibility or the Capability is missing at execution |

### Without a view

A Command that shows no view has nowhere to show a target, so a
`selection.replace` it requests, or a synchronous `selection.replace` call it
makes, is refused with `target_not_shown` and nothing is written; the Host
shows the refusal near the pointer. To insert, a Plugin shows a view that
names the target first.

### Level 1 Plugins

A Plugin that does not declare this revision keeps Level 1 exactly: its
standard `insert_text` inserts into the App the view came from, and its
`insert_text` Host Service into the App in front. It cannot use `operation`,
`operation_finished` or `shows_insertion_target`, which are unknown members
at Level 1.

## Failure category

`insertion_target_changed`: a synchronous `selection.replace` call inside a
View Session found another App in front than the one the Host showed when
the user acted, or focus moved to another element of it. Nothing was
inserted; the invocation fails as a refused Host Service does; the view
keeps its last good state and the target line updates.

## The helper protocol and the test kit

The invocation names `host_operations` in `candidate_contracts`, which is
how the helper adds this revision's SDK. What the Host showed as the target
never reaches the helper.

In the Plugin test kit, `run.answer()` reads an answer as the Host does, its
`operation` included, refusing one that answers an event that is no gesture.
`PluginTestInvocation(view:)` is the view the user made the event in: a
gesture in a view that sets `shows_insertion_target` is one the Host showed a
target for. `RecordedHostOperations` performs what an answer requested with
recorded outcomes, holds it to the Command's Capabilities and the target
rule, and gives the `operation_finished` event to run next.

## Limits

| Limit | Value |
| --- | --- |
| Operations per answer | 1 |
| Outstanding operations per Plugin | 1 |
| `id` | 64 characters |
| Inserted text | 128 KiB of UTF-8 |
| Target App coming to the front for an insertion | 1 s |
| Operation busy state shown after | 0.5 s |
| Script invocation, gesture or `operation_finished` | 4 s from when the script starts |

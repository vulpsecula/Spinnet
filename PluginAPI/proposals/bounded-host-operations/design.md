# Design: bounded script-requested Host operations

Issue #70, part of #47, governed by spec #68. Proposal only; see the
[README](README.md) for status. Host baseline inspected: `26819a6`.

This document answers #70's acceptance criteria. Sections 3 to 5 define the
request path, section 6 the insertion rules, section 7 the permission
boundaries, section 8 what waits on #69 evidence, and section 11 the product
choices returned to the user. The draft public contract is in
[`reference.md`](reference.md), [`host-operations.schema.json`](host-operations.schema.json)
and [`host-operations.d.ts`](host-operations.d.ts); budgets and the real-App
plan are in [`verification-plan.md`](verification-plan.md).

## 1. Problem

Some operations cannot run inside a script's bounded invocation:

- A trusted Host confirmation (#68: Force Quit, starting a reviewed task)
  waits for the user, and a script has four seconds.
- An operation whose target the Host must own and disclose (the working App
  for insertion or exit) should not hand the target's identity to the
  Plugin just because the Plugin asked to act on it.
- Some effects should happen only if the answer that asked for them is
  accepted. A future dirty-navigation refusal, for example, must discard
  both the answer and the operations it asked for (agreed in the 2026-10-01
  convergence, ADR 0016).

Level 1 already has one workaround: `capture_screen` returns once the capture
starts, because an interactive capture outlasts the deadline. This design
turns that one-off into a general path. A script *requests* an operation in
its answer, and the Host performs it after the invocation ends.

## 2. Baseline: what the Host does today

Read from the code at `26819a6`:

| Behaviour | Where | Consequence for this design |
| --- | --- | --- |
| A scripted Action and each View Event has a 4 s deadline, starting when the script starts, not while it waits for the Plugin's helper queue | `ScriptedActionBudgets.actionDeadline`, `PluginViewSession.started` | A confirmation cannot happen inside the script; the operation must outlive the invocation |
| One invocation at a time per Plugin; events queue in order; field changes coalesce after 100 ms | `PluginViewSession.send/enqueue/dispatchNext` | The session queue is where busy behaviour is enforced |
| An answer is `{view, state}`, `{close}`, `null`, each optionally with `toast`; any other member is a protocol violation that ends the session | `PluginScriptAnswer(parsing:)` | A new answer member is only legal under a declared candidate; Level 1 Plugins keep the strict parser |
| Every answer carries a generation; answers for an older generation are dropped | `PluginViewSession.receive` | Requests inherit the generation check: an answer that is dropped requests nothing |
| A failed event (refusal, timeout, crash, script error) keeps the view and the last good state; a protocol violation ends the session | `PluginViewSession.receive` | Commit refusals reuse the "keep last good state, show inline error" path |
| Presenting again (`replace`) drops in-flight and queued events of the old view | `PluginViewSession.replace/abandonEvents` | Requests must be owned by the session, not by a page, so a replace does not orphan an executing operation |
| Standard `insert_text` inserts into `origin`, the App frontmost when an Action last *presented* the view, through `AXUIElementCreateApplication(pid)` | `PluginViewWindows.present`, `main.swift` `insertText: { text, origin in … }` | Level 1 standard path; retained unchanged |
| The `insert_text` Host Service inserts into the system-wide focused element | `AppKitPluginHostServiceProvider.insertText(_:)` | Level 1 script path; inside a View Session it may resolve to the panel's own field (to be verified); retained unchanged for Level 1 |
| Insertion is Accessibility only: settable `AXSelectedText`, no paste, no clipboard | `insertText(_:into:)` | No new clipboard behaviour is introduced here |
| Standard actions are authorized by the broker's own check against the session's committed Action | `PluginViewHostActions.perform`, `HostServiceBroker.authorize` | Requested operations reuse the same authorization function |
| Closing, Plugin update/disable/removal and revocation end the session and cancel its events and sections | `PluginViewSessions.observe`, `end` | Pending requests are cancelled by the same observers |

## 3. Vocabulary used here

- **Requested Host operation** (proposed glossary term, section 12): an
  operation a script asks the Host to perform after its invocation ends,
  by naming it in its answer. The Host owns its confirmation, target,
  execution and outcome.
- **Gesture**: a user interaction that may lead to an operation. In this
  candidate, exactly: the Action's start (a Menu invocation or, once #68's
  repeated calls exist, an explicit repeated call), `submitted` and
  `action_chosen`. Not `field_changed`, `setting_changed`,
  `settings_swapped`, `section_delivered` or `operation_finished`.
- **Commit**: the moment the Host accepts an answer and applies all of it.
- **Outcome**: the single terminal result of a request: `succeeded`,
  `refused`, `declined`, `cancelled`, `failed` or `expired`.
- **Displayed insertion target**: the App whose name the Host shows as where
  insertion will go, at the moment of the gesture.
- **Insertion target**: the App that is frontmost when the Host inserts.

## 4. The request path

### 4.1 How a request is made

A script requests an operation with an `operation` member on its answer:

```js
// Emoji, answering Return on its search form.
ui.show(view, { state, operation: ui.insertTextOperation({ id: "insert", text: "😀", closesView: true }) });
```

Rules:

1. **At most one operation per answer.** Ordering, partial failure and
   confirmation of several operations in one answer have no workload that
   needs them: Emoji inserts one string, Current App quits one App, Brew
   starts one task. A later revision can add a list without breaking this
   one.
2. **Only an answer to a gesture may request an operation.** An answer to any
   other event that has an `operation` is a protocol violation and ends the
   session. Typing, fetched sections and results therefore never cause an
   effect by themselves, and a script cannot loop by answering
   `operation_finished` with another request. One gesture yields at most one
   operation.
3. `operation` may accompany a view, a toast, or neither (an Action without
   a view may request one, as when a Menu Item inserts directly). It may not
   accompany `close: true`; an operation that should close the view on
   success says `closes_view: true` instead, so a refused insertion keeps the
   view open to show the updated hint.
4. Members common to every kind are `kind`, an optional Plugin-chosen `id`
   (at most 64 characters, echoed in the result, never interpreted),
   `closes_view` and `notify`. Each kind adds its own input members. Unknown
   members, unknown kinds and kinds the Plugin's candidate revision does not
   include are protocol violations.

The synchronous `requestHostService` path stays for services that complete
within the invocation. A kind that needs confirmation or a Host-owned target
is offered only as a requested operation, never as a synchronous service.
Insertion is the one kind offered both ways, because Level 1 already offers
it synchronously and the convergence agreed to keep that path (section 6.4).

### 4.2 Ownership

Every request records, at commit:

| Field | Meaning |
| --- | --- |
| Plugin | From the helper connection, never from the message (as for Host Services) |
| Requesting Action | The complete configured Action whose invocation produced the answer, with its effective input. This is the authority the request runs under. It is not the session's handler, and not whichever Command handles the view later |
| Owner | The View Session the answer belongs to (an existing one, or the one this answer creates). Without a view: the Action's own lifecycle |
| Gesture | The gesture event, and the displayed insertion target captured when the user made it (section 6.2) |
| Host request ID | Generated by the Host, never shown to the Plugin, used to drop stale completions |
| Plugin `id` | Echoed in the result only |

Ownership is per session, not per page or per handler. A later view replacing
the page, or another Action presenting into the same session, does not cancel
an operation that was already committed. The rules for delivering its result
then decide whether the Plugin hears about it (section 4.7).

### 4.3 Atomic answer commit

An answer is committed as a whole or not at all: handler (once #68's handler
rule exists), view, state, toast and the operation request.

Before commit the Host checks, in order:

1. The answer's generation is current (Level 1 rule; a dropped answer
   requests nothing).
2. Shape: the answer, view and operation are valid for the Plugin's declared
   Level and candidate revision. Failure is a protocol violation and ends the
   session, as in Level 1.
3. The event was a gesture (rule 4.1.2). Failure is a protocol violation.
4. Authority: the requesting Action's Command declares the operation's
   Capability, the user has granted it within scope, and the System
   Permission the kind needs is present. Failure refuses the *whole answer*
   exactly as a refused Host Service refuses an invocation in Level 1: view
   and state stay at the last good ones, the view shows the inline error and
   its repair route, nothing is requested.
5. Kind-specific pre-checks that need no target, for example the 128 KiB text
   limit for insertion (a protocol violation, as a too-long standard action
   is today).

If all pass, the Host applies view, state and toast and enqueues the request
in the same executor turn. No other event can observe the view without the
request or the request without the view.

What commit does **not** undo: Host Service effects the script already caused
during its invocation (Plugin Storage writes, a synchronous `insert_text`).
They happened before the answer existed, as in Level 1. This is why the
deferred path is preferred when an effect should depend on the answer being
accepted.

A future dirty-navigation refusal (ADR 0016) is a refusal at commit: it
discards the answer *and* its request, and completed service effects are not
rolled back.

### 4.4 Lifecycle

```text
                  commit
  (answer) ──────────────► pending ──► confirming ──► executing ──► succeeded
                              │            │              │       ├► refused
                              │            │              │       └► failed
                              │            ├► declined     └► cancelled (only kinds that allow it)
                              │            └► expired
                              └► cancelled (owner ended)
```

- **pending**: committed, waiting for the operation slot (section 4.8) or,
  for most kinds, starting at once.
- **confirming**: the kind requires a Host confirmation and it is on screen.
- **executing**: the Host is performing it. Authority and target are checked
  again at the start of this state (section 4.6).
- Each request reaches exactly one outcome, and that outcome is reported at
  most once.

### 4.5 Confirmation

There are two kinds of confirmation, and they are separate mechanisms:

- **Host confirmation** (this design): trusted, required by the operation
  *kind*'s policy, never optional for the Plugin and never skippable by it.
  The Host draws it, inside the Plugin's panel when there is a view and near
  the pointer when there is not, without activating Spinnet, so the working
  App stays frontmost. Its text is Host-generated from the kind and its
  Host-resolved target ("Force Quit Safari? Unsaved changes in Safari will
  be lost."). In this proposal no Plugin-supplied text appears in it
  (product choice P5).
- **Plugin business confirmation** ("Clear all favourites?"): an ordinary
  view the Plugin draws, carrying no authority. README's Level 1 candidate
  "Confirmation" is this kind and is out of scope here.

Whether a kind needs Host confirmation is decided by its definition, not by
the Plugin:

| Kind | Host confirmation |
| --- | --- |
| `insert_text` | None. The gesture is the consent, and the target name is already on screen |
| `quit_app` (illustrative, #83) | Proposed: none for a graceful quit, which the App can refuse or turn into its own save prompt; required for Force Quit (P4) |
| `start_task` (illustrative, reviewed tasks) | Required: shows the Host's description of the reviewed operation and its source |

While a confirmation is on screen the view's own controls are inert; Escape
or Cancel declines; closing the view declines. Defaults are proposed in P4.

### 4.6 Refusal, decline, cancellation and expiry

| Outcome | When | Effect performed? |
| --- | --- | --- |
| `refused` | At execution start: the Capability was revoked or narrowed, the System Permission is gone, the Plugin or Command is unavailable, or the target is invalid (changed, gone, protected, not accepting the operation) | No |
| `declined` | The user declined a Host confirmation, or closed the view while it was shown | No |
| `expired` | A confirmation was left unanswered past its expiry (proposed 60 s, P8) | No |
| `cancelled` | The owner ended before execution (view closed, session ended by update/disable/removal/revocation, Host quitting), or the user cancelled an execution that the kind allows to be cancelled | No, or "may still take effect" for kinds whose effect cannot be withdrawn once sent (stated per kind) |
| `failed` | The effect itself failed after the Host began it (the App rejected the text, the task could not start) | Possibly partially, stated per kind |
| `succeeded` | The effect completed as the kind defines it | Yes |

Cancelling is never rollback (ADR 0017). A refused or failed operation is
never retried by the Host; a retry is a new gesture.

### 4.7 Result delivery

The Host always shows the outcome itself where the user is looking:

- with a view: an inline status for failures and refusals (the same place a
  refused standard action shows, with its repair route), and the updated
  insertion hint for `target_changed`; nothing extra for success, which the
  user can see. `closes_view: true` closes the view on `succeeded` only.
- without a view, or after the view has closed: Host feedback near the
  pointer for every outcome other than `succeeded` and `cancelled`-by-close.

The Plugin hears about the outcome only when it asked (`notify: true`), and
only while both of these still hold when the event is dispatched:

1. the owning session still exists, and
2. its current handler is the requesting Action: the same Command with the
   same configuration. If another Command took over the session, the result
   is not delivered, so that Commands do not combine authority through
   shared state (#68).

The Host queues `operation_finished` ahead of any gesture that is waiting
for the operation slot (section 4.8), so the requesting Action answers its
own result before the next gesture runs:

```json
{"type": "operation_finished", "operation": "insert", "kind": "insert_text",
 "outcome": "refused", "reason": "target_changed"}
```

It is an ordinary invocation with the four-second deadline, queued behind
earlier events. It is not a gesture, so its answer may update the view and
state but request no operation. Under #68's page rules it is delivered like a
persisted Settings notification: it does not depend on the page that
requested it still being shown. It never carries the target's name, bundle
ID, process or window. Kind-specific result members are allowed when the
Plugin is entitled to them. `start_task`, for example, may return the opaque
task handle the reviewed-task ticket defines.

Without `notify`, a Plugin that wants to record success (Emoji's recent list)
writes it on the gesture, accepting that the insertion may then be refused,
or asks for `notify` and pays one more invocation (budget in the
verification plan).

### 4.8 Busy behaviour

- **One outstanding operation per Plugin.** "Outstanding" covers pending,
  confirming and executing, and, when the request set `notify`, the
  invocation that answers its `operation_finished`. The slot is free once
  that invocation ends, whether it answered, failed or timed out.
- **While one is outstanding, gesture events wait.** They stay in the
  session queue in order and are dispatched when the slot is free. The next
  Return therefore runs with the state the previous answer (or the answer to
  its `operation_finished`) committed, and two quick Returns insert twice,
  in order, each checked against the target at its own execution.
  Because explicit calls also wait, the handler normally cannot change
  between a request and its result; the handler check in section 4.7 guards
  the remaining cases, such as a Level 1 style presentation replacing the
  session's Action.
- **Non-gesture events keep flowing.** `field_changed`, `setting_changed`,
  `settings_swapped`, `section_delivered` and `operation_finished` dispatch
  as usual, so typing in a search field is never blocked by an insertion or a
  pending confirmation.
- The view shows the Host's operation busy state, distinct from the event
  busy state, once execution has run for 500 ms, mirroring ADR 0007's
  progress delay. For a kind that allows cancellation it offers Cancel.
- An explicit repeated call that arrives while a confirmation is on screen is
  a gesture and waits behind it (P7).

Rejected alternative: refusing a second request with a "busy" error. It
discards a whole answer the user caused, and it makes a fast double Return
lose the second insertion.

### 4.9 Deadlines

| Span | Bound | Status |
| --- | --- | --- |
| Script invocation, gesture or result event | 4 s from when the script starts | Level 1, unchanged |
| Commit to execution start, no confirmation, slot free | Same executor turn; measured, not a timer | To measure |
| Pending in the queue behind another operation | Bounded by that operation's own bounds | Derived |
| Confirmation on screen | Proposed 60 s, then `expired` | P8 |
| Insertion execution (Accessibility messaging) | Proposed 1 s messaging timeout, then `failed` with `target_unresponsive` | To measure (#69) |
| Graceful quit wait (illustrative) | Defined by #83 | #83 |
| Task start (illustrative) | Covers starting only; the task's own lifetime belongs to the reviewed-task tickets and ADR 0017 | Owned elsewhere |

No helper is kept alive across a confirmation or an execution. The helper may
idle out and retire while an operation waits; `operation_finished` cold-starts
it like any other event.

### 4.10 Stale and late results

| Situation | Result |
| --- | --- |
| The answer's generation is stale (the session moved on, timed out, was replaced) | Dropped; no request exists |
| The session ends while the request is pending or confirming | `cancelled`, not executed. Host feedback when the end was not the user's own close: update, disable, removal, revocation |
| The session ends while executing | The execution finishes (an Accessibility write cannot be withdrawn); the outcome shows as Host feedback; nothing is delivered |
| Revocation between commit and execution | The revocation ends the session, which cancels the request (above). Execution's own authority check covers the race where revocation lands during execution start |
| Handler changed to another Command before the result is ready | Outcome shown by the Host, not delivered |
| Helper retired or crashed after commit | Irrelevant to execution; the result event starts a new helper |
| A completion arrives for a Host request ID that is no longer current (Host-internal race) | Ignored |
| Host quits | Pending and confirming requests are cancelled; executing insertion completes or is abandoned by the process exit; nothing is restored at the next launch |

No outcome is ever replayed, and no request survives its owner. This matches
ADR 0007 ("a retired helper's work is never replayed") and #68 ("no replay").

## 5. Insertion compared with mutating operations

The same shape has to serve insertion, quitting the working App, and starting
a reviewed task. Working all three through:

| Aspect | `insert_text` | `quit_app` (illustrative, #83) | `start_task` (illustrative, reviewed tasks) |
| --- | --- | --- | --- |
| Typical gesture | Return on a result; an insert button | "Quit" / "Force Quit" action | "Install" on a selected package |
| Input | `text` ≤ 128 KiB | `target: "frontmost"`, `force: bool` | Reviewed profile operation and its bounded arguments |
| Target | Frontmost App at execution, Host-resolved | The working App, Host-resolved: frontmost at gesture, re-validated by identity at execution | No App target; a reviewed tool profile |
| Disclosure | Host hint, Host-only | Host confirmation (Force Quit) or hint (Quit) | Host confirmation with Host description and source |
| Confirmation | None | Force Quit: required | Required |
| Capability | `insert_into_focused_app` + Accessibility (existing) | New, defined by #83; separate from identity reads | New, defined by the reviewed-task tickets |
| Cancellable while executing | No (atomic write) | Waiting for exit can stop; the quit request itself cannot be withdrawn | Starting: no; the started task is cancelled through ADR 0017's activity controls |
| Success means | The App accepted the write (see section 8 for whether "accepted" means "inserted") | The App exited within the wait | The task started; its completion is not this request's outcome |
| Result payload to Plugin | None beyond outcome | None beyond outcome; no PID, no name | Opaque task handle, if the task ticket defines one |
| Outlives the view | No | No | Yes, the task does; the request does not |

What is generic: commit, ownership, gesture binding, one outstanding
operation, the lifecycle and its outcomes, Host confirmation as a per-kind
policy, execution-time authority re-check, result delivery, stale handling.

What each kind defines: input members, target resolution and validation,
whether it confirms and what the confirmation says, its execution bound,
whether it can be cancelled, what success means, and any result members.

The deletion test (ADR 0009): no part of the generic path mentions emoji,
Apps, tasks or a Plugin ID. Removing Emoji, Current App or Homebrew would
leave the generic path unchanged.

## 6. Insertion under the candidate

### 6.1 Target resolution

At execution the Host reads the frontmost application
(`NSWorkspace.frontmostApplication`). The insertion target is that App,
identified by process ID, bundle identifier and launch date together, so a
reused process ID cannot match. The Host writes into *that App's* focused UI
element (`AXUIElementCreateApplication(pid)` → `AXFocusedUIElement` →
settable `AXSelectedText`), never the system-wide focused element, which may
be the panel's own field.

The Host refuses, without writing, when:

- Spinnet itself is frontmost (its Settings or Clipboard History window), or
  no App is: `no_target`;
- the target is not the displayed target (section 6.3): `target_changed`;
- the App has no focused element with a settable selection: `no_text_input`
  *(category waits on #69)*;
- the focused element is a secure text field: `secure_input` *(proposed;
  needs a user decision, P9)*.

There is no fallback to the App the view came from, to the most recent
non-Spinnet App (Clipboard History's rule), or to a field in the panel.

### 6.2 Displayed target and Host-only disclosure

While a candidate view is open, the Host keeps a current insertion target,
updated from frontmost-App activation notifications. It shows the name:

- on every standard `insert_text` action button: "Insert into Notes", or the
  action title with the App as a secondary label (P1);
- in a Host-drawn target line, when the view sets
  `shows_insertion_target: true`, for views whose gestures may lead to an
  answer-requested or synchronous insertion (Emoji's search form).

The name, icon and identity are Host data. They never appear in the view
description, an event, a result or `spinnet.environment`, and a view cannot
style or reposition them except by choosing whether the line is shown.
VoiceOver reads the hint as part of the action's label or as the line's own
label. A Plugin that needs to know the App, for example to branch per App,
needs the separate identity-read Capability (section 7), which this design
does not add.

When the user makes a gesture, the Host captures the displayed target, the
one the user could see, with the gesture. If the view showed no target
(neither an insert action was the gesture, nor `shows_insertion_target` was
set), the capture is "none shown".

### 6.3 Refuse and update the hint

At execution:

- displayed target captured and equal to the insertion target: insert;
- displayed target captured and different: refuse with `target_changed`,
  write nothing, update the hint to the real frontmost App (it normally
  already shows it, because the change that caused the mismatch also updated
  the hint), and show the inline refusal "Spinnet showed Notes, but TextEdit
  is in front. Nothing was inserted."; the user presses again to insert into
  the App now shown;
- no target shown, from a view: refuse with `target_not_shown`. A candidate
  view must show where text goes before it may insert;
- no target shown, from an Action without a view: see section 6.5.

A gap between the hint and the actual frontmost App can only come from an
activation the Host has not yet processed, or one that happens between the
gesture and execution. Both end in a refusal, never in text written to an App
the user was not shown.

### 6.4 The three candidate paths agree

| Path | When the target is resolved | Compared with |
| --- | --- | --- |
| Standard `insert_text` action | When the Host performs it, immediately on the click or key | The target shown on that button when it was pressed |
| Answer-requested `insert_text` operation | At execution, after commit | The target shown when the gesture was made |
| Synchronous `insert_text` Host Service in a View Session invocation | When the service runs, inside the invocation | The target shown when the gesture that started this invocation was made |

All three use section 6.1's resolution and refusals, so expressing the same
insertion a different way never changes where it goes (#68 user story 13).

The synchronous path has two extra rules under the candidate:

- it is refused (`target_not_shown`) in an invocation that answers a
  non-gesture event, since no gesture exists to carry a displayed target;
- a `target_changed` refusal fails the invocation as a refused Host Service
  does in Level 1 (the script cannot catch it and carry on), the view keeps
  its last good state, and the hint updates. A new failure category,
  `insertion_target_changed`, names it (P10 asks whether it should be a
  category or a message under `host_service_failed`).

Its effect is not part of the answer and is not undone if the answer is then
refused. The reference recommends the requested path for new Plugins.

### 6.5 Outside a View Session

A Command with no view may insert synchronously or by request (a Menu Item
"Insert today's date"). No hint exists on the radial Menu. The proposed rule
captures the frontmost App when the Menu Action starts and refuses if a
different App is frontmost at execution. Whether that is enough disclosure,
or whether a viewless insertion should need something more, is product
choice P2.

### 6.6 Level 1 paths, retained

| Level 1 path | Behaviour kept for Plugins that do not declare the candidate |
| --- | --- |
| Standard `insert_text` action | Into the `origin` App, captured when an Action last presented the view, via its focused element |
| `insert_text` Host Service | Into the system-wide focused element |
| `clipboard.paste` Host Command | Unchanged |
| Clipboard History paste | Its own rule (most recent non-Spinnet App), unchanged; it is a Host Surface |
| Window Position services | Unchanged; their own "window last read" rule |

The rules are chosen by declaration, not per call. A Plugin declaring the
candidate gets the candidate rules on every path in its View Sessions; a
Level 1 Plugin running on a candidate Host gets exactly Level 1. Declaring
Level 1 never exposes a Plugin to `operation`, `operation_finished` or
`shows_insertion_target`; to a Level 1 Plugin they remain unknown members.

### 6.7 Limits of an App-level target

The target is an App, not a window or field. If the user moves focus to
another window or field *inside the same App* between gesture and execution,
the insertion goes to the newly focused field and is not refused. A window-
or element-level check would need the Host to remember an Accessibility
element across the gesture, which `set_focused_window_frame` already does for
windows. Whether that is worth adding depends on #69's evidence about how
often it matters and how reliably elements compare (section 8).

## 7. Permission boundaries

- **Insertion** keeps `insert_into_focused_app` plus Accessibility. Showing
  the target name to the *user* is Host UI and needs no Capability, because
  the Plugin learns nothing from it.
- **Reading App identity** (name, bundle ID, icon of the frontmost App) is a
  separate future Capability, README's Level 1 candidate "The frontmost
  application", owned by #83. Neither insertion nor quitting implies it.
  The outcome reasons this design returns (`target_changed`, `no_target`)
  name no App. A Plugin can still infer from success or failure that
  *something* changed, which is the same coarse signal a refused Level 1
  standard action already gives.
- **Quitting the working App** needs its own Capability with its own consent
  (#83), distinct from the identity read, and Force Quit is a separately
  disclosed operation within it.
- **Starting a reviewed task** needs the reviewed-tool Capability its ticket
  defines; the Host confirmation does not replace consent.
- **No paste or clipboard capability is added.** Insertion never writes,
  reads or restores the clipboard and never synthesizes ⌘V. If #69 shows that
  Accessibility insertion fails for target Apps that matter, the options go
  back to the user (P3). The user asking for "insert" is not consent to a
  clipboard-based mechanism.
- **Requested operations carry no authority of their own.** Authority comes
  from the requesting Action, is checked at commit, and is checked again at
  execution. A Host confirmation is the user approving one specific
  operation on one specific target. It is not a grant.

## 8. What waits on #69 evidence

These are deliberately not frozen. #76 must not freeze its Host build for E2
before they are settled with evidence.

1. **Supported insertion scope.** Which Apps and control types accept
   `AXSelectedText` writes (native AppKit, WebKit, Chromium, Firefox,
   Electron, terminal emulators, IME composition active). The candidate's
   reference will either name a supported scope or say "best effort" with
   documented failures, depending on the evidence.
2. **Success semantics.** Whether `AXUIElementSetAttributeValue` returning
   success reliably means text appeared, notably in web content and
   Electron. If not, whether the Host reads the value back to verify, and
   what `succeeded` then promises.
3. **Failure reasons.** The final enumeration of `reason` for `insert_text`
   (`no_text_input`, `text_rejected`, `target_unresponsive`, and whatever the
   evidence shows is distinguishable). The schema's list is provisional.
4. **App-scoped focus versus system-wide focus.** Whether
   `AXUIElementCreateApplication(frontmost)` → `AXFocusedUIElement` finds the
   right element while the non-activating panel is key, pinned and unpinned.
   The Level 1 standard path relies on the same call; its behaviour across
   Apps has not been recorded.
5. **Chromium/Electron accessibility activation.** Some Chromium-based Apps
   expose their tree only to assistive clients that ask
   (`AXManualAccessibility`, `AXEnhancedUserInterface`). Setting such an
   attribute changes the target App's behaviour. Whether the Host may do so
   is a product decision if the evidence shows it is needed (P3).
6. **Element-level target checks** (section 6.7).
7. **The 1 s messaging timeout**, from measured latencies of slow targets.
8. **Secure fields**: whether Apps let Accessibility write into secure text
   fields at all, which decides whether `secure_input` is a refusal or simply
   never reached.

The design does not depend on any of these for the request path itself
(sections 4 and 5), which can be implemented and tested at the test-kit seam
before #69 completes.

## 9. Public contract summary

Draft, in [`reference.md`](reference.md) and the schema:

- answer member `operation` (`insert_text` kind in this revision);
- View Event `operation_finished`;
- view member `shows_insertion_target`;
- candidate semantics for the standard `insert_text` action and the
  `insert_text` Host Service inside View Sessions;
- failure category `insertion_target_changed` (P10);
- `spinnet.ui` builder `insertTextOperation`, an `operation` option on
  `show`, and `ui.request(operation)` for an answer with no view. Proposed
  only; `spinnet.js` is unchanged.

`quit_app` and `start_task` appear in the schema under
`$defs/illustrative` only, to show that the generic members hold for a
mutating kind. They are not in the `kind` enum and are not proposed by this
revision.

## 10. Test seams and fixtures

Primary seam: an external package with the pinned test kit and the real
helper (#68). The proposal needs these test-kit additions, which #76
implements:

- `run.answer().operation`, read the way the Host reads it (shape and
  gesture rule), so a Plugin can assert what it requested;
- a recorded-operation outcome to feed back as `operation_finished`, in the
  style of `RecordedHostFetchedSections`;
- refusal of `operation` from an answer to a non-gesture event and from a
  Level 1 declaration, with the Host's protocol-violation message.

[`fixtures/`](fixtures/) holds valid and invalid answers and events, which
`check.py` validates against the draft schema, and behaviour scenarios
(`fixtures/scenarios/`) written as given/when/then steps. The scenarios are
the cases #76's Host tests and test-kit tests should cover: commit
atomicity, gesture rule, busy ordering, owner end before and during
execution, handler change, revocation, target change on each path, Level 1
retention, and the illustrative mutating kinds. They describe external
behaviour, not implementation structure.

Real-App behaviour (target, focus, IME, Accessibility results) cannot be
proved by fixtures; [`verification-plan.md`](verification-plan.md) lists
what must be run on the actual Host.

## 11. Product choices returned to the user

None of these is decided by this design. Each has a proposed default so that
#76 can start, and the user may overrule any of them.

| # | Question | Proposed default | Why it is a product choice |
| --- | --- | --- | --- |
| P1 | Where does the insertion target name appear: in each insert button's title ("Insert into Notes"), as a secondary label, or only in a footer line? Are insert controls disabled when no valid target exists (Spinnet frontmost)? | Secondary label on each insert action plus the optional target line; controls stay enabled and refuse with `no_target` | Visible UX of every inserting Plugin |
| P2 | May a Command without a view insert (Menu Item → text appears) when nothing showed the target? | Yes, with the frontmost App captured at Menu invocation and re-checked at execution | Disclosure standard differs from views |
| P3 | If #69 shows Accessibility insertion failing in important Apps: accept a documented narrower scope with Copy as the fallback the user chooses; add a reviewed paste-style insertion Capability (clipboard write, ⌘V, restore rules); or let the Host switch on Chromium/Electron accessibility | Undecided. Wait for #69 evidence; no clipboard or paste behaviour until the user chooses | New permission or behaviour toward other Apps |
| P4 | Which operations need Host confirmation, and how: Quit (none?) vs Force Quit (always); default button; whether Return confirms a destructive operation; any "don't ask again" | Quit: none. Force Quit and task start: always. Default button Cancel; Return does not confirm destructive kinds; no "don't ask again" | Trust and friction |
| P5 | May Plugin text appear in a Host confirmation (for example a reason line)? | No, Host text only | A Plugin could word it to mislead |
| P6 | Should the Host announce a refused insertion beyond the inline message (sound, panel flash)? | Inline message only, plus VoiceOver announcement | UX |
| P7 | An explicit repeated call while a Host confirmation is open: wait behind it, or decline the confirmation and run? | Wait | Which action the user meant |
| P8 | Confirmation expiry | 60 s | How long a pinned panel may hold a stale confirmation |
| P9 | Refuse insertion into secure text fields even when the App allows it | Refuse | Password-field safety versus utility (password generators) |
| P10 | Target change on the synchronous path: a new failure category `insertion_target_changed`, or `host_service_failed` with a message | New category | Category names are stable, user-facing contract |
| P11 | Should a request from `field_changed` ever be allowed (for example "insert as you type")? | No | Typing would then have effects in another App |

## 12. Proposed ADR and glossary text

### Proposed ADR 0018: Execute script-requested Host operations after the answer commits

> **Status: proposed (#70), not implemented.**
>
> Some operations a Plugin needs cannot complete inside a bounded script
> invocation: they wait for a trusted Host confirmation, or act on a target
> the Host must own and disclose. A script therefore requests such an
> operation in its answer, and the Host performs it after the invocation
> ends. The answer and the request commit together or not at all; only an
> answer to a user gesture (the Action's start or an explicit call,
> `submitted`, `action_chosen`) may request one, and it may request at most
> one. The request runs under the authority of the Action that produced it,
> which the Host checks at commit and again at execution. A View Session
> owns its requests: ending the session cancels any not yet executing, and
> nothing is replayed. Each Plugin has at most one outstanding operation;
> gesture events wait behind it while other View Events continue. Each
> request reaches exactly one outcome (succeeded, refused, declined,
> cancelled, failed, expired), which the Host shows, and which it delivers
> to the Plugin as an `operation_finished` View Event only when asked and
> only while the requesting Action still handles the session.
>
> Whether a kind of operation needs Host confirmation is part of that kind's
> definition and cannot be skipped by a Plugin. Host confirmations are drawn
> by the Host with Host-generated text and Host-resolved targets, without
> activating Spinnet, and are distinct from a Plugin's own business
> confirmation views.
>
> Under the first new UI contract, insertion is the first kind. Every
> insertion path in a View Session (the standard action, the requested
> operation and the synchronous `insert_text` service) inserts into the App
> frontmost at the moment of insertion, through that App's focused element.
> The Host shows that App's name and keeps it current; the name is never
> given to the Plugin. If the App the Host showed when the user acted is not
> the App in front at execution, the insertion is refused, nothing is
> written and the hint updates. There is no fallback to the view's origin,
> to the most recent external App, or to the panel. Level 1 Plugins keep
> every Level 1 insertion path. No clipboard or paste mechanism is part of
> this decision; one would need evidence and a separate user decision.
>
> **Considered options.** Synchronous confirmation inside the script was
> rejected: it cannot fit the four-second deadline and would hold a helper
> for as long as a dialog is open. A resident helper awaiting the result was
> rejected by ADR 0004 and ADR 0010. Several operations per answer and
> refusing a second request as busy were rejected for this candidate for
> lack of a workload and because they lose user actions; a later revision
> may add a list.
>
> **Consequences.** Kinds such as App exit (#83) and reviewed task start add
> only their input, target, confirmation policy, bounds and result members.
> Supported insertion scope, success semantics and failure reasons are
> settled from #69's recorded evidence before the E2 Host is frozen.

### Proposed CONTEXT.md additions

**Requested Host Operation**:
An operation a script asks the Host to perform after its invocation ends, by
naming it in its answer to a user gesture; the Host checks authority,
confirms when the kind requires it, resolves the target, performs it and
reports one outcome.
_Avoid_: Callback, deferred Host Service, async call

**Host Confirmation**:
A trusted confirmation the Host draws, with its own text and the target it
resolved, before performing an operation whose kind requires it; a Plugin can
neither skip nor word it.
_Avoid_: Confirmation dialog (for a Plugin's own view), alert, consent

**Insertion Target**:
The App that receives inserted text: under the first new UI contract, the
App frontmost when the Host inserts, whose name the Host shows and never
gives to the Plugin.
_Avoid_: Origin App, recent App, focused App (when the panel is meant)

## 13. Notes for #76 (Host touchpoints)

Not public contract; recorded so the implementation does not rediscover
them.

- `PluginScriptAnswer(parsing:)` gains `operation` only for a candidate
  declaration (#75's runtime member checks).
- `PluginViewSession.receive` is where commit happens; the gesture check
  needs the in-flight event, which it already holds. The pending operation
  slot and the "gesture events wait" rule belong to `dispatchNext`.
- `PluginViewSession.abandonEvents` (replace) must not cancel a committed
  operation; `end` must.
- `PluginViewSessions.actionAnswered` is the commit point for the Action's
  first answer and for viewless requests.
- `PluginViewWindows.present` currently captures `origin` on presentation;
  candidate sessions need a live current target instead, observed from
  `NSWorkspace.didActivateApplicationNotification`, and the gesture-time
  capture in `PluginViewModel.submit/choose`.
- `AppKitPluginHostServiceProvider.insertText(_:intoApplication:)` already
  inserts into one App's focused element; the candidate path adds the
  identity comparison and the messaging timeout, and runs off the main
  thread so a slow target cannot stall the UI.
- `PluginViewHostActions.perform` and the broker's `authorize` are reused for
  both commit-time and execution-time authority.

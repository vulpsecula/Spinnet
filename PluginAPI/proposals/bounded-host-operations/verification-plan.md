# Budgets and real-App verification plan

Proposal for #70; executed by #76 (insertion) and #83 (App exit). Nothing
here has been run. Every number marked *to measure* is a starting target to
check with recorded samples, not a promise. Existing budgets are not raised
silently (#68).

## 1. Budgets

### Existing budgets that must still hold

| Budget | Value | Source |
| --- | --- | --- |
| Script invocation deadline, per gesture or `operation_finished` | 4 s | ADR 0007, `ScriptedActionBudgets.actionDeadline` |
| Helper message | 1 MiB | ADR 0007 |
| View state / view description | 64 KiB / 256 KiB | ADR 0010 |
| Typing pause to view update, p95 | 150 ms warm, 300 ms cold | ADR 0010 |
| Active helper incremental `phys_footprint`, p95 | 6 MiB | ADR 0007, ADR 0010 |
| Helper idle exit | 30 s (+0.25 s) | ADR 0007 |
| Post-teardown Host growth, p95 | 512 KiB | ADR 0007 |
| Inserted text | 128 KiB | Level 1 `insert_text` |

Requested operations must not keep a helper alive: confirmation and
execution happen with no invocation running. The measurement re-checks the
helper's idle exit with an operation pending.

### New budgets proposed

| Measurement | Proposed target | How |
| --- | --- | --- |
| Commit to execution start (no confirmation, slot free) | p95 ≤ 5 ms | Host-internal timestamps in the measurement target; logged, not user-visible |
| Gesture to text inserted, requested path, warm helper, `notify` off | p95 ≤ 150 ms (same as the typing budget) | Extended `script/measure_view_sessions.sh` against a fixture target App that timestamps `AXValueChanged` |
| Same, cold helper | p95 ≤ 300 ms | As above, helper retired first |
| Extra cost of `notify: true` | One View Event round trip: report warm/cold p50/p95/max, no new target | Measured, then decide whether Emoji uses it |
| Accessibility write bound | 1 s messaging timeout | From #69 latencies: choose ≥ 3× the slowest observed successful write, report if that exceeds 1 s |
| Host memory per outstanding operation | Under the existing 512 KiB post-teardown budget after 200 operations | Same harness |
| Confirmation expiry | 60 s | Product choice P8, not a measurement |

All measurements keep every sample and report p50, p95 and max, on the
reference machine with its load recorded, like W13 (ADR 0010).

## 2. Protocol and test-kit checks (no real App)

Run through the external package seam with the pinned test kit, plus Host
session tests for what the test kit cannot see. Each item maps to a fixture
scenario in [`fixtures/scenarios/`](fixtures/scenarios/).

- Answer shapes accepted and refused exactly as the schema says
  (`check.py`, then the same fixtures in the Swift schema tests).
- Gesture rule: an operation from `field_changed`, `setting_changed`,
  `settings_swapped`, `section_delivered` or `operation_finished` ends the
  session.
- Commit atomicity: a refused Capability leaves view, state and toast at the
  last good ones and requests nothing.
- Busy: two quick `submitted` events produce two operations, in order, the
  second dispatched after the first's outcome; `field_changed` is not
  delayed.
- Owner end before execution (close, update, disable, removal, revocation):
  `cancelled`, effect not performed, nothing delivered, feedback when not the
  user's own close.
- Owner end during execution: effect completes, outcome shown by the Host,
  nothing delivered.
- Handler change: result not delivered to another Command.
- Level 1 declaration: `operation` and `shows_insertion_target` are
  protocol violations; standard and synchronous insertion follow Level 1.
- Helper retired between commit and `operation_finished`: the event
  cold-starts it and is delivered once.

## 3. Real-App verification (actual Host)

Protocol fixtures cannot prove target resolution, focus, IME or
Accessibility results. These runs are required, and each run records: Host
build and tag, candidate revision, Plugin package revisions, installation
source, grants, System Permissions, macOS version, App versions, expected and
actual result, and any requested Host change (#68).

### 3.1 Target Apps and controls

Start from #69's list. Add to it rather than replacing it, so the Level 1
results and the candidate results can be compared App by App.

| Group | Apps | Controls |
| --- | --- | --- |
| AppKit | TextEdit, Notes, Mail (compose), Xcode, Pages | Plain text view, rich text, single-line field, search field |
| WebKit | Safari | `<input>`, `<textarea>`, `contenteditable` |
| Chromium | Chrome, Edge or Arc | Same three |
| Gecko | Firefox | Same three |
| Electron | VS Code, Slack, one more the user uses | Editor, message composer |
| Terminal | Terminal, iTerm2 | Prompt |
| Chinese input | Any two of the above with a Pinyin IME, composing and not composing | As above |
| Secure | Safari password field, a native `NSSecureTextField` | Secure field |
| Spinnet | Settings window, Clipboard History window | Frontmost Spinnet |

### 3.2 Paths

For each App and control, run every path that applies:

| ID | Path | Plugin declares |
| --- | --- | --- |
| L1-S | Standard `insert_text` action | Level 1 |
| L1-Y | Synchronous `insert_text` from a View Event | Level 1 |
| C-S | Standard `insert_text` action | Candidate |
| C-R | Requested `insert_text` operation | Candidate |
| C-Y | Synchronous `insert_text` from a gesture's invocation | Candidate |
| C-M | Requested operation from a Menu Action with no view | Candidate |

L1-Y inside a View Session is expected to risk writing into the panel's own
field; record what actually happens rather than assuming it.

### 3.3 Conditions

| Condition | Expected under the candidate |
| --- | --- |
| Unpinned panel, target App unchanged | Inserted into the target; hint names it throughout |
| Pinned panel, user clicks into another App, comes back to the panel, presses Return | Hint follows the click; insertion goes to the App now shown |
| Frontmost App changes between gesture and execution (scripted activation during a slow fixture script) | `target_changed`, nothing written, hint updated |
| Spinnet Settings frontmost | `no_target`; hint says no App |
| Target App quits after the gesture | `no_target` or `target_changed`, nothing written |
| No focused text element | Refused; record the actual reason |
| IME composing in the target | Record: committed, replaced, or broken composition |
| Secure field | `secure_input` (P9) |
| Accessibility permission removed after commit | `refused`, `system_permission_denied`, repair route shown |
| Capability revoked after commit | Session ends, request cancelled, feedback shown |
| Session closed by focus loss while executing | Effect completes, Host feedback for failures |
| Helper killed between commit and `operation_finished` | Delivered once from a new helper |
| VoiceOver on | Hint read with the action label and as the target line's label; refusal announced |
| Same App, different field focused between gesture and execution | Inserted into the new field (documented limit); recorded to inform the element-level question |

### 3.4 What each run records for insertion

For #69 compatibility: whether `AXSelectedText` was settable; whether the
set call returned success; whether text appeared (by eye and by reading the
value back); undo behaviour in the target; latency of the set call; and the
`reason` the Host reported. A success return without visible text is a
finding, not a pass.

### 3.5 App exit and task start (owned elsewhere, listed for shape)

#83 runs the same structure for `quit_app`: graceful quit with and without
unsaved documents, Force Quit confirmation shown, declined and expired, App
already gone at execution, PID reuse not matched, the App changed between
confirmation and execution. The reviewed-task tickets do the same for task
start confirmation and declined/expired outcomes. Both reuse sections 2 and
3.3's ownership rows.

## 4. Freeze gate

Before #76 freezes the Host for E2, there must be:

1. #69's recorded Level 1 results for the section 3.1 Apps;
2. the candidate paths C-S, C-R, C-Y run on the same Apps, on the existing
   non-activating panel, pinned and unpinned (not waiting for Pin resizing);
3. the user's answers to P1, P3 (if the evidence shows important failures)
   and P9 to P11;
4. the measured budgets of section 1, with the 1 s Accessibility bound
   confirmed or changed with a reason.

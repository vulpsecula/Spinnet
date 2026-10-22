# Plugin API Level 6: command output inside Plugin Views

Level 6 adds `tools.read({tool:"homebrew",operation:"commandOutput",command:"version"})`
and its once-only visible-page source. It returns `output`, `output_truncated` and
the native `exit_status`, including nonzero exits, instead of package projections.
The [input/result schema](../schemas/command-output.schema.json) limits reads to
list, outdated, search, info, config, version, doctor, listing taps, and services
list/info. No mutation, arbitrary flag, executable, environment or shell is accepted.
Declare `read_reviewed_tools`, Homebrew operation `commandOutput`, and the package
kinds used. Existing read admission, source trust, process sandbox, output budgets,
15-second source deadline and cancellation apply. Compose visible-page sources
with the [Level 6 source schema](../schemas/sources-level-6.schema.json).
A read source never grants access.

Own Homebrew Tasks additionally expose a bounded sanitized `output` transcript and
`output_truncated` in `activities.list`. The transcript keeps up to 64 KiB; earlier
text may be dropped. Across an activity list, transcript JSON is limited to 256 KiB,
with ongoing work ahead of ended history. The original `log` remains its 20-line/200-character summary.
Earlier Levels receive their original activity shape. Grants, owner isolation,
Host Confirmation, Stop and no-replay semantics are unchanged by this addition.
Task authorization follows the current [Homebrew profile](homebrew-system-authorization.md).
Task progress remains actual printable Homebrew output; no synthetic percentage is
inferred. Credentials are never Plugin input or output.

`ui.components.text({id:"output",text:"...",format:"output"})` renders literal,
selectable monospaced text with native scrolling, without Markdown or terminal input.
The [Level 6 page schema](../schemas/pages-level-6.schema.json) includes this format.
The output renderer follows the end while the user is there, preserving their scroll
position when they inspect earlier lines. Plugins may retain a smaller bounded tail
in View Session state and disclose truncation.

Use [Level 6 types](../spinnet-level-6.d.ts), [manifest schema](../schemas/manifest-level-6.schema.json)
and [typed example](../fixtures/level-6/usage.ts). Levels 1–5 retain their contracts.
The exact `homebrew_command_output` r1 candidate is retired into Level 6. This
addition does not launch Terminal or ask for Automation access.

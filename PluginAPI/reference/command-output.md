# Command output and Task transcripts

Use `tools.read({tool:"homebrew",operation:"commandOutput",command:"version"})`
and its once-only visible-page source. It returns `output`, `output_truncated` and
the native `exit_status`, including nonzero exits, instead of package projections.
The [input/result schema](../schemas/command-output.schema.json) limits reads to
list, outdated, search, info, config, version, doctor, listing taps, and services
list/info. No mutation, arbitrary flag, executable, environment or shell is accepted.
Declare `read_reviewed_tools`, Homebrew operation `commandOutput`, and the package
kinds used. Existing read admission, source trust, process sandbox, output budgets,
15-second source deadline and cancellation apply. Compose visible-page sources
with the [Current source schema](../schemas/host-run-sources.schema.json).
A read source never grants access.

Own Homebrew Tasks additionally expose a bounded sanitized `output` transcript and
`output_truncated` in `activities.list`. The transcript keeps up to 64 KiB; earlier
text may be dropped. Across an activity list, transcript JSON is limited to 256 KiB,
with ongoing work ahead of ended history. The original `log` remains a summary
of up to 20 lines of 200 characters, projected from the retained Task Output.
When that transcript is truncated, older lines may no longer be available
for the summary. Older journals retain their original recorded summaries.
Grants, owner isolation,
Host Confirmation, Stop and no-replay semantics are unchanged by this addition.
Task authorization follows the current [Homebrew profile](homebrew-system-authorization.md).
Task progress remains actual printable Homebrew output; no synthetic percentage is
inferred. Credentials are never Plugin input or output.

`ui.components.text({id:"output",text:"...",format:"output"})` renders literal,
selectable monospaced text with native scrolling, without Markdown or terminal input.
The [Current page schema](../schemas/pages.schema.json) includes this format.
The output renderer follows the end while the user is there, preserving their scroll
position when they inspect earlier lines. Plugins may retain a smaller bounded tail
in View Session state and disclose truncation.


Use the [current types](../sdk/spinnet.d.ts) and [contract sample](../fixtures/sdk/command-output.ts).

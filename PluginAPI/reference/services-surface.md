# Reviewed Services Host Surface (Level 2)

`tools.showServices` shows a controlled native Host Surface for Homebrew's
current user-owned services. Any installed Plugin declaring and granted
`read_reviewed_tools` for Homebrew operation `services`, kind `formula`, may
request it. Origin grants nothing. No System Permission is needed.

Input is exactly `{tool:"homebrew"}`. It is offered as a Host Command,
Requested Host Operation or View Action; no script call or source is offered.
The SDK provides `spinnet.tools.showServices.operation({tool:"homebrew"})`
and `.action({tool:"homebrew"}, {title:"Services"})`. Success means the Host
accepted presentation, not that a service was changed.

The Host reads names and statuses through the reviewed `tools.read` adapter,
with the same scopes, 15-second read deadline, cancellation and 512 KiB result
bounds. It accepts at most 2000 unique service records; names follow the
reviewed package-name grammar and status strings are bounded to 64 characters.
Only the latest result is kept. No Plugin helper runs for status or controls.
One native Surface is shown at a time. A new request replaces its owner.

The Host reads once on show or manual Refresh, then with a five-second fixed
delay after each answer while the Surface is visible. At most one read is in
flight; it cancels on hide, close, display sleep, inactive user session,
owner replacement or revocation. A hidden interval creates no backlog and
late results never redraw a closed or replaced Surface.

Native Start, Stop and Restart controls target only a selected currently
shown user-owned service. Each control independently checks the calling
Command's current `run_reviewed_tool_tasks` scope for `serviceStart`,
`serviceStop` or `serviceRestart`, kind `formula`, then uses the standard
`tools.startTask` admission path. The Host re-resolves service ownership
before confirmation and again before launch, generates the confirmation,
and refuses a changed/foreign/root target. There are no Plugin-supplied
commands, flags, paths, usernames, environment or `launchctl` calls.

A Plugin can make the Task grant optional on a JavaScript Command requesting
the Surface, so users may inspect status with mutation controls disabled.
The Host Command entry follows ordinary declarative Command capability rules.
A pending confirmation cancels when the Surface closes; already confirmed
Tasks follow their usual independent lifetime, prevent idle sleep, and remain
stoppable in the Spinnet Status Item. Stopping never promises rollback.

# Plugin API Level 5: Terminal Homebrew

A Plugin declaring Level 5 may hand a typed Homebrew command to Terminal through
`apps.perform.operation({bundle_id:"com.apple.Terminal", operation:"homebrew", arguments:{command:"upgrade",kind:"cask",package:"example"}})`.
Declare `control_external_app` with a scope naming `com.apple.Terminal` and
operation family `homebrew_commands`. Existing grants for reviewed tool Tasks
provide no authority here; the user must approve this distinct App scope.

The Host builds `do script` for Terminal from a standard Homebrew executable and
validated, individually shell-quoted arguments. Each handoff opens a new Terminal
window and activates it. No Plugin shell text, argv, executable, environment,
working directory, sudo instruction or AppleScript is accepted. Search text is
one quoted data argument; package and tap selectors use a bounded grammar.

Only gesture-requested operations may hand off; synchronous helper calls,
background Sources and non-gesture replies cannot execute a command. The
Host-private admission flag is never serialized. The operation outcome reports
handoff only, not Homebrew completion. Terminal owns output, input, progress,
password prompts, cancellation and lifetime. There is no Host Task, journal,
sleep assertion or privileged helper requirement for the handoff. macOS may ask
for Spinnet Automation access to Terminal, and denial is explicit. Revocation
prevents another handoff but cannot cancel a command already owned by Terminal.

Supported commands are `list`, `outdated`, `search`, `info`, `update`, `upgrade`,
`install`, `uninstall`, `adopt`, `services`, `tap`, `untap`, `doctor`, `cleanup`,
`autoremove`, `config`, and `version` (`--version`). Package commands accept
optional `kind:formula|cask`; install/uninstall/search/info/adopt require `package`.
Adopt maps to `install --cask --adopt`. Services accept `action:list|start|stop|restart|info`;
action list takes no package, others require one. Tap accepts an optional owner/repository;
untap requires one. Unknown or inapplicable keys and control characters are refused.

The [argument schema](../schemas/terminal-homebrew.schema.json) and [typed example](../fixtures/level-5/usage.ts) describe the request.

Use [Level 5 types](../spinnet-level-5.d.ts) and the [manifest schema](../schemas/manifest-level-5.schema.json).
Levels 1–4 retain their contracts. Older Hosts refuse Level 5. The evaluated
[`terminal_homebrew` r1](../candidates/terminal_homebrew/r1/candidate.json) is retired.

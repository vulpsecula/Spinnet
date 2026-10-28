### Issue tracker

Issues and specs live in GitHub Issues; task maps are optional. For issue
lookup, triage, publication or an existing task map, use the local workflow in
`docs/agents/issue-tracker.md` when available.

### Triage labels

Use the five default canonical triage labels unchanged: `needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`.

### Domain docs

For usage, development commands or repository layout, read
[HANDBOOK.md](HANDBOOK.md).

Read `GLOSSARY.md`, use its domain terms and avoid its listed synonyms.
When local `docs/adr/` files are available,
read the relevant decisions for the area being changed. They are optional
local context: a clean checkout uses the committed glossary, `PluginAPI/`,
source and tests without requiring those files.

`docs/` is deliberately git-ignored; current edits there are local context.
Keep implementation claims tied to source and tests. Public budget quotations
come from committed `PluginAPI/`, not local ADR text.

The Plugin interface itself is documented only in `PluginAPI/`, which is
committed: its README indexes one current interface, and `engines.spinnet`
declares Host SemVer compatibility. `PluginAPI/reference/` and the schemas
specify the supported contract. Write interface changes there, never into
`docs/`, which keeps Host-internal design and ADRs.

### Development verification

For build, run, test, or debugging work, use the relevant `build-macos-apps:*`
skill. Use the `xcode` MCP for Xcode-native validation such as builds, tests,
Issue Navigator diagnostics, build logs, and previews; use SwiftPM shell
commands for tight package-level checks.

### Host launch

- Use `./script/build_and_run.sh` for normal development and manual acceptance
  of the packaged app. Reserve `swift run SpinnetHost` for targeted debugging.
- Quit existing Hosts before switching entrypoints; they share saved user data.
  Confirm the running app path and Plugin versions before reporting acceptance.

The app contains no Plugins. To install or update local Plugin packages, such
as a SpinnetPlugins checkout, use the launcher's `--install-plugins DIR`; it
uses the same install-and-update path as the Library and writes the user's
saved data. For launch options and signing, read
[the launcher](script/build_and_run.sh).

### Sub-agent Rules

For review only sub-agents, choose suitable model and reasoning depth for the task (e.g., GPT-6.1 Terra High, Opus 5.5 Medium).

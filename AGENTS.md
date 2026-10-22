## Agent skills

### Issue tracker

For issue lookup, triage, publication or an existing task map, read
[the issue workflow](agent-guide/issue-tracker.md). Issues and specs live in
GitHub Issues; task maps are optional.

### Triage labels

Use the five default canonical triage labels unchanged: `needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`.

### Domain docs

Read `GLOSSARY.md`, use its domain terms and avoid its listed synonyms.
When local `docs/adr/` files are available,
read the relevant decisions for the area being changed. They are optional
local context: a clean checkout uses the committed glossary, `PluginAPI/`,
source and tests without requiring those files.

`docs/` is deliberately git-ignored (see commit 97558ec) and has no version
history. `DocumentedBudgetsTests` compares constants with copied expectations
and checks quotations from committed `PluginAPI/` pages; it does not read ADR
text. Keep current implementation claims tied to source and tests.

The Plugin interface itself is documented only in `PluginAPI/`, which is
committed: its README indexes supported Levels 1–7, and `PluginAPI/reference/`
and the schemas specify each Level. Write interface changes there, never into
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

For launch options, signing and Plugin source overrides, read
[the launcher](script/build_and_run.sh) and
[the Plugin resolver](script/resolve_bundled_plugins.sh).

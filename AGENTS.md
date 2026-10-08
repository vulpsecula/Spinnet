## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five default canonical triage labels unchanged: `needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`.

### Domain docs

Single-context layout. Read `GLOSSARY.md` for the domain glossary and the
relevant ADRs in `docs/adr/` before working in an area. Use the glossary's
terms, and avoid the synonyms it lists.

Note that `docs/` is deliberately git-ignored (see commit 97558ec), so these
documents carry no version history. A documentation change cannot be reviewed
as a diff; the budgets in the ADRs are instead pinned by
`DocumentedBudgetsTests`.

The Plugin interface itself is documented only in `PluginAPI/`, which is
committed: its README catalogues Plugin API Level 1, and `PluginAPI/reference/`
and the schemas specify it. Write interface changes there, never into
`docs/`, which keeps Host-internal design and ADRs.

### Development verification

For build, run, test, or debugging work, use the relevant `build-macos-apps:*` skill. Use the `xcode` MCP for Xcode-native validation such as builds, tests, Issue Navigator diagnostics, build logs, and previews; use SwiftPM shell commands for tight package-level checks.

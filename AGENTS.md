## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five default canonical triage labels unchanged: `needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`.

### Domain docs

Single-context layout. Read `CONTEXT.md` for the domain glossary and the
relevant ADRs in `docs/adr/` before working in an area. Use the glossary's
terms, and avoid the synonyms it lists.

Note that `docs/` is deliberately git-ignored (see commit 97558ec), so these
documents carry no version history. A documentation change cannot be reviewed
as a diff; the budgets in `docs/adr/0007` and `docs/plugin-interface.md` are
instead pinned by `DocumentedBudgetsTests`.

### macOS development verification

For macOS build, run, test, or debugging work, use the relevant `build-macos-apps:*` skill. When Xcode is running with this package open, use the `xcode` MCP for Xcode-native validation such as builds, tests, Issue Navigator diagnostics, build logs, and previews; use SwiftPM shell commands for tight package-level checks.

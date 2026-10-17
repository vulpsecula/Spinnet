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

For build, run, test, or debugging work, use the relevant `build-macos-apps:*`
skill. Use the `xcode` MCP for Xcode-native validation such as builds, tests,
Issue Navigator diagnostics, build logs, and previews; use SwiftPM shell
commands for tight package-level checks.

### Host launch

- **Packaged app:** use `./script/build_and_run.sh` for normal development,
  user testing and manual acceptance. It builds the Host and Helpers, bundles
  Plugins, signs and launches `dist/SpinnetHost.app`; it does not install into
  `/Applications` or `~/Applications`. `--verify` also checks that the process
  stays running; `--package` builds and verifies the same app without stopping
  or launching the Host.
- **Signing:** keep the stable Apple Development identity for permission and
  native behaviour checks. macOS binds Accessibility consent to the signed
  app. Use `SPINNET_ALLOW_ADHOC_SIGNING=1` only for isolated tests that do not
  depend on retained System Permissions.
- **Direct debugging:** reserve `swift run SpinnetHost` for targeted executable
  debugging. Build the Helpers needed by the scenario separately and supply
  Bundled Plugins with
  `SPINNET_BUNDLED_PLUGINS_DIR="$(./script/resolve_bundled_plugins.sh)" swift run SpinnetHost`.
  Without that variable, a direct run loads no Bundled Plugins. For coordinated
  Plugin development, the variable can instead name a local
  `SpinnetPlugins/Plugins` directory; packaging also accepts this build input.
  A packaged Host always loads its own `Contents/Resources/Plugins` and ignores
  the runtime override.
- **Instances and evidence:** quit existing Hosts through their normal Quit
  flow before switching entrypoints or app copies. Both entrypoints use the
  same saved user data, and the script stops only its own `dist/` executable.
  Before reporting manual acceptance, confirm the running executable path and
  the Plugin versions it loads; identify whether the check used the packaged
  app or a direct run. Keep test artifacts separate from the daily app path.

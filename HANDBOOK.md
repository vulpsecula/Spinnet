# Spinnet Handbook

This handbook covers using and developing the Host. Plugin authors should
start with the [Documented Plugin Interface](PluginAPI/README.md); package
behaviour and Plugin development live in
[SpinnetPlugins](https://github.com/vulpsecula/SpinnetPlugins).

## Using Spinnet

A first launch without a saved Menu starts with eight empty Slots. Open
Settings → Menu and add a Plugin's Preset to a Slot. Each Menu Item has one
Primary Action and optional Alternate Actions, available by right-click.
Its Configuration Sheet saves or cancels edits together; Menu arrangement,
appearance and triggers save automatically. Unavailable Actions keep their
Slots and can be repaired in Settings.

App Overrides change what some Slots contain for one App. Choose the App in
the Menu Editor's App switcher, or add it from running Apps or Applications;
an App needs a bundle identifier. Adding a Preset to a Slot or editing its
Menu Item then overrides that Slot, and right-clicking a Slot empties it or
resets it to the default. They apply while that App is the Current App;
every other App gets the default Menu. Slots are arranged in the default
Menu only.

Mouse Side Button 1 opens the Menu by default. Change the mouse trigger or
record or enter a keyboard shortcut under Settings → Menu. The Library
contains Plugins, including those whose Commands directly call Host Services.
Spinnet itself contains no Plugins: install a package from the Library. Official
Plugins from [SpinnetPlugins](https://github.com/vulpsecula/SpinnetPlugins)
are installed, updated and removed like any other Plugin.

### Plugin Updates

A Plugin that declares an Update Source, a GitHub repository, offers Check for
Update on its Library entry, however it was installed, even when this Host
refused to load it. The check asks GitHub's public API for that repository's
tags starting `<plugin-id>/v`, looks up their releases newest first, and
offers the highest newer version it accepts: same Plugin identity and Update
Source, a strictly greater SemVer version, a compatible Host range, and a
package downloaded over HTTPS from the repository's release asset. Update then
replaces the package through the Library's install path: Plugin Storage,
Plugin Settings, Menu Items and Capability decisions are kept, and newly
requested Capabilities are reviewed, again at that moment, before anything is
replaced. Nothing
installs automatically. A refused version, being offline or GitHub's rate
limit is shown on the entry, and the installed version keeps working. A Plugin
without an Update Source shows no update controls.

General's "Check for Plugin updates automatically" (on by default) checks
every such Plugin at most once a day across launches, never at launch before
a check is due, with a single timer for the next one; turned off, no
automatic request is made and an automatic check under way stops asking. General's Check Now and the Library's Check All
for Updates run the same check at once. General shows how many updates are
available, and each affected Library entry offers Update. Tags are listed once
per repository; a failure or GitHub's rate limit is reported on General, not
in an alert, and is not retried before the next check. Authors publish releases
as described in [Update Source](PluginAPI/reference/update-source.md).

### Privacy and ongoing work

Privacy & Permissions separates macOS System Permissions, Sensitive Data
Collection and each Plugin's Capability grants. The Host stores Capability
decisions per Plugin version. Removing a Plugin forgets its grants.
Startup preserves Refused Plugins' decisions and drops those of Plugins that
are no longer installed. Menu Items of a Plugin that is not installed stay in
their Slots as unavailable until a Plugin with the same identity is installed.

Clipboard History collection defaults off. When enabled, the Host retains
copies locally in owner-only storage. A Plugin needs a type-scoped
`read_clipboard_history` Capability to read them. The same grant allows a
Plugin to open the Host-rendered history window: the user reads their own
data there, and the Plugin learns nothing from the window.

The Status Item shows ongoing Effects and Tasks and offers their Stop
controls. Reviewed Homebrew Tasks use typed, scoped requests and Host
confirmation before package changes. Native Homebrew runs as the current
user; system sudo/PAM owns authentication where needed. Spinnet does not save
passwords or share them with Plugins; when sudo needs one, its signed askpass
passes it directly to sudo. The [authorization contract](PluginAPI/reference/homebrew-system-authorization.md)
describes this interface.

## Build and run

The project requires macOS 13 or later and Xcode's Swift toolchain. Use the
packaged app for normal development:

```sh
./script/build_and_run.sh
```

The launcher selects an Apple Development identity or uses
`SPINNET_CODESIGN_IDENTITY`. An ad-hoc build requires the explicit
`SPINNET_ALLOW_ADHOC_SIGNING=1` opt-in and cannot establish persistent
Accessibility consent. Launcher modes are listed by
`./script/build_and_run.sh --help`; their implementation lives in
[the launcher](script/build_and_run.sh).

Reserve `swift run SpinnetHost` for targeted debugging. Quit existing Hosts
before switching entrypoints because they share saved user data. Confirm the
running app path and Plugin versions when reporting packaged-app acceptance.
Launch can write Capability-grant records and migrate existing settings, even
before the user edits a Menu.

### Plugins for development

The packaged app contains no Plugins. Official packages live in the
independent MIT repository
[SpinnetPlugins](https://github.com/vulpsecula/SpinnetPlugins); the Host has no
submodule, SwiftPM or packaging dependency on it. To try local packages,
install them through the path a user takes:

```sh
./script/build_and_run.sh --install-plugins ../SpinnetPlugins --verify
```

`--install-plugins DIR` installs or updates every `.spinnetplugin` package in
`DIR`, or in `DIR/Plugins` for a SpinnetPlugins checkout, into the user's saved
data before the app opens. An update keeps Plugin Storage and Capability
decisions; newly requested Capabilities stay undecided, as after a Library
install. `--verify` reports the installed Plugin versions, as saved on disk,
once the app has stayed up. Both modes write or read your real saved data.

## Verification

Run package tests with `swift test`. For Xcode-native builds, tests and
diagnostics, follow [development verification](AGENTS.md#development-verification).
Passing package tests does not establish native permissions or actual App
behaviour. Report native acceptance with the change being verified.

With [uv](https://docs.astral.sh/uv/), run schema and tooling checks without
building the macOS Host:

```sh
uv run --locked --script script/check_plugin_schemas.py
uv run --no-project python -B -m unittest discover -s Tests/Tooling -v
```

The schema checker reads the same current conformance fixture matrix as
`PluginSchemaCompositionTests` and validates every schema's Draft
2020-12 meta-schema structure. It reports actual payload/check/schema counts
and fails on mismatches or incomplete checks. Optional `format` annotations
are not asserted: Python's regex-format checker cannot validate the published
ICU Unicode properties. Payload `pattern` constraints still execute; an
unsupported pattern fails the check rather than counting as an expected
refusal. The Python suite also covers packaging, the development install
option and developer-tool entry points.

For scripted Action progress, timeout, cancellation and explicit retry checks,
`./script/build_and_run.sh --lifecycle-check` opens the Debug-only lifecycle
window with temporary Actions. Saved Menu configuration stays unchanged;
the window is excluded from release builds.

### Developer tools

`script/` holds command entry points and build or validation orchestration.
`Tools/` holds the Swift implementations of developer-only probes. Shared
validation such as [background-helper signature checks](script/check_background_helper.sh)
is reused by the callers.

| Entry point | Implementation | Purpose |
| --- | --- | --- |
| [`script/ax_insertion_matrix.sh`](script/ax_insertion_matrix.sh) | [`Tools/AXInsertionProbe/`](Tools/AXInsertionProbe/) | Native insertion checks using current Host sources by default; `--build-only` builds, signs and self-checks the probe. |
| [`script/check_background_lifecycle.sh`](script/check_background_lifecycle.sh) | [`Tools/BackgroundLifecycleProbe/`](Tools/BackgroundLifecycleProbe/) | Isolated background-service lifecycle integration checks. |
| [`script/measure_view_sessions.sh`](script/measure_view_sessions.sh) | [`Tools/ViewSessionMeasurement/`](Tools/ViewSessionMeasurement/) | Current View Session latency, memory and authority measurements using the real helper. |

The insertion matrix's explicit `--host a2` mode reproduces historical Host A2.
It establishes historical results, not acceptance of the current Host.

The lifecycle tool's `--status` reads test registration state. `--clean`
removes unregistered test state and rebuildable caches; only the explicit
`--clean --unregister` also unregisters its isolated test service. Its fixed
`Tools/.state/` location can remain registered or pending system approval,
so use this flow when cleaning it. Raw results remain in `tmp/`.

## Repository layout

| Location | Responsibility |
| --- | --- |
| `Sources/` | Production modules and independently signed runtime helpers. |
| `PluginAPI/` | Public Plugin contract: reference, schemas, SDKs and deterministic contract fixtures. |
| `Tests/` | Behaviour tests, test-only executable fixtures and Python tooling regressions. |
| `script/` | Build, validation and measurement command entry points. |
| `Tools/` | Developer-only probe and measurement sources. |
| `dist/` | The packaged Host app. |
| `.build/` | Rebuildable compiler and verification caches. |
| `Tools/.state/` | Local test service registration state, managed by its explicit cleanup command. |
| `tmp/` | Local task and verification working outputs, grouped by task or run. |
| `.audit-archive/` | Local retained audit evidence and removal archives. |
| `docs/` | Optional local agent workflows, ADRs and internal rationale. |

The output, cache, state, archive and local `docs/` directories above are
Git-ignored. Keep temporary outputs under one named task or run directory.
After reviewing the results, retain the useful evidence in the local archive
and remove the working copies. Retain only the currently needed task tracker
while work is active. Build caches can be recreated; registered test state
needs its dedicated cleanup flow.

### Documentation and module responsibilities

The [README](README.md) introduces the product; this handbook covers usage and
development; [AGENTS.md](AGENTS.md) supplies agent workflow instructions;
[GLOSSARY.md](GLOSSARY.md) defines domain terms. `PluginAPI/` is the sole
published Plugin interface. Plugins declare Host SemVer compatibility through
`engines.spinnet`; all compatible packages use the current interface. Its README indexes the
reference, schemas, `sdk/` sources and contract fixtures. Interface changes
belong there. Local `docs/` supplies optional internal context; a clean
checkout uses the committed documentation, source and tests.

`SpinnetCore` owns manifest/configuration validation, Plugin registration,
Action editing, persistence, Menu geometry, the Clipboard History Store and
the `HostActionRunner` seam. It keeps Reviewed Tool request models and input
validation, while `SpinnetReviewedTools` owns concrete tool discovery, execution
and historical Task recovery. The Plugin helper and public TestKit depend on
Core without linking that execution module.

`SpinnetHost` owns the AppKit overlay, triggers, settings, common Host Command
adapters, clipboard collection and feedback. Its Action dispatcher owns the
invocation queues shared by Actions and View Events. Configuration Sheets
persist before publishing their new Menu state; a failed save keeps the draft
open and reports any failure to restore a partially written credential.

Scripted Actions launch `SpinnetPluginHelper` on demand. Registration, idle
state, Menu opening and Host Commands do not launch a Plugin helper.
Scripted Actions reuse one serialized helper per Plugin. Disable, removal,
update, Capability revocation and Host shutdown retire the relevant helpers.
The Host owns progress, cancellation, deadlines and terminal feedback.

Capability-checked Host Services use the documented helper protocol. Timing,
size and resource budgets are declared in types such as
`ScriptedActionBudgets` and `ClipboardHistoryBudgets` and checked against the
published contract by `DocumentedBudgetsTests`.

## Licence

Copyright © 2026 vulpsecula and the Spinnet contributors.

Spinnet is free software: you can redistribute it and/or modify it under the
terms of the **GNU General Public License, version 3 only**
(`GPL-3.0-only`), as published by the Free Software Foundation. The full text
is in [`LICENSE`](LICENSE).

Spinnet is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. See the GNU General Public License for more details.

`Sources/SpinnetCore`, `Sources/SpinnetHost`, `Sources/SpinnetPluginHelper`,
the remaining first-party application source, and the historical Host test
fixtures are covered by that licence unless a file states otherwise. The exception is [`PluginAPI/`](PluginAPI/), the versioned
Documented Plugin Interface, which is published under the MIT licence in
[`PluginAPI/LICENSE`](PluginAPI/LICENSE) so that Plugins can copy its schemas
and type definitions.

### Source and binaries

The complete source is on GitHub, and building Spinnet yourself is free. The
GPL rights — to read, modify, build, and redistribute the source, and to
publish GPL-compliant forks — always apply, including to any licensing and
trial code itself.

Website and Homebrew distribution of signed, notarized builds, with a trial and
paid lifetime licence, are planned. Distributed binaries, including sold builds,
retain the recipient's rights under the GPL.

### Plugins

A Plugin that is not based on Spinnet-Owned Code and reaches Spinnet only
through the Documented Plugin Interface in [`PluginAPI/`](PluginAPI/) keeps
its own licence;
running inside Spinnet does not place it under the GPL. Community Plugins may
use any OSI-approved open-source licence, and their authors keep their
copyright. Official Plugins are maintained separately in
[SpinnetPlugins](https://github.com/vulpsecula/SpinnetPlugins) under MIT; their
exact third-party notices remain applicable. The official Plugin registry is
for open-source Plugins.

### Third-party material

Third-party dependencies, third-party Plugins, and separately licensed assets
stay under their own licences. Spinnet claims no copyright over them.

### Contributions

Contributions are accepted under this repository's `GPL-3.0-only` licence.
There is no contributor licence agreement.

### Name and branding

The licence covers the code. It does not grant rights to the Spinnet name,
logo, or branding beyond accurate references to the project. Forks must not
present themselves as official Spinnet releases.

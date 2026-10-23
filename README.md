# Spinnet

Spinnet is a native macOS Host for mouse-first radial Menus. Everything in
the Library is a Plugin, reached through the Documented Plugin Interface, and
configuration stays in the Settings window. The Host renders Plugin Views,
runs bounded scripts in per-Plugin helpers, and owns protected system operations,
Clipboard History collection and ongoing Effects and Tasks.

## Run

The project requires macOS and Xcode's Swift toolchain. The development launcher
also requires a stable code-signing identity: it selects an Apple Development
identity or uses `SPINNET_CODESIGN_IDENTITY`. An ad-hoc build requires the
explicit `SPINNET_ALLOW_ADHOC_SIGNING=1` opt-in and cannot establish persistent
Accessibility consent. Run from the repository root:

```sh
./script/build_and_run.sh
```

Run `swift test` for package tests. For choosing between packaged-app and
direct SwiftPM launches, follow [Host launch](AGENTS.md#host-launch). Launcher
modes, signing and Plugin overrides are defined in
[`script/build_and_run.sh`](script/build_and_run.sh).

With [uv](https://docs.astral.sh/uv/), run the standard Draft 2020-12 schema
check and its entry-point regression tests without building the macOS Host:

```sh
uv run --locked --script script/check_plugin_schemas.py
uv run --no-project python -B -m unittest discover -s Tests/Validation -v
```

The check reads the same stable-Level fixture matrix as
`StablePluginSchemaCompositionTests`, reports actual payload/check/schema counts,
and fails on mismatches or incomplete checks. It also checks every schema's
meta-schema structure. Optional `format` annotations are not asserted: Python's
regex-format checker cannot validate the published ICU Unicode properties.
Payload `pattern` constraints still execute; an unsupported pattern fails the
check rather than counting as an expected refusal. These checks do not establish
native Host acceptance.

The official packages live in the independent MIT repository
[SpinnetPlugins](https://github.com/vulpsecula/SpinnetPlugins). The Host has no
submodule or SwiftPM dependency on it: packaging reads the lock file, fetches
that full commit into a cache and copies its `Plugins/` packages into the app.
For local development, `SPINNET_BUNDLED_PLUGINS_DIR` selects a packages directory;
the [resolver](script/resolve_bundled_plugins.sh) documents this override.
The public manifest loader reads the resulting bundled directory. Open URL,
Screenshot and the other Plugins whose Commands are
Host Commands (see the Host Command catalogue in
[`PluginAPI/reference/manifest.md`](PluginAPI/reference/manifest.md#host-commands))
are packages in that repository like
Clipboard History, and can be removed like it. A Bundled Plugin is delivered into
`SpinnetHost.app/Contents/Resources/Plugins` and an installed Plugin into
Application Support, and the Host discovers both by reading a directory.

A first launch without a saved Menu starts with eight empty Slots; Menu
configuration is saved when the user edits it. Launch can still write Plugin
discovery and Capability-grant records, and can migrate existing settings.
The Host opens the radial Menu
with Mouse Side Button 1 by default, and an optional keyboard shortcut can be
recorded or entered manually under Settings → Menu. Scripted Actions launch
`SpinnetPluginHelper` on demand; registration, idle state, Menu opening, and
Host-backed Actions do not launch a helper. Actions, Menu bindings, appearance,
and triggers are saved automatically.

## Using the Host

Add a Plugin's Preset to an empty Slot in Settings → Menu before invoking
the Menu. Each Menu Item has one Primary Action and optional Alternate
Actions, available by right-click. Its Configuration Sheet saves or cancels
edits together; Menu arrangement, appearance and triggers save automatically.
Unavailable Actions keep their Slots and can be repaired in Settings.

Privacy & Permissions separates macOS System Permissions, Sensitive Data
Collection and each Plugin's Capability grants. Plugin-specific behaviour and
development instructions belong in the
[Plugins repository](https://github.com/vulpsecula/SpinnetPlugins).

For scripted Action progress, timeout, cancellation and explicit retry checks,
`./script/build_and_run.sh --lifecycle-check` opens the Debug-only lifecycle
window with temporary Actions. It leaves saved Menu configuration unchanged
and is excluded from release builds. Native acceptance results belong with
the change being verified; passing package tests does not establish them.

## Scope

`SpinnetCore` owns manifest/configuration validation, Plugin registration,
Action editing, configuration persistence, Menu geometry, the Clipboard History
Store, and the Host-level `HostActionRunner` seam. `SpinnetHost` owns the
AppKit overlay, global shortcuts, settings window, common Host Command
adapters, clipboard collection, and user-visible feedback.

Capability-checked Host Services are available through the documented helper
protocol. The Host stores per-Plugin-version Capability decisions and exposes
each registered Plugin's grants in Privacy & Permissions. Removing a Plugin
forgets its decisions. Startup preserves Refused Plugins' decisions; it drops
other undiscovered owners only when discovery accounts for the Bundled set.
A direct development launch with no Bundled packages preserves those decisions.
The Host owns scripted Action
progress, cancellation, deadlines, and terminal feedback. Scripted Actions
reuse one serialized helper per Plugin, and Plugin disable, uninstall, update,
Capability revocation, and Host shutdown retire helpers immediately.

Clipboard History collection defaults off. While enabled, the Host retains
copies locally in owner-only storage and exposes them to a Plugin only through
a granted, type-scoped `read_clipboard_history` Capability. Opening the
Host-rendered history window is a separate Host Service that the same grant
allows, whichever Plugin asks: the user reads their own data there, and the
Plugin learns nothing from it.

The Documented Plugin Interface supports Levels 1–7 and is published in
[`PluginAPI/`](PluginAPI/README.md): the manifest, the helper protocol, every
Host Service, Plugin Views, and their schemas. The timing, size, and resource
budgets those contracts promise are declared once in budget types such as
`ScriptedActionBudgets` and `ClipboardHistoryBudgets`, and pinned against the
published pages by `DocumentedBudgetsTests`.

Reviewed Homebrew Tasks use typed, scoped requests and Host confirmation before
package changes. Native Homebrew runs as the current user; system sudo/PAM owns
authentication where needed. Spinnet collects no password. See the
[authorization contract](PluginAPI/reference/homebrew-system-authorization.md).

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
copyright. Official Plugins bundled with Spinnet are maintained separately in
[SpinnetPlugins](https://github.com/vulpsecula/SpinnetPlugins) under MIT; their
exact third-party notices remain applicable. The official Plugin registry is
for open-source Plugins.

### Third-party material

Third-party dependencies, converted Plugins, and separately licensed assets
stay under their own licences. Spinnet claims no copyright over them.

### Contributions

Contributions are accepted under this repository's `GPL-3.0-only` licence.
There is no contributor licence agreement.

### Name and branding

The licence covers the code. It does not grant rights to the Spinnet name,
logo, or branding beyond accurate references to the project. Forks must not
present themselves as official Spinnet releases.

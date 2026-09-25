# Spinnet

Spinnet is a native macOS Host for mouse-first radial Menus. Everything in
the Library is a Plugin, reached through the Documented Plugin Interface, and
configuration stays in the Settings window. The current slice covers the Menu-first Settings workflow, scripted
Actions in per-Plugin helpers, and local Clipboard History collection.

## Run

The project requires macOS and Xcode's Swift toolchain. Run these commands from
the repository root:

```sh
swift build
swift build --product SpinnetPluginHelper
swift test
SPINNET_BUNDLED_PLUGINS_DIR=Plugins swift run SpinnetHost
```

Bundled Plugins ship inside the app bundle, so a `swift run` has none unless
`SPINNET_BUNDLED_PLUGINS_DIR` points at the repository's `Plugins` directory.
Without it the Host still starts, with an empty Library, and it leaves
the access decisions alone rather than reading a launch that saw no Bundled
Plugin as a sign that they are gone. A Host running from an app bundle reads
the Plugins that bundle carries and ignores the variable: Bundled authority is
for the Plugins a signed build ships, not for a directory the environment
names.

For the bundled app workflow, use `./script/build_and_run.sh`. It selects an
Apple Development identity and refuses ad-hoc signing by default because macOS
binds Accessibility consent to the app's signed code requirement. If you need
an intentionally permission-free local run without a development certificate,
opt in explicitly:

```sh
SPINNET_ALLOW_ADHOC_SIGNING=1 ./script/build_and_run.sh --verify
```

Ad-hoc builds are for isolated tests only; macOS may ask for Accessibility
permission again after rebuilding them.

The Host reads every Plugin package it finds in `Plugins` through the public
manifest loader. Open URL, Screenshot and the other Plugins whose Commands are
Host Commands (see the Host Command catalogue in
[`docs/plugin-interface.md`](docs/plugin-interface.md)) are packages there like
Clipboard History, and can be removed like it. A Bundled Plugin is delivered into
`SpinnetHost.app/Contents/Resources/Plugins` and an installed Plugin into
Application Support, and the Host discovers both by reading a directory.

A first launch opens an empty Menu: eight Slots, none of them bound, and nothing
is written until the user configures something. The Host opens the radial Menu
with Mouse Side Button 1 by default, and an optional keyboard shortcut can be
recorded or entered manually under Settings → Menu. Scripted Actions launch
`SpinnetPluginHelper` on demand; registration, idle state, Menu opening, and
Host-backed Actions do not launch a helper. Actions, Menu bindings, appearance,
and triggers are saved automatically.

## Manual acceptance checks

Smart Jump recognises links, DOI identifiers, Bilibili AV/BV numbers, local
paths and arithmetic; other text becomes a web search. The first target in a
passage wins. Quote paths containing spaces so their boundaries are explicit.
Downloads open in the default browser. In the Library's Plugin Settings,
configure search engines as one `Name | URL` per line, with `{query}` in the
URL; the first is the default (Google initially). Running with no selection
opens an input window with a destination preview and search-engine picker.
Arithmetic results can be copied explicitly. Opening local paths and writing
the clipboard each require their own grant.

For #46, check a bare domain, a DOI inside a sentence, an AV/BV number, a
download link, an existing file and folder, and `32-68*(50/6-3.28)+5` from
another app. Also check no selection, Return/Escape in the input window,
editing shortcuts, changing search engines, copying a result, and revoking a
grant while the window remains open. These real-app checks are separate from
the deterministic classifier and Host Action tests.

1. Open Settings from the status item and add `Open URL` from the Library to a
   Slot. A first launch has an empty Menu, so every check below needs at least
   one Menu Item to exist first.
2. Press Mouse Side Button 1 while the pointer is near the middle of a
   display. The overlay appears at the pointer without activating the Host.
3. Move clockwise around the ring. At most one Menu Item is highlighted; the
   center remains a dead zone.
4. Release on `Open URL` and confirm the URL opens and a completion message is
   visible.
5. Open the Menu again and dismiss it with Escape, a click outside the ring, or
   Mouse Side Button 1. None of these dismissal paths runs the Action.
6. Repeat near each display edge and corner. The complete ring remains inside
   the display's visible frame.
7. Open Settings from the status item. Create a second Action, select it as an
   Alternate Action, close and relaunch the Host, and confirm the binding is
   still present. Right-click the Menu Item to expose the Alternate Action.
8. In the Library, add `Open Application`, `Open File`, `Open Folder`, `Run
   Shortcut`, or `Run Keyboard Shortcut`. The Configuration Sheet offers native
   pickers or a shortcut recorder. Recording temporarily blocks keyboard
   events from reaching other apps when Accessibility is available. If a
   utility still intercepts the event, choose `Choose Manually…` and select
   modifiers and a key from the two lists. Text and URL fields use the standard
   macOS editing menu and keyboard shortcuts. Cancel leaves the Slot unchanged;
   Save commits all fields at once. Rename the Menu Item with its optional
   alias, and use the visible Edit button, double-click, `Command-E`, or
   `Return`/`Space` after focusing a Slot to reopen the sheet.
9. Add `Copy Selected Text`, grant its `Read Selected Text` and `Write
   Clipboard` capabilities in Privacy & Permissions, select text in another
   app, and run the Menu Item. The copied value comes from the current
   selection rather than a configured text parameter.
10. Add `Paste` or `Cut`, grant Spinnet Accessibility permission in Privacy &
   Permissions, focus a text field in another app, and run the Menu Item.
11. `Run macOS Service` is useful for installed Services that transform,
    look up, or share selected text. To test it, select text in the target app
    and copy the exact title from that app's Services menu into the
    Configuration Sheet. Use the full menu path with `/` separators when the
    service is nested.
12. Remove `Clipboard History` from the Library. The confirmation names the
    Slots whose Menu Items use it; those stay in their Slots and report as
    unavailable. Restart the app and confirm it is still gone. Bring it back
    with `Install or Update Plugin…` and a copy of its package, allow the
    access it asks for, and run it, window included: the copy you chose is
    installed like any other Plugin.
13. If an application, file, or folder used by a Menu Item is later removed,
    the Menu Item remains in its Slot and only that Action is disabled. Its
    Slot keeps the Preset name (or your Alias), while the unavailable reason
    appears on the Action. Open its Configuration Sheet and use `Choose Again…`
    to repair the path.

## Scripted Action lifecycle checks

Run `./script/build_and_run.sh --lifecycle-check` to open the Debug-only
lifecycle test window. It creates temporary scripted Actions without changing
saved Menu configuration or requesting Capabilities:

- **Slow success (3 seconds)** runs long enough to show Progress, then completes.
- **Hang until timeout** loops until the scripted Action deadline. Press Escape
  while Progress is visible to cancel, or wait for `timed_out`.
- Click **Retry** (or press Return) on a failure to start a new execution.

The launcher returns when feedback is dismissed. In this Debug test mode,
success feedback stays visible for ten seconds for inspection. Normal runs
retain the standard feedback duration. The test window is excluded from
release builds.

## Scope

`SpinnetCore` owns manifest/configuration validation, Plugin registration,
Action editing, configuration persistence, Menu geometry, the Clipboard History
Store, and the Host-level `HostActionRunner` seam. `SpinnetHost` owns the
AppKit overlay, global shortcuts, settings window, common Host Command
adapters, clipboard collection, and user-visible feedback.

Capability-checked Host Services are available through the documented helper
protocol. The Host stores per-Plugin-version Capability decisions and exposes
each registered Plugin's grants in Privacy & Permissions. Removing a Plugin
forgets its decisions, and the Host drops decisions left behind by Plugins it no
longer finds. The Host owns scripted Action
progress, cancellation, deadlines, and terminal feedback. Scripted Actions
reuse one serialized helper per Plugin, and Plugin disable, uninstall, update,
Capability revocation, and Host shutdown retire helpers immediately.

Clipboard History collection defaults off. While enabled, the Host retains
copies locally in owner-only storage and exposes them to a Plugin only through
a granted, type-scoped `read_clipboard_history` Capability. Opening the
Host-rendered history window is a separate Host Service reserved for a Bundled
Plugin, because it is a Host privilege rather than something the Capability
grants.

The manifest shape, helper protocol, Host Command catalogue, and Clipboard
History contract are documented in
[`docs/plugin-interface.md`](docs/plugin-interface.md). The timing, size, and
resource budgets those contracts promise are declared once in
`ScriptedActionBudgets` and `ClipboardHistoryBudgets`, and pinned against the
documents by `DocumentedBudgetsTests`.

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
the remaining first-party application source, and the first-party Plugins
maintained in this repository are covered by that licence unless a file states
otherwise. The exception is [`PluginAPI/`](PluginAPI/), the versioned
Documented Plugin Interface, which is published under the MIT licence in
[`PluginAPI/LICENSE`](PluginAPI/LICENSE) so that Plugins can copy its schemas
and type definitions.

### Source and binaries

The complete source is on GitHub, and building Spinnet yourself is free. The
GPL rights — to read, modify, build, and redistribute the source, and to
publish GPL-compliant forks — always apply, including to the licensing and
trial code itself.

Official signed and notarized builds are distributed separately through the
Spinnet website and Homebrew, and may be sold: a free trial followed by a paid
lifetime licence. Paying is for the convenience of a ready-to-run notarized
build and for supporting development. It does not change, extend, or restrict
anyone's rights under the GPL, and using an official binary does not take any
of those rights away.

### Plugins

A Plugin that is not based on Spinnet-Owned Code and reaches Spinnet only
through the Documented Plugin Interface in [`PluginAPI/`](PluginAPI/) and
[`docs/plugin-interface.md`](docs/plugin-interface.md) keeps its own licence;
running inside Spinnet does not place it under the GPL. Community Plugins may
use any OSI-approved open-source licence, and their authors keep their
copyright. Plugins bundled with Spinnet and maintained here are
`GPL-3.0-only`, and the official Plugin registry is for open-source Plugins.

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

# Spinnet

Spinnet is a native macOS Host for mouse-first radial Menus. This slice
implements the Menu-first Settings workflow from #18 on top of the common
Host Command and Plugin runtime seams: Host-owned Built-in Presets are the
user-facing entry points, and configuration stays in the Settings window.

## Run

The project requires macOS and Xcode's Swift toolchain. Run these commands from
the repository root:

```sh
swift build
swift build --product SpinnetPluginHelper
swift test
swift run SpinnetHost
```

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

The Host registers standalone Built-in Presets for Open URL, Open Application,
Open File, Open Folder, Shortcuts, Services, Copy Selected Text, Paste, and Cut, then
loads `Plugins/SpinnetFixture.spinnetplugin` through the public manifest
loader for its deterministic JavaScript compatibility Actions. The fixture
retains the common Host Command declarations for existing persisted
configurations, but is hidden from the Library so those operations appear only
as standalone Built-in Presets. The Host opens the radial Menu with Mouse Side
Button 1 by default. Scripted Actions launch
`SpinnetPluginHelper` on demand; registration, idle state, Menu opening, and
Host-backed Actions do not launch a helper.
An optional keyboard shortcut can be recorded under Settings → Menu. The
fixture's Menu Item opens the Spinnet issue in the default browser. Actions,
Menu bindings, appearance, and triggers are saved automatically.

## Manual acceptance checks

1. Press Mouse Side Button 1 while the pointer is near the middle of a
   display. The overlay appears at the pointer without activating the Host.
2. Move clockwise around the ring. At most one Menu Item is highlighted; the
   center remains a dead zone.
3. Release on `Open URL` and confirm the URL opens and a completion message is
   visible.
4. Open the Menu again and dismiss it with Escape, a click outside the ring, or
   Mouse Side Button 1. None of these dismissal paths runs the Action.
5. Repeat near each display edge and corner. The complete ring remains inside
   the display's visible frame.
6. Open Settings from the status item. Create a second Action, select it as an
   Alternate Action, close and relaunch the Host, and confirm the binding is
   still present. Right-click the Menu Item to expose the Alternate Action.
7. In the Library, add `Open Application`, `Open File`, `Open Folder`, `Run
   Shortcut`, or `Run Keyboard Shortcut`. The Configuration Sheet offers native
   pickers or a shortcut recorder. Text and URL fields use the standard macOS
   editing menu and keyboard shortcuts. Cancel leaves the Slot unchanged; Save
   commits all fields at once.
8. Add `Copy Selected Text`, grant its `Read Selected Text` and `Write
   Clipboard` capabilities in Privacy & Permissions, select text in another
   app, and run the Menu Item. The copied value comes from the current
   selection rather than a configured text parameter.
9. Add `Paste` or `Cut`, grant Spinnet Accessibility permission in Privacy &
   Permissions, focus a text field in another app, and run the Menu Item.
10. To test `Run macOS Service`, select text in the target app and copy the exact
    title from that app's Services menu into the Configuration Sheet. Use the
    full menu path with `/` separators when the service is nested.

## Scripted Action lifecycle checks

Run `./script/build_and_run.sh --lifecycle-check` to open the Debug-only
lifecycle test window. It creates temporary scripted Actions without changing
saved Menu configuration or requesting Capabilities:

- **Slow success (3 seconds)** shows Progress after 500 ms, then completes.
- **Hang until timeout** loops until the four-second deadline. Press Escape
  while Progress is visible to cancel, or wait for `timed_out`.
- Click **Retry** (or press Return) on a failure to start a new execution.

The launcher returns when feedback is dismissed. In this Debug test mode,
success feedback stays visible for ten seconds for inspection. Normal runs
retain the standard feedback duration. The test window is excluded from
release builds.

## Scope

`SpinnetCore` owns manifest/configuration validation, Plugin registration,
Action editing, configuration persistence, Menu geometry, and the Host-level
`HostActionRunner` seam. `SpinnetHost` owns the AppKit overlay, global
shortcuts, settings window, common Host Command adapters, and user-visible
feedback.

Capability-checked Host Services are available through the documented helper
protocol. The Host stores per-Plugin-version Capability decisions and exposes the
current fixture grants in Privacy & Permissions. The Host owns scripted Action
progress, cancellation, deadlines, and terminal feedback. Scripted Actions
reuse one serialized helper per Plugin. After 30 seconds idle the Host requests
exit, then force-terminates any survivor 250 ms later. Plugin disable, uninstall,
update, Capability revocation, and Host shutdown retire helpers immediately.

The current manifest shape is documented in
[`docs/plugin-interface.md`](docs/plugin-interface.md).

# Spinnet

Spinnet is a native macOS Host for mouse-first radial Menus. This slice
implements frontier ticket #12: a bundled Plugin registers one Host-backed URL
Action, and the Host exposes it through a non-activating radial Menu.

## Run

The project requires macOS and Xcode's Swift toolchain. Run these commands from
the repository root:

```sh
swift build
swift test
swift run SpinnetHost
```

The Host registers `Plugins/SpinnetFixture.spinnetplugin` through the public
manifest loader and opens the radial Menu with Control-Option-Space. The
fixture's Menu Item opens the Spinnet issue in the default browser.

## Manual acceptance checks

1. Invoke Control-Option-Space while the pointer is near the middle of a
   display. The overlay appears at the pointer without activating the Host.
2. Move clockwise around the ring. At most one Menu Item is highlighted; the
   center remains a dead zone.
3. Release on `Open URL` and confirm the URL opens and a completion message is
   visible.
4. Open the Menu again and dismiss it with Escape, a click outside the ring, or
   Control-Option-Space. None of these dismissal paths runs the Action.
5. Repeat near each display edge and corner. The complete ring remains inside
   the display's visible frame.

## Scope

`SpinnetCore` owns manifest/configuration validation, Plugin registration, Menu
geometry, and the Host-level `HostActionRunner` seam. `SpinnetHost` owns the
AppKit overlay, global shortcuts, URL execution, and user-visible feedback.

Scripted Actions, Plugin helpers, capabilities, and broader Host Services are
outside this ticket and are intentionally not part of this walking skeleton.

The current manifest shape is documented in
[`docs/plugin-interface.md`](docs/plugin-interface.md).

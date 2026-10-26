# Spinnet

Your everyday Mac actions, gathered in a radial Menu at your pointer.

Spinnet is a native macOS app built around mouse-first control. Arrange the
Commands you use, open the Menu with a mouse button or keyboard shortcut, and
choose an Action without leaving your work.

- **Build your Menu.** Choose Plugins from the Library, arrange Menu Items,
  and give each one a Primary Action and optional Alternate Actions.
- **Bring more tasks within reach.** Official Plugins cover links,
  screenshots, Clipboard History, system monitoring, keep-awake Effects
  and Homebrew package management.
- **Work in native views.** Spinnet renders Plugin search, forms and
  collections using the same native interface.
- **Choose what Plugins can access.** Manage System Permissions, sensitive
  data collection and each Plugin's Capability grants in Settings.

## Try it from source

Requires macOS 13 or later, Xcode's Swift toolchain and a stable code-signing
identity. From the repository root:

```sh
./script/build_and_run.sh
```

Open Settings → Menu and add a Plugin's Preset to an empty Slot. Mouse Side
Button 1 opens the Menu by default; you can change the trigger in Settings.
See the [handbook](HANDBOOK.md#build-and-run) for signing and development options.

## Explore

- [Handbook](HANDBOOK.md): usage, privacy, development and repository layout.
- [Official Plugins](https://github.com/vulpsecula/SpinnetPlugins): installable
  packages and Plugin development.
- [Plugin interface](PluginAPI/README.md): Host compatibility, references, SDKs
  and schemas for Plugin authors.

## Licence

Spinnet is [GPL-3.0-only](LICENSE). The public [Plugin interface](PluginAPI/LICENSE)
and [official Plugins](https://github.com/vulpsecula/SpinnetPlugins) are MIT-licensed.
See the [licence policy](HANDBOOK.md#licence) for distribution, contributions
and branding.

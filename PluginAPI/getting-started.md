# Your first Plugin

The [Hello example](examples/Hello.spinnetplugin/manifest.json) is a complete,
installable current Plugin. It displays a toast and requests no Capabilities or
macOS System Permissions.

## Package

Copy the [Hello.spinnetplugin](examples/Hello.spinnetplugin/manifest.json) directory
with both files intact:

```text
Hello.spinnetplugin/
  manifest.json
  main.js
```

The manifest declares the Plugin's identity, one JavaScript Command and its
ready-to-use Menu Item Preset. Its empty `capabilities` list requests no protected
Host Services. See the complete [manifest](examples/Hello.spinnetplugin/manifest.json)
and [manifest reference](reference/manifest.md) before adding configuration or access.

The entire [main.js](examples/Hello.spinnetplugin/main.js) script is:

```js
spinnet.ui.toast("Hello from Spinnet");
```

The Host supplies the `spinnet` global. A script's final expression is its answer;
this example answers with a toast and performs no Host Service request. Scripts
run in JavaScriptCore, without Node.js imports or direct operating-system access.
The Host injects the SDK, so the installed package needs no SDK copy.

## Install and run

1. Run Spinnet and open Settings → Menu.
2. Choose **Install or Update Plugin…** and select the `Hello.spinnetplugin` directory.
3. Add its **Hello** Preset to an empty Menu Slot.
4. Invoke the Menu with your configured trigger and choose **Hello**. A toast displays “Hello from Spinnet”.

After changing the package, choose **Install or Update Plugin…** again to install
the replacement. A renamed or changed Command can make an existing Action
unavailable; keep Command IDs stable and follow the [update rules](reference/manifest.md#commands).

## Build further

- Declare the supported [Host range](reference/compatibility.md), initially `^1.0.0`.
- Use the [current types](sdk/spinnet.d.ts) for editor assistance.
- Read [scripts and answers](reference/scripts.md), [pages](reference/pages.md)
  and the [Host Service catalogue](reference/namespaces.md) as needed.
- Declare each protected operation's Capability and scope in the manifest;
  declarations request authority, and the Host enforces the user's grants.
- Use the [SpinnetPluginTestKit](../Sources/SpinnetPluginTestKit/README.md) to run
  the package through the helper and check actual answers. Contract validation
  supplements the normal in-app check of your Plugin's behavior.

The [contract fixtures](fixtures/README.md) include intentional invalid values
and type errors. Start by copying this example rather than a fixture sample.

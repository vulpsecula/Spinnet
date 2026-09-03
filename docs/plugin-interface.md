# Documented Plugin Interface

Frontier tickets #12 and #13 accept a local `.spinnetplugin` directory
containing a `manifest.json`. The Host loads the package through
`PluginManifestLoader` and registers it with `PluginRegistry`.

## Manifest

The current walking skeleton supports Host Commands only:

```json
{
  "protocol_version": "1.0",
  "id": "com.example.plugin",
  "name": "Example Plugin",
  "version": "1.0.0",
  "commands": [
    {
      "id": "example.open",
      "title": "Open URL",
      "execution": "host",
      "host_command": "url.open"
    }
  ]
}
```

`id`, `name`, `version`, Command IDs, and Command titles must be non-empty and
no longer than 256 characters. Command IDs must be unique, and the protocol
version must be `1.0`.

The supported Host Command is `url.open`. Its Action input is a JSON string
containing a URL. The production Host passes the configured Action to the
system workspace; tests inject a `HostCommandExecutor` at the
`HostActionRunner` seam.

## Host configuration

The Host configuration creates Actions from registered Commands and binds them
to Menu Items:

```json
{
  "actions": [
    {
      "id": "fixture-open-url",
      "pluginID": "com.example.plugin",
      "commandID": "example.open",
      "title": "Open URL",
      "execution": "host",
      "hostCommand": "url.open",
      "input": "https://example.com"
    }
  ],
  "menu": {
    "items": [
      {
        "primary_action_id": "fixture-open-url",
        "alternate_action_ids": []
      }
    ]
  }
}
```

`MenuConfiguration` contains between one and twelve Menu Items. Each Menu Item
has one Primary Action and may have multiple Alternate Actions. Every bound
Action ID must be unique and present in the Host configuration.

`PluginRegistry.availableCommands()` supplies the enabled Plugin Commands to
the Host-rendered settings window. The settings window provides a text or JSON
input field for the Command's configuration value and supports creating,
editing, and removing Actions. Changes are saved after each successful edit by
`HostConfigurationStore` and restored on the next Host launch.

An Action retains the Command definition it was configured from. Before
execution, the Host compares that snapshot with the currently registered
Plugin. A missing Plugin, disabled Plugin, missing Command, or changed Command
is shown as unavailable and produces a `command_unavailable` terminal outcome;
the stale Host executor is not called.

The radial Menu executes a Primary Action with its normal selection gesture.
Right-clicking a Menu Item, or pressing `Option-Return` after keyboard
selection, opens its Alternate Actions. Arrow keys select Menu Items and
Return executes the Primary Action. Alternate Actions that are unavailable
are visible but disabled.

Scripted Actions, Plugin helpers, capabilities, and additional Host Services
are intentionally deferred to later tickets.

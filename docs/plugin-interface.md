# Documented Plugin Interface

Frontier ticket #12 accepts a local `.spinnetplugin` directory containing a
`manifest.json`. The Host loads the package through `PluginManifestLoader` and
registers it with `PluginRegistry`.

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

## Menu configuration

The Host binds an `ActionConfiguration` to each `MenuItemConfiguration`. A Menu
contains between one and twelve items, and every bound Action ID must be
unique and present in the Host configuration. The current Menu Item has one
primary Action.

Scripted Actions, Plugin helpers, capabilities, and additional Host Services
are intentionally deferred to later tickets.

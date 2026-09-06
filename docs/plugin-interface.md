# Documented Plugin Interface

Frontier tickets #7, #12, and #13 accept a local `.spinnetplugin` directory
containing a `manifest.json`. The Host loads the package through
`PluginManifestLoader` and registers it with `PluginRegistry`.

## Manifest

The current walking skeleton supports Host Commands and Common JavaScript Commands:

```json
{
  "protocol_version": "1.0",
  "id": "com.example.plugin",
  "name": "Example Plugin",
  "version": "1.0.0",
  "preset": {
    "readiness": "ready_to_use",
    "is_configurable": true,
    "default_primary_command_id": "example.open",
    "default_alternate_command_ids": [],
    "default_inputs": {
      "example.open": "https://example.com"
    }
  },
  "commands": [
    {
      "id": "example.open",
      "title": "Open URL",
      "execution": "host",
      "host_command": "url.open"
    },
    {
      "id": "example.transform",
      "title": "Transform Text",
      "execution": "javascript",
      "script": "transform.js"
    }
  ]
}
```

`id`, `name`, `version`, Command IDs, and Command titles must be non-empty and
no longer than 256 characters. Command IDs must be unique, and the protocol
version must be `1.0`.

Every Plugin appears once in the Library through its single `preset` declaration.
The Host assigns the trusted Built-in or Plugin Library group when it registers
the package; a third-party manifest cannot claim Built-in identity. `readiness`
is `ready_to_use` when every default Primary and Alternate Command
has a valid, immediately executable value in `default_inputs`; otherwise use
`setup_required`. The latter is
visible in the Library but awaits the Configuration Sheet workflow before it can
be added. `is_configurable` is presented independently from readiness. Manifests
without `preset` remain compatible and appear as configurable, Setup-Required
Plugin Presets whose Primary Command is the first declared Command.

The supported Host Command is `url.open`. Its Action input is a JSON string
containing a URL. The production Host passes the configured Action to the
system workspace; tests inject a `HostCommandExecutor` at the
`HostActionRunner` seam.

The `javascript` execution kind points to a UTF-8 Common JavaScript source
file relative to the Plugin package root. The Host reads that source and sends
it, together with the configured input, to a short-lived helper executable.
The helper is a separate SwiftPM product that links the system
`JavaScriptCore` framework; `SpinnetHost` and `SpinnetCore` do not link or
initialize a JavaScript runtime. The script receives these globals:

- `input`, containing the Action's JSON value;
- `inputJSON`, containing the same value as JSON text; and
- `pluginID`, `actionID`, `commandID`, and `invocationID` identifying the
  current invocation.

The helper exchange is newline-delimited JSON using protocol version `1.0`.
The JSON object before the newline is the message body; it is accepted when
its UTF-8 representation is at most 1 MiB. The newline delimiter is framing
and is not included in that limit. The two supported top-level message
variants are:

```json
{
  "type": "invocation",
  "protocol_version": "1.0",
  "invocation_id": "invocation-1",
  "plugin_id": "com.example.plugin",
  "action_id": "action-1",
  "command_id": "example.transform",
  "script_path": "transform.js",
  "script_source": "input",
  "input": "Selected text"
}
```

```json
{
  "type": "terminal",
  "protocol_version": "1.0",
  "invocation_id": "invocation-1",
  "action_id": "action-1",
  "terminal": {
    "kind": "succeeded",
    "result": {"value": "transformed"}
  }
}
```

The terminal `kind` is either `succeeded` with a JSON `result`, or `failed`
with a `failure` containing one of the documented failure categories. Unknown
protocol versions, top-level `type` values, terminal `kind` values, missing
fields, invalid values, and payloads above 1 MiB are rejected.

The Host chooses the Plugin identity when it creates a helper connection. The
`plugin_id` in an invocation is Host-owned context for the script; the Host
does not accept Plugin identity or Capability claims from a helper response.
Invocation and Action identifiers must be non-empty and unique on a
connection. One invocation may be in flight at a time, and its terminal
response must carry the matching invocation and Action identifiers. A
duplicate, out-of-order, or otherwise invalid message closes only that helper
connection and gives its Action the stable `runtime_protocol_failed` outcome.
The Host also bounds the wait for a terminal frame by the four-second scripted
Action deadline; a partial or silent helper is terminated and reported through
the same stable failure path.

Each invocation must produce exactly one terminal response, either a JSON
result or a stable script failure. A helper process that exits by signal is
reported by the Host as `helper_crashed`; the Host process remains alive.

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

`PluginRegistry.menuItemPresets()` supplies one Library entry per registered
Plugin, including disabled Plugins as unavailable Presets. Commands are shown
inside that entry rather than duplicated as top-level Library entries. The
settings window supports adding a Ready-to-Use Preset, explicit replacement,
moving a Menu Item only to an empty Slot, and deletion. Changes are saved after
each successful edit by `HostConfigurationStore` and restored on the next Host
launch.

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

Capability-checked Host Services, helper reuse/retirement, and user-visible
progress/cancellation remain later tickets. The initial helper exchange is
deliberately narrow; it establishes the process boundary without granting a
Plugin direct access to protected operating-system facilities.

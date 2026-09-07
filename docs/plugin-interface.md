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
  "capabilities": ["read_selected_text", "write_clipboard"],
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

`capabilities` is optional and declares which protected Host Services the
Plugin may request. The supported declarations are `read_selected_text` and
`write_clipboard`. A declaration is not a grant: the Host stores an explicit
per-Plugin-version, per-Capability decision (`not_determined`, `denied`, or
`granted`) and treats every decision other than `granted` as denied. A new
manifest version starts with `not_determined` decisions, so expanding a
Plugin's declared Capability scope requires fresh consent.

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

When a ready Preset is placed into a Menu Slot, the Host creates one Action for
the declared Primary Command and one Action for each
`default_alternate_command_ids` entry, using `default_inputs` for each Action.
The normal gesture runs the Primary Action; the runtime right-click Actions menu
lists the Primary Action and all configured Alternate Actions. Commands omitted
from the Preset's default list are not silently bound to the Slot. For example, a
screenshot Plugin can declare `capture_region` as its Primary Command and put
`capture_screen` in `default_alternate_command_ids`; a future third capture mode
can be added to that same list without changing the Slot model.

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
- `requestHostService(name, input)`, which sends a Capability-checked request
  to the Host and returns its JSON result. The helper exposes no direct
  protected operating-system API.

The helper exchange is newline-delimited JSON using protocol version `1.0`.
The JSON object before the newline is the message body; it is accepted when
its UTF-8 representation is at most 1 MiB. The newline delimiter is framing
and is not included in that limit. The four supported top-level message
variants are `invocation`, `host_service_request`, `host_service_response`,
and `terminal`:

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

While a script is running, the helper can request a Host Service. The request
contains only the connection-bound invocation and Action identifiers; it does
not carry a Plugin identity or Capability claims:

```json
{
  "type": "host_service_request",
  "protocol_version": "1.0",
  "invocation_id": "invocation-1",
  "action_id": "action-1",
  "request_id": "host-service-1",
  "service": "read_selected_text",
  "input": null
}
```

The Host responds on the same connection and evaluates the current manifest,
stored grant, and required System Permission for every request:

```json
{
  "type": "host_service_response",
  "protocol_version": "1.0",
  "invocation_id": "invocation-1",
  "action_id": "action-1",
  "request_id": "host-service-1",
  "outcome": {
    "kind": "succeeded",
    "result": "Selected text"
  }
}
```

The MVP services are:

- `read_selected_text` requires the `read_selected_text` Capability and the
  macOS Accessibility System Permission. Its input is `null` and its result is
  a string.
- `write_clipboard` requires the `write_clipboard` Capability. Its input is a
  string and its result is `null`.

A withheld Capability produces a `capability_denied` failure; a missing
required macOS permission produces `system_permission_denied`; and provider
or request failures produce `host_service_failed`. The helper turns a failed
Host Service response into a failed Action, so a denied request cannot fall
through to a later protected operation.

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
`plugin_id` in an invocation is Host-owned context for the script; Host Service
authorization uses the registered package bound to that connection and does
not accept Plugin identity or Capability claims from a helper message.
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

The helper process is the JavaScript execution boundary, not a source of OS
authority. Protected operations are performed by the Host-side broker only
after the current Capability grant and System Permission checks succeed.

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
selection, opens its Actions menu with the Primary Action followed by its
Alternate Actions. Arrow keys select Menu Items and Return executes the Primary
Action. Actions that are unavailable are visible but disabled.

Capability-checked Host Services are available through the public helper
protocol described above. The Host's Privacy & Permissions page presents and
persists the current per-Plugin-version decisions; a later settings ticket can add
installation-time consent and update-scope disclosure. Helper
reuse/retirement and user-visible progress/cancellation remain separate
lifecycle tickets. The helper exchange remains deliberately narrow and does
not grant a Plugin direct access to protected operating-system facilities.

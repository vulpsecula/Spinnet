# Documented Plugin Interface

Frontier tickets #7, #12, #13, #17, and #18 accept a local `.spinnetplugin` directory
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
      "is_configurable": true,
      "host_command": "url.open",
      "configuration_field": {
        "kind": "url",
        "title": "URL",
        "placeholder": "https://example.com"
      }
    },
    {
      "id": "example.transform",
      "title": "Transform Text",
      "execution": "javascript",
      "is_configurable": false,
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
is `ready_to_use` when every configurable default Primary and Alternate Command
has a valid, immediately executable value in `default_inputs`; a non-configurable
Command does not need an input. Otherwise use `setup_required`. The latter is
visible in the Library but awaits the Configuration Sheet workflow before it can
be added. Preset-level `is_configurable` describes whether the Slot can be
edited; each Command's `is_configurable` independently controls whether that
Command exposes an Action parameter editor. A configurable Command may also
declare a `configuration_field` (or the legacy `configuration` key) to select
the Host-rendered field kind: `text`, `multiline_text`, `toggle`, `choice`,
`application`, `file`, `folder`, `shortcut`, `keyboard_shortcut`, or `url`.
`choice` fields provide a non-empty `choices` array. The Host supplies native
application/file/folder pickers and keyboard shortcut recording controls;
plain text and URL fields use the standard macOS editing commands. Manifests without `preset`
remain compatible and appear as configurable, Setup-Required Plugin Presets
whose Primary Command is the first declared Command.

When a ready Preset is placed into a Menu Slot, the Host creates one Action for
the declared Primary Command and one Action for each
`default_alternate_command_ids` entry. Configurable Actions use their matching
`default_inputs` value; non-configurable Actions receive a null internal input
and do not show a parameter field.
The normal gesture runs the Primary Action; the runtime right-click Actions menu
lists the Primary Action and all configured Alternate Actions. Commands omitted
from the Preset's default list are not silently bound to the Slot. For example, a
screenshot Plugin can declare `capture_region` as its Primary Command and put
`capture_screen` in `default_alternate_command_ids`; a future third capture mode
can be added to that same list without changing the Slot model. The Slot
Configuration Sheet may select any other Command from the same Plugin as an
Alternate Action; only Commands whose declaration sets `is_configurable` to
true receive a parameter field.

The supported Host Command catalogue is:

| Host Command | Action input | Host integration | Authority |
| --- | --- | --- | --- |
| `url.open` | URL string, or `{ "url": "…" }` | `NSWorkspace` | none |
| `application.open` | application path or bundle identifier | `NSWorkspace` | none |
| `file.open` | file path, or `{ "path": "…" }` | `NSWorkspace` | file must exist |
| `folder.open` | folder path, or `{ "path": "…" }` | `NSWorkspace` | folder must exist |
| `keyboard_shortcut.invoke` | `{ "key": "P", "modifiers": ["command"] }` or `key_code` | Quartz Event Services | Accessibility System Permission |
| `service.invoke` | Service name, or `{ "name": "…", "input": "…" }` | macOS Services | service availability |
| `shortcut.invoke` | Shortcut name, or `{ "name": "…", "input": "…" }` | Public `shortcuts` command-line interface | Shortcut availability |
| `clipboard.copy` | `null` to copy current selected text, or legacy text string / `{ "text": "…" }` | Host clipboard | `write_clipboard`; `read_selected_text` when input is `null` |
| `clipboard.paste` | `null` | Quartz Event Services (`Command-V`) | Accessibility System Permission |
| `clipboard.cut` | `null` | Quartz Event Services (`Command-X`) | Accessibility System Permission |
| `feedback.present` | message string, or `{ "message": "…" }` | Host-rendered feedback | none |

For `service.invoke`, use the exact item title shown in the active application's
Services menu. A selected text object must be present when the service expects
text input; nested service paths use `/` separators. The Settings sheet explains
this beside the service name field.

The Host also registers standalone Built-in Presets for Open URL, Open
Application, Open File, Open Folder, Run Shortcut, Run Keyboard Shortcut, Run
macOS Service, Copy Selected Text, Paste, and Cut. They share the same Command catalogue
and Settings workflow without requiring a fixture Plugin. The bundled fixture
Plugin retains its declarations for compatibility with existing persisted
Actions and continues to provide deterministic JavaScript examples. The
production Host validates the configured JSON shape before executing an
Action, checks the Command's required Capability and System Permission, then
passes the request to an AppKit adapter. Tests inject a recording adapter at
the `HostActionRunner` seam, so automated checks verify the external request
without opening a real application, mutating the clipboard, or posting a
keyboard event.

An unavailable application, file, folder, Service, Shortcut, or system request
produces a stable terminal failure. A missing `write_clipboard` grant produces
`capability_denied`; a missing Accessibility grant for a keyboard shortcut
produces `system_permission_denied`. The Host never silently falls back to a
different Command.

The `javascript` execution kind points to a UTF-8 Common JavaScript source
file relative to the Plugin package root. The Host reads that source and sends
it, together with the configured input, to an on-demand per-Plugin helper executable.
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
Invocation and Action identifiers must be non-empty. The Host generates a fresh
invocation identifier for every explicit execution, including repeated execution
of a configured Action. One invocation may be in flight per Plugin, and its terminal
response must carry the matching invocation and Action identifiers. A
duplicate, out-of-order, or otherwise invalid message closes only that helper
connection and gives any waiting Action the stable `runtime_protocol_failed` outcome.
An unsolicited message received after an Action finishes retires the helper;
it cannot change the finished outcome or become the next Action's result.
The Host also bounds the wait for a terminal frame by the four-second scripted
Action deadline; a partial or silent helper is terminated and reported through
the same stable failure path.

Each invocation must produce exactly one terminal response, either a JSON
result or a stable script failure. A helper process that exits by signal is
reported by the Host as `helper_crashed`; the Host process remains alive.

Consecutive scripted Actions reuse their Plugin's process; each invocation
receives a fresh JavaScript context. Registration, installed-idle state, Menu
opening, and declarative Commands start no helper. After its Action queue has
been empty for 30 seconds, the Host sends this graceful-exit request and closes
the input stream:

```json
{"type":"shutdown","protocol_version":"1.0"}
```

The helper exits on this request or input EOF. A process still alive 250 ms
after the request is force-terminated. Disabling, uninstalling, or updating a
Plugin, revoking a granted Capability, or shutting down the Host terminates
its helpers immediately, including processes already awaiting graceful exit.
An explicit later scripted Action can start a fresh helper; retired work is
never replayed. The Host rejects new helper execution after shutdown.

While a helper is alive, the Host samples its macOS `phys_footprint` every
100 ms. Two consecutive samples at or above 64 MiB force-terminate that helper
and invalidate its current or queued Actions exactly once. The resulting
user-facing category is the stable `helper_terminated` category. The resource
breach and any protocol or process diagnostics are written to the protected
system log; user-facing feedback receives only the Plugin, Action, and stable
failure category.

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
      "isConfigurable": true,
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

`MenuConfiguration` contains between one and twelve Slots. Each Slot may carry
an optional user-provided `name`; when omitted, the Host displays the bound
Primary Action's title (or `Empty Slot` when the Slot has no Menu Item). Each
Menu Item has one Primary Action and may have multiple Alternate Actions. A
Menu Item may also retain `disabled_alternate_action_ids` and an
`alternate_action_order` so the Settings editor can hide an Alternate without
discarding its parameters; older configurations may omit both keys. Every
bound Action ID must be unique and present in the Host configuration.

`PluginRegistry.menuItemPresets()` supplies one Library entry per registered
Plugin that opts into the user-facing catalogue, including disabled Plugins as
unavailable Presets. Commands are shown inside that entry rather than
duplicated as top-level Library entries. A compatibility package can remain
registered for persisted Actions while opting out of the Library. The
settings window supports adding a Ready-to-Use Preset, a Configuration Sheet
for Setup-Required Presets, explicit replacement, moving a Menu Item only to an
empty Slot, and deletion. Sheet edits use Save/Cancel atomically; page-level
edits and Appearance changes are saved immediately and expose Undo/Redo.
Changes are restored on the next Host launch.

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
installation-time consent and update-scope disclosure. The Host owns helper
reuse/retirement and user-visible progress/cancellation. The helper exchange does
not grant a Plugin direct access to protected operating-system facilities.

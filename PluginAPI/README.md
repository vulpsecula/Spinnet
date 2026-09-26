# Spinnet Plugin API

This directory is the versioned home of the Documented Plugin Interface: the
contract a Plugin builds against (ADR 0013). Everything here is published under
the MIT licence in [`LICENSE`](LICENSE), so a Plugin can copy the schemas and
type definitions without taking on the GPL that covers the rest of Spinnet.

| File | Contents |
| --- | --- |
| [`schemas/manifest.schema.json`](schemas/manifest.schema.json) | JSON Schema (draft 2020-12) for a package's `manifest.json` |
| [`spinnet.d.ts`](spinnet.d.ts) | Types for the globals a Plugin script runs with, including `spinnet` |
| [`spinnet.js`](spinnet.js) | Source of the `spinnet` SDK object the helper injects into every script |
| [`SpinnetSDK.swift`](SpinnetSDK.swift) | Embeds `spinnet.js` in the helper when it is built |

## Plugin API Level

The interface is versioned by an integer Plugin API Level. Additive changes
raise it. A manifest's `api_level` is the lowest level the Plugin needs, and a
Host installs a Plugin only if it supports that level; otherwise it refuses and
asks the user to update Spinnet.

`protocol_version` is unrelated: it only frames the messages between the Host
and the Plugin's helper, and stays `"1.0"`.

Level 1 is the first level. It is still being shaped and may change until it
is published; no Plugin outside this repository depends on it yet.

The schema requires `api_level`. A Host reads a manifest written before the
field existed as needing Level 1, the level that interface became.

## The spinnet SDK

Every script runs with a `spinnet` global, organised by area. Each wrapper is
a camelCase name for exactly one Host Service: it sends its argument as the
service's input, unchanged (`null` when omitted), and returns the answer, so it
fails exactly as `requestHostService` does. A refused Capability or System
Permission ends the whole invocation even if the script catches the error.
`requestHostService(name, input)` stays available as the raw call.

| Area | Wrappers |
| --- | --- |
| `spinnet.selection` | `readText` (`read_selected_text`), `replace` (`insert_text`) |
| `spinnet.clipboard` | `read` (`read_current_clipboard`), `write` (`write_clipboard`), `history` (`read_clipboard_history`), `historyContent` (`read_clipboard_history_content`), `showHistory` (`present_clipboard_history`, the Host Surface) |
| `spinnet.window` | `read` (`read_focused_window`), `setFrame` (`set_focused_window_frame`), `toggleFullScreen` (`toggle_focused_window_full_screen`), `restore` (`restore_focused_window_frame`) |
| `spinnet.open` | `url` (`open_url`), `path` (`open_local_path`) |
| `spinnet.http` | `request` (`https_request`) |
| `spinnet.text` | `detectLanguage` (`detect_language`, which needs no Capability) |
| `spinnet.screen` | `capture` (`capture_screen`) |
| `spinnet.apps`, `spinnet.storage`, `spinnet.ui` | Empty until External Apps, Plugin Storage and Plugin Views land |
| `spinnet.environment` | `apiLevel`, `hostVersion`, `preferredLanguage`, `pluginID`, `commandID`, `actionID`, `invocationID` |

`present_results`, `smart_jump` and `invoke_external_app` have no wrapper:
they are removed before Level 1 is published.

## What the manifest schema checks

The schema checks the shape of each member: which members exist, their types,
the allowed Capabilities, Host Commands, and field kinds, and the length limits.
The Host checks the rest when it loads a package, such as that the Preset names
declared Commands, that each Capability scope belongs to a declared Capability
and names the data and targets it affects, that default inputs and settings
suit their fields, and that each `migrations` step moves a retired Command or
settings key onto a declared one and drops only the input of a Command that is
not configurable.

`migrations` may rename Commands, rename settings keys, and drop an Action's
input, and nothing else; a member the Host does not know is refused, so a
migration can never grant a Capability. The Host applies the block every time
it registers or updates the Plugin, and applying it again changes nothing.

A few older spellings the Host still reads are not part of the interface and
the schema rejects them: `script_path` and `javascript` for `script`,
`configuration` for `configuration_field`, and the `common_javascript` and
`script` executions.

# Spinnet Plugin API

This directory is the Documented Plugin Interface: the contract a Plugin
builds against (ADR 0013), versioned by Plugin API Level. It is the single
reference for that contract. Everything here is published under the MIT
licence in [`LICENSE`](LICENSE), so a Plugin can copy the schemas, type
definitions and SDK without taking on the GPL that covers the rest of Spinnet.
A Plugin that reaches Spinnet only through this interface keeps its own
licence.

| File | Contents |
| --- | --- |
| [`reference/manifest.md`](reference/manifest.md) | The package, its manifest, Capabilities and scopes, Commands, Host Commands, fields, Plugin Settings and `migrations` |
| [`reference/scripts.md`](reference/scripts.md) | How a script runs: its globals, the `spinnet` SDK, its answer, failures, limits, and the helper protocol |
| [`reference/host-services.md`](reference/host-services.md) | Every Host Service: input, result, Capability, System Permission and rules |
| [`reference/views.md`](reference/views.md) | Plugin Views, View Sessions, standard actions and Host-Fetched Sections |
| [`schemas/manifest.schema.json`](schemas/manifest.schema.json) | JSON Schema (draft 2020-12) for a package's `manifest.json`, the `list` field and `migrations` included |
| [`schemas/plugin-view.schema.json`](schemas/plugin-view.schema.json) | The Plugin View a script answers with |
| [`schemas/view-session.schema.json`](schemas/view-session.schema.json) | The View Events a script receives and the answers it may give |
| [`schemas/host-fetched-section.schema.json`](schemas/host-fetched-section.schema.json) | A Detail section's `fetch` and the `section_delivered` View Event |
| [`schemas/https-request.schema.json`](schemas/https-request.schema.json) | `https_request` and its Credential Uses |
| [`schemas/external-apps.schema.json`](schemas/external-apps.schema.json) | `perform_app_operation`, the Reviewed App Interfaces the Host ships, and `open_deep_link` |
| [`schemas/plugin-storage.schema.json`](schemas/plugin-storage.schema.json) | The Plugin Storage Host Services |
| [`spinnet.d.ts`](spinnet.d.ts) | Types for the globals a script runs with, including `spinnet` |
| [`spinnet.js`](spinnet.js) | Source of the `spinnet` SDK object the helper injects into every script |
| [`SpinnetSDK.swift`](SpinnetSDK.swift) | Embeds `spinnet.js` in the helper when it is built |

The schemas check shapes. What a shape cannot say, such as that a Preset
names declared Commands or that a request goes to a consented host, the
reference pages state and the Host checks. Spinnet's tests hold the Host to
the schemas, this catalogue to the Host Services it registers, and the
budgets on these pages to the Host's constants.

## Plugin API Level

The interface is versioned by an integer Plugin API Level. A manifest's
`api_level` is the lowest level the Plugin needs, and a Host installs a Plugin
only if it supports that level; otherwise it refuses and asks the user to
update Spinnet. Additive changes raise the level: a Plugin written for Level 1
keeps working on a Host that supports a later one.

Level 1 is the first published level, and the one this Host supports. The
schema requires `api_level`; a Host reads a manifest written before the field
existed as needing Level 1.

`protocol_version` is unrelated: it only frames the messages between the Host
and the Plugin's helper, and stays `"1.0"`.

## What Level 1 offers

A Plugin is a package with a manifest and scripts. Its Commands either name a
Host Command, which the Host performs itself, or run a script. A script reads
its context and acts through Host Services, each checked against the
Capability and System Permission it needs, and describes Plugin Views the Host
draws. The `spinnet` SDK wraps each Host Service under the namespace of its
area; `requestHostService(name, input)` is the raw call beneath it.

### Host Services, by SDK namespace

| Namespace | Wrapper | Host Service | Capability | System Permission |
| --- | --- | --- | --- | --- |
| `spinnet.selection` | `readText` | `read_selected_text` | `read_selected_text` | Accessibility |
| | `replace` | `insert_text` | `insert_into_focused_app` | Accessibility |
| `spinnet.clipboard` | `read` | `read_current_clipboard` | `read_current_clipboard` | none |
| | `write` | `write_clipboard` | `write_clipboard` | none |
| | `history` | `read_clipboard_history` | `read_clipboard_history` | none |
| | `historyContent` | `read_clipboard_history_content` | `read_clipboard_history` | none |
| | `showHistory` | `present_clipboard_history`, the one Host Surface | `read_clipboard_history` | none |
| `spinnet.window` | `read` | `read_focused_window` | `position_focused_window` | Accessibility |
| | `setFrame` | `set_focused_window_frame` | `position_focused_window` | Accessibility |
| | `toggleFullScreen` | `toggle_focused_window_full_screen` | `position_focused_window` | Accessibility |
| | `restore` | `restore_focused_window_frame` | `position_focused_window` | Accessibility |
| `spinnet.open` | `url` | `open_url` | `open_url` | none |
| | `path` | `open_local_path` | `open_local_path` | none |
| `spinnet.http` | `request` | `https_request`, with Credential Uses | `contact_https` | none |
| `spinnet.apps` | `perform` | `perform_app_operation`, an operation of a Reviewed App Interface | `control_external_app` | Automation, asked by macOS |
| | `openDeepLink` | `open_deep_link`, one of the Plugin's Deep Link Templates | `control_external_app` | none |
| `spinnet.text` | `detectLanguage` | `detect_language` | none | none |
| `spinnet.screen` | `capture` | `capture_screen` | `capture_screen` | Screen Recording |
| `spinnet.storage` | `get` | `get_storage_value` | none | none |
| | `set` | `set_storage_value` | none | none |
| | `remove` | `remove_storage_value` | none | none |
| | `keys` | `list_storage_keys` | none | none |
| | `clear` | `clear_storage` | none | none |

`monitor_clipboard` is a Capability a manifest may declare and a user may
grant, but no Host Service uses it at Level 1: monitoring stays unavailable.
The contracts are in [Host Services](reference/host-services.md).

### Plugin Views, in `spinnet.ui`

`spinnet.ui` only builds views and answers; it requests no Host Service. A
view has a title and optional subtitle, then these components in this order,
at least one of the last three (see [Plugin Views](reference/views.md)):

| Component | Builders | What the Host draws |
| --- | --- | --- |
| `settings` | `setting` | Controls for up to 6 of the Plugin's own `choice` and `toggle` settings, two `choice` controls optionally joined by a swap button |
| `form` | `form`, `textField`, `multilineTextField`, `urlField`, `toggleField`, `choiceField` | 1 to 20 fields of the kinds `text`, `multiline_text`, `url`, `toggle` and `choice`, a `text` or `url` field optionally with a live `status` and `accent` |
| `detail` | `detail`, `section` | 1 to 20 sections of text in a Markdown subset, each with a Copy button, or fetched by the Host |
| `actions` | `action` and the standard actions below | Up to 12 buttons with optional keyboard shortcuts |

The answers are built by `show` (a view and its state), `toast` and `close`.
A toast shows briefly inside the view, or near the pointer without one.

Standard actions are performed by the Host itself, without a View Event:

| Standard action | Builder | Needs |
| --- | --- | --- |
| `copy_text` | `copyText` | `write_clipboard` |
| `open_url` | `openURL` | `open_url` |
| `insert_text` | `insertText` | `insert_into_focused_app` and Accessibility |
| `open_plugin_settings` | `openPluginSettings` | nothing |

View Events arrive as the script's `event` global: `field_changed`,
`submitted`, `action_chosen`, `setting_changed`, `settings_swapped` and
`section_delivered`. A Detail section with `fetch` is a Host-Fetched
Section, sent by the Host with the Plugin's Credential Uses applied.

### The manifest

The manifest declares the Plugin's Commands, its one Menu Item Preset, the
Capabilities it may request and their scopes, its Plugin Settings, and
`migrations` for data an earlier version left behind (see
[the manifest](reference/manifest.md)). The Capabilities are
`read_selected_text`, `write_clipboard`, `read_current_clipboard`,
`read_clipboard_history`, `monitor_clipboard`, `contact_https`,
`control_external_app`, `position_focused_window`, `open_url`,
`open_local_path`, `capture_screen` and `insert_into_focused_app`.

A Command that runs no script names one of these Host Commands:
`url.open`, `application.open`, `file.open`, `folder.open`,
`keyboard_shortcut.invoke`, `service.invoke`, `shortcut.invoke`,
`clipboard.copy`, `clipboard.paste`, `clipboard.cut`, `feedback.present`,
`screen.capture_area`, `screen.capture_full_screen`, `screen.capture_window`
and `deep_link.open`.

`spinnet.environment` holds `apiLevel`, `hostVersion`, `preferredLanguage`,
`pluginID`, `commandID`, `actionID` and `invocationID`.

## Candidates for later levels

These are left out of Level 1 because no Spinnet Plugin needs them yet. Each
is added, when a Plugin does, as a Plugin-independent Host Service or view
component with its own Capability where it reads or changes anything, which
raises the Plugin API Level.

| Candidate | The need that would bring it in |
| --- | --- |
| List | A view of many rows to search, choose from, or act on, such as a history, favourites, or a dictionary's grouped results; Detail sections stop at 20 and have no selection |
| Progress | A task the user waits on longer than a toast lasts, with a way to cancel it, such as a multi-step download or a batch |
| Selected Finder items | A Command that acts on the files the user has selected in Finder, such as converting or sharing them |
| The frontmost application | A Command whose behaviour depends on the App in front, such as a per-App shortcut or reading the current browser page |
| Revealing a file in Finder | A Command that shows the user where something is, rather than opening it, as `open_local_path` does |
| Icons | Menu Items, actions or rows that need a picture to tell them apart |
| Images | A view that shows an image the Plugin produced or fetched, such as a QR code or a preview, or copies one to the clipboard |
| Confirmation | An action that cannot be undone, such as clearing stored history, asking the user first inside the view |
| Launching another Command | One Command handing over to another of the same Plugin, such as a search result opening its detail |

## What Spinnet will not offer

| Not offered | Why |
| --- | --- |
| Live Command metadata, such as a title or subtitle updated in the Menu | It needs a script running while the Menu is idle; Spinnet keeps no resident runtime (ADR 0004), and a helper lives only for a bounded invocation (ADR 0007) |
| Menu bar extras | The same: a Plugin's item in the menu bar would need a script kept alive to update it |
| Background schedules | The same: a script that runs on a timer runs when the user asked for nothing, outside any invocation the Host can bound and show |
| Browser extension access | It reaches pages, tabs and history in another App, which no Capability can disclose precisely enough to consent to |
| Arbitrary file operations | Reading, writing or deleting any path reaches far beyond what one Capability can disclose; Level 1 offers opening a path and Plugin Storage instead, and exports would come as user-chosen destinations |
| AI tools | Handing a Plugin's operations to a model lets the model, not the user, decide what runs and with what data, which consent to a Capability cannot cover |

## Licence

The files in this directory are published under the MIT licence in
[`LICENSE`](LICENSE). The Host that implements them is `GPL-3.0-only`.

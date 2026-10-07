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
| [`reference/namespaces.md`](reference/namespaces.md) | Level 2: every Host Service under one `namespace.verb` ID, where each is offered, its input and authority |
| [`reference/host-operations.md`](reference/host-operations.md) | Level 2: Requested Host Operations an answer commits and the Host performs, their outcomes, and where insertion goes in a View Session |
| [`reference/pages.md`](reference/pages.md) | Level 2: pages of identified components with a List or Grid, the input the Host keeps, windows of items, and Explicit Calls into the open View Session |
| [`reference/level-1-names.md`](reference/level-1-names.md) | Level 2: every Level 1 name and the catalogue ID that replaces it |
| [`schemas/manifest.schema.json`](schemas/manifest.schema.json) | JSON Schema (draft 2020-12) for a package's `manifest.json`, the `list` field and `migrations` included |
| [`schemas/plugin-view.schema.json`](schemas/plugin-view.schema.json) | The Plugin View a script answers with |
| [`schemas/view-session.schema.json`](schemas/view-session.schema.json) | The View Events a script receives and the answers it may give |
| [`schemas/host-fetched-section.schema.json`](schemas/host-fetched-section.schema.json) | A Detail section's `fetch` and the `section_delivered` View Event |
| [`schemas/https-request.schema.json`](schemas/https-request.schema.json) | `https_request` and its Credential Uses |
| [`schemas/external-apps.schema.json`](schemas/external-apps.schema.json) | `perform_app_operation`, the Reviewed App Interfaces the Host ships, and `open_deep_link` |
| [`schemas/plugin-storage.schema.json`](schemas/plugin-storage.schema.json) | The Plugin Storage Host Services |
| [`schemas/namespaces.schema.json`](schemas/namespaces.schema.json) | Level 2: each operation's input and result under its ID, the IDs each entry point accepts, and a Level 2 manifest's Commands |
| [`schemas/host-operations.schema.json`](schemas/host-operations.schema.json) | Level 2: Requested Host Operations, their outcomes and `operation_finished` |
| [`schemas/pages.schema.json`](schemas/pages.schema.json) | Level 2: pages, their components and collections, and their events |
| [`schemas/catalogue.schema.json`](schemas/catalogue.schema.json) | The shape of `catalogue.json` |
| [`catalogue.json`](catalogue.json) | Level 2's Plugin API catalogue: every operation, where it is offered, its authority and the Level 1 names it replaces |
| [`fixtures/`](fixtures/pages/index.json) | Level 2: valid and invalid answers and events for [pages](fixtures/pages/index.json) and [Requested Host Operations](fixtures/host-operations/index.json) |
| [`spinnet.d.ts`](spinnet.d.ts) | Types for the globals a script runs with, including `spinnet` |
| [`spinnet.js`](spinnet.js) | Source of the `spinnet` SDK object the helper injects into every Level 1 script |
| [`spinnet-level-2.d.ts`](spinnet-level-2.d.ts) | Types for a Level 2 script's `spinnet`, `event` and answers |
| [`spinnet-level-2.js`](spinnet-level-2.js) | Source of the `spinnet` SDK object of a Level 2 script, built over Level 1's |
| [`SpinnetSDK.swift`](SpinnetSDK.swift) | Embeds the SDKs in the helper when it is built |
| [`candidates/README.md`](candidates/README.md) | Candidate Contracts: provisional revisions declared by exact revision, kept apart from every stable Level, and the retired ones Level 2 was proved as |

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

Level 1 is the first published level and Level 2 the second; this Host
supports both. The schema requires `api_level`; a Host reads a manifest
written before the field existed as needing Level 1. A Plugin kept outside
this repository pins the Level it was written for by the commit of this
repository it tests against.

Level 2 is still open: while no Plugin outside this repository depends on
it, additions are made to Level 2 itself rather than raising the level, so a
Plugin pinned to an earlier commit of Level 2 may lack a later addition.
Once an outside Plugin depends on Level 2, it is frozen and later additions
raise the level to 3.

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

## What Level 2 offers

Level 2 is everything Level 1 offers, laid out under one name per operation,
with pages, collections and Requested Host Operations. It was proved by the
external Emoji Plugin as Candidate Contracts `namespaces` r1,
`host_operations` r2 and `collections` r3, promoted together on 2026-10-06
(#79), which Level 2 retires ([Candidate Contracts](candidates/README.md)). A
Plugin declares it in its manifest:

```json
{
  "protocol_version": "1.0",
  "api_level": 2
}
```

### Host Services, by ID

Every Host Service has one ID, `namespace.verb`, the same string in a
script's call (`spinnet.<id>(input)` or `requestHostService("<id>", input)`),
a manifest Command's `host_command`, a page action's and a Requested Host
Operation's `perform`, and `operation_finished`
([Host Service IDs](reference/namespaces.md)). The SDK holds an operation at
`spinnet.<id>` when a script can call it; one offered as a request or a page
action also has `spinnet.<id>.operation(input, options)` and
`spinnet.<id>.action(input, options)`, so `spinnet.host.showPluginSettings`
holds only those two, and the namespaces with Command-only operations,
`keyboard` and `system`, are absent from the SDK.

| Namespace | ID | Offered as | Capability | System Permission |
| --- | --- | --- | --- | --- |
| `host` | `host.toast` | Command, answer | none | none |
|  | `host.closeView` | answer | none | none |
|  | `host.showPluginSettings` | Command, page action, request | none | none |
| `selection` | `selection.readText` | call | `read_selected_text` | Accessibility |
|  | `selection.replace` | call, page action, request | `insert_into_focused_app` | Accessibility |
|  | `selection.copy` | Command | `read_selected_text`, `write_clipboard` | Accessibility |
|  | `selection.cut` | Command | none | Accessibility |
|  | `selection.paste` | Command | none | Accessibility |
| `keyboard` | `keyboard.press` | Command | none | Accessibility |
| `clipboard` | `clipboard.read` | call | `read_current_clipboard` | none |
|  | `clipboard.write` | call, Command, page action, request | `write_clipboard` | none |
| `clipboardHistory` | `clipboardHistory.read` | call | `read_clipboard_history` | none |
|  | `clipboardHistory.readContent` | call | `read_clipboard_history` | none |
|  | `clipboardHistory.show` | call, Command, page action, request | `read_clipboard_history` | none |
| `open` | `open.url` | call, Command, page action, request | `open_url`; as a Command, none | none |
|  | `open.path` | call, Command, page action, request | `open_local_path`; as a Command, none | none |
|  | `open.application` | call, Command, page action, request | `open_local_path`; as a Command, none | none |
| `apps` | `apps.perform` | call, Command, page action, request | `control_external_app` | Automation, asked by macOS |
|  | `apps.openDeepLink` | call, Command, page action, request | `control_external_app` | none |
| `system` | `system.runShortcut` | Command | none | none |
|  | `system.runService` | Command | none | none |
| `window` | `window.read` | call | `position_focused_window` | Accessibility |
|  | `window.setFrame` | call | `position_focused_window` | Accessibility |
|  | `window.toggleFullScreen` | call, Command | `position_focused_window` | Accessibility |
|  | `window.restore` | call, Command | `position_focused_window` | Accessibility |
| `screen` | `screen.capture` | call, Command | `capture_screen` | Screen Recording |
| `http` | `http.request` | call, source | `contact_https` | none |
| `text` | `text.detectLanguage` | call | none | none |
| `storage` | `storage.get` | call | none | none |
|  | `storage.set` | call | none | none |
|  | `storage.remove` | call | none | none |
|  | `storage.keys` | call | none | none |
|  | `storage.clear` | call | none | none |

The IDs `catalogue.json` reserves, such as `apps.frontmost` and
`system.keepAwake`, are refused until a later Level adds them, and
`selection.cut`, `selection.paste`, `keyboard.press`, `system.runShortcut`
and `system.runService` are offered only as Commands, whose input the user
configures.

### Pages, in `spinnet.ui.components`

`spinnet.ui` keeps Level 1's builders and adds `ui.page`, `ui.showPage`,
`ui.request` and `ui.components` ([pages](reference/pages.md)). A page has
an `id` and up to 40 components, each with an `id` unique in the page:

| Component | Builder | What the Host draws |
| --- | --- | --- |
| `row` | `components.row` | Up to 4 of the components below side by side, columns included |
| `column` | `components.column` | Up to 8 of the components below top to bottom, rows included |
| `text_field` | `components.textField` | A one-line field, optionally the search field of the page's collection |
| `choice_field` | `components.choiceField` | A pop-up |
| `text` | `components.text` | Text in the Markdown subset |
| `actions` | `components.actions`, `components.button` and `.action(...)` | Up to 8 buttons: event buttons and page actions the Host performs |
| `list` | `components.list`, `section`, `item`, `itemAction` | A selectable list of up to 2,000 items, or a window of them |
| `grid` | `components.grid`, `section`, `item`, `itemAction` | A selectable grid of 2 to 12 columns, likewise |
| `icon` | `components.icon` | A system symbol, tinted |
| `image` | `components.image` | A PNG or JPEG the Host loads from the package or a host the Plugin may contact, in a fixed frame |
| `progress` | `components.progress` | A task's stages, status and state, indeterminate unless the Plugin knows its value, with a cancel View Action |

`text`, `row`, `column`, `icon`, `image` and `progress` take a `style` of
their own (colours, including custom ones, a font size and weight,
background, padding, corner radius); nothing inherits it, and the Host's
fields, buttons, Collections and chrome keep their native look. Items may
show a system symbol as their `icon`. These were appended to Level 2 by
#81 while it is open ([Styles, images and progress](reference/pages.md#styles-images-and-progress)).

The Host keeps each component's immediate state (typed text, caret,
input-method composition, focus, selection, scroll) across answers to the
same page until the Plugin resets it, owns a collection's selection, keys,
scrolling and its window of items, which it fills with `load_range`, and
draws no buttons for item actions: Return and double-click run the default,
and the context menu offers each, toggles shown checked by the items' marks.
No component or action carries a shortcut.

### Requested Host Operations and outcomes

An answer to a gesture may carry one `operation`, which the Host commits
with the answer, performs after the invocation ends and, with `notify`,
reports as `operation_finished`, after the view closed too
([Requested Host Operations](reference/host-operations.md)). Every
insertion in a Level 2 View Session goes to the App in front when the Host
inserts, which must be the App the Host showed when the user acted.

View Events add `item_action`, `load_range`, `called` (an Explicit Call
into the open View Session) and `operation_finished` to Level 1's.

### Level 1 at Level 2

Level 1 is unchanged: a Plugin declaring `api_level: 1` keeps every Level 1
name, view rule, insertion path and restart-on-call, and its invocation and
SDK are Level 1's. A Level 2 Plugin names Host Services by ID only, so a
Level 1 name is refused with the ID to use instead
([Level 1 names](reference/level-1-names.md)), but it may still answer with
a Level 1 `view`, which keeps Level 1's view rules and names, its standard
actions included. `spinnet.environment.apiLevel` is the highest Level the
Host supports, 2, for every Plugin. The types are in
[`spinnet-level-2.d.ts`](spinnet-level-2.d.ts).

## Candidates for later levels

These are left out of Levels 1 and 2 because no Spinnet Plugin needs them
yet. Each is added, when a Plugin does, as a Plugin-independent Host Service
or view component with its own Capability where it reads or changes
anything, which raises the Plugin API Level. Level 2 brought in the List, and pages'
Progress, icons and images (#81).

| Candidate | The need that would bring it in |
| --- | --- |
| Selected Finder items | A Command that acts on the files the user has selected in Finder, such as converting or sharing them |
| The frontmost application | A Command whose behaviour depends on the App in front, such as a per-App shortcut or reading the current browser page |
| Revealing a file in Finder | A Command that shows the user where something is, rather than opening it, as `open_local_path` does |
| Icons beyond pages | Menu Items or buttons that need a picture to tell them apart |
| Images the Plugin produces | A view that shows an image the script itself made, such as a QR code, or copies one to the clipboard |
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

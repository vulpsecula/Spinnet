# Level 1 names at Plugin API Level 2

Every Plugin API Level 1 name and the catalogue ID a Level 2 Plugin uses
instead; see [Host Service IDs](namespaces.md). Generated from
[`catalogue.json`](../catalogue.json), which is held to Level 1's published
files: every Level 1 Host Command, Host Service, standard
action, SDK wrapper and builder, `spinnet.environment` member, answer
member, View Event, script global and Capability appears here once per
place it maps to. Level 1 itself is unchanged: a Plugin declaring
`api_level: 1` keeps every name on the left, and a Level 2 Plugin names
only the IDs, except inside a Level 1 `view`, which keeps Level 1's names.

## Host Commands

| Level 1 name | Catalogue ID | Reached as | Note |
| --- | --- | --- | --- |
| `feedback.present` | `host.toast` | `"host_command": "host.toast"` | Level 1's feedback.present drew the Host feedback panel; the catalogue form shows the toast near the pointer, as an answer's toast does without a view (decision N2) |
| `clipboard.copy` | `selection.copy` | `"host_command": "selection.copy"` | With a null input; The read may fall back to Command-C under a separate read_current_clipboard grant, as at Level 1 |
| `clipboard.cut` | `selection.cut` | `"host_command": "selection.cut"` | No Capability, as Level 1 |
| `clipboard.paste` | `selection.paste` | `"host_command": "selection.paste"` | No Capability, as Level 1 |
| `keyboard_shortcut.invoke` | `keyboard.press` | `"host_command": "keyboard.press"` | A configured shortcut, without a Capability, as Level 1 |
| `clipboard.copy` | `clipboard.write` | `"host_command": "clipboard.write"` | With a text input; write_clipboard is needed here too, as at Level 1 |
| `url.open` | `open.url` | `"host_command": "open.url"` | A configured link of any scheme, without a Capability, as Level 1's url.open: the user chose it (design 6.2) |
| `file.open` | `open.path` | `"host_command": "open.path"` | A configured path, without a Capability, as Level 1's file.open and folder.open; the configuration field's kind (file or folder) decides what the user can pick |
| `folder.open` | `open.path` | `"host_command": "open.path"` | A configured path, without a Capability, as Level 1's file.open and folder.open; the configuration field's kind (file or folder) decides what the user can pick |
| `application.open` | `open.application` | `"host_command": "open.application"` | A configured application, without a Capability, as Level 1 |
| `deep_link.open` | `apps.openDeepLink` | `"host_command": "apps.openDeepLink"` | The Command names its template with deep_link_template and its configuration fields fill parameters, as Level 1 |
| `shortcut.invoke` | `system.runShortcut` | `"host_command": "system.runShortcut"` | A configured Shortcut, without a Capability, as Level 1 |
| `service.invoke` | `system.runService` | `"host_command": "system.runService"` | A configured Service, without a Capability, as Level 1 |
| `screen.capture_area` | `screen.capture` | `"host_command": "screen.capture"` | Level 1's three screen Host Commands become one ID with source fixed in the Command's input; without copy_to_clipboard and save the user's screenshot preferences apply (decision N9) |
| `screen.capture_full_screen` | `screen.capture` | `"host_command": "screen.capture"` | Level 1's three screen Host Commands become one ID with source fixed in the Command's input; without copy_to_clipboard and save the user's screenshot preferences apply (decision N9) |
| `screen.capture_window` | `screen.capture` | `"host_command": "screen.capture"` | Level 1's three screen Host Commands become one ID with source fixed in the Command's input; without copy_to_clipboard and save the user's screenshot preferences apply (decision N9) |

## Host Services

| Level 1 name | Catalogue ID | Reached as | Note |
| --- | --- | --- | --- |
| `read_selected_text` | `selection.readText` | `spinnet.selection.readText(…)` |  |
| `insert_text` | `selection.replace` | `spinnet.selection.replace(…)` | Inside a View Session of a Level 2 Plugin it is compared with the target shown at the gesture, and fails with insertion_target_changed on a mismatch (ADR 0018) |
| `read_current_clipboard` | `clipboard.read` | `spinnet.clipboard.read(…)` |  |
| `write_clipboard` | `clipboard.write` | `spinnet.clipboard.write(…)` |  |
| `read_clipboard_history` | `clipboardHistory.read` | `spinnet.clipboardHistory.read(…)` |  |
| `read_clipboard_history_content` | `clipboardHistory.readContent` | `spinnet.clipboardHistory.readContent(…)` |  |
| `present_clipboard_history` | `clipboardHistory.show` | `spinnet.clipboardHistory.show(…)` | Kept because Level 1 offers it; a new Host window would be perform-only |
| `open_url` | `open.url` | `spinnet.open.url(…)` |  |
| `open_local_path` | `open.path` | `spinnet.open.path(…)` |  |
| `perform_app_operation` | `apps.perform` | `spinnet.apps.perform(…)` |  |
| `open_deep_link` | `apps.openDeepLink` | `spinnet.apps.openDeepLink(…)` |  |
| `read_focused_window` | `window.read` | `spinnet.window.read(…)` |  |
| `set_focused_window_frame` | `window.setFrame` | `spinnet.window.setFrame(…)` |  |
| `toggle_focused_window_full_screen` | `window.toggleFullScreen` | `spinnet.window.toggleFullScreen(…)` |  |
| `restore_focused_window_frame` | `window.restore` | `spinnet.window.restore(…)` |  |
| `capture_screen` | `screen.capture` | `spinnet.screen.capture(…)` | Returns once the capture starts |
| `https_request` | `http.request` | `spinnet.http.request(…)` |  |
| `detect_language` | `text.detectLanguage` | `spinnet.text.detectLanguage(…)` |  |
| `get_storage_value` | `storage.get` | `spinnet.storage.get(…)` |  |
| `set_storage_value` | `storage.set` | `spinnet.storage.set(…)` |  |
| `remove_storage_value` | `storage.remove` | `spinnet.storage.remove(…)` |  |
| `list_storage_keys` | `storage.keys` | `spinnet.storage.keys(…)` |  |
| `clear_storage` | `storage.clear` | `spinnet.storage.clear(…)` |  |

## Standard actions

| Level 1 name | Catalogue ID | Reached as | Note |
| --- | --- | --- | --- |
| `open_plugin_settings` | `host.showPluginSettings` | `spinnet.host.showPluginSettings.action(...)` in a page |  |
| `insert_text` | `selection.replace` | `spinnet.selection.replace.action(...)` in a page | The App it goes to is named on the action and checked at execution (ADR 0018) |
| `copy_text` | `clipboard.write` | `spinnet.clipboard.write.action(...)` in a page |  |
| `open_url` | `open.url` | `spinnet.open.url.action(...)` in a page |  |

## SDK wrappers

| Level 1 name | Catalogue ID | Reached as | Note |
| --- | --- | --- | --- |
| `spinnet.selection.readText` | `selection.readText` | `spinnet.selection.readText(…)` |  |
| `spinnet.selection.replace` | `selection.replace` | `spinnet.selection.replace(…)` | Inside a View Session of a Level 2 Plugin it is compared with the target shown at the gesture, and fails with insertion_target_changed on a mismatch (ADR 0018) |
| `spinnet.clipboard.read` | `clipboard.read` | `spinnet.clipboard.read(…)` |  |
| `spinnet.clipboard.write` | `clipboard.write` | `spinnet.clipboard.write(…)` |  |
| `spinnet.clipboard.history` | `clipboardHistory.read` | `spinnet.clipboardHistory.read(…)` |  |
| `spinnet.clipboard.historyContent` | `clipboardHistory.readContent` | `spinnet.clipboardHistory.readContent(…)` |  |
| `spinnet.clipboard.showHistory` | `clipboardHistory.show` | `spinnet.clipboardHistory.show(…)` | Kept because Level 1 offers it; a new Host window would be perform-only |
| `spinnet.open.url` | `open.url` | `spinnet.open.url(…)` |  |
| `spinnet.open.path` | `open.path` | `spinnet.open.path(…)` |  |
| `spinnet.apps.perform` | `apps.perform` | `spinnet.apps.perform(…)` |  |
| `spinnet.apps.openDeepLink` | `apps.openDeepLink` | `spinnet.apps.openDeepLink(…)` |  |
| `spinnet.window.read` | `window.read` | `spinnet.window.read(…)` |  |
| `spinnet.window.setFrame` | `window.setFrame` | `spinnet.window.setFrame(…)` |  |
| `spinnet.window.toggleFullScreen` | `window.toggleFullScreen` | `spinnet.window.toggleFullScreen(…)` |  |
| `spinnet.window.restore` | `window.restore` | `spinnet.window.restore(…)` |  |
| `spinnet.screen.capture` | `screen.capture` | `spinnet.screen.capture(…)` | Returns once the capture starts |
| `spinnet.http.request` | `http.request` | `spinnet.http.request(…)` |  |
| `spinnet.text.detectLanguage` | `text.detectLanguage` | `spinnet.text.detectLanguage(…)` |  |
| `spinnet.storage.get` | `storage.get` | `spinnet.storage.get(…)` |  |
| `spinnet.storage.set` | `storage.set` | `spinnet.storage.set(…)` |  |
| `spinnet.storage.remove` | `storage.remove` | `spinnet.storage.remove(…)` |  |
| `spinnet.storage.keys` | `storage.keys` | `spinnet.storage.keys(…)` |  |
| `spinnet.storage.clear` | `storage.clear` | `spinnet.storage.clear(…)` |  |

## SDK view builders

| Level 1 name | Catalogue ID | Reached as | Note |
| --- | --- | --- | --- |
| `spinnet.ui.view` | `ui.view` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.setting` | `ui.setting` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.form` | `ui.form` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.textField` | `ui.textField` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.multilineTextField` | `ui.multilineTextField` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.urlField` | `ui.urlField` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.toggleField` | `ui.toggleField` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.choiceField` | `ui.choiceField` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.detail` | `ui.detail` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.section` | `ui.section` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.action` | `ui.action` | `spinnet.ui` | Unchanged; builds part of a Level 1 view, which a Level 2 Plugin may still answer (C9) |
| `spinnet.ui.copyText` | `ui.copyText`, for `clipboard.write` | `spinnet.ui` | Kept for Level 1 views only, where it builds Level 1's standard action; a page's button is spinnet.clipboard.write.action(...) |
| `spinnet.ui.openURL` | `ui.openURL`, for `open.url` | `spinnet.ui` | Kept for Level 1 views only, where it builds Level 1's standard action; a page's button is spinnet.open.url.action(...) |
| `spinnet.ui.insertText` | `ui.insertText`, for `selection.replace` | `spinnet.ui` | Kept for Level 1 views only, where it builds Level 1's standard action; a page's button is spinnet.selection.replace.action(...) |
| `spinnet.ui.openPluginSettings` | `ui.openPluginSettings`, for `host.showPluginSettings` | `spinnet.ui` | Kept for Level 1 views only, where it builds Level 1's standard action; a page's button is spinnet.host.showPluginSettings.action(...) |
| `spinnet.ui.show` | `ui.show` | `spinnet.ui` | Unchanged; at Level 2 it also takes operation |
| `spinnet.ui.toast` | `ui.toast`, for `host.toast` | `spinnet.ui` | Unchanged; builds the answer form of host.toast |
| `spinnet.ui.close` | `ui.close`, for `host.closeView` | `spinnet.ui` | Unchanged; builds the answer form of host.closeView |

## spinnet.environment

| Level 1 name | Catalogue ID | Reached as | Note |
| --- | --- | --- | --- |
| `spinnet.environment.apiLevel` | `environment.apiLevel` | `spinnet.environment` | Unchanged; apiLevel is the highest stable Level the Host supports, whatever Level the Plugin declares |
| `spinnet.environment.hostVersion` | `environment.hostVersion` | `spinnet.environment` | Unchanged |
| `spinnet.environment.preferredLanguage` | `environment.preferredLanguage` | `spinnet.environment` | Unchanged |
| `spinnet.environment.pluginID` | `environment.pluginID` | `spinnet.environment` | Unchanged |
| `spinnet.environment.commandID` | `environment.commandID` | `spinnet.environment` | Unchanged |
| `spinnet.environment.actionID` | `environment.actionID` | `spinnet.environment` | Unchanged |
| `spinnet.environment.invocationID` | `environment.invocationID` | `spinnet.environment` | Unchanged |

## Answer members

| Level 1 name | Catalogue ID | Reached as | Note |
| --- | --- | --- | --- |
| `toast` | `host.toast` | the answer | The answer's toast member, built by ui.toast or the toast option of ui.show and ui.close; a toast with close is the HUD (decision N2) |
| `close` | `host.closeView` | the answer | The answer's close member, built by ui.close |
| `view` | `view` | the answer | Unchanged: a Level 1 view, kept whole with Level 1's names (decision N5) |
| `state` | `state` | the answer | Unchanged |

## View Events

| Level 1 name | Catalogue ID | Reached as | Note |
| --- | --- | --- | --- |
| `field_changed` | `field_changed` | `event` | Unchanged for a Level 1 view; events are not operations; a page's version adds members |
| `submitted` | `submitted` | `event` | Unchanged for a Level 1 view; events are not operations; a page's version adds members |
| `action_chosen` | `action_chosen` | `event` | Unchanged for a Level 1 view; events are not operations; a page's version adds members |
| `setting_changed` | `setting_changed` | `event` | Unchanged for a Level 1 view; events are not operations |
| `settings_swapped` | `settings_swapped` | `event` | Unchanged for a Level 1 view; events are not operations |
| `section_delivered` | `section_delivered` | `event` | Unchanged for a Level 1 view; events are not operations |

## View members

| Level 1 name | Catalogue ID | Reached as | Note |
| --- | --- | --- | --- |
| `detail.sections[].fetch.request` | `http.request` | a Host-Fetched Section | A Host-Fetched Section's fetch.request is this operation's input; Host-run sources (#71, #82) generalise this entry point |

## Script globals

| Level 1 global | Catalogue | Reached as | Note |
| --- | --- | --- | --- |
| `input` | `input` | global | Unchanged: the Plugin Settings, then the Menu Item's overrides, then the Command's own fields |
| `inputJSON` | `inputJSON` | global | Unchanged |
| `pluginID` | `pluginID` | global | Unchanged |
| `commandID` | `commandID` | global | Unchanged |
| `actionID` | `actionID` | global | Unchanged |
| `invocationID` | `invocationID` | global | Unchanged |
| `event` | `event` | global | Unchanged; Level 2 adds events |
| `state` | `state` | global | Unchanged |
| `spinnet` | `spinnet` | global | Level 2's SDK object, laid out by namespace; see spinnet-level-2.d.ts |
| `requestHostService` | `requestHostService` | global | Takes catalogue IDs with a call entry point; Level 1 names are refused |

## Capabilities

| Level 1 Capability | Catalogue | Operations it covers | Note |
| --- | --- | --- | --- |
| `read_selected_text` | `read_selected_text` | `selection.readText`, `selection.copy` | Unchanged; covers these operations |
| `write_clipboard` | `write_clipboard` | `selection.copy`, `clipboard.write` | Unchanged; covers these operations |
| `read_current_clipboard` | `read_current_clipboard` | `clipboard.read` | Unchanged; covers these operations |
| `read_clipboard_history` | `read_clipboard_history` | `clipboardHistory.read`, `clipboardHistory.readContent`, `clipboardHistory.show` | Unchanged; covers these operations |
| `monitor_clipboard` | `monitor_clipboard` | none | Declared and granted but used by no operation, as at Level 1: monitoring stays unavailable |
| `contact_https` | `contact_https` | `http.request` | Unchanged; covers these operations |
| `control_external_app` | `control_external_app` | `apps.perform`, `apps.openDeepLink` | Unchanged; covers these operations |
| `position_focused_window` | `position_focused_window` | `window.read`, `window.setFrame`, `window.toggleFullScreen`, `window.restore` | Unchanged; covers these operations |
| `open_url` | `open_url` | `open.url` | Unchanged; covers these operations |
| `open_local_path` | `open_local_path` | `open.path`, `open.application` | Unchanged; covers these operations |
| `capture_screen` | `capture_screen` | `screen.capture` | Unchanged; covers these operations |
| `insert_into_focused_app` | `insert_into_focused_app` | `selection.replace` | Unchanged; covers these operations |

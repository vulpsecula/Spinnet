# Form/detail SDK builders

`spinnet.ui` only builds views and answers; it requests no Host Service. A
view has a title and optional subtitle, then these components in this order,
at least one of the last three (see [Plugin Views](views.md)):

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
| `clipboard.write` | `copyText` | `write_clipboard` |
| `open.url` | `openURL` | `open_url` |
| `selection.replace` | `insertText` | `insert_into_focused_app` and Accessibility |
| `host.showPluginSettings` | `openPluginSettings` | nothing |

View Events arrive as the script's `event` global: `field_changed`,
`submitted`, `action_chosen`, `setting_changed`, `settings_swapped` and
`section_delivered`. A Detail section with `fetch` is a Host-Fetched
Section, sent by the Host with the Plugin's Credential Uses applied.


The [current types](../sdk/spinnet.d.ts) also cover pages, catalogue calls and Requested Host Operations. `spinnet.environment` reports Host version and language; invocation IDs are separate globals.

# Spinnet Plugin API

This directory is the versioned home of the Documented Plugin Interface: the
contract a Plugin builds against (ADR 0013). Everything here is published under
the MIT licence in [`LICENSE`](LICENSE), so a Plugin can copy the schemas and
type definitions without taking on the GPL that covers the rest of Spinnet.

| File | Contents |
| --- | --- |
| [`schemas/manifest.schema.json`](schemas/manifest.schema.json) | JSON Schema (draft 2020-12) for a package's `manifest.json` |
| [`schemas/plugin-storage.schema.json`](schemas/plugin-storage.schema.json) | JSON Schemas for the inputs and results of the Plugin Storage Host Services |
| [`schemas/plugin-view.schema.json`](schemas/plugin-view.schema.json) | JSON Schema for the Plugin View a script answers with |
| [`schemas/host-fetched-section.schema.json`](schemas/host-fetched-section.schema.json) | JSON Schemas for a Detail section's `fetch` and the `section_delivered` View Event |
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
a camelCase name for exactly one Host Service, except in `spinnet.ui`, whose
builders only build views: it sends its argument as the
service's input, unchanged (`null` when omitted), and returns the answer, so it
fails exactly as `requestHostService` does. A refused Capability or System
Permission ends the whole invocation even if the script catches the error.
The one failure a script may catch is a Plugin Storage write over a limit,
thrown as an `Error` whose `code` is `storage_limit_exceeded`.
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
| `spinnet.apps` | `perform` (`perform_app_operation`, an operation of a Reviewed App Interface), `openDeepLink` (`open_deep_link`, one of the Plugin's Deep Link Templates) |
| `spinnet.storage` | `get` (`get_storage_value`), `set` (`set_storage_value`), `remove` (`remove_storage_value`), `keys` (`list_storage_keys`), `clear` (`clear_storage`), over Plugin Storage, which needs no Capability |
| `spinnet.ui` | Pure builders, which request no Host Service: `view`, `setting`, `form`, `textField`, `multilineTextField`, `urlField`, `toggleField`, `choiceField`, `detail`, `section`, `action`, the standard actions `copyText`, `openURL`, `insertText` and `openPluginSettings`, and the answers `show`, `toast` and `close` (see [Plugin Views](#plugin-views)) |
| `spinnet.environment` | `apiLevel`, `hostVersion`, `preferredLanguage`, `pluginID`, `commandID`, `actionID`, `invocationID` |

## Plugin Storage

Each Plugin has its own key-value store of JSON values, kept between
invocations and launches, which no other Plugin can reach (ADR 0015). It needs
no Capability and no consent: a Plugin keeps there only what it already holds.
The Library shows how much each Plugin keeps and offers Clear Stored Data;
removing a Plugin deletes its store, so installing it again starts empty, and
an update keeps it. It is not the Keychain and never the place for a secret.

```js
const runs = (spinnet.storage.get("runs") ?? 0) + 1;
spinnet.storage.set({ key: "runs", value: runs });
```

A key is a non-empty string of at most 128 characters. `get` answers `null`
for a key with no value, and setting `null` removes the key. A value, as JSON,
is at most 512 KiB, so it always fits in one helper message; a Plugin keeps at
most 10 MiB in at most 1000 keys, so the list `keys` answers always fits in
one message too. A write over any
of them stores nothing and throws an error with `code` `storage_limit_exceeded`
that the script may catch and carry on from. Each key is its own file, written
atomically, so a write rewrites only its own value.

## Answers and View Sessions

A script also runs with `event` and `state`, both `null` when its Action
starts. It answers with the value of its last expression: `{view, state}` to
show or update its Plugin View, `{close: true}` to close it, or `null` when it
has nothing to show. Any answer may add a `toast` string; without a view the
Host shows it near the pointer and starts no View Session. Any other value is
a protocol violation.

While the view is open the Host keeps `state` and runs the same script again
for each View Event: `field_changed` (after a 100 ms pause; only the latest
waiting one is delivered), `submitted`, `action_chosen`, `setting_changed`,
`settings_swapped` and `section_delivered`. One event runs at a time; the others wait in order. Each
event is an ordinary invocation with the same four-second deadline, Host
Services and Capability checks as the Action, so the helper may retire between
events. A refused Capability keeps the view with an inline error and the last
good state; a timeout or crash keeps the view and state; a protocol violation
ends the session. The limits are 64 KiB of state and 256 KiB of view
description. A view shows the answer to a typing pause within 150 ms on a warm
helper and 300 ms from cold, at p95 with the 100 ms debounce included; the
helper still retires between events. `spinnet.d.ts` types the events and answers as `ViewEvent` and
`ScriptAnswer`.

## Plugin Views

A view is data the Host draws; it never holds the Plugin's own markup. It has
a title, an optional subtitle, and then, in this order, controls for the
Plugin's own settings, a Form, a Detail and Actions, at least one of the last
three. [`schemas/plugin-view.schema.json`](schemas/plugin-view.schema.json)
publishes the shape and `spinnet.ui` builds it:

```js
const ui = spinnet.ui;
if (event === null) {
  ui.show(ui.view({
    title: "Greeter",
    settings: [ui.setting("tone")],
    form: ui.form({ submitTitle: "Greet", fields: [ui.textField({ key: "name", title: "Name" })] }),
    actions: [ui.openPluginSettings()]
  }), { state: { greeted: 0 } });
} else if (event.type === "submitted") {
  const text = `Hello, ${event.values.name}`;
  ui.show(ui.view({
    title: "Greeter",
    detail: ui.detail({ sections: [ui.section({ id: "greeting", text: `**${text}**` })] }),
    actions: [ui.copyText({ text }), ui.insertText({ text, closesView: true })]
  }), { state: { greeted: state.greeted + 1 } });
} else {
  null;
}
```

A view the Host would not draw, such as one with an unknown member, a field
kind it does not offer, two fields with one key, or a setting the Plugin does
not declare, ends the View Session as a protocol violation.

| Component | What the Host draws |
| --- | --- |
| Setting controls | `settings`: up to 6 of the Plugin's own `choice` and `toggle` settings, showing what is stored. A change is stored as Plugin Settings are and then delivered as `setting_changed`; the Action does not run again, and the event's `input` already holds the new value. A `choice` control's `swap_with` (`ui.setting(key, {swapWith})`) names the `choice` control right after it, which offers the same choices: a swap button between the two stores both values exchanged, then delivers one `settings_swapped`, `{type, keys}` with this key first |
| Form | `form.fields`: 1 to 20 fields of the kinds `text`, `multiline_text`, `url`, `toggle` and `choice`, each with a `key`, `title`, optional `placeholder` and `value`; a `choice` has `choices` and optional `choice_titles`. Each edit is `field_changed` with every value, after a 100 ms pause; Return in a one-line field, the submit button (`submit_title`, "Submit" by default) or Command-Return is `submitted`. With `submit_on_return: true` (`ui.form({submitOnReturn})`) Return submits from any field, a multiline one included, where Shift-Return starts a new line, and the form draws no submit button and takes no `submit_title`. While the answer to the user's own typing arrives, a field keeps what they typed; any other answer with a view sets each field to its `value` |
| Detail | `detail.sections`: 1 to 20 sections `{id, title?, text?, fetch?}` with distinct IDs. A section's `text` supports a Markdown subset: `**bold**` or `__bold__`, `*italic*` or `_italic_`, `` `inline code` ``, ```` ``` ```` fenced code blocks, and `[links](https://example.com)` to http or https pages, which open under the `open_url` rules. Anything else, such as headings, lists, images or HTML, shows as the plain text it is. Each section with text has a Copy button, which is the user's own copy and needs no Capability. A section with `fetch` is a [Host-Fetched Section](#host-fetched-sections) |
| Actions | `actions`: up to 12 buttons. One with an `id` delivers `action_chosen`; one with `perform` is a standard action. An optional `shortcut` such as `cmd+shift+k` names modifiers from `cmd`, `ctrl`, `option` and `shift`, at least `cmd` or `ctrl`, then a lowercase letter, a digit or `return`; the view keeps Command-W, -Q, -C, -V, -X, -A, -Z, Shift-Command-Z and Command-Return. Without a form, Return chooses the first action that has no shortcut of its own |
| Toast | `toast` on any answer: shown briefly inside the view, or near the pointer when there is no view |

Standard actions are performed by the Host itself, without a View Event, under
the Capability their Host Service needs. A refusal shows in the view with the
way to repair it, such as opening the Plugin's Plugin Settings to grant access,
and the view stays open. With `closes_view`, the view closes once the action
succeeds.

| `perform` | Member | Needs |
| --- | --- | --- |
| `copy_text` | `text` | `write_clipboard` |
| `open_url` | `url`, http or https only | `open_url` |
| `insert_text` | `text`, at most 128 KiB, inserted into the App the view came from in place of its selection | `insert_into_focused_app` and Accessibility |
| `open_plugin_settings` | none | nothing |

Each Plugin has at most one view. Presenting again replaces it in place and
keeps its pin; views of different Plugins may be open together. A view opens
near the pointer and takes the keyboard without bringing Spinnet forward, so
the App the user was in stays in front. An unpinned view closes when it loses
focus; Escape or its close button closes any view. While an event runs the
view shows its own busy state. Every component carries an accessibility label:
fields, setting controls and actions their titles, sections their titles (or
"Details" and their position), and the pin, close and Copy buttons what they
do.

## Host-Fetched Sections

A Detail section, `{id, title?, text?, fetch?}`, may name a request for the
Host to send instead of text the script already has. The Host sends it with
the Plugin's Credential Uses applied, so a script can show an answer from a
service that needs a key without ever holding the key, and in `show` mode
without seeing the answer either.

```js
// One section of a Detail view.
const deepl = {
  id: "deepl",
  title: "DeepL",
  fetch: {
    request: {
      method: "POST",
      url: "https://api-free.deepl.com/v2/translate",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: [text], target_lang: "DE" }),
      credential_uses: [{ reference: "deepl_key", header: "Authorization", template: "DeepL-Auth-Key {credential}" }]
    },
    mode: "show",
    pointer: "/translations/0/text",
    error_pointer: "/message",
    status_messages: { "456": "The DeepL quota is used up" },
    cache: true
  }
};
```

`fetch.request` is an `https_request` input and is held to the same rules as it
is sent: https to a host consented for the Plugin, the same headers, body and
Credential Uses, redirects only within the consented hosts, and a 128 KiB
response. The section is sent with the authority of the Command that presented
the view, read afresh for every request: once `contact_https` is revoked or a
host is removed, nothing more is sent, cached answers included.

- **`mode: "show"`**: the Host reads the answer, a string, at the RFC 6901
  `pointer` in a 2xx JSON response and shows it as plain text. For a failed
  response it shows the `status_messages` entry for the status, else the
  string at `error_pointer`, else the status. The script never sees the
  response, and the section's own `text` is ignored.
- **`mode: "deliver"`**: the Host sends the `https_request` result to the
  script as a `section_delivered` View Event, `{type, section, response}`,
  which waits its turn behind the session's other events. The section shows
  the `text` it has in the view the script answers with, in the Markdown
  subset like any section's text; until then it is loading. A failed event, or an answer whose view gives the section no text,
  shows as the section's failure. A request that fails before any response
  arrives delivers nothing and shows why.

Every section of a view is sent at once, so a slow service never holds back
another, and each request has its own 15-second budget, redirects included;
a script's own `https_request` keeps its 3-second budget. A view fetches at
most 8 sections. A section keeps what it fetched while its `id` and `fetch`
stay the same, so answering `section_delivered`, or any other event, sends
nothing again; a changed `fetch` is sent afresh, and a section the view no
longer has is cancelled. A view presented by another of the Plugin's Commands
fetches afresh. Closing the view, or anything else that ends the View
Session, cancels its sections and drops answers that arrive later.

With `cache: true` the Host may answer the same request from its last 2xx
answer to it, for 10 minutes, among at most 50 answers across all Plugins,
in memory only, and forgets them all whenever a grant changes.

A malformed `fetch`, such as a `show` section without a `pointer` or a
`deliver` section with one, fails that section with the reason and leaves
the rest of the view alone. Pointers and messages are at most 512
characters.

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

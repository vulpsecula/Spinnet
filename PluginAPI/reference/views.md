# Plugin Views

A Plugin View is data a script describes and the Host draws; it never holds the
Plugin's own markup or native UI (ADR 0002, ADR 0010).
[`schemas/plugin-view.schema.json`](../schemas/plugin-view.schema.json)
publishes a view, [`schemas/view-session.schema.json`](../schemas/view-session.schema.json)
the events and answers around it, and `spinnet.ui` builds both.

## View Sessions

A script runs with `event` and `state`, both `null` when its Action starts. It
answers with the value of its last expression: `{view, state}` to show or
update its Plugin View, `{close: true}` to close it, or `null` when it has
nothing to show. Any answer may add a `toast` string; without a view the Host
shows it near the pointer and starts no View Session. Any other value is a
protocol violation.

While the view is open the Host keeps `state` and runs the same script again
for each View Event:

| Event | Members | When |
| --- | --- | --- |
| `field_changed` | `field`, `values` | A form field was edited, after a 100 ms pause; only the latest waiting one is delivered, and `values` holds every field |
| `submitted` | `values` | The form was submitted |
| `action_chosen` | `action` | An action with an `id` was chosen |
| `setting_changed` | `key`, `value` | A setting control changed; the Host has already stored it as Plugin Settings |
| `settings_swapped` | `keys` | A swap button exchanged two settings; the Host has already stored both |
| `section_delivered` | `section`, `response` | A `deliver` section's response arrived |

One event runs at a time; the others wait in order. Each event is an ordinary
invocation with the same four-second deadline, Host Services and Capability
checks as the Action, so the helper may retire between events; nothing lives
in the helper between them. Answers to an event the session has moved past are
dropped.

- A refused Capability keeps the view with an inline error, its way to repair,
  and the last good state.
- A timeout or crash keeps the view and state; the next event starts a new
  helper.
- A protocol violation ends the session.
- Closing the view, updating, disabling or removing the Plugin, or revoking a
  Capability it uses ends the session, cancels its events and sections, and
  drops answers that arrive later.

The limits are 64 KiB of state and 256 KiB of view description. A view shows
the answer to a typing pause within 150 ms on a warm helper and 300 ms from
cold, at p95 with the 100 ms debounce included; the helper still retires
between events.

## Describing a view

A view has a title, an optional subtitle, and then, in this order, controls for
the Plugin's own settings, a Form, a Detail and Actions, at least one of the
last three.

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

## Components

| Component | What the Host draws |
| --- | --- |
| Setting controls | `settings`: up to 6 of the Plugin's own `choice` and `toggle` settings, showing what is stored. A change is stored as Plugin Settings are and then delivered as `setting_changed`; the Action does not run again, and the event's `input` already holds the new value. A `choice` control's `swap_with` (`ui.setting(key, {swapWith})`) names the `choice` control right after it, which offers the same choices: a swap button between the two stores both values exchanged, then delivers one `settings_swapped`, `{type, keys}` with this key first |
| Form | `form.fields`: 1 to 20 fields of the kinds `text`, `multiline_text`, `url`, `toggle` and `choice`, each with a `key`, `title`, optional `placeholder` and `value`; a `choice` has `choices` and optional `choice_titles`. Each edit is `field_changed` with every value, after a 100 ms pause; Return in a one-line field, the submit button (`submit_title`, "Submit" by default) or Command-Return is `submitted`. With `submit_on_return: true` (`ui.form({submitOnReturn})`) Return submits from any field, a multiline one included, where Shift-Return starts a new line, and the form draws no submit button and takes no `submit_title`. While the answer to the user's own typing arrives, a field keeps what they typed; any other answer with a view sets each field to its `value` |
| Field status | A `text` or `url` field may have a `status`, one line of plain text the Host draws in the field's box under what is typed, shortened in the middle when it does not fit, and an `accent`, one of the system colours `blue`, `indigo`, `purple`, `pink`, `red`, `orange`, `green`, `teal` or `gray`: the Host tints the field's box, its background, border and status line, in the shade for the current appearance, and animates a change of colour. Together they are a live status for what is typed. Any other colour, a blank status, or either on another kind, is a protocol violation. There is no yellow, which cannot be told from the field's own background in light appearance. The colour only adds to what the view says in words, which is all VoiceOver reads |
| Detail | `detail.sections`: 1 to 20 sections `{id, title?, text?, fetch?}` with distinct IDs. A section's `text` supports a Markdown subset: `**bold**` or `__bold__`, `*italic*` or `_italic_`, `` `inline code` ``, ```` ``` ```` fenced code blocks, and `[links](https://example.com)` to http or https pages, which open under the `open_url` rules. Anything else, such as headings, lists, images or HTML, shows as the plain text it is. Each section with text has a Copy button, which is the user's own copy and needs no Capability. A section with `fetch` is a [Host-Fetched Section](#host-fetched-sections) |
| Actions | `actions`: up to 12 buttons. One with an `id` delivers `action_chosen`; one with `perform` is a standard action. An optional `shortcut` such as `cmd+shift+k` names modifiers from `cmd`, `ctrl`, `option` and `shift`, at least `cmd` or `ctrl`, then a lowercase letter, a digit or `return`; the view keeps Command-W, -Q, -C, -V, -X, -A, -Z, Shift-Command-Z and Command-Return. Without a form, Return chooses the first action that has no shortcut of its own |
| Toast | `toast` on any answer: shown briefly inside the view, or near the pointer when there is no view |

## Standard actions

Standard actions are performed by the Host itself, without a View Event, under
the Capability their Host Service needs. A refusal shows in the view with the
way to repair it, such as opening the Plugin's Plugin Settings to grant access,
and the view stays open. With `closes_view`, the view closes once the action
succeeds.

`insert_text` types its text into the App the view came from as
[`insert_text`](host-services.md#insert_text) does into the App in front,
after bringing that App back to the keyboard. With `closes_view` the view
therefore closes before the text is typed, and a failure after that is shown
by the Host rather than in the view; without it, an unpinned view closes when
the App takes the keyboard, and a pinned one stays where it is.

| `perform` | Member | Needs |
| --- | --- | --- |
| `copy_text` | `text` | `write_clipboard` |
| `open_url` | `url`, http or https only | `open_url` |
| `insert_text` | `text`, at most 128 KiB, inserted into the App the view came from in place of its selection | `insert_into_focused_app` and Accessibility |
| `open_plugin_settings` | none | nothing |

## Windows

Each Plugin has at most one view. Presenting again replaces it in place and
keeps its pin; views of different Plugins may be open together. A view opens
near the pointer and takes the keyboard without bringing Spinnet forward, so
the App the user was in stays in front. An unpinned view closes when it loses
focus; Escape or its close button closes any view. While an event runs the
view shows its own busy state, not the Action's progress. Every component
carries an accessibility label: fields, setting controls and actions their
titles, sections their titles (or "Details" and their position), and the pin,
close and Copy buttons what they do.

## Host-Fetched Sections

A Detail section, `{id, title?, text?, fetch?}`, may name a request for the
Host to send instead of text the script already has. The Host sends it with
the Plugin's Credential Uses applied, so a script can show an answer from a
service that needs a key without ever holding the key, and in `show` mode
without seeing the answer either.
[`schemas/host-fetched-section.schema.json`](../schemas/host-fetched-section.schema.json)
publishes `fetch` and `section_delivered`.

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
      credential_uses: [{ reference: input.deepl_credential, header: "Authorization", template: "DeepL-Auth-Key {credential}" }]
    },
    mode: "show",
    pointer: "/translations/0/text",
    error_pointer: "/message",
    status_messages: { "456": "The DeepL quota is used up" },
    cache: true
  }
};
```

`fetch.request` is an [`https_request`](host-services.md#https_request) input
and is held to the same rules as it is sent: https to a host consented for the
Plugin, the same headers, body and Credential Uses, redirects only within the
consented hosts, and a 128 KiB response. The section is sent with the authority
of the Command that presented the view, read afresh for every request: once
`contact_https` is revoked or a host is removed, nothing more is sent, cached
answers included.

- **`mode: "show"`**: the Host reads the answer, a string, at the RFC 6901
  `pointer` in a 2xx JSON response and shows it as plain text. For a failed
  response it shows the `status_messages` entry for the status, else the
  string at `error_pointer`, else the status. The script never sees the
  response, and the section's own `text` is ignored.
- **`mode: "deliver"`**: the Host sends the `https_request` result to the
  script as a `section_delivered` View Event, `{type, section, response}`,
  which waits its turn behind the session's other events. The section shows
  the `text` it has in the view the script answers with, in the Markdown
  subset like any section's text; until then it is loading. A failed event,
  or an answer whose view gives the section no text, shows as the section's
  failure. A request that fails before any response arrives delivers nothing
  and shows why.

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

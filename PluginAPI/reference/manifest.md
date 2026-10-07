# The manifest

A Plugin is a local `.spinnetplugin` directory holding a `manifest.json` and
the scripts its Commands run. The shape of the manifest is published as
[`schemas/manifest.schema.json`](../schemas/manifest.schema.json); this page
states what the shape cannot, which the Host checks when it loads the package.

```json
{
  "protocol_version": "1.0",
  "api_level": 1,
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

## Identity and level

`id`, `name`, `version`, Command IDs, and Command titles must be non-empty and
no longer than 256 characters. Command IDs must be unique, and the protocol
version must be `1.0`.

`api_level` is the lowest Plugin API Level the Plugin needs, an integer of at
least 1. The Host supports up to Level 2 and refuses to install a Plugin that
needs a higher level, telling the user to update Spinnet. A manifest without
`api_level` is read as needing Level 1. `protocol_version` only frames the
[helper messages](scripts.md#the-helper-protocol) and does not version the
interface.

At Level 2 a Command that runs no script names its Host Service by
[catalogue ID](namespaces.md), such as `"host_command": "open.url"`, and may
fix members of its input in `input` ([input](namespaces.md#input)); a Level 1
Host Command name is refused with the ID to use instead. The schema holds a
Level 2 manifest's Commands to `namespaces.schema.json`'s `command`, and a
Level 1 manifest's to the Commands below. A manifest that still declares
a retired Candidate Contract in `candidate_contracts` is refused with the
Level to declare instead ([Candidate Contracts](../candidates/README.md)).

## Commands

A Command has an `id`, a `title`, and an `execution`: `host` names a
`host_command` the Host performs itself, and `javascript` names a `script`,
a UTF-8 file relative to the package root that does not leave it (see
[Scripts](scripts.md)).

A Command may add an optional `description`: one sentence saying what it does,
under the same non-empty, 256-character rule as its title. The Host shows it in
the Configuration Sheet under the Primary Action picker, each Alternate Action,
and each parameter field, and as the tooltip of the runtime Actions menu. It is
display text only: rewording it does not make a configured Action's Command
count as changed, and existing Actions show the description of the Command
registered now.

An Action keeps the Command definition it was configured from. Before it runs,
the Host compares that with the Command registered now; a missing or disabled
Plugin, a missing Command, or a changed one leaves the Action unavailable with
the `command_unavailable` outcome, and nothing runs.

### Host Commands

| Host Command | Action input | Host integration | Authority |
| --- | --- | --- | --- |
| `url.open` | URL string, or `{ "url": "…" }` | `NSWorkspace` | none |
| `application.open` | application path or bundle identifier | `NSWorkspace` | none |
| `file.open` | file path, or `{ "path": "…" }` | `NSWorkspace` | file must exist |
| `folder.open` | folder path, or `{ "path": "…" }` | `NSWorkspace` | folder must exist |
| `keyboard_shortcut.invoke` | `{ "key": "P", "modifiers": ["command"] }` or `key_code` | Quartz Event Services | Accessibility System Permission |
| `service.invoke` | Service name, or `{ "name": "…", "input": "…" }` | macOS Services | service availability |
| `shortcut.invoke` | Shortcut name, or `{ "name": "…", "input": "…" }` | Public `shortcuts` command-line interface | Shortcut availability |
| `clipboard.copy` | `null` to copy current selected text, or text string / `{ "text": "…" }` | Host clipboard | `write_clipboard`; `read_selected_text` when input is `null` |
| `clipboard.paste` | `null` | Quartz Event Services (`Command-V`) | Accessibility System Permission |
| `clipboard.cut` | `null` | Quartz Event Services (`Command-X`) | Accessibility System Permission |
| `feedback.present` | message string, or `{ "message": "…" }` | Host-rendered feedback | none |
| `screen.capture_area`, `screen.capture_full_screen`, `screen.capture_window` | `null` | `/usr/sbin/screencapture`, then the Screenshot Plugin Settings | `capture_screen`; Screen Recording System Permission |
| `deep_link.open` | the values of the template's parameters, from the Command's configuration | one of the Plugin's [Deep Link Templates](host-services.md#open_deep_link) | `control_external_app` |

For `service.invoke`, use the exact item title shown in the active
application's Services menu. Services are context-sensitive actions supplied by
installed apps or extensions, commonly used to transform, look up, or share
selected text. A selected text object must be present when the service expects
text input; nested service paths use `/` separators.

A `deep_link.open` Command names its template with `deep_link_template`; the
template must be declared in the `control_external_app` scope that covers the
Command, and each of its parameters is filled from the configuration field with
the same key. Such a Command needs no script.

The Host checks an Action's input against its Host Command, and the Capability
and System Permission it needs, before it performs it. An unavailable
application, file, folder, Service, Shortcut, or system request produces a
stable failure; a missing grant produces `capability_denied` and a missing
System Permission `system_permission_denied`. The Host never falls back to a
different Command.

## Capabilities and scopes

`capabilities` declares which protected Host Services the Plugin may request.
A declaration is not a grant: the Host stores an explicit per-Plugin-version,
per-Capability decision (`not_determined`, `denied`, or `granted`) and treats
every decision other than `granted` as denied. Updates inherit decisions only
for unchanged Capability scopes. A changed scope starts with `not_determined`,
even when an update reuses the version string.

`optional_capabilities` is an optional list of declared Capabilities for
JavaScript Commands. A missing or denied optional grant does not prevent the
Command from starting. Every Host Service request still needs that
Capability's grant; a script may handle a denied optional request and continue
with another path. The scope, when present, limits which Commands may use it.
Optional Capabilities are still disclosed and can be granted or denied in
Plugin Settings.

The optional `capability_scopes` array adds concrete disclosure. Each entry has
`capability`, `command_ids`, `data_types`, `includes_existing_host_data`,
`https_hosts`, and `external_apps` (use empty arrays for unused fields). Each
External App entry contains `bundle_id`, and optionally `name`,
`operation_families`, and `deep_link_templates`; it names at least one of the
last two, and needs a `name` with templates. Command IDs must belong to the
manifest; HTTPS hosts are exact hostnames without schemes, paths, ports,
credentials, or wildcards. A scope is persisted with its grant: any change
requires a new decision, even if the version string is reused.

`read_selected_text`, `write_clipboard`, `position_focused_window`,
`open_url`, `open_local_path`, `capture_screen`, `read_frontmost_app` and
`quit_frontmost_app` need no scope; every other Capability does. A scope that
is declared anyway for `read_selected_text` or `write_clipboard`, like the
required one for `insert_into_focused_app`, may name Command IDs and the
`text` data type only; for the other six it may name Command IDs only.
`read_frontmost_app` and `quit_frontmost_app` are Plugin API Level 2's
([the App in front](apps.md)): a manifest declaring `api_level` 1 that
declares either is refused. `read_current_clipboard`, `read_clipboard_history` and
`monitor_clipboard` scopes must name data types. History declarations must name data types and disclose access to
retained Host data. Contact and External App declarations must name hosts and
operation families or Deep Link Templates, respectively. None of these
declarations enables background collection, network access, Automation, or
general app control by itself, and `monitor_clipboard` stays unavailable even
after consent.

Hosts a user adds through an `https_endpoint` field are persisted with the
grant as `consented_https_hosts`, which only the Host writes; a manifest
declaring it is rejected. They survive revoking and granting again, and updates
that keep the declared scope; a changed declared scope drops them with the
decision. Adding a host does not change the Capability's own decision.

## Installing, updating and removing

Install or Update Plugin in the Library first checks the package without
copying it, then asks the user to install it, listing the access nobody has
decided on yet, grouped as Reads, Monitors, Contacts, Controls, Changes, and
System Access. Installing copies the package into Host-owned storage and grants
that access; cancelling installs nothing. A package asking for no new access
installs at once, and a refused one, such as one needing an unsupported Plugin
API Level, is reported. An update keeps the decisions for unchanged scopes and
asks again for new or changed ones. Revoking access later leaves the Plugin
and its Menu Items in place and makes the affected Commands unavailable with a
Grant Access repair route; it also retires a running helper at once.

Removing a Plugin forgets its access decisions and deletes its
[Plugin Storage](host-services.md#plugin-storage); installing it again starts
empty, and an update keeps both. Menu Items made from it stay in their Menu Slots,
unavailable. A Bundled Plugin follows the same rules and may do nothing an
installed one cannot.

## The Preset

Every Plugin appears once in the Library through its single `preset`. The Host
decides where a Plugin came from; a manifest cannot claim to be a Bundled
Plugin. `readiness`
is `ready_to_use` when every configurable default Primary and Alternate Command
has a valid, immediately executable value in `default_inputs`; a
non-configurable Command does not need an input. Otherwise use
`setup_required`: the Library shows the Preset, which needs the Configuration
Sheet before it can be added. Preset-level `is_configurable` says whether the
Menu Item can be edited; each Command's `is_configurable` independently says
whether that Command has an Action parameter editor. A manifest without
`preset` appears as a configurable, Setup-Required Preset whose Primary Command
is the first declared Command.

When a ready Preset is placed into a Menu Slot, the Host creates one Action for
the declared Primary Command and one for each `default_alternate_command_ids`
entry. Configurable Actions take their `default_inputs` value; non-configurable
Actions receive a null input and show no parameter field. The normal gesture
runs the Primary Action; the right-click Actions menu lists the Primary Action
and every configured Alternate Action. Commands left out of the defaults are
not bound to the Menu Slot, but the Configuration Sheet may add any other Command of
the same Plugin as an Alternate Action.

## Fields

A configurable Command may declare a `configuration_field` to choose the
Host-rendered field kind: `text`, `multiline_text`, `toggle`, `choice`,
`application`, `file`, `folder`, `shortcut`, `keyboard_shortcut`, `url`,
`size`, or `position`. It may instead declare `configuration_fields`: an array
of fields, each with a unique `key` (at most 64 characters) and a kind of
`text`, `toggle`, `choice`, `file`, `folder`, or `url`. The Configuration
Sheet shows one row per field, and the Action input is then an object with
exactly one member per key: a boolean for `toggle`, one of the declared
`choices` for `choice`, and a string otherwise. A Command declares
`configuration_field` or `configuration_fields`, not both.

`configuration_fields` may also hold `multiline_text`, `credential`, and
`https_endpoint`; these two last kinds are valid only inside
`configuration_fields` and `settings_fields`. `url` accepts any link.
`https_endpoint` is an https base URL without a user name, query, fragment, or
a port other than 443. On a Command in the `contact_https` scope, an
`https_endpoint` host that is neither declared nor already added must be
disclosed and allowed before the Configuration Sheet saves. A `credential`
field stores only a reference, the name the Host keeps the secret under, which
the field's default value must give: in `default_settings` for a setting, such
as `"deepl_credential": "deepl"`, or in the Command's `default_inputs`. Without
one there is nowhere to keep a secret, and the field stays missing. The secret
the user types is kept by the Host in the Keychain, per Plugin and reference.
The Host-rendered field shows the stored secret, hidden behind a reveal
button, so the user can check and correct a key; a Plugin never reads it, and
uses it only through [Credential Uses](host-services.md#credential-uses).

`size` and `position` fields render as text and store a string of two
comma-separated lengths, each in points or as a percentage of the visible frame
(`800, 600`, `50%, 100%`). The Host rejects empty, negative, or over-100%
values, and zero in `size`, when the Configuration Sheet saves and in
Ready-to-Use `default_inputs`.

`choice` and `ordered_choices` fields provide a non-empty `choices` array, and
may add `choice_titles`, one display name per choice in the same order, so a
stored code such as `ZH-HANS` is shown as the name the user reads.

A field inside a field set may declare `used_when`,
`{"key": "…", "values": […]}`, naming another `choice` field in the same set
and some of its choices; the field is used only while that field holds one of
them. The Host ignores an unused field's value, so a folder used only when
another field chooses to save cannot make an Action that does not save
unavailable.

The Host supplies native application, file and folder pickers and keyboard
shortcut recording controls. Plain text and URL fields use the standard macOS
editing commands.

## Plugin Settings

`settings_fields` declares Plugin Settings: values every Menu Item made from
the Plugin shares, such as an endpoint or an API key. They take the same kinds
as `configuration_fields`, plus `ordered_choices` and `list`, and
`default_settings` gives their starting values.

- An `ordered_choices` setting holds some of its `choices`, each at most once,
  in the order the user put them (a JSON array of strings); the sheet shows
  every choice with a checkbox and moves checked ones up and down.
- A `list` setting holds rows of typed cells in the order the user put them: a
  JSON array of objects with one string per column. It declares `columns` (one
  to eight, each a `key`, a `kind`, and optionally a `title`, a `placeholder`,
  and `unique`) and optionally `max_rows` (1–100, default 100). A `text` cell
  is one non-blank line of at most the column's `max_length` characters
  (1–256, default 256); a `url_template` cell is an https address holding
  `{query}` exactly once, in its path or query, never its authority. A
  `unique` column never holds the same cell twice, ignoring surrounding
  whitespace. The sheet edits a list as rows that can be added, moved, and
  removed. A list saved as text by an earlier version (one row per line, cells
  separated by `|`) is rewritten as its rows, once, when the Host registers or
  updates the Plugin.

`ordered_choices` and `list` are valid only in `settings_fields` and cannot be
overridable. A setting may declare `used_when` naming another `choice` or
`ordered_choices` setting and some of its choices; it is in use while that
setting holds (or, for `ordered_choices`, contains) one of them. The sheet
shows only settings in use, and a setting not in use is never missing, never
checked when the sheet saves, and never needs endpoint consent.

A setting may declare a `group`, the heading it sits under in the Plugin
Settings sheet, so a Plugin with many settings reads as a few short groups;
settings with no group come first, each group keeps the order its settings
were declared in, and a missing value names its group ("DeepL API Key").
`group` is only valid in `settings_fields`.

The user fills Plugin Settings in from the Library before placing anything; the
Library marks the Preset "Needs Plugin Settings" until every setting in use has
a usable value (non-blank text, at least one choice for `ordered_choices`, at
least one row for a `list`, a stored secret for a `credential`, an https
address for an `https_endpoint`), and the Plugin's Menu Items are unavailable
(`plugin_settings_incomplete`) meanwhile. A field marked `"overridable": true`
may also be set on one Menu Item: its Configuration Sheet offers "Plugin
Setting (…)" or a value of its own, and the Action stores only the override. A
settings key may not also be a key of a Command's `configuration_fields`.

A script receives one input object: the settings, then the Menu Item's
overrides, then the Command's own fields. An `https_endpoint` setting reaches
every Command, so a host the Plugin did not declare needs consent in the Plugin
Settings sheet before it saves. A Plugin View may show some of its `choice` and
`toggle` settings as [controls](views.md#components).

## Migrations

`migrations` maps data an earlier version of the Plugin left behind onto this
one.

- `rename_commands` maps retired Command IDs to declared ones, and their
  Actions move over keeping their IDs, so Menu Slots, aliases and Alternate Actions
  are kept.
- `rename_settings` maps retired settings keys to declared ones; a stored value
  moves to its new key unless one is already stored there.
- `drop_input` names declared Commands that are not configurable, whose Actions
  drop any input an earlier version stored.

Each step must start from something this version no longer declares and end at
something it does. The Host applies the block whenever it registers or updates
the Plugin, before Plugin Settings take values from Actions, and applying it
again changes nothing. It may do nothing else: a manifest whose `migrations`
has any other member is refused, so a migration can never grant a Capability.

## What the schema checks

The schema checks the shape of each member: which members exist, their types,
the allowed Capabilities, Host Commands, and field kinds, and the length limits.
The Host checks the rest when it loads a package, such as that the Preset names
declared Commands, that each Capability scope belongs to a declared Capability
and names the data and targets it affects, that default inputs and settings
suit their fields, and that each `migrations` step moves a retired Command or
settings key onto a declared one and drops only the input of a Command that is
not configurable.

A few older spellings the Host still reads are not part of the interface and
the schema rejects them: `script_path` and `javascript` for `script`,
`configuration` for `configuration_field`, and the `common_javascript` and
`script` executions.

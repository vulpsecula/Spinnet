# Regression baseline: the six Bundled Plugins

What a user of Translator, Smart Jump, Window Position, Clipboard History, Bob
and Shottr can see and do today, written down before the Plugin architecture
work (#47) moves any of it. Every ticket that touches one of these Plugins is
checked against its section here, by hand, in the running app
(`./script/build_and_run.sh --verify`).

A change a ticket makes on purpose is recorded in that ticket and then here, so
this file always describes the app as it should be. Anything else that differs
is a regression.

`RegressionBaselineTests` keeps this file honest in one direction: it fails if a
Command ID or a Plugin Settings key in the six manifests is missing from it.

## How to walk it

- Start from the fixture data (below) or your own configuration.
- For each line, do what it says and compare. A line reads *entry → what
  happens*.
- "Feedback" means the Host's short message near the pointer. "Unavailable"
  means the Menu Item is dimmed and its explanation gives the reason quoted.

## Shared behaviour

- **Presets.** Each Plugin appears in the Library with its Preset, *Ready to
  Use*. Adding the Preset to a Slot creates a Menu Item with the Preset's
  Primary Action and its default Alternate Actions, in manifest order.
- **Menu Items.** An alias shows in place of the title. Alternate Actions
  appear in the context menu in the editor's order; a disabled one is kept
  in the editor, unticked, with its values, and absent from the context menu.
- **Descriptions.** Every Command's description shows as the Menu Item's
  explanation, taken from the registered Command rather than the stored Action.
- **Access.** Library → Plugin → Plugin Settings lists every declared
  Capability with Grant Access / Revoke Access. A required Capability that is
  not granted makes the Menu Item unavailable: "Grant Access in Plugin
  Settings". An optional one that is not granted is skipped and the Command
  still runs.
- **Plugin Settings.** The sheet says "Shared by every Menu Item made from
  *Plugin*." Fields in a group are shown under the group's name; a field whose
  `used_when` is not met is hidden. A missing value the current sources need
  makes every Menu Item of the Plugin unavailable: "Complete this Plugin's
  Plugin Settings in the Library".
- **Installation.** Library → Install or Update Plugin… asks "Install
  *name*?" with the access it requests, before anything is copied. Install
  grants that access; Cancel installs nothing. A Plugin that asks for no new
  access installs at once. A refusal, such as a Plugin that needs a newer
  Plugin API Level, is an alert.
- **Removal.** Library → Plugin → Remove Plugin (confirmed) removes it. The
  confirmation names the Slots whose Menu Items use it; those stay in their
  Slots and become unavailable ("Plugin is not registered"). The removal
  survives a relaunch.
- **Coming back.** A removed Bundled Plugin has no separate way back.
  Installing a copy of its package installs that copy, like any other Plugin,
  with its Menu Items working again: access is **not** inherited, and the
  install asks for every Capability again. Every install ends in an alert:
  Plugin Installed, Plugin Updated (from which version), Plugin Reinstalled,
  or Plugin Not Installed.
- **Updates.** A new Plugin version with an unchanged Capability scope keeps
  the user's decision; a changed scope asks again.

## Translator (`com.spinnet.translator`)

### Commands

| Command | Entry | What happens |
| --- | --- | --- |
| `translator.selection` | Menu Item with text selected | Popup near the pointer with the selection as the original and one section per source turned on |
| `translator.selection` | Nothing selected, or the App keeps its selection to itself | Popup with a "Text to translate" field and a Translate button instead of failing |
| `translator.input` | Menu Item | Popup with the "Text to translate" field; Return or Translate sends it |
| `translator.clipboard` | Text on the clipboard | Popup with the clipboard text as the original |
| `translator.clipboard` | Clipboard holds no text | Popup with the input field |

### Popup

- Title "Translate"; under it, the direction in use.
- Each section is titled by its source (Google, DeepL, "OpenAI · *model*"),
  in the order of the `sources` setting. Each shows a spinner, then the
  translation (selectable) or a warning line with the failure message.
- A Copy button appears on each finished section and copies that translation.
- The settings line offers Input and Target pickers, a Swap button between
  them, and an "Auto" switch for detecting the direction. Changing one stores
  the Plugin Setting and runs the Action again; the new popup keeps the text.
- With Detect Direction on and the text already in the target language, the
  popup translates into the Input language instead and says "Detected
  *target*, translating into *input*".
- The pin button keeps the popup open when focus moves; unpinned, clicking
  elsewhere closes it. Escape closes it. It can be dragged, and then grows
  from where it was left.
- A new popup replaces the old one.
- Translating the same text again within 10 minutes is answered from the
  cache (no new network request; at most 50 answers kept).

### Plugin Settings

| Key | Control | Default | Notes |
| --- | --- | --- | --- |
| `sources` | Checklist, reorderable: Google, DeepL, OpenAI | Google | "Checked ones are used, in this order." None checked → unavailable |
| `source_language` | Input picker (Languages) | EN-US | 23 languages, English titles |
| `target_language` | Target picker (Languages) | ZH-HANS | Same list |
| `auto_detect` | Detect Direction switch (Languages) | on | No effect when Input equals Target |
| `google_endpoint` | Endpoint (Google) | `https://clients5.google.com` | Shown only with Google on |
| `deepl_endpoint` | Endpoint (DeepL) | `https://api-free.deepl.com` | `api.deepl.com` also declared |
| `deepl_credential` | API Key (DeepL) | reference `deepl` | Secure field with show/hide; kept in the Keychain |
| `formality` | Formality (DeepL) | default | default / prefer_more / prefer_less |
| `openai_endpoint` | Base URL (OpenAI) | `https://api.openai.com/v1` | Any https base URL |
| `openai_model` | Model (OpenAI) | gpt-4.1-mini | Blank → unavailable |
| `openai_credential` | API Key (OpenAI) | reference `openai` | Keychain |

### Version 1 data

- Launched with `TranslatorVersion1/` as the saved data, the "翻译" Menu Item
  keeps its alias and Alternate Actions, its Actions are Translate Selection,
  Translate Input and Translate Clipboard, and each still translates. The
  Translate Selection and Copy Action's own `target_language` is dropped;
  Plugin Settings show the DeepL endpoint `https://api.deepl.com` and key
  reference `deepl` carried over.

### Errors and repair routes

- Endpoint on a host the Plugin did not declare → the sheet shows "New
  network host" and "Allow Translator to contact *host*"; saving is refused
  until it is allowed. The allowed host is added to the `contact_https`
  scope and kept across launches.
- A source with no key stored → unavailable until the key is entered.
- A non-https endpoint → the section fails: "Configure an https address for
  *source* in Translator's Plugin Settings".
- Service refusals show per section: DeepL 401/403 "DeepL rejected the API
  key", 429 "Too many requests to DeepL; try again shortly", 456 "The DeepL
  quota is used up"; Google 429 "Google is refusing requests from this
  network for now; try again later", 403 "Google refused the request", 413
  "The text is too long for Google"; OpenAI 401 "The service rejected the
  OpenAI API key"; any other status "The service answered *status*".
- Network access revoked while a popup is open → its next send fails with
  "Network access is not granted to this Plugin".

### Permission prompts

- `read_selected_text` (Accessibility) for Translate Selection.
- `read_current_clipboard` is optional: granted, it lets Translate Selection
  fall back to a targeted copy and lets Translate Clipboard read the
  clipboard; not granted, Translate Selection stays Accessibility-only.
- `contact_https` for the declared hosts, plus any host the user allowed.

## Smart Jump (`com.spinnet.smart-jump`)

### Commands

| Command | Entry | What happens |
| --- | --- | --- |
| `smart_jump.open_selection` | Selection containing a web address | Opens the first address in the browser; no window |
| `smart_jump.open_selection` | Selection with a DOI (`10.xxxx/…`) | Opens `https://doi.org/…` |
| `smart_jump.open_selection` | Selection with a Bilibili ID (BV…, av…) | Opens the video page |
| `smart_jump.open_selection` | Selection with a local path (`/…`, `~/…`, quoted) | Opens it in Finder or its App; "The local file or folder does not exist" when absent |
| `smart_jump.open_selection` | Link ending in zip/dmg/pdf/pkg/tar/gz/bz2/xz/7z/rar | Opens it in the browser, which downloads it |
| `smart_jump.open_selection` | Plain text | Searches with the first search engine |
| `smart_jump.open_selection` | Arithmetic, e.g. `2*(3+4)` | Opens the Smart Jump window showing the result |
| `smart_jump.open_selection` | Nothing selected | Opens the Smart Jump window with an empty field |

- The first target in reading order wins; at the same position a DOI, video
  or path wins over a web address. A leading `/` is a path, not a division.

### Smart Jump window

- Title "Smart Jump"; field "Text, link, path or calculation".
- As the user types, a status line previews the target: "Type to preview",
  "Open web address", "Open DOI", "Open Bilibili video", "Open download link
  in browser", "Open local file", "Search the web · Using *engine* · *host*",
  "Calculate · Result: *value*", or "Check this input" with the error.
- Return or the action button (Open / Watch / Download / Search / Calculate)
  performs it and closes the window, except a calculation, which stays open
  and offers "Copy Result" ("Copied" once done).
- Escape or clicking elsewhere closes it. Text over 16 KiB is refused.

### Plugin Settings

| Key | Control | Default |
| --- | --- | --- |
| `search_engines` | "Search Engines (first is default)": the generic list editor (#53): one line per engine showing its name with its Search URL beneath, and Edit (pencil), move up/down and remove buttons; Edit opens a sheet with labelled "Name" and "Search URL" fields, whose Save stays disabled until both are valid and whose Cancel keeps the row as it was; "Add Row" opens the same sheet, and cancelling it adds nothing | Google, Bing, DuckDuckGo |

- Search URLs must be https and contain `{query}` once, in the path or query;
  names are unique, at most 50 characters; at most 10 engines. Saving an
  invalid row names the row and refuses; an empty list → unavailable ("Still
  needed: Search Engines (first is default)").
- Engines saved before #53, as text, are written as rows in their order at
  the first launch, and open as those rows.

### Permission prompts

- `read_selected_text` required; `read_current_clipboard` optional (copy
  fallback), `write_clipboard` optional (Copy Result), `open_local_path`
  optional (paths), `open_url` required.

## Window Position (`com.spinnet.window-position`)

All Commands act on the focused window, within the visible frame of its
display (menu bar and Dock excluded), and need Accessibility; without it
every Menu Item is unavailable: "Enable Accessibility in Privacy &
Permissions".

### Commands

| Command | Result |
| --- | --- |
| `window.center` | Centred, size kept unless it does not fit |
| `window.maximize` | Fills the visible frame |
| `window.left_half`, `window.right_half`, `window.top_half`, `window.bottom_half` | Half; running it again on a window already there cycles 1/2 → 2/3 → 1/3 → 1/2 |
| `window.first_third`, `window.center_third`, `window.last_third` | Thirds of the longer edge (columns on landscape, rows on portrait) |
| `window.first_two_thirds`, `window.last_two_thirds` | Two thirds of the longer edge |
| `window.top_left_quarter`, `window.top_right_quarter`, `window.bottom_left_quarter`, `window.bottom_right_quarter` | Quarters |
| `window.first_fourth`, `window.second_fourth`, `window.third_fourth`, `window.last_fourth` | Fourths of the longer edge |
| `window.top_left_sixth`, `window.top_center_sixth`, `window.top_right_sixth`, `window.bottom_left_sixth`, `window.bottom_center_sixth`, `window.bottom_right_sixth` | Sixths: three columns, two rows |
| `window.maximize_height`, `window.maximize_width` | Full height (width and x kept) / full width (height and y kept) |
| `window.reasonable_size` | 60% of the visible frame, at most 1025 × 900, centred |
| `window.move_up`, `window.move_down`, `window.move_left`, `window.move_right` | To that edge, size kept |
| `window.toggle_full_screen` | Into or out of macOS full screen |
| `window.previous_display`, `window.next_display` | To the neighbouring display (left to right, wrapping), size and relative position kept; nothing with one display |
| `window.restore` | Back to where it was before Spinnet's consecutive moves (remembered in memory only) |
| `window.resize` | To the configured "Width, Height" from the top-left corner |
| `window.move` | To the configured "X, Y", size kept |

- Adjacent cells share edges with no gaps; odd points go to the right or
  lower cells.

### Command configuration fields

- `window.resize`: "Width, Height", e.g. `800, 600` or `50%, 100%`; zero and
  percentages over 100 are refused.
- `window.move`: "X, Y", e.g. `0, 0` or `25%, 10%`; zero allowed.

### Errors

- "No focused window"; "The focused window cannot be moved or resized"; "The
  focused window is in full screen; leave full screen before choosing a
  layout"; "The focused window cannot enter or leave full screen"; "The
  focused window did not accept the new frame".

## Clipboard History (`com.spinnet.clipboard-history`)

Clipboard History is the one Host Surface (ADR 0009): its window stays
Host-owned. Collection settings live in Privacy settings, not Plugin
Settings.

### Commands

| Command | Entry | What happens |
| --- | --- | --- |
| `history.browse` | Menu Item | Opens the Clipboard History window (replacing an open one) |

### Window

- Search field with a clear button; Refresh (⌘R); More menu: Clear History…,
  Ignored Applications…, Plugin Settings…, Privacy Settings….
- Filters: Type (All Types, Text, Rich Text, Links, Images, Files, Other), App
  (All Applications, then each source App), Sort (Newest First, Oldest First,
  Source Application, Type); "Reset" appears when any is changed.
- Rows show a preview: text, image thumbnail with pixel size, "File reference
  only — source contents are not stored.", or "Unavailable — *reason*".
- Double-click or Return pastes into the previous App; the context menu offers
  Paste, Copy to Clipboard and Delete (or "Delete *n* Entries"); ⌫ deletes.
  The footer shows "*n* entries", "*n* of *m* entries" when filtering, the
  selection count, Delete and Paste.
- Scrolling to the end loads more.
- Collection off or paused → a banner ("Collection is off. Retained entries
  remain readable until they expire." / "Collection is paused. No new
  entries are collected.") with "Open Privacy Settings…".
- Clear History asks "Delete all retained clipboard entries?" and cannot be
  undone.

### Errors and repair routes

- Access denied → the window shows the error and "Manage Access in Library…".
- Any Plugin granted `read_clipboard_history` may open this window, installed
  or Bundled; without the grant it is refused.

### Permission prompts

- `read_clipboard_history`, covering existing retained data, for all data
  types.

## Bob (`com.spinnet.bob`)

Needs Bob (`com.hezongyidev.Bob`). Bob owns its own windows and results.

### Commands

| Command | What happens |
| --- | --- |
| `bob.selection_translate` | Reads the selection and sends it to Bob to translate; blank selection opens Bob's input window; if Spinnet cannot read it, Bob reads the selection itself |
| `bob.snip_translate` | Bob captures a screen region and translates it |
| `bob.input_translate` | Bob's input window opens |
| `bob.pasteboard_translate` | Bob translates the clipboard |
| `bob.translate_text` | Sends the configured text to Bob |

### Command configuration fields

- `bob.translate_text`: "Text", multi-line, placeholder "Text for Bob to
  translate". Missing text → "Configure the text Bob should translate".

### Errors and repair routes

- Bob not installed → unavailable: "Install Bob to use Bob Commands".
- Automation denied → "Allow Spinnet to control Bob in System Settings >
  Privacy & Security > Automation".
- Older Bob → "This Bob version does not support the requested operation;
  update Bob and try again". Other refusals → "Bob rejected the request:
  *message*" or "Bob did not accept the request".
- Selected or configured text over 128 KiB → the Action fails before Bob is
  asked.

### Permission prompts

- `control_external_app` for "Bob (com.hezongyidev.Bob): translate", the
  operations of the Host's Reviewed App Interface for Bob (all Commands);
  `read_selected_text` for Translate Selection; `read_current_clipboard`
  optional (copy fallback). macOS asks for Automation consent the first time,
  explaining that Spinnet sends an app only the requests it has reviewed for
  it. A grant given before W8 (#55) still applies.

## Shottr (`com.spinnet.shottr`)

Needs Shottr 1.8 or later (`cc.ffitch.shottr`) with its URL Scheme API on.
Shottr owns the capture, what happens after it, and Screen Recording. Each
Command opens one of the Plugin's Deep Link Templates without starting a
Plugin helper, and Shottr is not brought forward.

### Commands

| Command | Shottr route |
| --- | --- |
| `shottr.capture_area` | area |
| `shottr.capture_fullscreen` | full screen |
| `shottr.capture_window` | window |
| `shottr.capture_repeat_area` | previous area again |
| `shottr.capture_scrolling` | scrolling down |
| `shottr.capture_scrolling_reverse` | scrolling up |
| `shottr.capture_delayed` | after the configured delay |
| `shottr.append_capture` | adds to the current screenshot |

### Command configuration fields

- `shottr.capture_delayed`: "Delay" — 3, 5 or 10 seconds; the Preset
  defaults to 3.

### Errors and repair routes

- Shottr not installed → unavailable: "Install Shottr to use Shottr Commands".
- Shottr not opening `shottr:` links (older than 1.8, or URL Scheme API off)
  → "Shottr does not open shottr: links; update Shottr or turn on its URL
  scheme in its settings, then try again".

### Permission prompts

- `control_external_app` listing "Shottr (cc.ffitch.shottr) links, opened
  without bringing it forward" and each of the eight `shottr://grab/…`
  templates, the delayed one with "delay_seconds: 3, 5, 10". A grant given to
  Shottr's `capture` operations before W8 (#55) carries over, because the
  templates open exactly those links; a changed template asks again.

## Fixture data

The files beside this one are user data in the formats the Host writes to
`~/Library/Application Support/Spinnet/`. `RegressionBaselineTests` loads them
through the launch path (`StoredDataMigration`) and requires that nothing
changes and that they write back unchanged. A ticket that changes a format
adds its migration and keeps this test passing on these files unchanged.
The expected changes so far: since W8 (#55) the Shottr Actions move onto
its Deep Link Templates, keeping their IDs and inputs, and its
`control_external_app` grant is stored with the templates; since W6 (#53)
Smart Jump's engines, saved as text, are written as `list` rows.

| File | Covers |
| --- | --- |
| `configuration.json` | One Action for every Command of the six Plugins (56); aliases (including non-ASCII); enabled, disabled and interleaved Alternate Actions; an empty Slot; Command inputs for `bob.translate_text` (multi-line), `shottr.capture_delayed` (non-default), `window.resize` and `window.move`; a legacy input still held by a `shottr.capture_fullscreen` Action |
| `PluginSettings.json` | Non-default Translator settings (reordered sources, Pro DeepL endpoint, self-hosted OpenAI base URL, a renamed credential reference) and a custom Smart Jump engine list |
| `capability-grants.json` | Granted, denied and undecided decisions; declared scopes; a user-allowed host on `contact_https`; a decision kept for an older Bob version; the Host Command Plugins' decisions |
| `keychain-items.json` | The Keychain items the credential references name (service and account; never a secret) |
| `TranslatorVersion1/` | The Translator Menu Item and Plugin Settings as Translator 1 wrote them: `translator.copy` and `translator.replace` Actions, configurable Actions with inputs (one overriding `target_language`), and DeepL's `endpoint` and `credential` under their old keys. Translator's manifest `migrations` must turn them into exactly the Translator Actions of `configuration.json`, and a second launch must change nothing |

Not covered, because no planned ticket changes them: the Clipboard History
archive (`ClipboardHistory/`), Menu appearance, triggers, and Screenshot
settings (all Host-owned, in their own files or user defaults).

# Interface overview

Declare Host compatibility in the [manifest](manifest.md); all compatible Plugins use these current names and behaviours.

### Host Services, by ID

Every Host Service has one ID, `namespace.verb`, the same string in a
script's call (`spinnet.<id>(input)` or `requestHostService("<id>", input)`),
a manifest Command's `host_command`, a page action's and a Requested Host
Operation's `perform`, and `operation_finished`
([Host Service IDs](namespaces.md)). The SDK holds an operation at
`spinnet.<id>` when a script can call it; one offered as a request or a page
action also has `spinnet.<id>.operation(input, options)` and
`spinnet.<id>.action(input, options)`, so `spinnet.host.showPluginSettings`
holds only those two. Command-only operations such as `keyboard.press`,
`system.runShortcut` and `system.runService` have no SDK member; the `keyboard`
namespace is absent. The `system` namespace provides `metrics` calls and sources,
and pure `keepAwake` request/action builders.

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
|  | `apps.frontmost` | call | `read_frontmost_app` | none |
|  | `apps.quit` | page action, request, after a Host Confirmation for Force Quit or an App not in front | `quit_frontmost_app` | Accessibility, except Force Quit |
|  | `apps.close` | page action, request, after a Host Confirmation for an App not in front | `quit_frontmost_app` | Accessibility |
| `system` | `system.runShortcut` | Command | none | none |
|  | `system.runService` | Command | none | none |
|  | `system.keepAwake` | Command, page action, request | `keep_awake`; App-alive also `read_frontmost_app` | none |
|  | `system.metrics` | call, source | `read_system_status` | none |
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
| `activities` | `activities.list` | call, own activities only | none | none |
|  | `activities.stop` | page action, request, own activities only | none | none |
| `tools` | `tools.read` | call, once-only source | `read_reviewed_tools`, scoped to tool, operation and package kind | none |
| | `tools.showServices` | Command, page action, request | `read_reviewed_tools` | none |
| | `tools.startTask` | page action, request | `run_reviewed_tool_tasks`, scoped to operations and package kinds | native sudo/PAM when Homebrew needs it |

Reserved entry points in `catalogue.json` are refused until a later Host release adds them.
`selection.cut`, `selection.paste`, `keyboard.press`, `system.runShortcut`
and `system.runService` are offered only as Commands, whose input the user
configures.

### Pages, in `spinnet.ui.components`

`spinnet.ui` offers form/detail builders and `ui.page`, `ui.showPage`,
`ui.request` and `ui.components` ([pages](pages.md)). A page has
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
| `grid` | `components.grid`, `section`, `item`, `itemAction` | A selectable grid of 2 to 12 columns, or as many as the width holds, likewise |
| `icon` | `components.icon` | A system symbol, tinted |
| `image` | `components.image` | A PNG or JPEG the Host loads from the package or a host the Plugin may contact, in a fixed frame |
| `progress` | `components.progress` | A task's stages, status and state, indeterminate unless the Plugin knows its value, with a cancel View Action |
| `activity_list` | `components.activityList` | This Plugin's active Host resources, remaining seconds and native Stop controls |
| `adaptive` | `components.adaptive` | 1–8 identified cards with bounded passive viewport fit |

`text`, `row`, `column`, `icon`, `image` and `progress` take a `style` of
their own (colours, including custom ones, a font size and weight,
background, padding, corner radius); nothing inherits it, and the Host's
fields, buttons, Collections and chrome keep their native look. Items may
show a system symbol as their `icon`. See [Styles, images and progress](pages.md#styles-images-and-progress).

A page may declare `resizable`, letting the user resize its panel whether
pinned or not, and a `grid` may take `columns: "auto"`, whose columns the
Host chooses from the width as the panel is resized; pages that do not
declare it, and form/detail views, keep the default layout. See [Resizable pages](pages.md#resizable-pages).

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
([Requested Host Operations](host-operations.md)). Every
insertion in a current View Session goes to the App in front when the Host
inserts, which must be the App the Host showed when the user acted.

View Events add `item_action`, `load_range`, `called` (an Explicit Call
into the open View Session) and `operation_finished` alongside field, form, settings and detail events.

### The App in front

`spinnet.apps.frontmost()` identifies the App behind Spinnet's panel, under
`read_frontmost_app`: its name, bundle identifier and an App Target, an
opaque name the Plugin may give back to the Host, never a process list or ID.
`spinnet.apps.quit` asks the Host to quit or force quit that App, or the one
a target names, and `spinnet.apps.close` to close its front window, both
under `quit_frontmost_app`. Quit and Close are exactly the App's own ⌘Q and
⌘W: the Host presses the App's menu item, through Accessibility, and offers
them only for an App whose menu has that item enabled. The Host asks the
user first, in a Host Confirmation naming the App, before every Force Quit
and before closing or quitting an App that was not in front when it
accepted the request; closing or gracefully quitting the App in front asks
nothing, the App's own save prompts still applying. A manifest may declare the two Capabilities ([the App in front](apps.md)).

### Host-owned keep-awake effects

`ui.components.activityList({id, emptyText})` renders the Plugin’s own Host Activities,
with native Stop and a live countdown in seconds, without invoking its helper.

`system.keepAwake` prevents idle system and display sleep together under the
new `keep_awake` Capability. Manual, duration and App-alive effects survive
view closure and bounded helper retirement. `activities.list` exposes only
the requesting Plugin's running effects; `activities.stop` releases its own
activity. The Host Status Item lists and stops every owner's activities.
See [lifetime and limitations](keep-awake.md),
[schemas](../schemas/namespaces.schema.json) and [fixtures](../fixtures/keep-awake/index.json).

## Reviewed local Homebrew data

`tools.read` requires a scoped `read_reviewed_tools` grant. See
[inputs, sources, bounds and regression coverage](tools.md) and
[schema](../schemas/reviewed-tools.schema.json). Install and upgrade use separately
granted, Host-confirmed [Reviewed Tasks](reviewed-tasks.md). Native Homebrew runs
as the current user. System sudo/PAM handles authentication; when a password is
needed, the signed Host-owned askpass window passes it directly to sudo without
saving it or sharing it with the Plugin. [Authorization and legacy recovery](homebrew-system-authorization.md)
are separate from read access.

### Host-run sources

Pages may declare up to eight visible-page sources, with text bindings
rendered by the Host and optional `source_delivered` events. Reviewed Homebrew `tools.read`
sources sample once within 15 seconds, use the call's scope and result, and stop
their process group when hidden or closed. HTTPS `http.request`
samples once, within 15 seconds, bypasses the section cache and adds parsed `json`.
Local adapters have a one-second minimum; changed-result deliveries have a
15-second floor except the one-second activity source. The Host coalesces to the latest result. Metrics and reviewed Spotify playback
sources are offered in the current interface. See [sources](sources.md),
[schemas](../schemas/host-run-sources.schema.json), and [recordings](../fixtures/sources/index.json).

`system.metrics` is a current call and visible source for aggregate
CPU, memory, startup disk capacity and battery. It requires `read_system_status`,
no System Permission, and samples at most once per second. See the metric units
and unavailable-value rules in [the namespace reference](namespaces.md#systemmetrics)
and [schema](../schemas/system-metrics.schema.json).
Local Spotify's current Reviewed App Interface and playback source are documented
in [spotify.md](spotify.md), with [typed schema](../schemas/spotify.schema.json).

`tools.showServices` presents a controlled panel or Status Item Services menu through the [native Services Host Surface](services-surface.md)
under a scoped Homebrew services read grant. Its native user-owned Start/Stop/Restart
controls separately enter Host-confirmed reviewed Task admission.
The expanded Homebrew `tools.read` profile is documented in
[management reads](homebrew-management-reads.md), with
[typed operations/results](../schemas/homebrew-management-reads.schema.json).

Spotify controls and External App connections are described in [Spotify](spotify.md).

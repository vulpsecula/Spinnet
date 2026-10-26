# Host Service IDs (current interface)

The current interface names every operation the Host performs for a Plugin, a
Host Service, by one ID, `namespace.verb`, which a Plugin uses
wherever it names the operation: in a script's call, in a manifest Command,
in a page action, in a Requested Host Operation and in `operation_finished`.
The Host names it the same way in refusals and in what it discloses.
[`catalogue.json`](../catalogue.json) lists every operation
([schema](../schemas/catalogue.schema.json)), and the Host's own table of
operations is held to it;
[`namespaces.schema.json`](../schemas/namespaces.schema.json) publishes
their inputs and results and the shapes that name them;
[`spinnet.js`](../sdk/spinnet.js) is the SDK and
[`spinnet.d.ts`](../sdk/spinnet.d.ts) its types. Use this with
[Requested Host Operations](host-operations.md) and
[pages](pages.md).

```json
{
  "protocol_version": "1.0",
  "engines": {"spinnet": "^1.0.0"}
}
```

Plugins name operations by ID at every entry point: calls, Commands,
answers and sources here, page actions in [pages](pages.md) and requests
in [Requested Host Operations](host-operations.md).

## IDs

An ID is exactly `namespace.verb`, two lowerCamelCase segments. The namespace
organizes a domain; it grants no authority. The ID is the same in JSON and the
SDK: `spinnet.selection.readText` calls `selection.readText`. Historical spellings
such as `write_clipboard`, `url.open` and `copy_text` are refused at public entry
points, including form/detail standard actions. See [migration](compatibility.md).

## Where an operation is offered

| Entry point | How a Plugin names the operation | Performed |
| --- | --- | --- |
| Call | `spinnet.<id>(input)`, or `requestHostService("<id>", input)` | At once, inside the four-second invocation; returns the result |
| Command | `"execution": "host"` and `"host_command": "<id>"` in the manifest | When the Menu Action runs, with the Action's configured input; no helper starts |
| Page action | `{"perform": "<id>", "input": …}` in a page's `actions`, or an item action's `perform` ([pages](pages.md)) | On the user's click or key, without a View Event |
| Request | `{"operation": {"perform": "<id>", "input": …}}` in the answer to a gesture ([Requested Host Operations](host-operations.md)) | After the answer commits; `operation_finished` reports the outcome when asked |
| Answer | The answer's `toast` and `close` members | When the answer commits |
| Source | A Host-Fetched Section's `fetch.request` | While the view shows the section |

An operation that returns data is offered as a call, and may also be offered as
a visible-page source when the catalogue publishes its bounded read lifecycle. An effect with no
result is offered as a Command, a page action and a request, with the same
input. An effect is also offered as a call when it completes inside the
invocation and needs neither a Host Confirmation nor a target the Host
shows. The catalogue states every entry point of every operation, and why an
operation is reserved or not offered where it is not.

## Input

An operation's input is a JSON object, or nothing (`null`, or left out). When
its object has one required string member, its primary member, a bare string
stands for that member wherever the operation is named:
`spinnet.clipboard.write("😀")`, `{"perform": "clipboard.write", "input":
"😀"}` and `{"perform": "clipboard.write", "input": {"text": "😀"}}` are
the same operation. In the tables below a member written alone is the
primary member.

A Command's input is its Action's configured input. A single
`configuration_field` supplies the primary member, or the whole input of an
operation without one (`keyboard.press`); `configuration_fields` supply the
members their keys name. The Command may fix other members in its own
`input`:

```json
{"id": "builtin.capture_area", "title": "Capture Area", "execution": "host",
 "is_configurable": false, "host_command": "screen.capture", "input": {"source": "area"}}
```

A member is fixed or configured, never both, and every member belongs to the
operation's input. `screen.capture` fixes its `source`. `apps.perform` fixes
`bundle_id` and `operation` in `input`, and `apps.openDeepLink` names its
template with `deep_link_template`; their configuration fields, keyed by the
parameter names, fill `arguments` and `parameters`. A Command needs the
Capabilities its operation needs as a Command, declared in the manifest.
The Host checks all of this when it reviews, installs and registers the
Plugin, and refuses the package with the Command and the reason.

A Command naming an ID runs no script and starts no helper.
`open.path` opens a folder or a file, whichever the path names, and
`host.toast` shows its message near the pointer.

## Authority

Each operation names the Capabilities and the System Permission it needs,
the same at every entry point, with one exception: a Command's input is what
the user configured. A Command may open a link, path or application, press a
shortcut, cut, paste, or run a Shortcut or Service without a Capability. A configured
link may have any scheme. When the Plugin chooses the input, in a call, a
page action or a request, the operation's Capability always applies, and a
link must be http or https with a host.

An operation fails with the same Host Service categories wherever it is named, including and `insertion_target_changed`
([Requested Host Operations](host-operations.md#failure-category)).
A call ends the invocation with it, a Command ends its Action with it, a page
action shows it with the way to repair it, and a request reports it as its
outcome's reason. An unavailable application, file, folder, Shortcut or
Service is `host_service_failed` with its reason; `command_unavailable` means
only that the Plugin or Command is missing, disabled or changed.

## The SDK

The `spinnet` object is laid out by namespace. An operation offered as a call is a function at
`spinnet.<id>`, which requests exactly that ID with its argument as the
input and returns the result:

```js
const text = spinnet.selection.readText({ best_effort: true });
spinnet.clipboard.write(text.toUpperCase());
```

An operation an answer may request also has `.operation(input, options)`,
and one a page action may perform `.action(input, options)`
(`spinnet.clipboard.write.operation("😀")`,
`spinnet.open.url.action(url, { title: "Homepage" })`);
`spinnet.host.showPluginSettings`, which only a request or a page action
reaches, is an object holding those two builders. A namespace none of whose
operations a script can reach, `keyboard`, is absent, and so are
historical wrappers, such as `spinnet.clipboard.history`. `spinnet.ui` offers form/detail and page builders. Both answer shapes use
catalogue IDs. `ui.toast` and `ui.close` build the answer forms of `host.toast`
and `host.closeView`; `ui.request`, `ui.page`, `ui.showPage` and `ui.components`
compose pages and operations. `spinnet.environment.hostVersion` reports the
running Host release; compatibility is declared in `engines.spinnet`.
`requestHostService` takes IDs only.

## The helper protocol and the test kit

The Host's invocation carries Host version and preferred language. The helper
always installs the current SDK. A `host_service_request` names a catalogue ID
in `service`; unknown, historical and unoffered IDs fail explicitly.

In the Plugin test kit, `RecordedHostServices(operations:)` answers by ID,
such as `["clipboard.write": .value(.null)]`, and `run.performed` and
`run.inputs(to: "clipboard.write")` list what a run performed by ID, each
input as the Host performs it: a bare string where the script gave the
primary member alone. A Command naming an ID runs in the kit as in the Host,
without a helper; its result is its value, or the `ActionFailure` it ended
with.

## Operations

### `host`

Spinnet's own UI and flow, which the Plugin asks the Host to act on.
`host.toast` shows inside the view when one is open and near the pointer
otherwise; an answer with a toast and `close` is a HUD.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `host.toast` | `text` | null | Command, answer | nothing |
| `host.closeView` | none | null | answer | nothing |
| `host.showPluginSettings` | none | null | Command, page action, request | nothing |

### `selection`

The focused App's selection: reading, replacing, copying, cutting and pasting it; every operation targets the focused App.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `selection.readText` | none, or `{best_effort: true}` | text or null | call | `read_selected_text`, Accessibility |
| `selection.replace` | `text`, at most 128 KiB | null | call, page action, request | `insert_into_focused_app`, Accessibility |
| `selection.copy` | none | null | Command | `read_selected_text`, `write_clipboard`, Accessibility |
| `selection.cut` | none | null | Command | Accessibility |
| `selection.paste` | none | null | Command | Accessibility |

### `keyboard`

Keys pressed in the focused App; text is typed by `selection.replace`.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `keyboard.press` | `{key, modifiers?}` or `{key_code, modifiers?}` | null | Command | Accessibility |

### `clipboard`

The current clipboard's content; no operation here targets an App.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `clipboard.read` | none | `{text, type}` or null | call | `read_current_clipboard` |
| `clipboard.write` | `text` | null | call, Command, page action, request | `write_clipboard` |

### `clipboardHistory`

The Clipboard History Store, which holds entries only while its Sensitive
Data Collection setting is on, behind its own Capability.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `clipboardHistory.read` | none, or `{offset}` | a page | call | `read_clipboard_history` |
| `clipboardHistory.readContent` | `{entry_id, offset, length}` | a chunk | call | `read_clipboard_history` |
| `clipboardHistory.show` | none | null | call, Command, page action, request | `read_clipboard_history` |

### `open`

Handing a link, path or application to the App that opens it.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `open.url` | `url` | null | call, Command, page action, request | `open_url`; nothing as a Command |
| `open.path` | `path` | null | call, Command, page action, request | `open_local_path`; nothing as a Command |
| `open.application` | `application` | null | call, Command, page action, request | `open_local_path`; nothing as a Command |

### `apps`

External App integration through Reviewed App Interfaces and Deep Link Templates, and the App in front: identifying it, closing its window and quitting it ([the App in front](apps.md)).

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `apps.perform` | `{bundle_id, operation, arguments?}` | null, or [Spotify playback](spotify.md) | call, Command, page action, request; source for Spotify playback only | `control_external_app`, Automation (sources never prompt) |
| `apps.openDeepLink` | `{template, parameters?}` | null | call, Command, page action, request | `control_external_app` |
| `apps.frontmost` | none | `{target, name, bundle_id, exits}` or null | call | `read_frontmost_app` |
| `apps.quit` | `{target?, force?}` or none | null | page action, request | `quit_frontmost_app`; Accessibility except for Force Quit; a Host Confirmation for Force Quit and for an App not in front |
| `apps.close` | `{target?}` or none | null | page action, request | `quit_frontmost_app`, Accessibility; a Host Confirmation for an App not in front |

### `system`

macOS facilities no single App owns; Host-owned keep-awake (#84) and basic metrics (#86).

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `system.runShortcut` | `name`, optionally `{name, input}` | null | Command | nothing |
| `system.runService` | `name`, optionally `{name, input}` | null | Command | nothing |
| `system.keepAwake` | `{mode, seconds? or target?}` | null | Command, page action, request | `keep_awake`; App-alive also `read_frontmost_app` |

Keep Awake owns paired idle-system and idle-display assertions, survives view
closure, and releases on its own lifetime or owner invalidation. See
[effects and limitations](keep-awake.md).

`selection.cut`, `selection.paste`, `keyboard.press`, `system.runShortcut`
and `system.runService` are offered only as Commands, whose input the user
configures. A script, a page action or a request cannot choose keys, a
Shortcut or a Service in the current interface.

### `window`

The focused window.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `window.read` | none | frames | call | `position_focused_window`, Accessibility |
| `window.setFrame` | `{x, y, width, height}` | null | call | `position_focused_window`, Accessibility |
| `window.toggleFullScreen` | none | null | call, Command | `position_focused_window`, Accessibility |
| `window.restore` | none | null | call, Command | `position_focused_window`, Accessibility |

### `screen`

Screen captures the Plugin never receives.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `screen.capture` | `source`, optionally with `copy_to_clipboard` and `save` | null | call, Command | `capture_screen`, Screen Recording |

### `http`

HTTPS requests with Credential Uses, from a script or as a Host-Fetched Section.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `http.request` | an HTTPS request | `{status, headers, body}` | call, source | `contact_https` |

### `text`

Text processing on this Mac.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `text.detectLanguage` | `text` | a BCP 47 code or null | call | nothing |

### `storage`

Plugin Storage.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `storage.get` | `key` | the value or null | call | nothing |
| `storage.set` | `{key, value}` | null | call | nothing |
| `storage.remove` | `key` | null | call | nothing |
| `storage.keys` | none | the keys | call | nothing |
| `storage.clear` | none | null | call | nothing |

### `activities`

Only the requesting Plugin's Host-owned Effects and Tasks, never another owner's.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `activities.list` | none | own active activities | call | nothing |
| `activities.stop` | `{id}` | null | page action, request | nothing |

See [Host activity controls](keep-awake.md#activities). A missing, ended or
foreign ID is a no-op; Host Status Item controls can stop every owner.
Task Stop attempts to stop supervised work and never promises rollback; see
[Reviewed Tasks](reviewed-tasks.md).

### `tools`

Bounded reads and separately confirmed mutations through a Reviewed Tool Profile.

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `tools.read` | `{tool: "homebrew", operation, kind?, greedy?, query?, names?}` | `{tool, operation, packages, not_found?, truncated?}` | call, once-only source | `read_reviewed_tools`, scoped to tool, operation and package kind; no System Permission |
| `tools.startTask` | typed Homebrew operation and concrete targets | Task admission, followed through own activities | page action, request | `run_reviewed_tool_tasks`, scoped to operation and package kind |

Read calls have a three-second deadline; sources have a fifteen-second deadline and
stop on hide or close. Neither refreshes a catalogue or installs a package.
See [Reviewed Homebrew reads](tools.md) for each operation's input and bounds.
Install and upgrade follow [Reviewed Tasks](reviewed-tasks.md); read authority
does not grant mutations. [Catalog refresh](catalog-refresh.md) provides the separately granted
catalog-refresh entry exception. System authentication belongs to native sudo/PAM,
as [Homebrew authorization](homebrew-system-authorization.md) describes.

## Reserved

These IDs are kept for the tickets that define them. Naming one is refused
until a later Host release adds it.

| ID | Owner | For |
| --- | --- | --- |
| `host.confirm` | #68's local dialogs | A Plugin-worded question whose answer is a request's outcome |
| `host.launchCommand` | Reserved; requires a future Host release | Running another Command of the Plugin in the same View Session |
| `selection.readFinderItems` | Reserved; requires a future Host release | The files selected in Finder |
| `open.reveal` | Reserved; requires a future Host release | Showing a file in Finder instead of opening it |

### `system.metrics`

A call or visible-page source reads 1–4 distinct names in `metrics`: `cpu`,
`memory`, `disk`, `battery`. Requires `read_system_status`, no System Permission
or Sensitive Data Collection opt-in. Only aggregate current readings are exposed:
no process names, network, temperatures, file names, history or disk identifiers.

`cpu.busy` is the busy fraction across all CPUs between consecutive reads for
this Plugin (user + system + nice ticks / all ticks). It is null on the first
read, if no ticks advanced, or after a gap exceeding twice the source interval.
`memory.total_bytes` is physical RAM; `used_bytes` is active + wired + compressed
physical pages (not Activity Monitor's app-memory figure); `compressed_bytes`
is compressor pages. `disk.total_bytes` and `available_bytes` are `statfs`
capacity and space available to the user on the startup Data volume, excluding
purgeable estimates. All sizes are bytes. `battery.present` reports an internal
battery, `charge` is current/max capacity as a fraction, `charging` is a boolean,
and `power_source` is the IOKit AC/Battery power-source description. No battery:
`present:false` and the other fields null. A failed/unsupported OS read makes
that metric null. Unrequested metrics are omitted; unavailable bindings use
`unavailable` (default `Unavailable`). The result is below 1 KiB.

Sources have a one-second minimum and one-second deadline, one snapshot in
flight per source, fixed delay and no catch-up. Omit `every` for a single read.
Reads never launch a helper; bindings update without script deliveries. Adding
`deliver` uses #82's 15-second latest-result delivery floor. Hide/close, inactive
session, sleeping display, owner replacement and revocation cancel or discard
reads through the shared source engine. No background collection is retained.

`tools.showServices` presents the controlled native Homebrew Services Surface or menu. It requires the scoped `read_reviewed_tools` grant; each mutation separately requires `run_reviewed_tool_tasks` and Host Confirmation. See [Reviewed Tasks](reviewed-tasks.md).

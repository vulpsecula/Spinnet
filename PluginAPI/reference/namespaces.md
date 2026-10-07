# Host Service IDs (Plugin API Level 2)

Plugin API Level 2 names every operation the Host performs for a Plugin, a
Host Service, by one ID, `namespace.verb`, which a Level 2 Plugin uses
wherever it names the operation: in a script's call, in a manifest Command,
in a page action, in a Requested Host Operation and in `operation_finished`.
The Host names it the same way in refusals and in what it discloses.
[`catalogue.json`](../catalogue.json) lists every operation
([schema](../schemas/catalogue.schema.json)), and the Host's own table of
operations is held to it;
[`namespaces.schema.json`](../schemas/namespaces.schema.json) publishes
their inputs and results and the shapes that name them;
[`spinnet-level-2.js`](../spinnet-level-2.js) is the SDK and
[`spinnet-level-2.d.ts`](../spinnet-level-2.d.ts) its types. Level 2 was
proved as Candidate Contract `namespaces` r1, now retired
([history](../candidates/namespaces/r1/reference.md)), with
[Requested Host Operations](host-operations.md) and
[pages](pages.md).

```json
{
  "protocol_version": "1.0",
  "api_level": 2
}
```

Level 2 names operations by ID at every entry point: calls, Commands,
answers and sources here, page actions in [pages](pages.md) and requests
in [Requested Host Operations](host-operations.md).

## IDs

An ID is exactly `namespace.verb`, two lowerCamelCase segments. A namespace
is one area of Spinnet's domain, usually the operations one Capability
covers, and its verbs keep Plugin API Level 1's SDK style: `read` and
`write` for Host data, `get` and `set` for Plugin Storage. An ID is spelled
the same in JSON and in the SDK: `spinnet.selection.readText` calls
`selection.readText`. A Level 2 Plugin names operations by ID only. A
Plugin API Level 1 name (`write_clipboard`, `url.open`, `copy_text`, …) is
refused with a message naming the ID to use instead: when
the package is reviewed for a manifest Command, with `host_service_failed`
for a call, and as a protocol violation in a page or a request. The one
exception is a Level 1 `view` answer, which keeps Level 1's vocabulary
whole, its standard actions included (C9). [Level 1 names](level-1-names.md)
lists every Level 1 name and its ID.

## Where an operation is offered

| Entry point | How a Plugin names the operation | Performed |
| --- | --- | --- |
| Call | `spinnet.<id>(input)`, or `requestHostService("<id>", input)` | At once, inside the four-second invocation; returns the result |
| Command | `"execution": "host"` and `"host_command": "<id>"` in the manifest | When the Menu Action runs, with the Action's configured input; no helper starts |
| Page action | `{"perform": "<id>", "input": …}` in a page's `actions`, or an item action's `perform` ([pages](pages.md)) | On the user's click or key, without a View Event |
| Request | `{"operation": {"perform": "<id>", "input": …}}` in the answer to a gesture ([Requested Host Operations](host-operations.md)) | After the answer commits; `operation_finished` reports the outcome when asked |
| Answer | The answer's `toast` and `close` members | When the answer commits |
| Source | A Host-Fetched Section's `fetch.request` | While the view shows the section |

An operation that returns data is offered as a call only. An effect with no
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
the user configured, so where Plugin API Level 1 lets a Command open a link,
a path or an application, press a shortcut, cut, paste, or run a Shortcut or
a Service without a Capability, so does Level 2, and a configured
link may have any scheme. When the Plugin chooses the input, in a call, a
page action or a request, the operation's Capability always applies, and a
link must be http or https with a host.

An operation fails with the same category wherever it is named: Level 1's
Host Service categories and `insertion_target_changed`
([Requested Host Operations](host-operations.md#failure-category)).
A call ends the invocation with it, a Command ends its Action with it, a page
action shows it with the way to repair it, and a request reports it as its
outcome's reason. An unavailable application, file, folder, Shortcut or
Service is `host_service_failed` with its reason; `command_unavailable` means
only that the Plugin or Command is missing, disabled or changed.

## The SDK

The `spinnet` object a Level 2 script runs with is laid out by namespace,
in place of Level 1's. An operation offered as a call is a function at
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
operations a script can reach, `keyboard` and `system`, is absent, and so are
Level 1's wrappers, such as `spinnet.clipboard.history`. `spinnet.ui` keeps
Plugin API Level 1's builders, since a Level 2 Plugin may still answer with a
Level 1 view whose standard actions keep Level 1's names; `ui.toast` and
`ui.close` build the answer forms of `host.toast` and `host.closeView`;
`ui.request`, `ui.page`, `ui.showPage` and `ui.components` are Level 2's
([Requested Host Operations](host-operations.md#requesting-an-operation),
[pages](pages.md#the-sdk)). `spinnet.environment` is unchanged, and its
`apiLevel` is the highest stable Level the Host supports.
`requestHostService` takes IDs only.

## The helper protocol and the test kit

For a Plugin declaring Level 2 or later, the Host's `invocation` message
also carries the manifest's level, as `"api_level": 2`, which is how the
helper chooses this SDK; a Level 1 Plugin's invocation is unchanged. A
`host_service_request` names the ID in `service`, and the Host refuses a name
the Plugin may not use with `host_service_failed` and the reason.

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

External App integration through Reviewed App Interfaces and Deep Link Templates, and the App in front: identifying it and quitting it ([the App in front](apps.md)).

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `apps.perform` | `{bundle_id, operation, arguments?}` | null | call, Command, page action, request | `control_external_app`, Automation (macOS asks) |
| `apps.openDeepLink` | `{template, parameters?}` | null | call, Command, page action, request | `control_external_app` |
| `apps.frontmost` | none | `{target, name, bundle_id, exits}` or null | call | `read_frontmost_app` |
| `apps.quit` | `{target?, force?}` or none | null | page action, request | `quit_frontmost_app`, and a Host Confirmation every time |

### `system`

macOS facilities no single App owns; later keep-awake (#84) and basic metrics (#86).

| ID | Input | Result | Offered as | Needs |
| --- | --- | --- | --- | --- |
| `system.runShortcut` | `name`, optionally `{name, input}` | null | Command | nothing |
| `system.runService` | `name`, optionally `{name, input}` | null | Command | nothing |

`selection.cut`, `selection.paste`, `keyboard.press`, `system.runShortcut`
and `system.runService` are offered only as Commands, whose input the user
configures. A script, a page action or a request cannot choose keys, a
Shortcut or a Service at Level 2.

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

## Reserved

These IDs are kept for the tickets that define them. Naming one is refused
until a later Level adds it.

| ID | Owner | For |
| --- | --- | --- |
| `host.confirm` | #68's local dialogs | A Plugin-worded question whose answer is a request's outcome |
| `host.launchCommand` | README, candidates for later levels | Running another Command of the Plugin in the same View Session |
| `selection.readFinderItems` | README, candidates for later levels | The files selected in Finder |
| `open.reveal` | README, candidates for later levels | Showing a file in Finder instead of opening it |
| `system.keepAwake` | #84 | A Host-owned keep-awake effect |
| `system.metrics` | #86 | Basic metrics while the view is visible |
| `activities.list`, `activities.stop` | #84, #88 | The Plugin's running effects and tasks |
| `tools.read`, `tools.startTask` | #87, #88 | Reviewed tool profiles such as Homebrew |

# Design: the Plugin API namespace boundary

Issue #99, part of #47, governed by spec #68. Proposal only; see the
[README](README.md) for status. Host baseline inspected: `c10d8fe`.

Each acceptance criterion of #99 is answered here:

| Criterion | Where |
| --- | --- |
| A catalogue covering every Level 1 Host Command, Host Service, standard action, Plugin Settings, Storage and environment access and view builder, with each operation's ID, input, output, Capability, System Permission, failure categories, entry points and the Level 1 name it replaces | [`catalogue.json`](catalogue.json), sections 3 to 6 and 8, [`level1-mapping.md`](level1-mapping.md) |
| Candidates already designed fit: collections (#74), host operations (#70), current App (#83) and the other #68 probes; Raycast-style areas not offered stay listed with reasons | Sections 9 and 10 |
| Level 1 unchanged; the unified names enter as a Candidate Contract in #75's format, grouped with `collections` and `host_operations` | Section 7, [`candidate.json`](candidate.json) |
| Draft schema, `.d.ts`, SDK namespace layout, reference and fixtures; the #70 and #74 proposals updated; CONTEXT.md updated | Section 5, [`namespaces.schema.json`](namespaces.schema.json), [`namespaces.d.ts`](namespaces.d.ts), [`reference.md`](reference.md), [`fixtures/`](fixtures/), section 9 |
| Product choices, with recommended defaults, decided by the user | Section 13 |

## 1. Problem

Level 1 grew one entry point at a time. The same operation has a different
name at each place a Plugin can reach it, and some places cannot reach it at
all:

| Operation | Script (Host Service) | SDK | Command (Host Command) | View Action (standard action) |
| --- | --- | --- | --- | --- |
| Copy text | `write_clipboard` | `spinnet.clipboard.write` | `clipboard.copy` | `copy_text` |
| Open a link | `open_url` | `spinnet.open.url` | `url.open` | `open_url` |
| Insert text | `insert_text` | `spinnet.selection.replace` | none | `insert_text` |
| Open a file or folder | `open_local_path` | `spinnet.open.path` | `file.open`, `folder.open` | none |
| Open an application | none | none | `application.open` | none |
| Paste | none | none | `clipboard.paste` | none |
| Open the Plugin's settings | none | none | none | `open_plugin_settings` |
| Show a message | the answer's `toast` | `spinnet.ui.toast` | `feedback.present` | none |
| Capture the screen | `capture_screen` | `spinnet.screen.capture` | `screen.capture_area`, `_full_screen`, `_window` | none |

An author learns up to four names for one operation, and the Host dispatches
the same effect from a separate table per entry point. A refusal or a
consent sheet cannot name the operation the same way twice. Whether an operation is offered at an entry point depends on
which ticket added it, not on any rule.

The user wants Plugins and the Host maintained separately (#66) behind one
explicit boundary that every Plugin calls the same way, organised by
namespaces, and adopted in the first new UI contract (2026-10-04). The user
accepted this design's direction the same day and asked that its
categories and names follow Spinnet's own domain and style rather than
mirror Raycast's API, which served as a comparison (section 10).

## 2. Principles

1. **One ID per operation.** Every Host Service has exactly one ID,
   `namespace.verb`. The SDK path (`spinnet.clipboard.write`), a manifest
   Command (`"host_command": "clipboard.write"`), a page action and a
   Requested Host Operation (`"perform": "clipboard.write"`),
   `operation_finished`, the helper's `host_service_request`, refusal
   messages, Capability disclosure and the test kit all use the same string.
2. **A namespace is one area of Spinnet's domain**, ideally one Capability
   boundary the user grants as a group. `clipboardHistory` is the Clipboard
   History Store behind `read_clipboard_history`, and `window` the focused
   window behind `position_focused_window`. The namespace then says which
   target and authority apply. Everything in `selection` acts on the
   focused App's selection and, in a view, follows `host_operations`' target
   rules (ADR 0018). Nothing in `clipboard` targets an App. `open` hands
   something to another App. `host` asks Spinnet to act on its own UI and
   flow.
3. **IDs are exactly two levels, in Level 1's SDK style.** Every ID is
   `namespace.verb`; no namespace has a sub-area. Verbs keep Level 1's SDK
   style (camelCase; `read` and `write` for Host data, `get` and `set` for
   Plugin Storage), so moving a Plugin to the catalogue renames as little
   as possible (section 4).
4. **The catalogue is the boundary.** [`catalogue.json`](catalogue.json)
   lists every operation with its input and result, authority, failures,
   entry points and Level 1 names. The Host's registry, the SDK, the schemas,
   the reference and the test kit are each checked against it, and nothing
   reaches the Host outside it.
5. **Level 1 is unchanged, for Level 1 Plugins, for good.** The catalogue
   maps every Level 1 name and renames nothing at Level 1.
6. **Coverage follows rules, not history** (section 3.3), and every gap is
   stated with its reason.

## 3. Entry points

### 3.1 The six entry points

| Entry point | Wire form | Input from | Performed | Result to the script | Catalogue-ID form provided by |
| --- | --- | --- | --- | --- | --- |
| `call` | `spinnet.<id>(input)`, `requestHostService("<id>", input)` | The script | Now, inside the four-second invocation | The operation's result | `namespaces` |
| `command` | `{"execution": "host", "host_command": "<id>"}` | The Action's configuration and the Command's fixed `input` | When the Menu Action runs; no helper starts | None | `namespaces` |
| `view_action` | `{"perform": "<id>", "input": …}` in a page's `actions` or as an item action | The page description, or the item's text | On the user's click or key, without a View Event | None | `collections` |
| `request` | `{"operation": {"perform": "<id>", "input": …}}` in the answer to a gesture | The script's answer | After the answer commits (ADR 0018) | `operation_finished`, when asked | `host_operations` |
| `answer` | The answer's own `toast` and `close` | The script's answer | When the answer commits | None | `namespaces` |
| `source` | A Host-Fetched Section's `fetch.request`; later a Host-run source | The view description | While the view shows it | Shown, or delivered as an event | `namespaces` (#71, #82 generalise it) |

`perform` with `input` is the one declarative shape that names an operation:
page actions, item actions, Requested Host Operations and
`operation_finished` all use it. A manifest Command keeps Level 1's member
name, `host_command`, since the glossary's Host Command is exactly a Command
that runs one Host Service directly.

### 3.2 Examples

```js
// call: now, inside the invocation
const text = spinnet.selection.readText({ best_effort: true });
spinnet.clipboard.write(text.toUpperCase());

// view_action: a page button the Host performs on click, no View Event
c.actions({ id: "buttons", actions: [spinnet.clipboard.write.action("😀", { title: "Copy" })] });

// request: performed after the answer to a gesture commits
ui.showPage(page, { state, operation: spinnet.selection.replace.operation({ text: "😀" }, { closesView: true }) });
```

```json
{"id": "builtin.capture_area", "title": "Capture Area", "execution": "host",
 "is_configurable": false, "host_command": "screen.capture", "input": {"source": "area"}}
```

### 3.3 Which entry points an operation is offered at, and why

| Rule | Operations | Entry points |
| --- | --- | --- |
| R1. An operation that returns data is called: only a script can use a result | `selection.readText`, `clipboard.read`, `clipboardHistory.read`, `clipboardHistory.readContent`, `window.read`, `http.request`, `text.detectLanguage`, `storage.get`, `storage.keys` | `call` (and `source` for `http.request`) |
| R2. Plugin Storage is the Plugin's own data, which its script manages | `storage.*` | `call` |
| R3. An effect with no result is offered at every perform entry point with the same input: anything a button can do, an answer can request, and a Command can do with configured input | `clipboard.write`, `open.*`, `apps.perform`, `apps.openDeepLink`, `host.showPluginSettings`, `clipboardHistory.show` | `command`, `view_action`, `request` |
| R4. An effect is also called only when it completes inside the invocation, needs no Host Confirmation and acts on no Host-shown target | Level 1's call effects, and `open.application` | `call` |
| R5. Keystrokes sent to the focused App are never sent from inside an invocation, which has no target the Host showed; in a view they would follow `host_operations`' target rules | `selection.cut`, `selection.paste`, `keyboard.press` | not `call` |
| R6. An operation that needs a Host Confirmation runs after the answer commits (ADR 0018) | `apps.quit` (force), `tools.startTask` | not `call` |
| R7. A toast and closing are members of the answer: a toast shown during the invocation would appear before its answer is accepted, and requesting one would spend the answer's one operation | `host.toast`, `host.closeView` | `answer` (and `command` for `host.toast`) |
| R8. No entry point that would let a Plugin choose what Level 1 lets only the user configure is offered until a decision gives it a Capability; it is reserved with the decision or question that keeps it closed | Keystrokes, paste, cut, Shortcuts and Services chosen by a Plugin (decision N8: not in r1); insertion from a Command (#70's P2) | reserved |
| R9. Nothing Level 1 offers is withdrawn | `clipboardHistory.show` stays callable | as at Level 1 |
| R10. An effect whose target or presentation in a view has no design yet, and no workload asking for one, is reserved there for a later revision | `window.toggleFullScreen`, `window.restore` (the focused window behind a panel), `screen.capture` (the panel on screen), `selection.copy` (a read of the shown target) | `view_action`, `request` reserved |

R3 and R4 fill the gaps that need no new authority: `open.application`
becomes callable under `open_local_path` (section 6.3), and Commands can run
`apps.perform`, `clipboardHistory.show`, `host.showPluginSettings`,
`window.toggleFullScreen` and `window.restore` without a script. R8 keeps
the gaps that do need new authority visible instead of closing them quietly,
and R10 those that need a design first.

Every operation in the catalogue states all four main entry points as
offered, reserved (with the ticket or decision that owns it and the reason)
or not offered (with the reason), and `check.py` refuses a gap. The result,
for the operations offered in r1 (L1: Level 1 offers it under a Level 1
name; new: added by a draft candidate; res: reserved; –: not offered):

| ID | call | command | view_action | request | Capability | System Permission |
| --- | --- | --- | --- | --- | --- | --- |
| `host.toast` (answer: L1) | – | L1 | – | – | none | none |
| `host.closeView` (answer: L1) | – | – | – | – | none | none |
| `host.showPluginSettings` | – | new | L1 | new | none | none |
| `selection.readText` | L1 | – | – | – | `read_selected_text` | Accessibility |
| `selection.replace` | L1 | res | L1 | new | `insert_into_focused_app` | Accessibility |
| `selection.copy` | – | L1 | res | res | `read_selected_text`, `write_clipboard` | Accessibility |
| `selection.cut` | – | L1 | res | res | none | Accessibility |
| `selection.paste` | – | L1 | res | res | none | Accessibility |
| `keyboard.press` | – | L1 | res | res | none | Accessibility |
| `clipboard.read` | L1 | – | – | – | `read_current_clipboard` | none |
| `clipboard.write` | L1 | L1 | L1 | new | `write_clipboard` | none |
| `clipboardHistory.read` | L1 | – | – | – | `read_clipboard_history` | none |
| `clipboardHistory.readContent` | L1 | – | – | – | `read_clipboard_history` | none |
| `clipboardHistory.show` | L1 | new | new | new | `read_clipboard_history` | none |
| `open.url` | L1 | L1 | L1 | new | `open_url` (none as a Command) | none |
| `open.path` | L1 | L1 | new | new | `open_local_path` (none as a Command) | none |
| `open.application` | new | L1 | new | new | `open_local_path` (none as a Command) | none |
| `apps.perform` | L1 | new | new | new | `control_external_app` | Automation |
| `apps.openDeepLink` | L1 | L1 | new | new | `control_external_app` | none |
| `system.runShortcut` | res | L1 | res | res | none | none |
| `system.runService` | res | L1 | res | res | none | none |
| `window.read` | L1 | – | – | – | `position_focused_window` | Accessibility |
| `window.setFrame` | L1 | – | – | – | `position_focused_window` | Accessibility |
| `window.toggleFullScreen` | L1 | new | res | res | `position_focused_window` | Accessibility |
| `window.restore` | L1 | new | res | res | `position_focused_window` | Accessibility |
| `screen.capture` | L1 | L1 | res | res | `capture_screen` | Screen Recording |
| `http.request` (source: L1) | L1 | – | – | – | `contact_https` | none |
| `text.detectLanguage` | L1 | – | – | – | none | none |
| `storage.get`, `.set`, `.remove`, `.keys`, `.clear` | L1 | – | – | – | none | none |

`view_action` L1 means Level 1 offers the operation as a standard action in a
Level 1 view; its catalogue-ID form is a page action (`collections`).

## 4. Naming rules

1. **Form.** An ID is exactly `namespace.verb`: two lowerCamelCase segments,
   each starting with a lowercase letter. A namespace holds no sub-area; an
   area that needs one is a namespace of its own. Clipboard History, which
   Level 1 reaches as `spinnet.clipboard.history`, is `clipboardHistory`,
   because it is its own store, Capability and Sensitive Data Collection.
2. **One spelling everywhere.** The ID is the SDK path after `spinnet.`, and
   JSON carries the same string: `"perform": "selection.readText"`, never a
   snake_case variant to convert (decision N6). Member names keep their
   conventions: snake_case on the wire (`closes_view`, `best_effort`),
   camelCase in SDK options (`closesView`), as at Level 1. IDs are values,
   not members.
3. **Verbs, in Level 1's SDK style.** `read` returns Host data
   (`selection.readText`, `clipboardHistory.readContent`); `write` and
   `replace` change it. Plugin Storage keeps Level 1's `get`, `set`,
   `remove`, `keys` and `clear`, because it is the Plugin's own data rather
   than the Host's. `show` presents a Host window or Host Surface
   (`clipboardHistory.show`); in `host`, which presents more than one, the
   verb names what it shows (`host.showPluginSettings`). `open` hands
   something to another App (`open.url`, `apps.openDeepLink`). `run`
   starts something macOS executes (`system.runShortcut`). `press` sends
   keys (`keyboard.press`). `perform` runs an operation of a reviewed
   interface. Others say what they do (`toast`, `closeView`, `capture`,
   `request`, `detectLanguage`).
4. **Level 1's SDK paths are kept where they fit.** Twenty of Level 1's 23
   wrapper paths become IDs unchanged (`spinnet.selection.readText` is
   `selection.readText`). Only Clipboard History's three move, into their
   own namespace: `spinnet.clipboard.history`, `historyContent` and
   `showHistory` become `clipboardHistory.read`, `clipboardHistory.readContent`
   and `clipboardHistory.show`. Level 1's Host Command names, which follow
   no SDK path, take the same style (`keyboard_shortcut.invoke` is
   `keyboard.press`).
5. **No ID equals a Level 1 name.** No catalogue ID is spelled like a Level 1
   Host Command, Host Service or standard action, so the Host and the test
   kit can always tell a Level 1 name from an ID and name the replacement in
   a refusal. This is one reason Level 1's `clipboard.copy`, `.paste` and
   `.cut` are not reused (decision N3).
6. **Inputs are objects.** An operation's input is a JSON object, or null
   when it takes none. When the object has one required string member, its
   *primary member*, a bare string stands for it at every entry point:
   `spinnet.open.url("https://…")`, `{"perform": "clipboard.write", "input":
   "😀"}`, and a Command's single `configuration_field`. Level 1's alias
   spellings (`bundle_id` and `bundleIdentifier` for an application,
   `service`, `character`, `modifier_flags`, `message`) stay Level 1's.
7. **Results are Level 1's**, unchanged.

## 5. The namespaces and the SDK

### 5.1 Namespaces

| Namespace | Area of Spinnet's domain | Operations (r1) | Reserved | Capabilities |
| --- | --- | --- | --- | --- |
| `host` | Spinnet's own UI and flow, which the Plugin asks the Host to act on | `toast`, `closeView`, `showPluginSettings` | `confirm`, `launchCommand` | none |
| `selection` | The focused App's selection | `readText`, `replace`, `copy`, `cut`, `paste` | `readFinderItems` | `read_selected_text`, `insert_into_focused_app`, `write_clipboard` |
| `keyboard` | Keys pressed in the focused App | `press` | | none (Accessibility) |
| `clipboard` | The current clipboard's content | `read`, `write` | | `read_current_clipboard`, `write_clipboard` |
| `clipboardHistory` | The Clipboard History Store | `read`, `readContent`, `show` | | `read_clipboard_history` |
| `open` | Handing a link, path or application to the App that opens it | `url`, `path`, `application` | `reveal` | `open_url`, `open_local_path` |
| `apps` | External App integration, and the App in front | `perform`, `openDeepLink` | `frontmost`, `quit` (#83) | `control_external_app` |
| `system` | macOS facilities no single App owns | `runShortcut`, `runService` | `keepAwake` (#84), `metrics` (#86) | none in r1; #84 and #86 add theirs |
| `window` | The focused window | `read`, `setFrame`, `toggleFullScreen`, `restore` | | `position_focused_window` |
| `screen` | Screen captures the Plugin never receives | `capture` | | `capture_screen` |
| `http` | HTTPS requests with Credential Uses | `request` | | `contact_https` |
| `text` | Text processing on this Mac | `detectLanguage` | | none |
| `storage` | Plugin Storage | `get`, `set`, `remove`, `keys`, `clear` | | none |
| `ui` | Builders for views, pages, components and answers; requests nothing | Level 1's view builders, `collections`' page builders | `components.image`, `.icon`, `.progress` (#81) | none |
| `environment` | The Host and the invocation | Level 1's seven values | | none |
| `activities`, `tools` | Reserved for #84 and #88, #87 and #88 | | `activities.list`, `activities.stop`, `tools.read`, `tools.startTask` | defined by those tickets |

`host` is where a Plugin asks Spinnet to act on Spinnet's own UI and flow:
a toast (with `close`, the HUD; decision N2), closing the Plugin View,
opening the Plugin's settings (decision N10), and later a Plugin-worded
question and launching another Command. None of it needs a Capability, so
one namespace holds what Level 1 spread over an answer member, a feedback
Host Command and a standard action. `clipboardHistory` is apart from
`clipboard` because the Clipboard History Store is its own store, Capability
and Sensitive Data Collection setting: granting `write_clipboard` grants
nothing in it. `system` holds what macOS offers beyond any one App
(Shortcuts and Services, later keep-awake and metrics), while `apps` keeps
External App integration through Reviewed App Interfaces and Deep Link
Templates and, with #83, the App in front. `selection.copy`, `.cut` and
`.paste` sit in `selection` because they act on the focused App's
selection, with that namespace's target rules (decision N3).

### 5.2 The SDK layout

Under the candidate the helper injects a `spinnet` object laid out by
namespace ([`namespaces.d.ts`](namespaces.d.ts)); #75 keeps a candidate's SDK
with its revision, so Level 1's `spinnet.js` is untouched. Every operation a
script can reach is at `spinnet.<id>`:

- an operation offered at `call` is a function: `spinnet.clipboard.write("😀")`;
- one offered at `view_action` has `.action(input, options)`, which builds a
  page action: `spinnet.open.url.action(url, { title: "Homepage" })`;
- one offered at `request` has `.operation(input, options)`, which builds a
  Requested Host Operation: `spinnet.selection.replace.operation({ text })`.

An operation offered only as a Command or only in the answer has no SDK
member: `keyboard` and `system` are absent from the r1 object, `host` holds
only `showPluginSettings`, and `ui.toast` and `ui.close` build the answer
forms of `host.toast` and `host.closeView`. `spinnet.ui` keeps Level 1's builders for Level 1 views,
including `copyText`, `openURL`, `insertText` and `openPluginSettings`, which
build Level 1's standard actions and only fit a Level 1 view; `collections`
adds `ui.page`, `ui.showPage` and `ui.components`, and `host_operations`
adds `operation` to `ui.show` and `ui.request` (decision N4).
`requestHostService(id, input)` takes catalogue IDs only, and
`spinnet.environment` is unchanged.

## 6. Authority

### 6.1 Capabilities stay per category

The twelve Level 1 Capabilities are unchanged. Each operation names the
Capabilities it needs, usually one; `selection.copy` reads the selection and
writes the clipboard, so it needs `read_selected_text` and
`write_clipboard`, as Level 1's `clipboard.copy` with a null input did. The
catalogue's capability table, derived from the operations and checked
against them, says which operations each Capability covers. Disclosure and
refusals read it: the install sheet keeps its groups (Reads, Monitors,
Contacts, Controls, Changes, System Access) and can list the operations a
grant covers, and a refusal names the operation and the Capability
("`clipboard.write` needs `write_clipboard`"). `monitor_clipboard` covers no
operation, as at Level 1. New Capabilities arrive only with the tickets that
need them: #83's identity read and exit, #86's metrics, #84's effects, #87's
profiles, and, in a later revision, the keystrokes, Shortcuts and Services
decision N8 keeps out of r1.

### 6.2 Configured input at the command entry point

At `command` the input is the user's configuration, which the Configuration
Sheet shows and the user can change, so Level 1's rule stays (decision N7):
`open.url`, `open.path`, `open.application`, `keyboard.press`,
`selection.cut`, `selection.paste`, `system.runShortcut` and `system.runService`
need no Capability as Commands, and a Command's configured link may have any
scheme, as `url.open` allows. Where Level 1's Host Command needed a
Capability (`clipboard.write`, `selection.copy`, `screen.capture`,
`apps.openDeepLink`), the Command still does, and the new Commands
(`apps.perform`, `clipboardHistory.show`, `window.toggleFullScreen`,
`window.restore`) need the operation's Capability. When the Plugin chooses
the input, at `call`, `view_action` and `request`, the operation's Capability
always applies and its input rules hold (an http or https link, for
instance). The catalogue records the exception per operation in the
`command` entry's `capabilities`.

### 6.3 Coverage without new authority

`open.application` at `call`, `view_action` and `request` needs
`open_local_path`. That Capability already lets a script launch any
application by its path (`open_local_path` opens an application the path
names), so opening one by bundle identifier grants nothing new. The new
Commands of section 3.3 run under the Capability their script form already
needs.

### 6.4 System Permissions

A System Permission belongs to the operation and is the same at every entry
point: Accessibility for `selection.*`, `keyboard.*` and `window.*`, Screen
Recording for `screen.capture`, and the Automation consent macOS asks for
`apps.perform`.

### 6.5 One failure vocabulary

An operation fails with the same category at every entry point: Level 1's
Host Service categories (`capability_denied`, `system_permission_denied`,
`automation_permission_denied`, `external_app_missing`,
`external_app_operation_unsupported`, `host_service_failed`,
`storage_limit_exceeded`) and `host_operations`' `insertion_target_changed`.
A call ends the invocation with it, as at Level 1. A Command ends its Action
with it. Level 1 reports a Host Command's own failures as
`host_command_failed` and an unavailable application, file or Shortcut as
`command_unavailable`; under the candidate an unavailable target is
`host_service_failed` with its reason, and `command_unavailable` keeps only
its meaning of a missing, disabled or changed Command. A page action shows
the category inline with its repair route, and a request reports it as its
outcome's reason.

## 7. Declaring the candidate

### 7.1 The declaration

A Plugin written against the catalogue declares the draft Candidate Contract
`namespaces` at revision 1, beside its stable Level:

```json
{
  "api_level": 1,
  "candidate_contracts": [{"name": "namespaces", "revision": 1}]
}
```

A Plugin that also requests operations or answers pages declares
`host_operations` r1 and `collections` r1 as well.

### 7.2 Grouping and dependency direction

| Candidate | Requires | Adds |
| --- | --- | --- |
| `namespaces` r1 | nothing | The catalogue IDs at `call`, `command` and `answer`; the namespaced SDK; the rules of sections 4 and 6 |
| `host_operations` r1 (#70) | `namespaces` r1 | The `request` entry point and `operation_finished`, by catalogue ID; insertion targeting |
| `collections` r1 (#74) | `host_operations` r1, `namespaces` r1 | Pages, page actions and item actions that perform catalogue IDs |

The names sit at the base because the other two name operations with them.
A Plugin can use the names alone, as a scriptless Bob or Open URL would, but
it cannot request an operation or answer a page without them, so no Plugin
mixes Level 1 names and IDs inside a request or a page. The three are proved
together on #79's Host and promoted together to the next stable Level; none
is promoted alone.

### 7.3 What declaring it changes

1. **Catalogue IDs only.** A Plugin declaring `namespaces` names operations
   by catalogue ID. A Level 1 name is refused with a message naming the
   replacement: at installation review for a manifest Command, as
   `host_service_failed` for a call, and as a protocol violation in a page or
   a request. The exception is a Level 1 `view` answer, which `collections`
   keeps as Level 1 vocabulary, whole (its decision C9): its four standard
   actions keep Level 1's names (decision N5).
2. **The namespaced SDK** of section 5.2 replaces Level 1's `spinnet`
   object.
3. **Command input.** A Command may fix members of its operation's input in
   `input` (`screen.capture`'s `source`, `apps.perform`'s `bundle_id` and
   `operation`); its configuration supplies the rest, and a member is never
   supplied twice. `apps.perform` and `apps.openDeepLink` fill `arguments`
   and `parameters` from configuration fields keyed by the parameter names,
   as Level 1's `deep_link.open` does.
4. **Failures** follow section 6.5.
5. **Screen capture preferences.** `screen.capture` with only a source copies
   or saves as the user's screenshot preferences say, at every entry point
   (decision N9). Level 1's three screen Host Commands always did; Level 1's
   `capture_screen` call never does.

### 7.4 #75's member kinds

#75's metadata knows `host_service`, `view_component`, `standard_action`,
`view_event` and `behaviour` members, but no Command or request member. The
drafts record Commands as `host_command:<id>` behaviours (`namespaces`),
requests as `request:<id>` behaviours (`host_operations`) and page actions as
`standard_action` members (`collections`), and `check.py` holds them equal to
the catalogue. The implementing ticket should add `host_command` and
`request` member kinds to `candidate-metadata.schema.json` and to the Host's
`PluginInterfaceMember`. That is candidate machinery, not Level 1.

### 7.5 Level 1 stays

Level 1's schemas refuse every catalogue ID, and a Level 1 Plugin keeps every
Level 1 name on a Host that provides the candidates
([scenario 02](fixtures/scenarios/02-level1-plugin-unchanged.json)). A Level 1
Plugin that calls a catalogue ID fails as #75 requires for any member outside
its declarations. Inside the Host, each operation has one implementation;
Level 1's names are a table at the edge that maps onto it.

## 8. Level 1 mapping

[`level1-mapping.md`](level1-mapping.md), generated from the catalogue and
checked against Level 1's own files, lists every Level 1 name: the 15 Host
Commands, 23 Host Services, 4 standard actions, 23 SDK wrappers, 18 view
builders, 7 `spinnet.environment` members, 4 answer members, 6 View Events,
10 script globals and 12 Capabilities. In short:

- 15 Host Commands become 13 IDs: the three screen captures are
  `screen.capture` with a fixed source, `file.open` and `folder.open` are
  `open.path`, and `clipboard.copy` divides by its input into
  `clipboard.write` (text) and `selection.copy` (null).
- 23 Host Services become 23 IDs, 20 of them spelled as Level 1's SDK path.
- 4 standard actions become `clipboard.write`, `open.url`,
  `selection.replace` and `host.showPluginSettings`.
- Builders, `spinnet.environment`, globals and View Events are unchanged;
  `toast` and `close` are the answer forms of `host.toast` and
  `host.closeView`; `requestHostService` takes IDs.

What an author moving a Plugin to the candidate meets besides new names:

| Level 1 behaviour | Under the candidate |
| --- | --- |
| `feedback.present` draws the Host feedback panel | `host.toast` as a Command shows the toast near the pointer, as an answer's toast does without a view (decision N2) |
| `file.open` refuses a folder and `folder.open` a file | `open.path` opens whichever exists; the configuration field's kind decides what the user can pick |
| `clipboard.copy` takes text or null | `clipboard.write` takes text; `selection.copy` copies the selection |
| `screen.capture_*` follow the screenshot preferences; `capture_screen` needs its own options | `screen.capture` follows the preferences whenever copy and save are left out (decision N9) |
| A Host Command's own failure is `host_command_failed` | The operation's category (section 6.5) |
| Alias input spellings | One canonical member per input (section 4.6) |

## 9. How the candidates and probes fit

| Work | In the catalogue |
| --- | --- |
| #70 `host_operations` | An operation is `{perform, input, id?, closes_view?, notify?}`; insertion is `selection.replace`; the nine perform-able operations are requestable; `operation_finished` names `perform`; the illustrative kinds are `apps.quit` and `tools.startTask` |
| #74 `collections` | Page actions perform `view_action` IDs with `input`; item actions perform `clipboard.write` or `selection.replace` on the item's text; the target line appears for a `selection.replace` item action |
| #78 repeated calls | Unaffected: `called` is an event, not an operation |
| #83 Current App | `apps.frontmost` (a call under an identity-read Capability, returning an opaque target) and `apps.quit` (Command, page action and request; force needs a Host Confirmation) |
| #84 Coffee | `system.keepAwake` (Command, page action, request) and `activities.stop` |
| #85 Spotify | No new ID: Spotify's Reviewed App Interface is reached through `apps.perform`, its reads return bounded values, and its playback state is a `source` (#82) |
| #86 System Monitor | `system.metrics`, a `source` while the view is visible, and a call |
| #87, #88 Homebrew | `tools.read` (a call to a reviewed profile), `tools.startTask` (a request with a Host Confirmation), `activities.list` and `activities.stop` |
| #71, #82 sources | The `source` entry point generalises Host-Fetched Sections; a data operation becomes a source when #71 defines how |
| #81 styles, images, Progress | `ui.components.image`, `.icon` and `.progress` builders; loading a granted HTTPS image stays a component member under `contact_https` |
| README's Candidates | List: `collections`. Progress, Icons, Images: #81. Selected Finder items: `selection.readFinderItems`. The frontmost application: `apps.frontmost`. Revealing a file in Finder: `open.reveal`. Confirmation: `host.confirm`. Launching another Command: `host.launchCommand` |

`host.confirm` fits `host_operations` without new machinery: a request
whose `operation_finished` outcome is the user's answer, worded by the
Plugin and authorizing nothing. A Host Confirmation, by contrast, is part of
an operation's own policy (ADR 0018) and is not an operation.

## 10. Comparison with Raycast

Raycast's API served as a checklist of what a launcher's Plugins ask for,
not as a template: the namespaces follow Spinnet's domain and Capabilities
(section 2). Raycast's API is asynchronous JavaScript in a resident Node
process. Spinnet has a bounded synchronous invocation, declarative forms the
Host performs after a gesture, and Commands that run no script. One Raycast
function can therefore correspond to two Spinnet forms, a call and a
perform, under one ID.

Where the grouping differs, Spinnet's domain decides. Raycast's top-level
`showToast`, `showHUD`, `closeMainWindow`, `launchCommand` and
`openExtensionPreferences` are one `host` namespace, because each asks
Spinnet to act on its own UI and flow and none needs a Capability.
Raycast's `Clipboard` reads older entries by offset; Spinnet keeps Clipboard
History in `clipboardHistory`, behind its own Capability and Sensitive Data
Collection setting. Shortcuts and Services, which Raycast's API does not
wrap, are `system`, beside keep-awake and metrics; `keyboard.press` and
`apps.perform` have no Raycast counterpart either.

| Raycast | Spinnet |
| --- | --- |
| UI: List, Grid | `collections`: a page with a `list` or `grid` |
| UI: Detail, Form | A Level 1 view; `collections`' `text`, `text_field` and `choice_field` |
| UI: ActionPanel, Action | Level 1 view actions; page and item actions that perform catalogue IDs |
| UI: navigation | Page IDs and page memory; no stack |
| UI: Icon, Image, Color | #81 |
| `showToast` | `host.toast` |
| `showHUD` | `host.toast` with `close` (merged, decision N2) |
| `confirmAlert` | `host.confirm` (reserved); a Host Confirmation is part of an operation |
| `closeMainWindow` | `host.closeView` |
| `launchCommand` | `host.launchCommand` (reserved) |
| `Clipboard.copy`, `.paste`, `.read` | `clipboard.write`, `selection.paste`, `clipboard.read` |
| `Clipboard.read` with an `offset` | `clipboardHistory.read`, `clipboardHistory.readContent` |
| `getSelectedText` | `selection.readText` |
| `getSelectedFinderItems` | `selection.readFinderItems` (reserved) |
| `getFrontmostApplication` | `apps.frontmost` (reserved, #83) |
| `open` | `open.url`, `open.path`, `open.application` |
| `showInFinder` | `open.reveal` (reserved) |
| `WindowManagement` | `window`, the focused window only |
| `LocalStorage` | `storage` |
| `getPreferenceValues` | `input`, which carries the Plugin Settings |
| `openExtensionPreferences` | `host.showPluginSettings` |
| `environment` | `environment` |

Not offered, deliberately:

| Area | Raycast | Why |
| --- | --- | --- |
| Menu bar extras | `MenuBarExtra` | A Plugin's item in the menu bar needs a script kept alive; Spinnet keeps no resident runtime (ADR 0004) and a helper lives only for a bounded invocation (ADR 0007). The Host Status Item lists Host-generated activities instead (ADR 0017) |
| Live Command metadata | `updateCommandMetadata` | It needs a script running while the Menu is idle |
| Background schedules | Command `interval` | A script on a timer runs when the user asked for nothing |
| AI and AI tools | `AI.ask`, Tools | A model, not the user, would decide what runs and with what data, which consent to a Capability cannot cover |
| Browser extension access | `BrowserExtension` | It reaches pages, tabs and history in another App, which no Capability can disclose precisely enough |
| Arbitrary file operations, including the Trash | `trash`, Node `fs` | Reading, writing or deleting any path reaches beyond what one Capability can disclose |
| AppleScript and arbitrary Apple Events | `runAppleScript` | Apple Events go only through Reviewed App Interfaces (ADR 0012) |
| OAuth sign-in | `OAuth.PKCEClient` | Credential Uses place or sign with stored keys the Plugin never sees (ADR 0011); no probe needs OAuth (#68 leaves Spotify OAuth out) |
| A page stack with push, pop and pop-to-root | `useNavigation`, `popToRoot` | Page memory instead; page stacks and dialogs are a #68 future direction without a workload |
| Plugin-bound shortcuts on page actions | `Action` `shortcut` | The user decided pages bind none (collections C5, C6); Level 1 views keep theirs |
| Per-Command preferences opened by the Plugin | `openCommandPreferences` | A Menu Item's configuration is the user's, in its Configuration Sheet |
| A separate cache | `Cache` | Plugin Storage holds Cache's default 10 MiB; a Host-Fetched Section caches its own answer |
| Listing installed applications | `getApplications` | No workload; it would be an identity read no Capability covers |
| Windows other than the focused one, and desktops | `WindowManagement` | No probe needs a window list |

The same list, with the Raycast names, is in `catalogue.json` under
`not_offered` and `raycast`.

## 11. Separate maintenance (#66)

- **A Plugin repository depends on the published interface only**, at a
  tag: the schemas, `catalogue.json`, the SDK's types and source, the
  reference, and the pinned test kit (`PluginTestHelper`). The catalogue is
  the machine-readable index of that dependency, and all of it is MIT
  (ADR 0013).
- **The Host is held to the catalogue.** A Host test should assert that its
  registry of operations equals the catalogue: IDs, Capabilities, System
  Permissions, failure categories and entry points, as
  `PluginAPICatalogueTests` holds Level 1's README to the Host today. Level 1
  names stay a table that maps onto the same implementations.
- **A Plugin is held to the catalogue.** The first-party repository's CI
  checks manifests and fixtures against the schemas and runs scripts in the
  pinned test kit, which refuses a Level 1 name or an ID outside the
  declared candidates as the Host does. One string per operation means one
  search finds every use.
- **Changes have one shape.** Adding an operation is one catalogue entry,
  its schema definitions, its Host implementation and a test-kit fixture, in
  one candidate revision. A promoted ID never changes, and a Host refactor
  behind an ID never reaches a Plugin.

## 12. Verification

[`check.py`](check.py) checks the catalogue against its schema; every Level 1
name, read from Level 1's own files, against the catalogue and
`level1-mapping.md`; each operation's consistency (namespace, entry points,
Level 1 names, Capabilities, failures, schema definitions, primary member);
that every ID is exactly `namespace.verb` and that operations are grouped
by namespace in the order the namespaces are listed;
`namespaces.schema.json`'s ID lists, `namespaces.d.ts`'s tags, the
namespaces its `spinnet` object holds, and `candidate.json` against the
catalogue; the fixtures and scenarios; and that
the `host_operations` and `collections` drafts use catalogue IDs and require
this candidate. The draft types were also type-checked against Level 1's
`spinnet.d.ts` with Deno (`deno check --unstable-sloppy-imports`).

What the implementing tickets add: the Host registry test above; test-kit
refusal messages that name the replacement ID; #76 and #77 building on these
names; and, on the actual Host, that the new Commands start no helper, that
configured-input authority holds, and that screen capture follows the
preferences.

## 13. Product choices, decided

The user decided all ten on 2026-10-04. Each takes the recommended default,
with the namespaces adjusted to Spinnet's own needs and style, which moved
N2's toast and N10's settings sheet into `host`. The catalogue, schemas,
types and fixtures follow these decisions.

| # | Question | Decision | Alternatives not taken |
| --- | --- | --- | --- |
| N1 | Is every operation offered at every entry point, or are some script-only or Command-only? | By the rules of section 3.3: data is called; effects with no result at every perform entry point; keystrokes, Shortcuts and Services chosen by a Plugin reserved under N8; every gap stated | Every operation everywhere; or Level 1's coverage only, renamed |
| N2 | Do toast and HUD merge? | Yes: one `host.toast`, inside the view when one is open, near the pointer otherwise; the HUD is `close` with a toast. The `feedback.present` Command shows that toast instead of the feedback panel | A separate HUD operation that closes the view and shows near the pointer |
| N3 | Where do insertion, copy, cut and paste live? | `selection`: `readText`, `replace`, `copy`, `cut`, `paste`, all acting on the focused App's selection with one set of target rules; `clipboard` holds only the current clipboard's content, and Clipboard History is `clipboardHistory` | The draft's `clipboard.paste` and `clipboard.cut`; or an `input` namespace (`input.insertText`, `input.press`, `input.paste`) |
| N4 | How are UI builders named? | `ui` keeps structure and answers; a button or request that performs an operation is built from the operation (`spinnet.clipboard.write.action(…)`, `.operation(…)`); page components stay at `ui.components.*` beside Level 1's view builders; Level 1's `ui.copyText` and the like stay for Level 1 views only | Generic `ui.action({perform, input})`; or per-operation builders in `ui` growing with the catalogue |
| N5 | Are Level 1 names accepted from a Plugin that declares `namespaces`? | No, except inside a Level 1 `view`, which keeps Level 1's vocabulary whole (collections C9) | Refused everywhere, so a Level 1 view's standard actions take IDs too; or accepted everywhere as aliases |
| N6 | Is the wire ID spelled as the SDK path? | Yes, lowerCamelCase everywhere: `"perform": "selection.readText"` | snake_case on the wire (`selection.read_text`) converted to camelCase in the SDK |
| N7 | Does a Command's configured input keep Level 1's no-Capability rule? | Yes, where Level 1's Host Command needed none (open a link, path or application, press keys, cut, paste, run a Shortcut or Service) | Every entry point needs the operation's Capability, so the Open URL Plugin asks for `open_url` |
| N8 | May a Plugin choose keystrokes, paste, cut, Shortcuts or Services, from a call, a page action or a request? | Not in r1. `selection.cut`, `selection.paste`, `keyboard.press`, `system.runShortcut` and `system.runService` stay reserved at `call`, `view_action` and `request`; each needs a new Capability and, for paste, the evidence-based decision #68 requires. The scriptless Commands equivalent to Level 1's remain, with the user's configured input | Add them now, each with a Capability |
| N9 | Does `screen.capture` with only a source follow the user's screenshot preferences, from any entry point? | Yes: the Plugin learns nothing and the user's preference applies | Only Commands, as at Level 1; or never, so every Command states copy and save |
| N10 | Where does opening the Plugin's settings live? | `host.showPluginSettings`: it asks Spinnet to show one of its own sheets, as the rest of `host` does | `settings.show` in a namespace of its own, as Raycast groups `openExtensionPreferences`; or `host.openPluginSettings` |

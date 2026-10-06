# Pages and collections (Plugin API Level 2)

A Level 2 Plugin may describe its Plugin View as **pages**: trees of
identified View Components that the Host draws natively, with a searchable,
selectable List or Grid. The Host keeps what the user is doing in a page
(typed text, caret, input-method composition, focus, selection, scroll)
across the Plugin's answers until the Plugin resets it, and an Explicit Call
of the Plugin runs inside its open View Session. Everything in
[Plugin Views](views.md) still applies unless this page says otherwise.

```json
{
  "protocol_version": "1.0",
  "api_level": 2
}
```

[`pages.schema.json`](../schemas/pages.schema.json) publishes the shapes,
[`fixtures/pages/`](../fixtures/pages/index.json) valid and invalid answers
and events, [`spinnet-level-2.d.ts`](../spinnet-level-2.d.ts) the types, and
[`spinnet-level-2.js`](../spinnet-level-2.js) the SDK. Level 2 was proved as
Candidate Contract `collections` r3, now retired
([history](../candidates/collections/r3/reference.md)); the rationale is
ADR 0019 and the design records in
[`proposals/collections/`](../proposals/collections/design.md).

## Answering with a page

A script answers `{page, state}`, optionally with `toast` and, from a
gesture, `operation` ([Requested Host Operations](host-operations.md)). It may still answer a Level 1
`{view, state}`, which keeps Level 1's view rules, but never both.
`{operation}` or `{toast}` alone, or `null`, leave the page and state as
they are.

```js
const ui = spinnet.ui, c = ui.components;
ui.showPage(ui.page({
  id: "search", title: "Emoji", showsInsertionTarget: true, reset: queryChanged ? ["results"] : undefined,
  content: [
    c.row({ id: "bar", content: [
      c.textField({ id: "query", title: "Search", value: "", collection: "results", status }),
      c.choiceField({ id: "category", title: "Category", choices, choiceTitles, value: "all" })
    ] }),
    c.grid({ id: "results", columns: 8, rows: 6, emptyText: "No emoji match",
      total: found.length, start, items: found.slice(start, start + count).map((e) =>
        c.item({ id: e.hex, title: e.name, symbol: e.emoji, marks: favourite(e) ? ["favourite"] : undefined })),
      actions: [c.itemAction({ id: "insert", title: "Insert", default: true }),
                c.itemAction({ id: "copy", title: "Copy", perform: "clipboard.write", notify: true }),
                c.itemAction({ id: "favourite", title: "Favourite", toggle: "favourite" })] })
  ]
}), { state });
```

## Components

Every component has an `id`, unique in its page, row children included. A
page has at most 40 components and at most one collection.

| `kind` | Members | What the Host draws |
| --- | --- | --- |
| `row` | `content`: up to 4 components | Its components side by side; no rows or collections inside |
| `text_field` | `title`, `placeholder`, `value`, `status`, `accent`, `collection` | A one-line field; `collection` makes it that collection's search field |
| `choice_field` | `title`, `choices`, `choice_titles`, `value` | A pop-up |
| `text` | `title`, `text` | Text in the Markdown subset |
| `actions` | `actions`: up to 8 buttons | Event buttons (`id`, `title`) and page actions |
| `list` | collection members, `rows` (1 to 12, default 8) | Rows: `symbol`, `title`, `subtitle`, `accessory` |
| `grid` | collection members, `columns` (2 to 12 columns, default 8), `rows` (1 to 12, default 6) | Square cells showing `symbol`, else `title` |

The page lays its components out top to bottom. With a collection, the
components before it stay above, those after it stay below, and the
collection takes `rows` rows and scrolls. Without one, the page scrolls when
it is taller than the panel.

A **page action** performs a Host Service by its catalogue ID, `{perform,
input, id?, title?, closes_view?, notify?}`, on the user's click and without a View
Event, under the Capability that operation needs, as Level 1's standard
actions do. It may perform `host.showPluginSettings`, `selection.replace`,
`clipboard.write`, `clipboardHistory.show`, `open.url`, `open.path`,
`open.application`, `apps.perform` or `apps.openDeepLink`, with the input a
request of the same ID takes; its title defaults to the catalogue's. The SDK
builds one from its operation: `spinnet.open.url.action(url, { title:
"Homepage" })`, `spinnet.clipboard.write.action(text)`. An insert button
names the App it inserts into beside its title. A refusal or failure shows in
the view with the way to repair it, and the page action runs in the Plugin's
operation slot after anything it requested before.

No component, button or item action takes a `shortcut`. A page the Host
would not draw ends the View Session as a protocol violation, as in
Level 1: unknown members or kinds, duplicate IDs, two collections, two
default item actions, an item offering an action the collection lacks, a
`collection`, `focus`, `reset` or `selected` naming nothing, or a
description over 256 KiB.

## Identity and immediate state

`page.id` identifies the View Page; within it, a component is identified by
`id` and `kind`.

- **Same page ID**: the Host keeps each component's immediate state, even
  when the component moved within the page or its other members changed. A
  `value`, a collection's `selected` and `page.focus` are initial values,
  applied only to a new or reset component or page. A kept field shows a new
  `status` or `accent` at once.
- **New ID, or the same ID with another kind**: a new component, from its
  description. A component left out of an answer is discarded; one that
  comes back later is new.
- **Another page ID**: the Host remembers the page on screen and shows the
  new one with its remembered state if it is among the last 4 pages shown
  besides the one on screen, or else new. This page memory lasts as long as
  the View Session and is not a stack: there is no Host Back. A Level 1
  `view` answer counts as a page change.
- **`reset`**: `["id", ...]` starts those components again from their
  description; `"page"` starts the whole page and its memory again. A reset
  applies to the answer that carries it only. A reset of a `text_field`
  whose input-method composition is open is dropped for that field.

The Host never replaces a kept field's text, caret or composition, so an
answer to any event (typing, `load_range`, `operation_finished`, `called`)
cannot undo or interrupt typing. Composing text is never sent: `field_changed` follows
committed text, after a 100 ms pause. Answers cannot move focus;
`page.focus`, else the first `text_field`, else the collection, is focused
when a page is new or reset.

## Collections

A `list` or `grid` has `items`, or `sections` of `{id, title?, items}`, up to
2,000 items and 32 sections in all; or, with `total`, a window of them (see
[Windows of items](#windows-of-items)). Each item:

| Member | Bound | Use |
| --- | --- | --- |
| `id` | 64 characters, unique in the collection | Echoed in events |
| `title` | 256 | Row text, cell tooltip, VoiceOver label |
| `subtitle` | 256 | Secondary row text |
| `symbol` | 32 | Grid cell content, row's leading glyph |
| `accessory` | 64 | Trailing row text |
| `text` | 4,096 | Text for Copy and Insert item actions; else `symbol`, else `title` |
| `actions` | item action IDs | The item actions this item offers; all by default. Valid, but use a toggle and `marks` to offer one of two states |
| `marks` | up to 6 marks | The marks it carries, each named by a toggle item action of its collection |

**Item actions** are declared once per collection, up to 6 item actions:
`{id, title, default?}` delivers `item_action`; `{id, title, toggle,
default?}` does too, and toggles a mark; `{id, title, perform:
"clipboard.write" | "selection.replace", closes_view?, notify?}` is performed by the
Host on the item's text, as the operation's primary member `text`, without an
event and under the Capability that operation needs. The `default: true`
action (at most one) runs on Return and double-click; every action the item
offers is in its context menu, the default first. The Host draws no buttons
for item actions and no bar below the collection. ⌘C performs a
`clipboard.write` item action when the collection has exactly one.

**Selection** is one item, kept by ID across answers; when its item leaves,
the item now at its position is selected, clamped to the last; when nothing
is selected and items exist, the first is. A new or reset collection selects
`selected`, else its first item, scrolled to the top. Scrolling keeps the
first visible item in place when items are added above it.

## Windows of items

A collection with `total` (at most 2,000) gives one slice of its items per
answer: `items` are positions `start` (default 0) onwards, and `start` plus
their number is at most `total`. Its `sections`, if any, are headers
`{id, title?, count}` whose counts add up to `total`; an item's section is
the one its position falls in. Without `total` every item is given.

- **The window.** The Host keeps the items within two screens (`columns` ×
  `rows` positions each) of what is on screen, at most 600, and lets the
  rest go. The scroll bar spans all `total` positions, so the user can drag
  or jump anywhere; a position whose item the Host does not hold shows a
  placeholder.
- **`load_range`.** When a position within one screen of what is on screen
  is missing, the Host sends `{"type": "load_range", "page", "collection",
  "start", "count"}` for the missing positions within its window, at most
  600. It is no gesture. At most one is outstanding per collection: a
  newer one replaces one still waiting, so the Host asks only for what the
  user looks at now, and one already running is answered first. Answer
  with the page, the collection giving at least that slice and no reset;
  the Host merges it into its window. Positions it asked for that did not
  come are not asked for again until the total or sections change or the
  user moves onto one. A failed `load_range` shows inline and leaves the
  placeholders.
- **Answers to anything else.** An answer to typing, a gesture, `called` or
  `operation_finished` gives the slice the Plugin chooses, usually from
  position 0. When it keeps the collection and its `total` and sections are
  unchanged, the items it gives replace those at their positions, and the
  ones it does not give stay shown until the Host has asked for them again,
  so nothing outdated stays on screen; when its `total` or sections changed,
  only what it gives is kept and the Host asks for the rest.
- **Selection.** The selection is kept by item ID, with the item as last
  shown, even while the window does not hold it: Return, double-click, the
  context menu and ⌘C act on it. Moving the selection onto a position the
  Host does not hold selects that position and asks for it; the item there
  is selected when it comes, and until then Return and ⌘C do nothing.
- **Size.** Keep each answer to about 200 items: answer size, not search
  time, is what costs latency. The Host asks for about five screens at a
  time.

## Toggles and marks

An item action with `toggle: "<mark>"` (a mark is an ID of at most 32
characters) toggles that mark on an item. It delivers `item_action` like any
event action, and the item's snapshot carries the `marks` it had when the
user chose, so the Plugin knows which way it went. The context menu shows
the action checked for an item whose `marks` include its mark, and
VoiceOver reads it as checked. The Plugin owns the data: it answers with the
item's new marks, and refuses as it likes (a toast, no change). An item may
carry only marks its collection's toggle actions name; two toggle actions of
one collection toggle different marks, and a toggle performs nothing.

## Outcomes of page and item actions

A page action or item action the Host performs may set `notify: true`. Once
the Host has performed it, its outcome reaches the Plugin as
`operation_finished`, as a requested operation's does
([Requested Host Operations](host-operations.md#operation_finished)):
`operation` is the action's `id`, and for an item action `item` is the item
as shown when the user acted, the same snapshot `item_action` carries.

```json
{"type": "operation_finished", "operation": "copy", "perform": "clipboard.write",
 "outcome": "succeeded", "item": {"id": "1F408", "text": "🐈"}}
```

It runs in the Plugin's operation slot like the action itself, so ⌘C
pressed twice copies twice and is heard twice, in order. With
`closes_view`, when the view closes on success, the outcome is delivered
after the view closed, with `view_closed: true`, to a viewless invocation
([after the view closed](host-operations.md#after-the-view-closed)). An item action that delivers an event, a toggle
included, takes no `notify`: the Plugin hears it anyway.

**Empty, loading and failure.** A collection without items shows its
`empty_text` (default "No items"). While an event runs the view shows its
busy state; typing never waits for it. A failed event shows inline and keeps
the page.

## Keys and pointer

| Input | In the search field | In the collection |
| --- | --- | --- |
| Typing, Left, Right, Option/Command-arrows, Delete, ⌘A, ⌘Z | Edits the text | Typing returns to the search field, with a keyboard layout; with an input method selected it is ignored |
| Any key during an input-method composition | The input method | |
| Up, Down | Moves the selection one row | Moves the selection one row |
| Left, Right | Caret | Moves the selection one item |
| Page Up/Down, Home/End | Text | By a screenful, to the first/last item of `total` |
| Return | Default item action | Default item action |
| Click / double-click / right click | | Select / default action / context menu |
| ⌘C | Copies the field's selection | The item's Copy item action, when there is exactly one |
| Tab, Shift-Tab | Next / previous field or the collection | Next / previous field |
| Escape | Closes the view | Closes the view |

Return in a `text_field` without `collection` sends `submitted`. Return in a
search field while the answer to the latest typing is still to come sends
that typing at once, waits for its answer, and then performs the default item
action on the selection it produced; if that answer fails, nothing is
performed. Arrow selection crosses section boundaries with the column
clamped. VoiceOver reads each item by its title, its item actions as custom
actions, and the insertion target line as text.

## Events

Page events name their `page`. The Host dispatches one only while that page,
and the component it came from, are still on screen with the same kind and
not reset since; otherwise it is dropped without a run.

| Event | Members | Gesture |
| --- | --- | --- |
| `field_changed` | `page`, `field`, `values` | No |
| `submitted` | `page`, `field`, `values`, `selection` | Yes |
| `action_chosen` | `page`, `action`, `values`, `selection` | Yes |
| `item_action` | `page`, `collection`, `action`, `item` `{id, section?, text?, marks?}`, `values` | Yes |
| `load_range` | `page`, `collection`, `start`, `count` | No |
| `called` | none | Yes |
| `operation_finished` | A requested operation's members, and `item` for an item action | No |

`values` holds every input of the page and `selection` the collection's
selected item ID (or null), as they were when the user acted. `item` is the
item as shown then, with its resolved text where it differs from its ID,
delivered even if the item has since left the collection. `called` names
no page and is never dropped for a page change; see below. Level 1 events
from a Level 1 view, `setting_changed`, `settings_swapped` and
`section_delivered` are unchanged. A gesture's answer may request an
operation; an answer to `field_changed`, `load_range` or
`operation_finished` may not.

## Calling the Plugin again

While a Level 2 Plugin's View Session is open, an explicit call of any of
its scripted Actions (a Menu Item's Primary or Alternate Action, of the same
Command or another, with any overrides) goes into that session
(`repeated_calls_into_session`). Under Level 1 a call starts the Action
again with no event and replaces the view, dropping what waited; at Level 2
it does not.

```js
if (event?.type === "called") {
  // input is the called Action's; state the session's last good state.
  const next = Object.assign({}, state, { scope: input.scope });
  return ui.showPage(list(next, next.scope !== state.scope ? ["scope", "results"] : undefined), { state: next });
}
```

- **Accepted at once.** The panel comes to the front where it is, keeping
  its pin and what the user is doing in it. The call is queued as it was
  made: its complete Action, in order behind the events already waiting,
  never merged with another call. As a gesture it waits while the Plugin
  has an operation outstanding ([Busy](host-operations.md#busy)).
- **Run in turn.** It runs the called Action's Command with that Action's
  input as it is then: the Plugin Settings when it runs, with the Menu
  Item's overrides, after the availability check an Action's start gets; a
  refusal shows in the view. `event` is `{"type": "called"}`, which carries
  nothing, and `state` the session's last good state, the state of the
  last answer that had a page or view, an earlier call's included. Its four
  seconds start when its script does, not while it waits.
- **Read under its own Action.** Its answer is read as an answer to the
  called Action: an `operation` it requests is authorized for that Action's
  Command. Nothing showed where text would go when the user called, so an
  insertion it makes or requests is refused with `target_not_shown`, as for
  the Action's start.
- **Only a page or view commits it.** An answer with a page or view makes
  the called Action the session's handler: later events run its Command
  with its input, page and standard actions use its authority, and only
  its own requests' `operation_finished` results reach it. Commands never
  combine their authority through the session. An answer with no page or
  view (`null`, a toast, an operation), a failure, a refusal, a timeout or a
  crash keeps the previous handler, page or view, and state; a failure shows
  inline, and the next call runs from that same state. `close: true` closes
  the view. An answer that breaks the interface ends the View Session.
- **What waited still counts.** Page events made before the call keep their
  provenance: one whose page and component are still on screen, unchanged
  and not reset, runs after the call, under the handler then; any other is
  dropped. Calls, `setting_changed`, `settings_swapped` and results are not
  page-bound. A call's answer with the same page ID keeps the page's
  immediate state, as any answer does; to start afresh on every call, reset
  the page.
- **A Level 1 view.** A Level 2 Plugin may still answer a call with a
  Level 1 `view`, which counts as a page change: the field changes,
  submissions, action choices and section deliveries waiting from the old
  view are dropped, as when Level 1 presents again. A Host-Fetched Section
  the new view shows with the same ID and `fetch` is kept when the call's
  Command is the one that showed it, overrides aside, and a response waiting
  for it is delivered again rather than fetched again; a call of another
  Command sends the new view's sections afresh under that Command.
- **Ending cancels.** Closing the view, the Plugin closing it, updating,
  disabling or removing the Plugin, revoking a Capability it uses, or an
  answer that breaks the interface cancels every call waiting or running.
  The Host tells the user of each ("Cancelled: the view was closed") and
  replays none; the next call starts the Action as usual. A call whose
  script had started may already have used Host Services, which are not
  undone.

A call while no session is open starts the Action as usual. A Host Command,
which runs no script, keeps its own path whatever the Plugin declares.

## Insertion

[Requested Host Operations](host-operations.md#insertion) apply to pages:
`shows_insertion_target` is a page
member, `item_action` is a gesture whose answer may request
`selection.replace`, and a `selection.replace` item action or page action
checks its target as a requested one does. The target shown when the user
pressed Return, double-clicked or chose from the menu must be the App in
front when the Host inserts.

Since no button carries an item action, the Host shows the target in the
target line: one non-interactive line of Host text at the
foot of the page, drawn only when the page sets `shows_insertion_target` or
its collection has a `selection.replace` item action. It has no buttons, is
not a Tab stop, and VoiceOver reads it as text. The context menu's insert
item also names the App. A page that cannot insert shows nothing below its
collection.

## The SDK

[`spinnet-level-2.js`](../spinnet-level-2.js) adds `.action(input, { id, title,
closesView, notify })` to the nine operations a page action may perform,
`spinnet.ui.components` with `row`, `textField`, `choiceField`, `text`,
`actions`, `button`, `list` and `grid` (with `total` and `start`),
`section` (with `items`, or `count` for a header), `item` (with `marks`) and
`itemAction` (with `toggle` and `notify`), `ui.page(options)` and
`ui.showPage(page, { state, toast, operation })`. Camel-case options become
snake-case members. The builders ask the Host for nothing; the Host checks
the answer.

## The helper protocol and the test kit

The invocation carries the Plugin's `"api_level": 2`, which is how the
helper adds the page builders with the rest of Level 2's SDK.

In the Plugin test kit, `run.answer()` reads a page as the Host does, its
page rules included, and `PluginTestPage` drives a View Session by recorded
gestures: typing, choosing, selecting, arrow keys, Return, double-click, the
context menu, ⌘C, buttons and scrolling. For a collection with a total it
keeps the screen around the selection, or where the test scrolled
(`scroll(to:)`), and asks for what it lacks with `load_range` as the Host
does; it performs page and item actions with the outcomes the test records
(`operationOutcomes`), closes an unpinned view (`isPinned`) on a successful
`closes_view`, and delivers `operation_finished` in the session or, after
the view closed, to a viewless run (`afterClose`). It applies
each answer through the same page memory the Host uses, so a test sees what
the Host keeps, and records what the Host performs for page and item actions.
`call(_:input:)` calls an Action of the Plugin into the open session, by
default the handler's own: as `called` for a Level 2 Plugin, with
`handler` following the rules above, and as a restart for a Level 1
Plugin.

## Not in Level 2

Images, styles and Progress (#81), Host-run sources (#71), multiline, URL and
toggle fields, a total over 2,000 items, Host-side sorting of a window, setting controls and Host-Fetched Sections in pages, multiple
selection, selection-change events, focus requests, Host-side filtering,
dirty drafts, page stacks and local dialogs. A Plugin that needs a Level 1
element a page lacks answers a Level 1 `view` for that step.

Dirty drafts are an accepted direction, not part of Level 2: if a later
Level lets a page refuse to be left while its draft is unsaved, a
call or event it refuses will have its answer discarded together with any
operation that answer requested, while Host Services its script already used
stay done; nothing is rolled back.

## Budgets

A page counts against the 256 KiB view description, `state` against
64 KiB, each event and each call against the four-second deadline from when
its script starts, and typing against the
150 ms (warm) and 300 ms (cold) p95 targets, as in Level 1. A Host holds
at most 40 components per page, 2,000 items per collection (given in one
answer, or as its `total`), 600 items in a collection's window, and 4 pages
in page memory. A `load_range` asks for at most 600 positions.

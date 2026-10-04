# Pages and collections (candidate `collections` r1)

> **Candidate Contract, not a stable Level.** This is revision 1 of the
> `collections` Candidate Contract ([`candidate.json`](candidate.json)),
> which this Host provides; nothing here is part of Plugin API Level 1, and a
> Plugin that does not declare it is unaffected. A published revision never
> changes ([Candidate Contracts](../../README.md)). The rationale is the
> design record in
> [`proposals/collections/design.md`](../../../proposals/collections/design.md).

A Plugin that declares this revision, beside the
[`host_operations` r1](../../host_operations/r1/reference.md) and
[`namespaces` r1](../../namespaces/r1/reference.md) it requires, may describe
its Plugin View as **pages**: trees of identified View Components that the
Host draws natively, with a searchable, selectable List or Grid. The Host
keeps what the user is doing in a page (typed text, caret, input-method
composition, focus, selection, scroll) across the Plugin's answers until the
Plugin resets it. Everything in [views.md](../../../reference/views.md) still
applies unless this page says otherwise.

```json
{
  "api_level": 1,
  "candidate_contracts": [
    {"name": "collections", "revision": 1},
    {"name": "host_operations", "revision": 1},
    {"name": "namespaces", "revision": 1}
  ]
}
```

[`collections.schema.json`](collections.schema.json) publishes the shapes,
[`fixtures/`](fixtures/index.json) valid and invalid answers and events,
[`collections.js`](collections.js) the SDK additions and
[`collections.d.ts`](collections.d.ts) their types.

## Answering with a page

A script answers `{page, state}`, optionally with `toast` and, from a
gesture, `operation` (see `host_operations`). It may still answer a Level 1
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
    c.grid({ id: "results", columns: 8, rows: 6, emptyText: "No emoji match", hasMore,
      actions: [c.itemAction({ id: "insert", title: "Insert", default: true }),
                c.itemAction({ id: "copy", title: "Copy", perform: "clipboard.write" })],
      items: shown.map((e) => c.item({ id: e.hex, title: e.name, symbol: e.emoji })) })
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
input, id?, title?, closes_view?}`, on the user's click and without a View
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
answer to any event (typing, `load_more`, `operation_finished`) cannot undo
or interrupt typing. Composing text is never sent: `field_changed` follows
committed text, after a 100 ms pause. Answers cannot move focus;
`page.focus`, else the first `text_field`, else the collection, is focused
when a page is new or reset.

## Collections

A `list` or `grid` has `items`, or `sections` of `{id, title?, items}`, up to
2,000 items and 32 sections in all. Each item:

| Member | Bound | Use |
| --- | --- | --- |
| `id` | 64 characters, unique in the collection | Echoed in events |
| `title` | 256 | Row text, cell tooltip, VoiceOver label |
| `subtitle` | 256 | Secondary row text |
| `symbol` | 32 | Grid cell content, row's leading glyph |
| `accessory` | 64 | Trailing row text |
| `text` | 4,096 | Text for Copy and Insert item actions; else `symbol`, else `title` |
| `actions` | item action IDs | The item actions this item offers; all by default |

**Item actions** are declared once per collection, up to 6 item actions:
`{id, title, default?}` delivers `item_action`; `{id, title, perform:
"clipboard.write" | "selection.replace", closes_view?}` is performed by the
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

**More items.** With `has_more: true`, the Host sends `load_more` when the
selection or the scrolled-to end comes within a screenful of the last item:
one at a time per collection and once per loaded count. Answer with every
loaded item, the new ones appended, and no reset. A failed `load_more` shows
"Couldn't load more" with Retry where the items end. Keep answers to typing
to about 200 items: answer size, not search time, is what costs latency.

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
| Page Up/Down, Home/End | Text | By a screenful, to the first/last item |
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
| `item_action` | `page`, `collection`, `action`, `item` `{id, section?, text?}`, `values` | Yes |
| `load_more` | `page`, `collection`, `loaded` | No |

`values` holds every input of the page and `selection` the collection's
selected item ID (or null), as they were when the user acted. `item` is the
item as shown then, with its resolved text where it differs from its ID,
delivered even if the item has since left the collection. Level 1 events
from a Level 1 view, `setting_changed`, `settings_swapped` and
`section_delivered` are unchanged. A gesture's answer may request an
operation (`host_operations`); an answer to `field_changed` or `load_more`
may not.

## Insertion

`host_operations` applies to pages: `shows_insertion_target` is a page
member, `item_action` is a gesture whose answer may request
`selection.replace`, and a `selection.replace` item action or page action
checks its target as a requested one does. The target shown when the user
pressed Return, double-clicked or chose from the menu must be the App in
front when the Host inserts.

Since no button carries an item action, the Host shows the target in
`host_operations`' target line: one non-interactive line of Host text at the
foot of the page, drawn only when the page sets `shows_insertion_target` or
its collection has a `selection.replace` item action. It has no buttons, is
not a Tab stop, and VoiceOver reads it as text. The context menu's insert
item also names the App. A page that cannot insert shows nothing below its
collection.

## The SDK

`collections.js` adds `.action(input, { id, title, closesView })` to the nine
operations a page action may perform, `spinnet.ui.components` with `row`,
`textField`, `choiceField`, `text`, `actions`, `button`, `list`, `grid`,
`section`, `item` and `itemAction`, `ui.page(options)` and
`ui.showPage(page, { state, toast, operation })`. Camel-case options become
snake-case members. The builders ask the Host for nothing; the Host checks
the answer.

## The helper protocol and the test kit

The invocation names `collections` in `candidate_contracts`, which is how the
helper adds this revision's SDK.

In the Plugin test kit, `run.answer()` reads a page as the Host does, its
page rules included, and `PluginTestPage` drives a View Session by recorded
gestures: typing, choosing, selecting, arrow keys, Return, double-click, the
context menu, ⌘C, buttons and reaching the end of a collection. It applies
each answer through the same page memory the Host uses, so a test sees what
the Host keeps, and records what the Host performs for page and item actions.

## Not in this revision

Repeated calls into an open View Session (the `called` event, #78), images,
styles and Progress (#81), Host-run sources (#71), multiline, URL and toggle
fields, setting controls and Host-Fetched Sections in pages, multiple
selection, selection-change events, focus requests, and Host-side filtering.
A Plugin that needs a Level 1 element a page lacks answers a Level 1 `view`
for that step.

## Budgets

A page counts against the 256 KiB view description, `state` against
64 KiB, each event against the four-second deadline, and typing against the
150 ms (warm) and 300 ms (cold) p95 targets, as in Level 1. A Host holds
at most 40 components per page, 2,000 items per collection, and 4 pages in
page memory.

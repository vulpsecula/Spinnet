# Pages and collections (candidate `collections` r1)

> **Draft for a candidate revision, not published.** This is the page a
> `collections` revision 1 would publish beside its `candidate.json`. No
> Host provides it, and a Plugin must not declare it. See the
> [README](README.md).

A Plugin that declares `collections` revision 1, which requires
`host_operations` revision 1, may describe its Plugin View as **pages**:
trees of identified View Components that the Host draws natively, with a
searchable, selectable List or Grid. The Host keeps what the user is doing
in a page (typed text, caret, input-method composition, focus, selection,
scroll) across the Plugin's answers until the Plugin resets it. Everything
in [views.md](../../reference/views.md) still applies unless this page says
otherwise.

```json
{
  "protocol_version": "1.0",
  "api_level": 1,
  "candidate_contracts": [
    {"name": "collections", "revision": 1},
    {"name": "host_operations", "revision": 1}
  ],
  "id": "com.example.emoji"
}
```

## Answering with a page

A script answers `{page, state}`, optionally with `toast` and, from a
gesture, `operation` (see `host_operations`). It may still answer a
Level 1 `{view, state}`, which keeps Level 1's view rules, but never both.
`{operation}` or `{toast}` alone, or `null`, leave the page and state as
they are. [`collections.schema.json`](collections.schema.json) publishes the
shapes.

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
                c.itemAction({ id: "copy", title: "Copy", perform: "copy_text" })],
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
| `actions` | `actions`: up to 8 buttons | Event actions (`id`, `title`) and standard actions, without `shortcut` |
| `list` | collection members, `rows` (1 to 12, default 8) | Rows: `symbol`, `title`, `subtitle`, `accessory` |
| `grid` | collection members, `columns` (2 to 12 columns, default 8), `rows` (1 to 12, default 6) | Square cells showing `symbol`, else `title` |

The page lays its components out top to bottom. With a collection, the
components before it stay above, those after it stay below, and the
collection fills and scrolls the rest. Without one, the page scrolls when it
is taller than the panel. `rows` sets the collection's initial height.

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
  applied only to a new or reset component or page.
- **New ID, or the same ID with another kind**: a new component, from its
  description. A component left out of an answer is discarded.
- **Another page ID**: the Host remembers the page on screen and shows the
  new one with its remembered state if it is among the last 4 pages shown
  besides the one on screen, or else new. This page memory lasts as long as
  the View Session and is not a stack: there is no Host Back.
- **`reset`**: `["id", ...]` starts those components again from their
  description; `"page"` starts the whole page and its memory again. A reset
  applies to the answer that carries it only. A reset of a `text_field`
  whose input-method composition is open is dropped for that field.

The Host never replaces a kept field's text, caret or composition, so an
answer to any event (typing, `load_more`, `operation_finished`, a repeated
call) cannot undo or interrupt typing. Composing text is never sent:
`field_changed` follows committed text, after a 100 ms pause. Answers cannot
move focus; `page.focus`, else the first `text_field`, else the collection,
is focused when a page is new or reset.

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
"copy_text" | "insert_text", closes_view?}` is performed by the Host on the
item's text without an event, under the same Capability as the standard
action. The `default: true` action (at most one) runs on Return and
double-click; the others are secondary, in the item's context menu and the
Host's selection bar under the collection, which also shows the selected
item, the default action and, for insertion, the target App.

**Selection** is one item, kept by ID across answers; when its item leaves,
the item now at its position is selected; when nothing is selected and items
exist, the first is. A new or reset collection selects `selected`, else its
first item, scrolled to the top. Scrolling is anchored to the first visible
item.

**More items.** With `has_more: true`, the Host sends `load_more` when the
user nears the end: one at a time per collection and once per loaded count.
Answer with every loaded item, the new ones appended, and no reset. Keep
answers to typing to about 200 items: answer size, not search time, is what
costs latency.

## Keys and pointer

| Input | In the search field | In the collection |
| --- | --- | --- |
| Typing, Left, Right, Option/Command-arrows, Delete, ⌘A, ⌘Z | Edits the text | Typing returns to the search field |
| Any key during an input-method composition | The input method | |
| Up, Down | Moves the selection one row | Moves the selection one row |
| Left, Right | Caret | Moves the selection one item |
| Page Up/Down, Home/End | Text | By a screenful, to the first/last item |
| Return | Default item action | Default item action |
| Click / double-click / right click | | Select / default action / context menu |
| ⌘C | Copies the field's selection | The item's Copy item action, when there is exactly one |
| Tab, Shift-Tab | Next / previous control | Next / previous control |
| Escape | Closes the view | Closes the view |

Return in a `text_field` without `collection` sends `submitted`.

## Events

Page events name their `page`. The Host dispatches one only while that page,
and the component it came from, are still on screen with the same kind and
not reset since; otherwise it is dropped.

| Event | Members | Gesture |
| --- | --- | --- |
| `field_changed` | `page`, `field`, `values` | No |
| `submitted` | `page`, `field`, `values`, `selection` | Yes |
| `action_chosen` | `page`, `action`, `values`, `selection` | Yes |
| `item_action` | `page`, `collection`, `action`, `item` `{id, section?, text?}`, `values` | Yes |
| `load_more` | `page`, `collection`, `loaded` | No |
| `called` | none | Yes |

`values` holds every input of the page and `selection` the collection's
selected item ID (or null), as they were when the user acted. `item` is the
item as shown then, delivered even if the item has since left the
collection. `called` is an explicit call of one of the Plugin's Actions
while its View Session is open: `input` holds that Action's effective input,
`state` the session's last good state, and it does not depend on the page.
Level 1 events from a Level 1 view, `setting_changed`, `settings_swapped`
and `section_delivered` are unchanged.

## Insertion

`host_operations` applies to pages: `shows_insertion_target` is a page
member, `item_action` is a gesture whose answer may request `insert_text`,
and an `insert_text` item action shows and checks its target as a standard
`insert_text` action does. The target shown when the user pressed Return,
double-clicked or chose from the menu must be the App in front when the
Host inserts.

## Budgets

A page counts against the 256 KiB view description, `state` against
64 KiB, each event against the four-second deadline, and typing against the
150 ms (warm) and 300 ms (cold) p95 targets, as in Level 1. A Host holds
at most 40 components per page, 2,000 items per collection, and 4 pages in
page memory.

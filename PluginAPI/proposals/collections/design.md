# Design: minimal composable pages and collections

Issue #74, part of #47, governed by spec #68. Proposal only; see the
[README](README.md) for status. Host baseline inspected: `e0564b9`. Evidence:
#69 (external Emoji on Level 1, `SpinnetProbes/emoji` `PROOF.md`), the
user's requirements of 2026-10-03, and the Clipboard History window
(`Sources/SpinnetHost/ClipboardHistoryWindow.swift`) as the interaction
reference.

**Names (#99, 2026-10-04).** Page actions and item actions name the Host
Service they perform by its ID in the namespace catalogue
([`../namespaces/`](../namespaces/README.md)): `clipboard.write` for Level 1's
`copy_text`, `selection.replace` for `insert_text`, `open.url` for
`open_url` and `settings.show` for `open_plugin_settings`, with the
operation's `input`. `collections` therefore requires the draft
`namespaces` revision as well as `host_operations`. The decision records in
section 12 keep the names they were decided with.

Each acceptance criterion of #74 is answered here:

| Criterion | Sections |
| --- | --- |
| Page/component identity, explicit reset, stable input/IME/focus/selection/scroll, same-page moves, changed kinds; page identity in the first new UI contract | 4, 5 |
| List/Grid items, selection, actions with associated-value snapshots, bounded paging/load-more, keyboard roles; search caret and IME priority | 6, 7 |
| Initial row/column/section/scroll composition, public shape and budgets, Level 1 mapped separately, a credible second workflow | 3, 8, 9, [`level1-mapping.md`](level1-mapping.md) |
| Grouping with input preservation, repeated calls and execution-time insertion; nothing else silently scheduled | 10 |

The product choices, which the user decided on 2026-10-03, are in
section 12.

## 1. Evidence and requirements

What #69 showed on Level 1, with Emoji 1.0.0 and 1.1.0 on Host A2:

- **No selectable collection.** A Level 1 view has 20 Detail sections and 12
  buttons, so Emoji capped results at 6 and bound them to ⌘1–⌘6 (insert)
  and ⇧⌘1–⇧⌘6 (copy), which used all 12 actions.
- **Insertion and use are not observable.** A standard action emits no View
  Event, so recents or favourites by use cannot be built, and Return could
  not insert because a script's own `insert_text` had no specified target in
  a View Session. #70 (`host_operations`) now answers the second half.
- **Typing budget holds with headroom of about 25 ms.** Typing p95 was
  120.7–122.9 ms warm and 137.5–147.1 ms cold (budgets 150 and 300 ms), with
  six results and views of at most 2.5 KB.
- Not run in E1: Chinese IME composition in the search field. It is a
  verification item for #77 below.

The user's requirements (2026-10-03) for Emoji in the new contract:

1. Results as a grid ("表格形式").
2. No Plugin-bound shortcuts: no ⌘1–⌘6 style bindings.
3. Double-clicking an emoji inserts it.
4. Keyboard interaction modelled on Clipboard History: arrow keys select,
   Return performs the default action.
5. The search field keeps caret editing and IME candidate handling first.

Clipboard History, which requirement 4 refers to, behaves like this today:
a search field above a selectable `List`; Return in the search field acts
on the selection (`onSubmit { pasteSelection() }`); double-click and Return
in the list are its `primaryAction`; Copy, Open and Delete are in a
context menu and a footer that names the keys ("Double-click or Return to
paste"); reaching the end of the list loads the next page, bounded at 1,000
loaded copies; after a refresh the selection stays on the same entry, or
else on the row that took its place, or else the first row, without
taking focus from the search field. Arrow keys move the selection only once
the list has focus.

## 2. Baseline: Level 1 behaviour this design changes or keeps

| Level 1 behaviour | Where | Consequence |
| --- | --- | --- |
| A view is a fixed sequence: title, settings, Form, Detail, Actions | `plugin-view.schema.json`, `PluginViewContent` | A page is a new answer member, `page`; `view` keeps its meaning |
| A field keeps what the user typed only while the answer to their own typing arrives; every other answer with a view sets each field to its `value` | `PluginViewModel.update` | Reversed for pages: `value` is an initial value and the user's input stays until the Plugin resets it. Kept exactly for `view` |
| Fields are keyed by `key`, sections by `id`, actions partly by position | `PluginViewDescription` | Page components all have IDs; state follows IDs, never position |
| `action_chosen` carries only the action ID | `view-session.schema.json` | Page gestures carry the values and selection they were made with |
| Presenting again replaces the session's Action, view and state and drops queued events | `PluginViewSession.replace` | Replaced under the candidate by repeated calls (#78) and page provenance |
| The multiline editor protects an open IME composition | `FocusMovingTextView` (`hasMarkedText`) | Generalised: no answer, reset or collection key ever interrupts a composition |
| Panel 440 pt wide, height from content | `PluginViewPanel.width` | Collections declare an initial number of visible rows |

## 3. Vocabulary used here

- **Page**: the candidate's description of one View Page, answered as
  `page`. It has an `id`.
- **Component**: one View Component of a page. Every component has an `id`
  unique within its page.
- **Immediate state**: what the Host holds for a component while the user
  works with it: typed text, caret and selected range, an open input-method
  composition, focus, a collection's selection and scroll position. It is
  never part of the Plugin's `state`, which stays the Plugin's business
  state.
- **Reset**: the Plugin's explicit request that a component, or a whole
  page, start again from what its description says.
- **Collection**: a `list` or `grid` component: items the Host draws,
  selects, scrolls and loads more of, whose data, search, filtering,
  sorting and batches the Plugin owns.
- **Item action**: an action offered on every item of a collection. The
  **default item action** is the one Return and double-click perform. (The
  glossary's Primary Action is a Menu Item's, so it is not reused.)
- **Snapshot**: the values, selection and item a gesture carries, captured
  when the user made it.
- **Gesture**: as in #70: the Action's start or an explicit call,
  `submitted`, `action_chosen`, and, added here, `item_action`.

## 4. The page and its components

### 4.1 Shape

A script declaring the candidate may answer with a `page` instead of a
Level 1 `view`:

```js
ui.showPage(ui.page({
  id: "search",
  title: "Emoji",
  showsInsertionTarget: true,
  content: [
    c.row({ id: "bar", content: [
      c.textField({ id: "query", title: "Search", placeholder: "smile, cat, heart", value: "", collection: "results" }),
      c.choiceField({ id: "category", title: "Category", choices: CATEGORY_IDS, choiceTitles: CATEGORY_TITLES, value: "all" })
    ] }),
    c.grid({ id: "results", columns: 8, rows: 6, emptyText: "No emoji match",
      actions: [
        c.itemAction({ id: "insert", title: "Insert", default: true }),
        c.itemAction({ id: "copy", title: "Copy", perform: "clipboard.write" })
      ],
      sections: GROUPS.map((g) => c.section({ id: g.id, title: g.title, items: g.items.map(item) })),
      hasMore: true })
  ]
}), { state });
```

`c` is `spinnet.ui.components` in the draft types. On the wire this is
`{"page": {...}, "state": ...}`; [`fixtures/answers/`](fixtures/answers/)
has complete examples. An answer has at most one of `page` and `view`.

### 4.2 Components in this revision

Only what Emoji and the Brew check need (section 9), each with an `id`:

| Kind | What the Host draws | Immediate state |
| --- | --- | --- |
| `text_field` | A one-line field: `title` (its label for VoiceOver and when there is room), `placeholder`, initial `value`, Level 1's `status` and `accent`. `collection` names the page's collection it searches (section 7) | Text, caret and selection, composition, undo, horizontal scroll |
| `choice_field` | A pop-up of `choices` with `choice_titles` and an initial `value` | The chosen value |
| `text` | Plain text in Level 1's Markdown subset, with an optional `title`; no Copy button and no `fetch` | None |
| `actions` | A row of up to 8 buttons: Level 1's event actions (`id`, `title`) and page actions that perform a Host Service by catalogue ID with its `input`, as Level 1's standard actions do (`clipboard.write`, `selection.replace`, `open.url`, `settings.show` and the catalogue's other page-action IDs), **without** `shortcut` | None |
| `row` | Up to 4 of the components above side by side; a `text_field` takes the spare width | None |
| `list` | A collection drawn as rows: `symbol`, `title`, `subtitle`, trailing `accessory` | Selection, scroll, load-more |
| `grid` | A collection drawn as square cells, `columns` across; a cell shows the item's `symbol`, or its `title` when it has none | Selection, scroll, load-more |

Deliberately absent from this revision (section 10): multiline, URL and
toggle fields, setting controls, Host-Fetched Sections, images and icons,
Progress, styles, absolute layout, several Forms, nested rows, more than
one collection per page, multiple selection. A Plugin that needs a Level 1
element this revision lacks keeps answering `view` for that page.

### 4.3 Composition: rows, columns, sections, scroll

- **Column.** `page.content` is laid out top to bottom. There is no column
  component: the page is the column.
- **Rows.** `row` places up to 4 leaf components side by side. Rows do not
  nest and cannot hold a collection.
- **Sections.** A collection has either `items` or `sections`, each section
  `{id, title?, items}`. Section headers stay visible while their items
  scroll. Item IDs are unique across the whole collection, so the same
  emoji in "Recent" and "Smileys" has two IDs.
- **Grid columns.** `columns` (2–12, default 8) is a fixed count chosen by
  the Plugin; cells divide the width. Arrow keys therefore move through
  predictable rows. At the 440 pt panel width, 8 columns give cells of
  about 50 pt.
- **Scroll.** A page has at most one collection. When it has one, the
  components before it stay above it, those after it stay below it, and the
  collection takes the remaining height and scrolls. A page without a
  collection scrolls as a whole when it is taller than the panel.
- **Initial size.** A collection asks for `rows` visible rows (1–12;
  default 6 for a grid, 8 for a list). The panel's height follows the
  content as in Level 1, clamped to the screen. Once #80 lets a pinned
  panel be resized, the collection takes the extra height and `rows` only
  sets the initial size.
- **Initial position.** A new page, or a reset collection, starts scrolled to
  the top, with the item named by `selected` (or else the first item)
  selected, and focus on the component named by `page.focus`, or else the
  first `text_field`, or else the collection.

### 4.4 Validation

As in Level 1 (ADR 0010, Q32), a page the Host would not draw ends the View
Session as a protocol violation: an unknown member or kind, a `shortcut`
anywhere, two components with one ID, two collections, a `text_field`
whose `collection` names no collection on the page, two default item
actions, an item listing an action the collection lacks, a duplicate item
ID, a `reset` or `focus` naming no component, or a description over the
budgets in section 8. [`check.py`](check.py) implements these checks over
the fixtures, beside the schema.

## 5. Identity and immediate state

### 5.1 Page identity

`page.id` names the View Page. The Host compares it with the page on
screen:

- **Same ID**: a refresh of the page on screen. Immediate state is kept
  (5.2).
- **Different ID**: the page on screen is put into the session's **page
  memory** with its immediate state, and the new page is shown with its
  own remembered state, if it was one of the last pages shown, or else
  fresh.
- Page memory holds up to 4 pages besides the one on screen, the most
  recently shown, keyed by page ID only. It is not a page stack: the Host offers no Back, keeps no
  history order the Plugin can see, and keeps no dirty drafts (Q15/Q22 stay
  unscheduled, section 10). It lets a Brew detail page return to its list
  with the search text, selection and scroll the user left (Q31: "pages
  keep their same-named state separately").
- A Level 1 `view` answer counts as a page change to and from a page with
  no ID; the `view` follows Level 1's rules (`level1-mapping.md`).
- Page memory ends with the View Session. Nothing is restored after the
  panel closes or the Host restarts (ADR 0016).

Page identity does not depend on which Command answered: two Commands of a
Plugin that answer the same page ID share its immediate state. A Plugin that
wants them apart uses two IDs.

### 5.2 Component identity and what survives an answer

Within a page, a component is identified by its `id` and `kind` together.
On every answer to the same page, for each component:

| Situation | Immediate state |
| --- | --- |
| Same `id` and `kind`, anywhere in the page | **Kept**: moved into or out of a row, reordered, retitled, restyled, given a new status, accent, placeholder, items, columns or actions |
| Same `id`, different `kind` (`grid` to `list`, `text_field` to `choice_field`) | **New**, from the description |
| `id` not on the page before | **New**, from the description |
| Named in `page.reset`, or `page.reset` is `"page"` | **New**, from the description (5.3) |
| Absent from the answer | Discarded; a later component with that ID is new |

So for pages, a component's `value`, a collection's `selected`, and
`page.focus` are **initial** values: the Host applies them only when the
component (or page) is new. Every event tells the Plugin the actual
values, so it never needs the Host to echo them. This is the reverse of
Level 1, where every answer that does not answer the user's own typing
overwrites each field; Level 1 keeps that rule (`level1-mapping.md`).

Kept immediate state never includes what the Plugin describes: a kept
`text_field` shows a new `status` and `accent` at once, and a kept
collection shows its new items at once, with its selection and scroll
reconciled (6.3).

### 5.3 Explicit reset

`page.reset` is either a list of component IDs or `"page"`:

- a listed component starts again from its description: a `text_field`'s
  text becomes its `value` (empty without one) with the caret at the end; a
  `choice_field` its `value`; a collection scrolls to the top and selects
  `selected` or its first item;
- `"page"` does that for every component, clears the page's memory and
  applies `page.focus` again;
- a reset is one-shot: it applies to the answer that carries it. An answer
  without `reset` never resets anything, however its values differ from
  what the user has.

Emoji, for example, resets `results` when the query or category changed, so a
new search starts at its first result, and leaves it alone when answering
`load_more`, so loading more never moves the user. After an insertion it
may reset `query` to clear the search.

**A reset never interrupts an input-method composition.** If a reset names a
`text_field` while a composition is open in it, that field's reset is
dropped (the rest of the reset applies); the user's composition and the
text it commits win, and the next `field_changed` tells the Plugin what the
field holds. A Plugin that still wants the field cleared resets it again.

### 5.4 Focus, caret and IME

- Focus belongs to the Host. Answers cannot move it in this revision (Q14:
  no focus requests in the starting commitment); `page.focus` applies only
  to a new or reset page. If the focused component disappears, focus moves to
  the page's first `text_field`, else its collection, else nothing.
- A `text_field` behaves as the native field it is: caret movement, word
  and line movement with Option and Command, selection, undo, services and
  the Edit menu. No collection key ever takes Left, Right, Option-arrow,
  Command-arrow, Delete, Command-A, Command-Z or Shift-arrow from it.
- While a composition is open (`hasMarkedText`), every key goes to the input
  method first: Return, Escape, Tab, Space, digits, and Up/Down which move
  through the candidate window. Nothing reaches the collection.
- Text being composed is not part of `values`: `field_changed` is sent after
  committed text changes, after the 100 ms pause as in Level 1. Composing
  Pinyin therefore sends no events and costs no invocations.
- No answer ever replaces the text, caret or composition of a kept field
  (5.2), so a slow or late answer cannot undo a keystroke, and an answer
  to some other event (a Brew task's progress, `operation_finished`, a
  load-more) arriving during typing changes nothing in the field. This
  answers the failure Level 1 has with any non-typing answer during the
  100 ms debounce.

### 5.5 Selection and scroll

Owned by the Host and reconciled on every answer (6.3). Scrolling is
anchored to the first visible item's ID, so appending items, or inserting a
section above, does not move what the user is looking at.

### 5.6 Queued events and provenance

An ordinary event records the page ID, the page's reset count and the
component it came from. Before dispatching it, the Host checks that the page
on screen still has that ID and has not been reset since, and that the
component is still on it with the same kind and has not been reset since.
Otherwise the event is dropped without a run and without feedback: the
user is already looking at the page that replaced it.

| Event | Page-bound? |
| --- | --- |
| `field_changed`, `submitted`, `action_chosen`, `item_action`, `load_more` | Yes, as above |
| `called` (explicit repeated call, #78) | No: it runs after any page change |
| `setting_changed`, `settings_swapped` (Level 1 `view` only) | No: persisted Settings notifications stay deliverable (#68) |
| `operation_finished` (#70) | No; it follows #70's handler rule |
| `section_delivered` (Level 1 `view` only) | Level 1's rules |

`item_action` is still delivered when the item has since left the
collection, because the event carries the item's snapshot (6.4). The
collection, page and their reset counts are what must still match.

### 5.7 Alternatives considered

- **Level 1's rule plus a revision per field** (the Host overwrites a field
  only when the Plugin bumps its revision). Rejected: every Plugin would keep
  a revision per field in `state`, and an answer that forgot one, or rebuilt
  state from Storage, would wipe the user's text. Initial values with an
  explicit one-shot reset make the safe behaviour the default.
- **Identity by position.** Rejected: moving the search field into a row, or
  adding a Recent section, would lose the caret and selection.
- **Patches instead of complete descriptions.** Deferred: paging keeps
  answers to typing small (section 8), and Level 1 has no patch protocol to
  extend. A later revision can add one if #77's measurements of `load_more`
  answers demand it.
- **A Host page stack with Back.** Not scheduled (Q15). Page memory gives
  Brew's list → detail → list without one.

## 6. Collections

### 6.1 Items

| Member | Use | Bound |
| --- | --- | --- |
| `id` | Identity within the collection, echoed in events | Identifier, 64 characters |
| `title` | List row text; grid cell tooltip; always the VoiceOver label | 256 characters |
| `subtitle` | Secondary list text | 256 characters |
| `symbol` | Large glyph in a grid cell; leading glyph in a list row | 32 characters |
| `accessory` | Trailing list text, such as a version or "Outdated" | 64 characters |
| `text` | What `clipboard.write` and `selection.replace` item actions use; without it, `symbol`, else `title` | 4,096 characters |
| `actions` | IDs of the collection's item actions this item offers; all when absent | Up to 6 |

Images and icons are #81's and not part of this revision.

### 6.2 Item actions

A collection declares its item actions once, not per item, so 1,906 emoji
do not each repeat "Insert" and "Copy":

- `{id, title, default?: true}` delivers `item_action` (a gesture);
- `{id, title, perform: "clipboard.write" | "selection.replace", closes_view?}`
  is a Host Service the Host performs on the item's text without a View
  Event, as Level 1's standard actions are; the text becomes the operation's
  primary member `text`.

At most one is `default: true`. Return and double-click perform the
default; the others are **secondary** and are offered only in the item's
context menu (right click, Control-click), after the default (C6). The Host
draws no buttons for item actions, for any Plugin: there is no quick-action
bar below a collection. No item action, page action or component may carry
a `shortcut`. The only key bindings are the Host's own, the same for every
Plugin (section 7): Return for the default and ⌘C for a single
`clipboard.write` item action (C5).

An item action may be offered on some items only (`item.actions`): Brew
shows "Upgrade" only on outdated packages and "Install" only on packages that
are not installed.

`selection.replace` item actions follow #70's candidate rules: their context-menu
item names the insertion target as #70's secondary label (P1), the page's
target line shows it for Return and double-click (6.5), and the frontmost
App at execution must be the one shown.

### 6.3 Selection

One item is selected at a time, or none when the collection is empty.
On every answer to the same collection without a reset:

1. the selected ID, if still present, stays selected, wherever it moved;
2. otherwise the item now at the selected item's former position is
   selected, clamped to the last item (Clipboard History's rule after a
   delete);
3. if nothing is selected and items exist, the first item is selected.

A new or reset collection selects `selected` if present, else its first
item, so Return works on the first result as soon as it is shown. The
Plugin is not told about selection changes in this revision: no workload
needs a View Event per arrow key, and the gestures carry the selection.

### 6.4 Snapshots: what gestures carry

| Event | Members |
| --- | --- |
| `item_action` | `page`, `collection`, `action`, `item` `{id, section?, text?}` as shown when the user acted, `values` |
| `action_chosen` (page button) | `page`, `action`, `values`, `selection` |
| `submitted` (Return in a `text_field` with no `collection`) | `page`, `field`, `values`, `selection` |
| `field_changed` | `page`, `field`, `values` |

`values` maps every input component of the page (in rows too) to its
committed value; `selection` maps the page's collection to its selected item
ID, or null. Both are captured at the gesture, so a refresh dispatched
first cannot change what the gesture meant. `item.text` is the resolved text
(6.1), included when it differs from `id`, so Emoji can insert exactly what
the user saw without searching again. Associated values are bounded by the
item limits; there is no free-form JSON value per item in this revision.

### 6.5 Host-drawn collection chrome

The Host draws no controls of its own below a collection, for any Plugin
(C6): no selection bar, no buttons for the default or secondary item
actions. The collection's items, its context menu and the Host's keys are
the only way to act on an item.

**Insertion target line.** #70 needs the Host to show where an insertion
would go before the user acts (its P1: a secondary label on each insert
action, plus the optional target line). A Return or double-click on a
`selection.replace` default has no button to carry that label, so for pages the
Host shows the target in the least intrusive place it owns: #70's target
line, one line of Host text (the App's name and icon) at the foot of the
page, below the collection and anything after it. The Host draws it only
when the page can insert:

- the page sets `shows_insertion_target: true` (required by #70 when a
  gesture's answer may request `selection.replace`, as Emoji's event `insert`
  does), or
- the collection has a `selection.replace` item action, whatever the page says.

The line is not interactive: it holds no buttons, is not a key-view stop,
and VoiceOver reads it as static text. A page that cannot insert shows
nothing below its collection. A `selection.replace` button in an `actions`
component carries the target as its own secondary label, as in #70, and
needs no line. The Plugin cannot style or move the line, and the App's
name never reaches the Plugin (#70 section 6.2).

Empty, loading and failure states:

- **Empty**: `empty_text` (default "No items") in place of the items.
- **Loading more**: a progress row at the end while `load_more` runs.
- **Failure**: an event failure shows as Level 1's inline error and keeps
  the page; a failed `load_more` shows "Couldn't load more" with Retry in
  the progress row's place.
- **Busy**: Level 1's event busy state; typing never waits for it.

### 6.6 Bounded paging: `has_more` and `load_more`

The Plugin owns the data and every batch; the Host owns when to ask (Q25):

- `has_more: true` says the Plugin has more items after the last one it
  described.
- When the selection or the visible range comes within one screenful of the
  last item, the Host sends `load_more` `{page, collection, loaded}` with
  the number of items now loaded.
- At most one `load_more` per collection is outstanding, and the Host asks
  at most once per loaded count. An answer that adds no items, or a failed
  event, stops asking until the user reaches the end again or retries.
- The Plugin answers with the page carrying all loaded items, the new ones
  appended, and without resetting the collection, so the selection and
  scroll stay. The description stays complete: there is no patch protocol.
- A collection holds at most 2,000 items, and the whole page at most
  256 KiB (section 8). A Plugin that reaches either stops offering
  `has_more` and asks the user to narrow the search.
- Batch size is the Plugin's. Section 8 recommends about 200 items per
  answer to typing.

Host-side local filtering (Q25's "generic local filtering may be opted
into") is not part of this revision: E1's latency shows the Plugin's own
search meets the typing budget, and section 8 shows that the item count, not
the search, is what costs time.

## 7. Keyboard and pointer roles

Focus has two roles on a collection page: the **search field** (the
`text_field` whose `collection` names the collection) and the
**collection**. Other inputs and buttons are ordinary key-view stops.

| Input | Search field focused | Collection focused |
| --- | --- | --- |
| Any key while a composition is open | Input method | (cannot happen: compositions live in the field) |
| Typing, Left/Right, Option/Command-arrows, Delete, ⌘A, ⌘Z, Shift-selection | Text editing, always | Printable keys return focus to the search field and type there (C3) |
| Up / Down | Move the selection one row (one item in a list, one grid row in the same column), focus stays in the field (C2) | Move the selection one row |
| Left / Right | Caret | Move the selection one cell; wraps to the previous/next row |
| Page Up / Page Down, Home / End | Text editing | Move by a screenful, to the first / last loaded item |
| Return | The default item action on the selection, nothing when there is none (C1 for a search still in flight) | The default item action |
| Double-click an item | | Select it and perform the default item action |
| Click an item | | Select it; the collection takes focus |
| Right click / Control-click | | Context menu: default action first, then secondary actions |
| ⌘C | Copies selected text in the field | The selected item's `clipboard.write` item action, when the collection has exactly one (C5) |
| Tab / Shift-Tab | Next / previous key-view stop: field → other inputs → collection → page actions; the target line is not a stop | Same |
| Escape | Closes the view, as in Level 1 (C4) | Same |
| Space | Types a space | Nothing in this revision |
| ⌘W, ⌘Q, ⌘Return, other Level 1 view keys | As in Level 1 | As in Level 1 |

Arrow selection crosses section boundaries: Down from a section's last row
goes to the next section's first row, column clamped. VoiceOver reads the
collection as a list or grid of its titles, the item actions as the item's
custom actions (the default first, the same list as the context menu), and
the insertion target line as static text; #77 verifies it.

The Return of a search field without a `collection` is `submitted` (one
implicit form per page; several Forms are not in this revision). A
`choice_field` change is sent at once, coalesced like typing.

## 8. Budgets and measurements

### 8.1 What was measured

[`measure-emoji.js`](measure-emoji.js) builds the draft Emoji page with the
probe's own search code and data (Emoji 1.1.0, Unicode 16.0, 1,906 emoji)
and measures each answer's UTF-8 size and its JavaScriptCore build and
`JSON.stringify` time, cold in a fresh `jsc` process (the helper uses a
fresh JSContext per invocation). A small Swift harness then timed the
helper's answer path (`JSValue.toObject` → `JSONSerialization` → decode into
`JSONValue` → encode the message) and the Host's decode of that message,
using the Host's `JSONValue` decoding. M1 Pro, 16 GiB, macOS 27, release
builds, on 2026-10-03. The machine was **not idle** (load average 9–12 from
other work), so these figures are conservative. SwiftUI drawing was not
measured (#77).

| Answer | Items | Bytes | JS build, cold median (max) | Helper + Host serialisation |
| --- | --- | --- | --- | --- |
| Level 1-sized: "cat", 6 results | 6 | 1,256 | 0.8 (1.5) ms | 1.2 ms |
| "cat" | 20 | 2,081 | 0.6 (1.0) ms | |
| "heart" | 43 | 3,561 | 0.7 (0.8) ms | |
| Browse, first page | 96 | 6,881 | 2.0 (2.3) ms | |
| Browse, first page | 200 | 12,964 | 2.3 (2.6) ms | 10.8 ms |
| "flag" | 275 | 19,698 | 1.5 (1.8) ms | 11.9 ms |
| People & Body, whole category | 386 | 29,409 | 2.0 (2.3) ms | |
| "a" (one key typed) | 426 | 26,023 | 3.0 (3.2) ms | |
| "s" (one key typed) | 736 | 44,429 | 3.1 (4.2) ms | 30.5 ms |
| Browse, 1,000 loaded | 1,000 | 63,015 | 2.9 (4.0) ms | |
| **Browse all, one answer** | 1,906 | 117,228 | 3.3 (5.2) ms | **95.7 ms** |
| Browse all, items also carrying `text` | 1,906 | 147,987 | | |

These were measured with the Copy item action named `copy_text`; its
catalogue ID, `clipboard.write` (#99), adds 6 bytes to each answer, which
`measure-emoji.js` now builds.

Items cost about 61 bytes each (`{id, title, symbol}`); repeating the emoji
as `text` would add 26%, which is why `text` defaults to `symbol`. A
Brew-shaped list of this machine's 203 installed formulae and casks, with
descriptions, versions and per-item actions, is 30,890 bytes, about
152 bytes per item, and a name search of the local catalogue (24,185
formulae and casks) finds 777 for "lib" and 199 for "py".

### 8.2 What it means

- Building pages in the script is cheap: under 6 ms even for every emoji.
- Moving the answer is not: the helper and Host each spend about 0.4 ms per
  KB in the `JSONValue` round trip, about 0.8 ms/KB together. E1 typing
  p95 on Host A2 was about 119–123 ms warm with 150 ms allowed, so an answer
  to typing has roughly 25 ms to spare: about 300 emoji items or 20 KB.
- A whole-set browse in one answer would add about 96 ms, projecting typing
  p95 to about 215–220 ms, over budget. **Emoji pages**: the first answer to
  any search or category browse carries at most about 200 items (about
  11 ms), and `load_more` appends further batches. All 1,906 remain
  reachable by scrolling; only answers to `load_more` grow toward 117 KB and
  100 ms, which no typing waits for.
- The byte budget, not the item count, binds Brew: 2,000 Brew items would be
  about 300 KB, over 256 KiB, so Brew pages its catalogue search as Emoji
  does.
- The `JSONValue` path's cost (a `try?` cascade in `Codable` decoding) is a
  Host-internal matter #77 may improve; it is not a reason to change the
  contract, and the budgets below do not assume it improves.

### 8.3 Budgets

Existing budgets are unchanged (ADR 0010, #68): a page description counts
against the 256 KiB view budget, `state` 64 KiB, each event the four-second
deadline, typing p95 150 ms warm and 300 ms cold including the 100 ms
debounce, the helper 6 MiB incremental footprint, the 1 MiB helper
message.

New limits for this revision:

| Limit | Value | Why |
| --- | --- | --- |
| Components per page, row children included, items excluded | 40 | Emoji's page has 4 and Brew's 3 or 4; Level 1 allows up to 58 elements (20 fields, 20 sections, 12 actions, 6 settings), which no single page here needs |
| Children per row | 4 | Emoji's and Brew's search rows need 2 |
| Nesting | page → row → leaf | No workload needs more; deeper layout is Q20/Q30 territory |
| Collections per page | 1 | Keeps keyboard roles unambiguous; sections cover "Recent" plus categories |
| Items per collection | 2,000 | Every emoji (1,906) fits by paging; Clipboard History bounds itself at 1,000; the 256 KiB budget usually binds first |
| Sections per collection | 32 | Emoji uses 9, plus Recent |
| Item actions per collection | 6 | Emoji 2, Brew 4 |
| Buttons per `actions` | 8 | |
| Grid columns / visible rows | 2–12 / 1–12 | Default 8 × 6 for a grid, 8 rows for a list |
| Page memory | 4 pages per session | Brew needs 2 |
| Outstanding `load_more` | 1 per collection, once per loaded count | Bounded paging |
| Recommended items per answer to typing | about 200 | Section 8.2; guidance, not a check |

#77 re-measures with the real helper and Host, including SwiftUI drawing
and Host memory for 2,000 items, and must not loosen an existing budget to
make a number fit. If a limit proves wrong it changes in the next candidate
revision, not silently.

## 9. Second workflow: Brew list, detail and progress

Brew is checked as a shape, without a finished Plugin (#68 asks for one
credible second workflow). The reviewed Homebrew operations are #72/#87/#88;
Progress is #81. The fixtures are
[`answers/brew-list.json`](fixtures/answers/brew-list.json),
[`answers/brew-detail.json`](fixtures/answers/brew-detail.json) and scenario
[`13-brew-list-detail-progress`](fixtures/scenarios/13-brew-list-detail-progress.json).

| Brew need | Same shape | Gap |
| --- | --- | --- |
| Installed / outdated / search all, with a search field | Page `packages`: a row with `text_field` `query` (collection `packages`) and `choice_field` `scope`; a `list` with title, description as `subtitle`, version or "Outdated" as `accessory` | None |
| Hundreds of results ("lib": 777) | `has_more` / `load_more` in batches of about 150 items | None |
| Open a package's details | Default item action `details` → `item_action` → answer page `package:wget` | None |
| Install, upgrade on the right packages only | Secondary item actions with per-item `actions`; the answer to `item_action` requests a reviewed task (#70's illustrative `start_task`) | The task kind itself is #88's |
| Back to the list as the user left it | The Plugin answers page `packages` again; page memory restores query, selection and scroll | None; no Host Back or page stack needed |
| Progress while installing, without disturbing typing | A Progress component (#81) on the detail page, updated by `operation_finished` or a source delivery (#71); the kept `text_field` and selection are untouched by those answers (5.4) | Progress and sources are #81/#71 |
| Copy the package name | Secondary `clipboard.write` item action on `text` | None |

What Brew adds to the design: per-item action availability (`item.actions`),
page memory for list → detail → list, and the rule that non-typing answers
never disturb typing. What it does not need: grids, sections or a second
collection. The same tree serves both, so the shape is not Emoji-specific.

## 10. The first new UI contract

### 10.1 Grouping

#68 groups three things into the first new UI contract, with no stable
promise for part of it. This design proposes:

| Part | Where it is specified | Candidate |
| --- | --- | --- |
| Stable input, page/component identity, reset, collections | This proposal | `collections` r1 |
| Repeated configured calls into the existing session (#78) | Event `called` and the provenance rules here (5.6); queueing, ordering, Settings/overrides and commit rules stay #78's | `collections` r1 |
| Execution-time frontmost insertion on every path, Host-shown target | #70's proposal | `host_operations` r1 |

`collections` r1 **requires** `host_operations` r1 (#75's `requires`), so no
Plugin can use pages without the new insertion rules, and both are proved
together on #79's Host B. Both also require the draft `namespaces` r1 (#99),
whose catalogue IDs name every operation a page action, an item action or a
request performs. Promotion assigns all three to the next stable Level in
one Host change; none is promoted alone. `host_operations` may still be
declared without `collections`, for #76's work and fixtures, but it is not
promoted without it.

Why repeated calls belong to `collections` rather than a third candidate:
the Level 1 rule (an explicit call restarts with `event: null`, replaces the
Action and drops queued events) can be replaced only once events have page
provenance, which only pages give. The `called` event (`{type: "called"}`,
with the new Action's input in `input` and the session's last good `state`)
is the entry point #78 implements; whether the session keeps its page is
the answer's business, by page ID.

Interaction with `host_operations`:

- `item_action` joins #70's gestures: its answer may carry `operation`.
  Emoji answers Return with `{"operation": {"perform": "selection.replace",
  "input": {"text": "😀"}, "closes_view": true}}` and no page, so nothing is re-described, and
  records the emoji in Plugin Storage for its Recent section.
- `shows_insertion_target` is a page member; the target line is also drawn
  for a collection with a `selection.replace` item action (6.5). The displayed
  target is captured with the gesture: Return, double-click or the
  context-menu choice.
- A double-click in the non-activating panel does not change the frontmost
  App, so the target shown is still the user's App.

### 10.2 Not in this contract

Nothing below is scheduled by this proposal: dirty drafts and leave
confirmation, page stacks, Back and local dialogs (page memory is not a
stack); several Forms per page; absolute layout and Plugin-owned resize
(Q20/Q26); reusable styles and custom colours, fonts, backgrounds (#81);
images and icons (#81); Progress (#81); Host-run sources (#71); multiple
selection; selection-change events; drag and drop; Host-side filtering;
focus requests; per-item free-form values; the rest of Q30's starting
catalogue. Each needs its own evidence and candidate revision.

## 11. Verification for #77 and #79

Protocol behaviour is checked at the external test-kit seam: answers read
as the Host reads them, events produced by recorded gestures, and the
scenarios in [`fixtures/scenarios/`](fixtures/scenarios/), which state their
manifest declarations. Native behaviour needs the actual Host and cannot be
proved by fixtures:

| Check | Where |
| --- | --- |
| Pinyin and Japanese composition in the search field with answers arriving mid-composition; Return, Up/Down, digits and Escape taken by the candidate window; no event for marked text | Actual Host, #77; Chinese IME was not run in E1 |
| Printable-key redirect from the grid into the field starts a composition correctly (C3) | Actual Host prototype, #77 |
| Refresh, same-page move, kind change, reset, page change with page memory: caret, selection, scroll, focus | Actual Host and test kit |
| Grid keyboard roles, double-click, context menu, ⌘C, no Host buttons below a collection, the non-interactive target line, VoiceOver labels and custom actions | Actual Host, #77 |
| Insertion target captured at Return, double-click and menu; target change refused (#70) | Actual Host, #76/#79 |
| Typing p95 and helper memory with 200-item pages; load-more to 1,906; Host memory with 2,000 items | Real helper and Host, #77, with `measure-emoji.js` as the payload baseline |
| Level 1 Plugins: Emoji 1.1.0, Translator and Smart Jump unchanged on the candidate Host | Existing regression baselines |

## 12. Product choices decided by the user

Each choice was returned to the user with a recommended default. The user
decided all nine on 2026-10-03: eight as recommended, and C6 changed.

| # | Question | Decision (2026-10-03) | Why it was a product choice |
| --- | --- | --- | --- |
| C1 | Return pressed before the answer to the latest typing has arrived: act on the result shown, or on the first result of what was typed? | **Decided as recommended.** Act on what was typed: Return sends the pending search at once, waits (bounded by that event's deadline) for its answer, then performs the default action on the selection it produced. Double-click and the context menu act on what is shown | Fast typists expect "cat⏎" to insert 🐈; a strict snapshot would insert a result of "ca" |
| C2 | Up/Down in the search field: move the selection while focus stays in the field, or leave arrows to the field and require Tab (Clipboard History today)? | **Decided as recommended.** Move the selection, focus stays in the field; Tab enters the collection for Left/Right | Typing flow versus strict Clipboard History parity |
| C3 | Printable keys while the collection has focus | **Decided as recommended.** Return focus to the search field and type there, if #77 proves it IME-safe; otherwise ignore them | Raycast-like behaviour versus surprise |
| C4 | Escape | **Decided as recommended.** Closes the view, as in every Level 1 view (after any composition) | Some launchers clear the search first |
| C5 | ⌘C with the collection focused | **Decided as recommended.** Performs the selected item's Copy item action when there is exactly one; no other Host bindings for item actions (no ⌘K menu) | It is the only Host-defined item key besides Return |
| C6 | Host selection bar under every collection (selected item, Return action, secondary buttons, insertion target)? Recommended: yes, always shown, not hideable | **Decided, changed from the recommendation.** No Host-drawn quick-action buttons or selection bar below a collection, for every Plugin. Secondary item actions are offered only in the item's context menu (and ⌘C for a `copy_text` item action, C5); Return and double-click run the default. The insertion target #70 requires is shown only in a non-interactive target line at the foot of a page that can insert (6.5) | Consistent Host chrome versus Plugin control of space |
| C7 | New results select their first item | **Decided as recommended.** Yes | Return then works immediately, as in Clipboard History |
| C8 | Multiple selection | **Decided as recommended.** Not in this revision | Clipboard History has it for Delete; neither Emoji nor Brew needs it |
| C9 | May a Plugin that raises its Level to the promoted Level still answer Level 1 `view`? | **Decided as recommended.** Yes, with exactly Level 1's view semantics; pages are opt-in per answer | Otherwise raising the Level forces rewriting every view; see `level1-mapping.md` |

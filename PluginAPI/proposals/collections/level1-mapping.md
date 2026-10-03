# Level 1 views and the proposed pages

Proposal only (#74); see the [README](README.md). This page keeps the
mapping from Plugin API Level 1 apart from the design, as #74 asks. It says
what stays exactly as published, how each Level 1 view element relates to
the proposed page components, and how Emoji's E1 interface becomes its E2
interface.

## What does not change

A Plugin that declares only `api_level: 1` sees nothing of this proposal.
Its views, events and answers are checked against the published
[`plugin-view.schema.json`](../../schemas/plugin-view.schema.json) and
[`view-session.schema.json`](../../schemas/view-session.schema.json), which
refuse `page`, `item_action`, `load_more` and `called`, and keep every rule
of [views.md](../../reference/views.md):

- every answer with a view that does not answer the user's own typing sets
  each field to its `value` (Translator and Smart Jump refill their fields
  from `state` this way);
- presenting again from a Menu runs the script with `event: null`, replaces
  the session's Action and view, and drops queued events;
- `shortcut` on actions, Return choosing the first action without a form,
  Command-Return submitting;
- standard `insert_text` into the App the view came from; the
  `insert_text` Host Service into the App in front.

A Plugin declaring the candidate may still answer `view`. That view keeps
Level 1's view rules above (value replacement, shortcuts, Return), because
its description has no IDs or reset to express anything else. What the
candidate changes for it is session-wide only: insertion follows
`host_operations` r1, and an explicit call arrives as `called` (#78). A
`view` answer counts as a page change to and from a page with no ID.

## Element by element

| Level 1 element | Page equivalent in `collections` r1 | Difference |
| --- | --- | --- |
| `view.title`, `subtitle` | `page.title`, `subtitle` | The page also has `id` |
| Form `text` field | `text_field` | `value` is initial; kept across answers until reset |
| Form `choice` field | `choice_field` | Same |
| Form `multiline_text`, `url`, `toggle` fields | None yet | Keep a Level 1 `view` for such a page |
| `submit_title`, `submit_on_return`, Command-Return | Return in a `text_field` without `collection` sends `submitted` | No submit button; one implicit form per page |
| Field `status`, `accent` | Same members on `text_field` | Updated on every answer without disturbing typing |
| Setting controls, `swap_with` | None yet | Keep a Level 1 `view` |
| Detail section with `text` | `text` component | No automatic Copy button; add a `copy_text` action |
| Detail section with `fetch` (Host-Fetched Section) | None yet | Keep a Level 1 `view`; #71 designs sources |
| `actions`, event action (`id`) | `actions` component, event action | `action_chosen` also carries `values` and `selection`; no `shortcut` |
| Standard actions | Same `perform` kinds in `actions`; `copy_text` and `insert_text` also as item actions | No `shortcut`; insertion follows `host_operations` |
| Return chooses the first action (no form) | None | Return belongs to the focused field or collection |
| `toast`, `close`, `state` | Same | |
| Twenty Detail sections plus twelve buttons as a result list | `list` or `grid` with item actions | Host selection, keyboard, scrolling, load-more |

Promotion question C9 in the design asked whether a Plugin that raises its
`api_level` to the promoted Level may keep answering `view`. The user
decided yes on 2026-10-03, with exactly the semantics above: the Host must keep
them for Level 1 Plugins anyway, so allowing them for later Levels adds no
second behaviour, and an author can move one page at a time.

## Emoji from E1 to E2

| E1 (Level 1, Emoji 1.1.0) | E2 (`collections` r1 + `host_operations` r1) |
| --- | --- |
| Form: `query` text field with status, `category` choice | Row: `text_field` `query` (`collection: "results"`), `choice_field` `category` |
| Six Detail sections "N. name", each with a Copy button | `grid` `results`, 8 columns: every match, paged 200 at a time, sections by category when browsing |
| "Insert X" ⌘1–⌘6 (standard, origin App) | Default item action `insert`: Return or double-click → `item_action` → answer requests `insert_text`, frontmost App at execution, target shown in the page's non-interactive target line |
| "Copy X" ⇧⌘1–⇧⌘6 (standard) | Secondary item action `copy` (`copy_text`): context menu and ⌘C (C5); no Host button (C6) |
| Return copies the first result | Return inserts the selected result; the selection starts on the first |
| No usage tracking | The `item_action` answer records the emoji in Plugin Storage for a Recent section |
| Results capped at 6 | All matches reachable; at most 2,000 per collection |

## Keeping the renderer single

The Host need not grow a second renderer. A Level 1 view maps onto the same
components (title, fields, text blocks, an action row), with two Level 1
policies applied by declaration and answer type: its fields are reset by
every answer that does not answer the user's own typing, and its buttons
take their shortcuts and Return rule. How the Host shares code is #77's
choice; this table only fixes the public behaviour on both sides.

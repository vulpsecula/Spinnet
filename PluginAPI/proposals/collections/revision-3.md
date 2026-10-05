# Design record: `collections` revision 3

Status: published as
[`../../candidates/collections/r3/`](../../candidates/collections/r3/reference.md)
on 2026-10-05, beside revisions 1 and 2, which stay provided. It answers the
findings of the external Emoji proof's second stage (E2, Spinnet #79,
`SpinnetProbes/emoji` PROOF-E2.md findings 1 to 4), which the user asked to be
fixed before any promotion to a stable Level. Findings 1 and 2 also need
[`host_operations` revision 2](../bounded-host-operations/revision-2.md),
which revision 3 requires.

## 1. Large grids: a window of items

**Evidence.** Scrolling through all 1,906 emoji of the fully loaded grid grew
the Host 56 to 60 MiB, of which 19 to 38 MiB stayed after the view closed
(finding 4). Paging only appended (`load_more`), so a user who scrolled far
made the Host hold, and the Plugin re-send, everything before.

**Decision.** A collection may give its `total` (at most 2,000, the existing
item bound) and one slice of its items from `start`; its sections become
headers that count their items. The Host keeps only the items within two
screens of what is on screen, at most 600, draws placeholders for the rest,
and asks for missing positions within one screen with `load_range {page,
collection, start, count}`, covering the missing positions of the whole
window (about five screens) in one request. `has_more` and `load_more` are
not part of revision 3.

- **One at a time, newest wins.** At most one `load_range` runs per
  collection; a newer one replaces one still waiting, so a fast scroll asks
  only for where it stopped. Page event provenance drops one whose collection
  was reset.
- **No loop.** Positions asked for that did not come are not asked for again
  until the layout changes or the user moves onto one; the test kit stops
  after 64 changing answers.
- **Answers to other events.** The Plugin does not know the Host's screen,
  so an answer to typing, a gesture, `called` or `operation_finished` gives
  the slice it chooses. Where the total and sections are unchanged, items it
  does not give stay shown but are refreshed by a `load_range` for the
  screen; where they changed, positions mean something else, so only the
  slice is kept and the screen is asked for again (placeholders show
  briefly). Rejected: an event member carrying the Host's screen to every
  answer, which would leak more Host state for one round trip saved.
- **Selection.** Kept by item ID with the item as last held, so Return, the
  menu and ⌘C act on it even when the window let it go. Moving onto a
  placeholder selects the position and asks for it; until the item comes,
  Return and ⌘C do nothing (rejected: waiting and acting later, which would
  act on an item the user never saw).
- **Views.** The Host draws every collection, of any revision, with an
  AppKit `NSCollectionView` whose cells are reused, instead of SwiftUI's lazy
  grid and stack, which kept views and their glyph renderings for every row
  passed. Every behaviour of revision 2 is kept: Host-drawn selection
  focused or not, click, double-click and Return for the default item
  action, a context menu of item actions only, ⌘C, the keyboard roles and
  the search field's priority, pinned section headers, the cell's title as
  its tooltip, VoiceOver labels, custom actions and selected state, no focus
  ring, and items laid out clear of a legacy scroll bar. Revisions 1 and 2's
  "Loading more…"/Retry row is the collection's footer.

**Measured** (debug build, the Host's synthetic 2,000-item grid, the same
steps on both Hosts: open, 60 moves, End, back to the top by Page Up):

| Host | Shown | After every row | After close | Second session | Move p95 |
| --- | --- | --- | --- | --- | --- |
| Before (SwiftUI) | +13.2 MiB | +56.4 | +35.2 | +11.4 | 47.4 ms |
| After, whole grid | +10.4 | +25.2 | +25.6 | +6.8 | 66.3 ms |
| After, window | +9.6 | +27.2 | +26.7 | +5.9 | 49.9 ms |

With one symbol for every item, the window's growth after every row is
14.4 MiB (before: 40.4), so about 12 MiB is the emoji glyphs themselves.
The objects alive after close grow 1.5 MiB (class and method caches, by
`heap`); the rest of the footprint kept after close is pages the allocator
holds and the next session reuses. `load_range` over the real helper
(release): p95 21 ms with 6 KB answers, against `load_more`'s 134 ms with
answers up to 94 KB. No budget changed.

## 2. Per-item action lists: toggles and marks

**Evidence.** Offering one of "Add to Favourites" and "Remove from
Favourites" per item cost about 42 bytes per item (finding 3).

**Decision.** An item action may name a mark it toggles (`toggle`, an ID of
at most 32 characters); items carry `marks`. The action delivers
`item_action` like any event action, its snapshot carrying the marks as
shown, so the Plugin knows which way the user went; the context menu shows
it checked for a marked item and VoiceOver reads "checked" or "not
checked". The Plugin keeps the data and may refuse. A toggle performs
nothing; two toggles of one collection name different marks; an item may
carry only marks its collection names.

Per-item `actions` stays valid (conservative choice): a Brew-shaped list
still needs "Upgrade only when outdated", which is availability, not a
state. The reference discourages it where a toggle says the same.

## 3. Outcomes of what the Host performs

**Evidence.** ⌘C performs a Host-performed Copy item action that emitted no
event, so a Plugin could not count copies without giving up ⌘C
(finding 2).

**Decision.** A page action or performed item action may set `notify`; its
outcome reaches the Plugin as `operation_finished`, an item action's with
`item`, the same snapshot `item_action` carries. It holds the Plugin's
operation slot like the action, so two ⌘C are heard in order. With
`closes_view` and a view that closed, `host_operations` r2 delivers it after
the close. An event item action takes no `notify`.

## Decisions returned to the user

- `total` stays within 2,000 items (the existing bound); a larger total is
  left for a later revision with its own measurements.
- Per-item `actions` stays valid but discouraged.
- A selection waiting for its item ignores Return and ⌘C.
- After a layout change the screen shows placeholders until its range comes.

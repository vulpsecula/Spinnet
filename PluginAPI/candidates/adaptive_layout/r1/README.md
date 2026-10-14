# Adaptive card layout, revision 1

This **Candidate Contract**, `adaptive_layout` r1, requires `api_level: 2` and
`candidate_contracts: [{"name":"adaptive_layout","revision":1}]`. It is not a
stable Level 2 addition. Installation, registration and every run require this
exact candidate revision; an older or mismatched Host refuses the Plugin.
Bundled Plugins cannot declare candidates. Promotion remains outstanding.
Validation includes public protocol/test-kit
checks, the complete independent System Monitor package and changed native UX;
a passing fixture or synthetic panel alone is not product acceptance.

[Declaration](candidate.json), [schema](adaptive-layout.schema.json),
[types](adaptive-layout.d.ts), [SDK](adaptive-layout.js), [fixtures](fixtures/index.json).
The test kit's `PluginTestHelper(contracts: .host)` and `PluginTestPage` use the
same declared candidate checks as the Host; pin their exact candidate revision.
Import this revision's types instead of augmenting stable types globally.

```js
const c = spinnet.ui.components;
spinnet.ui.showPage(spinnet.ui.page({id: "metrics", title: "Metrics", resizable: true,
  content: [c.adaptive({id: "cards", minCardWidth: 280, spacing: 12, maxColumns: 2,
    content: [c.column({id:"cpu",content:[c.text({id:"cpu-value",text:"CPU"})]}),
              c.column({id:"memory",content:[c.text({id:"memory-value",text:"Memory"})]})]
  })]
}));
```

`adaptive` is a top-level layout container of **identified components**, each
child acting as a card. Its content accepts Leaf, Row or Column; no Collection,
Activity List, or Adaptive inside, including through a nested Row or Column.
All components count toward the existing 40-component page budget. Adaptive,
Row and Column together nest at most 3 deep. Row/Column rules do not change.
A card keeps its ID, Immediate State, focus and source bindings as it moves.
The Host does not regroup it into new parent views. Reflow runs no Plugin script,
samples no new source and sends no size or layout event. Existing source
visibility, cadence and change-gated delivery rules remain in force.

There are 1–8 children, matching Column's existing 8-child budget. `min_card_width`
is 160–600 points (default 200); `spacing` is 0–24 points (default 12), the gap in
both axes; `max_columns` is 1–4 (default 4). The Host fits as many equal-width
cards as the actual content width permits, up to that maximum and child count.
It uses at least one column, even if the viewport is narrower than the desired
minimum. That minimum is a desired width, never a reason to overflow a panel.
Rows take the tallest card's measured height; text can wrap and grow vertically.
Cards retain declaration order, with no sorting, item selection or `load_range`.
These are not Collection Grid columns or square cells. Styles belong to each
child (for example a styled Column); the Adaptive container has no style field.

The existing 412-point content width fits two 200-point cards with a 12-point gap;
160 permits small labelled cards while 600 allows one descriptive card until a
wider panel is available. Four columns and eight children bound row work within
40 total components; spacing shares the existing 0–24-point padding scale. Use a
larger minimum such as 280 or 320 for multi-line metric cards. Exact native
measurement evidence and limits are recorded in `fixtures/measurements.md`.
These bounds are pinned by `AdaptivePageBudgetsTests` and enforced by parser,
schema and native renderer. A resizable page declares `resizable`; Pin affects
floating and remembered geometry, not layout policy. A fixed page still lays
out its available width; resize scripts, absolute layout, canvas and charts
remain outside this revision.

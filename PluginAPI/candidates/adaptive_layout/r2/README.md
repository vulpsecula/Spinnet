# Viewport fitting and passive content density, revision 2

Declare `api_level: 2` and `candidate_contracts: [{"name":"adaptive_layout","revision":2}]`.
This exact Candidate Contract adds `adaptive_viewport_fit` beside the adaptive
component. It does not promote a stable Level. The Host still provides revision
1 unchanged. Installation, recovery, registration, runtime and helper entry
check the exact declaration; a stable-only or r1 Plugin cannot use `fit`.
Bundled Plugins cannot declare candidates. Use a commit-pinned public kit and
helper; neither a Git tag nor a frozen two-round workflow is required.

[Declaration](candidate.json), [schema](adaptive-layout.schema.json),
[types](adaptive-layout.d.ts), [SDK](adaptive-layout-r2.js), [fixtures](fixtures/index.json),
[native measurements](fixtures/measurements.md).

```js
const c = spinnet.ui.components;
const cards = c.adaptive({id:"cards", maxColumns:2, content:[
  c.column({id:"cpu",style:{padding:8,background:"gray"},content:[
    c.text({id:"cpu-label",text:"CPU · all cores"}),
    c.text({id:"cpu-value",text:"25%",style:{fontSize:26}})
  ]})
], fit:{profiles:[
  {id:"compact",minCardWidth:180,minCardHeight:80,spacing:8,overrides:[
    {id:"cpu-label",text:"CPU",style:{fontSize:11}},
    {id:"cpu-value",style:{fontSize:20,fontWeight:"bold",monospacedDigits:true}}
  ]},
  {id:"standard",minCardWidth:280,minCardHeight:120}
]}});
spinnet.ui.showPage(spinnet.ui.page({id:"metrics",title:"Metrics",
  resizable:{minWidth:440,minHeight:420},content:[cards]}));
```

Without `fit`, adaptive uses exactly r1's width-driven natural-height rules.
With `fit`, it must be the page's **sole top-level component**. The Host reserves
its actual header, errors and insertion target first and gives the region the
remaining width and height. The Plugin declares ordered profiles from least to
most detail. The Host chooses the last profile whose declared minima fit:
columns are the largest permitted by actual width, child count and `max_columns`;
rows follow declaration order. A profile fits when at least its minimum width
and all row minima plus gaps fit the actual height. If none fits, the first is
the readable fallback. Profiles need not carry any particular names.

For that profile the Host measures real content at its allocated card width.
Each row takes at least the largest measured natural height and its declared
minimum; extra viewport height is distributed equally between rows. Root Row,
Column and Text cards expand before drawing their own backgrounds. Other Leaf
cards occupy their allocated placement but retain their native drawing rules.
A fixed page's initial content region has the existing 460-point default cap;
resizable pages use their actual available height. No fonts are automatically
shrunk, labels truncated or primary content clipped to manufacture a fit.
Declared minima are a Plugin promise, not a guarantee about arbitrary text:
understated minima, long translations, accessibility text scaling or an extreme
shrink can require scrolling with the selected readable profile. Authors should
set a supported minimum size and validate their complete page there. The Host
does not probe alternate text variants by creating duplicate control trees.

There are **1–3 profiles**, and each has **0–40 overrides**, bounded separately
from the unchanged **40 total components** and **3 container levels**. Profile
IDs and override target IDs are unique within their respective list. Profile
`min_card_width` is **160–600 points**; `min_card_height` is **48–600 points**;
`spacing` is **0–24 points**, defaulting to the adaptive's spacing. These ranges
bound native work and reuse r1's readable widths/gaps. Three profiles express
compact, standard and spacious without creating arbitrary breakpoint programs;
48 points permits a short label/value, while 600 supports descriptive cards.
The existing 1 MiB script-answer limit still applies.

An override names an existing **Text descendant of this adaptive region**. It
may replace `text`, replace that Text's complete `style` (ordinary 9–40-point
font and other existing style bounds), and/or set `hidden`. No cascading styles,
extra components, control changes, container hiding or arbitrary scripts are
allowed. Unknown, interactive or out-of-region targets are protocol violations.
`hidden` omits that passive Text from layout/accessibility without removing its
identified view or binding; its containing stack's ordinary gaps still apply.
A live source binding takes precedence over replacement `text`; it cannot be
replaced by a cached literal. The Plugin decides which passive details to hide
and must preserve its required primary information in every declared density.

Every card/control keeps the same identified parent tree across choices.
Immediate State, focus, text/caret and live Host-Run Source bindings persist.
Changing size or profile neither invokes JavaScript nor emits a View Event,
resamples, restarts or schedules another Source loop. Source authority,
visibility and one-second minimum cadence are unchanged. The complete external
System Monitor package and native evidence are separate from user visual
acceptance; synthetic measurements alone do not establish installed UX.

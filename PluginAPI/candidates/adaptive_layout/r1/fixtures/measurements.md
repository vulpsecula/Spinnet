# Native adaptive-card measurements

Measured 2026-10-14 through Xcode MCP, Spinnet-Package / My Mac, using the
real `PluginViewPanelWindow`, source engine and native text field editor.
Test: `AdaptivePagePanelTests.testPanelReflowsCardsWithoutReplacingFieldsSamplingOrInvokingThePlugin`.
This is a synthetic generic card probe, not System Monitor product acceptance.

Two styled Columns, minimum card width 320 pt, gap 12 pt, maximum 2 columns,
12 pt internal padding and 40 pt text were measured. The long bound memory
label was “Memory pressure and available physical memory”. Captured native
content bitmaps were visually inspected: the full label wrapped across three
lines in both widths without ellipsis, horizontal overflow or cropped text.
The taller row grows to its tallest measured card; shorter cards remain at
natural height. Native bitmap output includes the Host header and controls.

| Panel width and height | First native field (x, y, width, height), pt | Second native field | Result |
| --- | --- | --- | --- |
| Default 440 pt width, content-following height | 32, 59, 376, 16 | 32, 174, 376, 16 | One column |
| User-resized 860 × 600 pt | 32, 59, 374, 16 | 454, 59, 374, 16 | Two columns |
| User-resized 440 × 300 pt | 32, 59, 359, 16 | 32, 174, 359, 16 | One column; the page scrolls |

The same native field objects and field editor survived the width changes.
Text entered through the native editor (“retained note”) and its caret at
position 4 survived. Source bindings still displayed the same values. Reflow
kept one source sample and the same scheduled cadence, with no Plugin View
Event; advancing that existing cadence delivered the next bound CPU value
(12% → 25%) without a script invocation. The page had no Collection or
`load_range` and retained ordinary component IDs.

These observations justify choosing 320 pt for a descriptive metric card.
The generic default remains 200 pt: two such cards plus the 12 pt gap fit the
existing 412 pt content width exactly. The permitted 160–600 pt range allows
small labels and descriptive single cards, within the existing resizable
panel's 440–1,200 pt declared minimum width range. One column wins below the
preferred width, so that desired minimum never forces overflow. Gap 0–24 pt
shares the existing style padding scale. At most eight cards, four columns,
three container levels and 40 total components preserve existing bounded
page work. No performance, device/locale breadth, actual System Monitor UI
or end-user acceptance claim follows from these measurements.

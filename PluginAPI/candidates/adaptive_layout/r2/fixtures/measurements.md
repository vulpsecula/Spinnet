# Native viewport measurements

2026-10-14, actual NSPanel/SwiftUI renderer, debug macOS. Generic four-card
fixture mirrors the external metric page structure using an opaque #223344
measurement background, real revision-2 helper/SDK and controlled Host-Run
Source results. NSScrollView document height never exceeds its actual clip
height in these supported outer frames. Connected regions of the drawn card
backgrounds reach all viewport edges within 2 points; they are not wrapper
measurements. Captures were also visually inspected for required labels/values.

| Outer frame | Actual usable region | Density and grid | Actual card extent |
| --- | --- | --- | --- |
| 440 × 420 | 412 × 351 | compact, 2 × 2 | 202 × 171–172 |
| 440 × 700 | 412 × 631 | standard, 1 × 4 | 412 × 148–149 |
| 860 × 420 | 832 × 351 | standard, 2 × 2 | 410 × 169–170 |
| 860 × 650 | 832 × 581 | spacious, 2 × 2 | 408 × 282–283 |
| 1200 × 800 | 1172 × 731 | spacious, 2 × 2 | 578 × 357–358 |

The page declares widths/heights180/80,280/120,320/200 and gaps8/12/16, with
maximum two columns and eight-point card padding. Compact keeps all four labels
and primary values while hiding passive details; standard and spacious restore
context and increase declared value fonts20/26/32. Seven canonical bindings
remain, with ordinary source cadence and no resize delivery.

A generic native text-field probe edited real AppKit text to “retained note”,
kept its exact field/editor objects, selected caret4, focus and text through
compact/standard/spacious changes, then received the existing Source's next
25%→50% sample without extra invocation, sampling or timers. A contradictory
48-point minimum and an extreme440×160 frame retained readable content with
actual scrolling, without dropping the field or required metrics. These are
native automated probes, not final human acceptance of the installed Plugin.

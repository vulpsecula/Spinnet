# Historical adaptive layout evidence

These are synthetic native observations from 2026-10-14, before Level 3
promotion, on debug macOS builds. They are regression rationale, not current
release or installed System Monitor acceptance.

`AdaptivePagePanelTests` exercised the real panel, Source engine and native
field editor. Width changes 440 → 860 → 440 pt changed one/two/one columns;
the same field/editor objects, text, caret position 4 and source cadence
survived without a resize event or new Plugin invocation. Long labels wrapped
without ellipsis or horizontal overflow. The default 200 pt card width lets
two cards and a 12 pt gap fit 412 pt content; the 160–600 pt range allows small
and descriptive cards without requiring overflow. Eight cards, four columns,
three container levels and 40 page components bound page work.

The viewport probe measured drawn card backgrounds, not wrappers, within
2 pt of usable edges. Outer frames 440×420, 440×700, 860×420, 860×650 and
1200×800 selected compact/standard/standard/spacious/spacious profiles;
usable regions were 412×351, 412×631, 832×351, 832×581 and 1172×731 pt.
Seven canonical bindings survived density changes. Compact hid passive detail,
never controls; ordinary source delivery continued. A contradictory 48 pt
minimum and 440×160 frame kept required metrics and the real field readable
through scrolling. Field/editor identity, text, focus and caret survived
profile changes without extra source sampling or timers.

The existing native adaptive panel tests preserve these failure modes. These
observations do not establish performance, VoiceOver, device/locale breadth
or human acceptance of the installed Plugin.

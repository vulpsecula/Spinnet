# Adaptive cards and viewport fit

`spinnet.ui.components.adaptive` lays out 1–8 identified cards, using a
160–600 pt desired minimum width, 0–24 pt spacing and at most four columns.
Optional `fit.profiles` declares bounded passive density profiles, ordered
from least to most detailed. The Host selects a profile from available width
and height, distributes remaining height, and retains readable overflow
below the supported minimum. Profiles may override existing passive text,
style and visibility; they cannot supply replacement trees, hide controls,
run a resize script or receive a resize event. Component identity and page
state rules remain those of current. See the [schema](../schemas/adaptive-layout.schema.json)
and [valid/invalid fixtures](../fixtures/adaptive-layout/index.json).

Native regression tests exercise responsive card layout, readable overflow and
preserved field/editor identity, text, caret and source cadence across size and
density changes. They do not establish current performance, VoiceOver coverage
or acceptance of an installed Plugin.

### Adaptive layout bounds

There are 1–8 children in an adaptive container. `min_card_width` is 160–600 points (default 200).
`spacing` is 0–24 points (default 12); `max_columns` is 1–4 (default 4).
Viewport fit declares 1–3 profiles, each with 0–40 overrides and a
`min_card_height` of 48–600 points. Page-wide component and container-depth
bounds still apply; profiles never introduce replacement components.
The [card fixtures](../fixtures/adaptive-cards/index.json) also cover
adaptive containers without viewport fit.

# Host-run sources (Plugin API Level 2) — DRAFT

> Proposal only (#71). This is the reference page #82 would publish as
> `PluginAPI/reference/sources.md` when it appends Host-run sources to
> Level 2. Nothing here is offered yet. Numbers marked *(Q)* wait on the
> product choices in [`design.md`](design.md#14-open-product-choices).

A Level 2 page may declare **sources**: catalogue operations the Host
performs for the page while it is visible, once or every few seconds. The
Host shows each source's latest result in the `text` components bound to
it, without running the script, and hands a result to the script only when
the page asks and a value it watches changes. Nothing runs for a view that
is hidden or closed, and the helper may retire while the page keeps
updating. Everything in [pages](../../reference/pages.md) still applies.

```js
const ui = spinnet.ui, c = ui.components;
ui.showPage(ui.page({
  id: "monitor", title: "System Monitor",
  sources: [ui.source("metrics", "system.metrics", { metrics: ["cpu", "memory", "disk", "battery"] }, { every: 2 })],
  content: [
    c.row({ id: "top", content: [
      c.text({ id: "cpu", title: "CPU", text: "—", bind: c.bind("metrics", "/cpu/busy", { format: "percent" }) }),
      c.text({ id: "memory", title: "Memory used", text: "—", bind: c.bind("metrics", "/memory/used_bytes", { format: "bytes" }) })
    ] })
  ]
}), { state });
```

(`system.metrics` is #86's; at first only `http.request` is offered.)

## Sources

`page.sources` holds up to 8 sources, each `{id, perform, input, every?,
deliver?}`, with distinct `id`s:

| Member | |
| --- | --- |
| `perform` | A catalogue ID offered at the `source` entry point: `http.request` |
| `input` | That operation's input: for `http.request` an `https_request` input, Credential Uses included, held to the same rules as it is sent |
| `every` | Seconds from the end of one sample to the start of the next; at least 1, and at least the operation's own minimum (`http.request`: once only *(Q5)*). Absent: once while the page is visible |
| `deliver` | `{}` or `{pointer}`: deliver results to the script (below). Absent: the script never sees them |
| `error_pointer`, `status_messages` | `http.request` only: what a bound component shows for a failed response, as a show section's |

A source the Host would not run (an operation not offered as a source, an
input its schema refuses, `every` too small) ends the View Session as a
protocol violation. A request refused when it is sampled (an unconsented
host, a denied Capability) fails only that source.

`http.request`'s result as a source is its usual result plus `json`, the
body parsed when it is JSON. A source never answers from the 10-minute
response cache.

## When the Host samples

A page is **visible** while its View Session is open, it is the page on
screen, its panel is on screen and not covered (another window, another
Space), and the user's session is active with the displays awake. Only a
visible page's sources sample.

- One sample at a time per source; the next starts `every` seconds after
  the last ended. Each sample has a deadline (`http.request` 15 seconds)
  and counts as failed with `timed_out` past it.
- Hiding the page cancels samples in flight; showing it samples at once.
  Time hidden is not made up.
- Authority is read when a sample starts and again before its result is
  shown or delivered: the Command's declared Capability, the grant, the
  consented hosts, the System Permission.
- A sample never asks the user anything: no System Permission prompt and no
  confirmation. Where one is needed, the source fails with a reason whose
  repair is something the user clicks.

## Bindings

A `text` component with `bind: {source, pointer, format?, unavailable?}`
shows, as plain text, the value at `pointer` in the source's latest result,
in place of its `text`, which shows until the first result. `format` is
`text` (default), `integer`, `decimal`, `percent` (a fraction 0–1), `bytes`
or `duration` (seconds), in the user's locale. An absent, `null` or
mistyped value shows `unavailable` (default "Unavailable"). At most 4,096
characters show.

Showing a result runs no script, changes no state and keeps the page's
immediate state. A failure shows its message, except that a component with
a last good value keeps it, dimmed and read by VoiceOver as out of date; so
does a value from before the page was hidden, until the next sample.

## Deliveries

With `deliver`, the script receives results as a View Event:

```json
{"type": "source_delivered", "page": "player", "source": "playback", "sequence": 14, "result": {}}
```

or with `failure: {category, message}` in place of `result`.

- The first result after the source starts is delivered; after that, only
  a result whose value at `deliver.pointer` (the whole result without one)
  differs from the last delivered, and a failure whose category differs.
- At most one delivery per source every 15 seconds *(Q2)*; a later result
  replaces one still waiting.
- It is no gesture: its answer may not request an operation.
- It runs only while its page and the source's definition are still the
  ones on screen; otherwise it is dropped and never delivered again.

## What is kept

When an answer keeps the page (same ID, no page reset) under the same
Command, a source whose `id` it keeps with an equal definition (`perform`,
`input`, `every`, `deliver`, `error_pointer`, `status_messages`) keeps
running as it was: no new sample, the same cadence, its last result shown,
its waiting delivery. Anything else starts afresh; a source the answer
leaves out stops. An Explicit Call of the same Command keeps equal sources
whatever its overrides; a call of another Command that commits a page
stops every source, as it ends Host-Fetched Sections. Storing or removing a
stored credential starts again every source whose input uses one.

A source started or changed by the answer to a `source_delivered`,
`load_range`, `field_changed` or `operation_finished` waits its minimum
interval before sampling, and the delivery limit holds across changes.

Closing the view, the Plugin closing it, updating, disabling or removing
the Plugin, or revoking a Capability it uses ends the View Session and
every source with it; nothing sampled before applies afterwards.

## Not offered

Sources on a Level 1 `view` (which keeps Host-Fetched Sections), samples
for a hidden or closed view, a source the Plugin starts without a page, a
Plugin-chosen notification, file, process or event stream, a schedule that
runs the script on time alone, and anything a source changes on the Mac:
sources only read. Keep-awake effects and reviewed tasks have lifetimes of
their own.

## Budgets

8 sources per page, one sample in flight per source, one delivery waiting
per source, 4,096 characters per bound text; `http.request` keeps its
128 KiB response and 15-second budget, and a delivery counts against the
1 MiB helper message, 64 KiB of state and the four-second deadline like any
View Event.

## The test kit

`PluginTestPage` runs sources from recorded samples (`RecordedHostSources`)
on a virtual clock: `advance(by:)` fires due samples and deliveries,
`hide()` and `show()` change visibility, `revoke(_:)` and
`storeCredential(_:)` change authority and secrets. `shown(component:)`
reads what a bound component shows and whether it is stale, `samples` lists
each sample started, and `deliveries` each `source_delivered` run or
dropped with why. Deliveries run in the real helper.

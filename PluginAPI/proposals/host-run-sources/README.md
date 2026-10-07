# Proposal: Host-run sources for visible Plugin Views

> **Status: design proposal for issue #71, 2026-10-07; not offered by any
> Host.** It drafts a later **Plugin API Level 2 addition**, which #82
> implements by appending it to Level 2 (Level 2 is still open,
> [`../../README.md`](../../README.md#plugin-api-level)). It is not a
> Candidate Contract and declares none. Seven product choices in
> [`design.md`](design.md#14-open-product-choices) are open; the drafts
> assume the recommended options.

Level 1, Level 2 and their reference pages, schemas and fixtures one and two
directories up are unchanged by this proposal. Where these drafts reference
a published schema or the catalogue, they do so by relative path, so the
proposal is checked against the definitions it extends.

## What it proposes

A Level 2 page may declare up to 8 **sources**: catalogue operations
offered at the catalogue's `source` entry point, which the Host performs
for the page **only while it is visible** (session open, page on screen,
panel not covered, the user's session active), once or every few seconds,
one sample at a time. A `text` component may **bind** to a source: the
Host shows the value at a JSON pointer in its latest result, formatted as a
percentage, bytes, a duration and so on, without running the script. A
source with `deliver` also hands results to the script as a
`source_delivered` View Event, but only when the value it watches changes,
at most once per delivery floor, coalesced to the latest. So a System
Monitor runs no script after its page is drawn, a Spotify page runs its
script about once per track, and a hidden or closed view costs nothing.

A source's definition holds everything that decides what it reads, under
what authority and when; an answer that keeps the page, the Command and an
equal definition keeps the source, which is Host-Fetched Sections' rule
(same Command, same `id` and `fetch`) extended. Authority is read when a
sample starts and again before its result applies. Deliveries carry page
and source provenance and are dropped, never redelivered, when either
changes. Sources share owner invalidation and cancellation with Coffee's
effects and Brew's tasks (ADR 0017) but not their lifetimes.

`http.request` is the first operation offered as a source (#82, once only
at first); `system.metrics` (#86) and Spotify's playback read (#85) follow
as adapters with their own minimum interval, deadline, result and failure
vocabulary. Fixtures using them are marked illustrative.

## Files

| File | Contents |
| --- | --- |
| [`design.md`](design.md) | The design: baseline in Host code, the three workloads compared, visibility, sampling and coalescing, bindings, deliveries, adapters, identity and retention, provenance, limits, effects and tasks, verification, open product choices |
| [`reference.md`](reference.md) | A draft of `reference/sources.md` as #82 would publish it |
| [`host-run-sources.schema.json`](host-run-sources.schema.json) | Draft JSON Schema (draft 2020-12): the page's `sources`, a text component's `bind`, `source_delivered`, and illustrative metrics and Spotify sources |
| [`host-run-sources.d.ts`](host-run-sources.d.ts) | Draft types and proposed builders (`ui.source`, `components.bind`, `spinnet.http.request.source`); not type-checked here (no `tsc` on the measuring Mac) |
| [`level-2-addition.json`](level-2-addition.json) | What #82 appends to Level 2: members (a new `source` member kind among them), catalogue entries and builders, and what #85 and #86 add later |
| [`measurements.md`](measurements.md) | What was measured (metric read costs, Spotify's Automation state) and the scenarios #82, #85 and #86 measure |
| [`measure-metrics.swift`](measure-metrics.swift) | The measurement program; sends no Apple Event and launches nothing |
| [`fixtures/`](fixtures/index.json) | Valid and invalid answers and events, and 12 behaviour scenarios written as test-kit steps |
| [`check.py`](check.py) | Checks the schema, every fixture and scenario against it and Level 2's published pages schema, the Host's checks beyond shape, and the addition against the catalogue |

Run the check with `python3 PluginAPI/proposals/host-run-sources/check.py`.
Like the other proposals' checks it implements only the JSON Schema subset
of Spinnet's `JSONSchemaSubsetValidator`. Host-internal design (the
scheduler, adapter protocol and visibility observers) belongs in the
Host's design notes under `docs/`, not in `PluginAPI/`; design section 13.1
names only the seams the test kit stands on.

## Proposed glossary entry

**Host-Run Source**:
Part of a Plugin API Level 2 page: a Host Service the page names for the
Host to perform while the page is visible, once or repeatedly, whose latest
result the Host shows in the components bound to it and, when the page
asks, delivers to the Plugin when it changes. It reads only, never outlives
being seen, and is not a schedule. A Host-Fetched Section is the Level 1
form of it for HTTPS.
_Avoid_: Subscription, timer, polling, background refresh, live query

## Found on the way

The response cache keys an answer by a credential's reference, not its
secret (`Sources/SpinnetCore/FetchedResponseCache.swift`), and storing a
new secret neither clears the cache nor restarts a kept Host-Fetched
Section, while a grant change clears the cache. A Level 1 section can
therefore show an answer fetched with a replaced key for up to 10 minutes
(cached) or for the rest of the view (kept). Sources avoid it with a
credential generation (design section 8); Level 1 needs its own small fix.

## Relation to other work

- **#82** implements this, with an HTTPS source and a deterministic
  non-HTTP fixture adapter, and publishes the reference, schema, types,
  SDK and test kit.
- **#85** (Spotify) and **#86** (metrics) add adapters and decide Q4 and
  Q3; **#80** (Pin geometry) makes pinned, partly covered views common.
- **#72 / #88** (Homebrew tasks) may offer a task's Host-held status at the
  `source` entry point so a reopened view binds a running task's stage
  (design section 11); the task's lifetime stays its own.
- **#84** (keep-awake) shares owner invalidation and cancellation, not
  lifetime.
- **#81** may let Progress and images bind to sources under its own rules.

## Licence

Like the rest of `PluginAPI/`, these drafts are published under the MIT
licence in [`../../LICENSE`](../../LICENSE).

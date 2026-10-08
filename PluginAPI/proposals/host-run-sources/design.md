# Design: Host-run sources for visible Plugin Views

Issue #71, part of #47, governed by spec #68; it unblocks #82, which
implements it, and through #82 the Spotify (#85) and System Monitor (#86)
adapters. Proposal only; see the [README](README.md) for status. Host
baseline inspected: `c440132`. This is a draft of a later **Plugin API
Level 2 addition** (Level 2 is still open, see
[`../../README.md`](../../README.md#plugin-api-level)), not a Candidate
Contract: #82 appends what is accepted here to Level 2 itself.

Each acceptance criterion of #71 is answered here:

| Criterion | Sections |
| --- | --- |
| Compare HTTPS sections, local Spotify state and basic system metrics; define visibility, sampling/latest-result coalescing, delivery mode, source identity and resource limits | 2, 4, 5, 6, 7, 10 |
| All authority/result-affecting inputs in source definitions; existing same-Command id/fetch rules preserved where equivalent; authority rechecked; invalid, hidden and ended sources cancelled | 8, 9 |
| Page/source provenance for queued deliveries, Settings notifications, stale results and revoke/update/disable/removal; sampling separate from Coffee effects and Brew tasks | 9, 11 |
| Level 2 addition draft and recordable test-kit seams plus measurement scenarios; no helper timer, arbitrary subscription or perpetual script execution | 3, 12, 13, [`reference.md`](reference.md), [`measurements.md`](measurements.md) |

Open product choices are in section 14, each with options and a
recommendation; none is decided here.

## 1. Problem

A View Session keeps no script running (ADR 0010). Each View Event is a
bounded invocation, and the helper retires 30 seconds after its last one
(`ScriptedActionBudgets.helperIdleExit`,
`Sources/SpinnetCore/ScriptedActionBudgets.swift:29`). So a Plugin View
cannot change by itself: nothing runs to change it. Three probe workloads
need it to:

- **System Monitor** (#86, #92): CPU, memory, disk capacity and battery,
  refreshed while the view is visible and never otherwise (#68 user story
  24).
- **Spotify** (#85, #91): the local player's state and current track, with
  precise not-installed, not-running and Automation errors (story 23).
- **Remote text**, which Level 1 already has once per view: Host-Fetched
  Sections (`PluginAPI/reference/views.md`, "Host-Fetched Sections").

#68 rules out the obvious answers: no resident Plugin runtime, no helper
timer, no background schedule, no arbitrary subscription, and no perpetual
script execution (`PluginAPI/README.md`, "What Spinnet will not offer").
What is left is the shape Host-Fetched Sections already have: the Plugin
describes, as data, something for the Host to read, and the Host reads it,
shows it, and only when asked hands it to the script.

## 2. Baseline: Host-Fetched Sections today

A Host-run source generalises Host-Fetched Sections, so their exact rules
are the baseline (`Sources/SpinnetCore/HostFetchedSections.swift`):

| Rule | Where |
| --- | --- |
| A Level 1 Detail section `{id, fetch}` names an `https_request` input and `mode: show` (Host extracts a string at `pointer`) or `deliver` (response handed to the script as `section_delivered`) | `HostFetchedRequest.init(parsing:)` |
| Sent once per section; all of a view's sent at once; at most 8; 15 s each | `present(_:for:)` line 419, `HostFetchedSectionBudgets.maximumSections`, `ScriptedActionBudgets.hostFetchedSectionDeadline` |
| Kept while `id` and the whole `fetch` are unchanged; a changed `fetch` is sent afresh; a section that left the view is cancelled | `present(_:for:)` line 427 |
| Sent under the Action that presented the view (`session.action`), authority read afresh for every send: Plugin enabled, the Command declares `contact_https`, the grant and its consented hosts | line 450; `CapabilityCheckedHostServiceBroker.sendHostFetchedRequest`, `Sources/SpinnetCore/PluginCapabilities.swift:1024`, and `authorize(_:for:action:)` line 787, whose Capability check is per Command (line 798) |
| Another Command handling the view ends every section: presenting again (`PluginViewSessions.actionAnswered`, `PluginViewSession.swift:844`) and an Explicit Call that commits (`handOver(to:)`, line 582) | `commandChanged` |
| A delivery dropped with the view it was meant for is delivered again to the view that replaces it; after the session ends nothing is | `abandonEvents()`, `HostFetchedSections.delivery(of:...)` |
| Ending the session (close, Plugin update/disable/removal, any revocation) cancels sections and drops late answers | `PluginViewSessions.observe(registry:grantStore:on:)`, line 783; `end(pluginID:)` |
| `cache: true` answers the same request from the last 2xx answer for 10 minutes; any grant change clears the cache | `FetchedResponseCache`; `Sources/SpinnetHost/main.swift:298`, `:306` |

Three things the baseline does not do, which sources must:

1. **Repeat.** A section is read once.
2. **Know whether the view is seen.** Nothing in the Host observes a Plugin
   View panel's occlusion; the panel is `.singleDesktop` and only an
   unpinned one closes on losing focus (`Sources/SpinnetHost/PluginViewPanel.swift:71`,
   `Sources/SpinnetHost/PluginViews.swift:504`). A pinned view stays open
   behind other windows, on another Space, under a locked screen.
3. **Read anything but HTTPS.**

One gap in the baseline itself bears on source identity (section 8): the
response cache key holds a credential's *reference*, not its secret
(`Sources/SpinnetCore/FetchedResponseCache.swift:8`, `:42`), and changing a
stored secret in Plugin Settings (`Sources/SpinnetHost/PluginSettingsModel.swift:58`)
neither clears the cache nor restarts a kept section, while a grant change
does. A section kept across answers therefore keeps an answer fetched with
the old secret. It is a small Level 1 issue; this design does not repeat it
for sources and reports it for a separate fix (see the README).

## 3. Vocabulary used here

- **Host-run source** (*source*): a page's declaration of one catalogue
  operation, offered at the `source` entry point, that the Host performs for
  the page while it is visible, once or repeatedly, and whose latest result
  it shows in bound components and, when asked, delivers to the script.
  Proposed glossary entry in the README. *Avoid*: subscription, timer,
  polling job, background refresh, live query.
- **Source definition**: everything about a source that decides what it
  reads, under what authority, and when: section 8.
- **Sample**: one performance of the source's operation; its outcome is a
  **result** or a **failure**.
- **Binding**: a `text` component's `bind` member, naming a source and a
  JSON pointer into its result, which the Host renders without running the
  script.
- **Delivery**: a `source_delivered` View Event carrying one result to the
  script.
- **Visible**: section 5.

The `source` entry point already exists in the catalogue
(`PluginAPI/catalogue.json`, `entry_points.source`: "a Host-Fetched
Section, later a Host-run source (#71, #82)"); `http.request` is offered
there at Level 1 as a section's `fetch.request`, and `system.metrics`
reserves it for #86. This design fills that entry point in for pages.

## 4. Comparing the three workloads

| | HTTPS (`http.request`) | Local Spotify state (#85) | Basic metrics (`system.metrics`, #86) |
| --- | --- | --- | --- |
| Where it reads | A remote service, through the broker with Credential Uses | Spotify's AppleScript dictionary (`sdef /Applications/Spotify.app`, Spotify 1.3.3.264): `player state`, `player position`, `current track` (`name`, `artist`, `album`, `duration`, `id`, `artwork url`, `starred`), `sound volume`, `shuffling`, `repeating` | Mach host statistics, `statfs`, IOKit power sources |
| Cost per sample | Network round trip, remote rate limits; 128 KiB response | One Apple Event per sample, not measured (Spotify not running on the measuring Mac; launching it to measure would change the user's state) | 55 µs p50, 90 µs p95 for the whole snapshot; one disk API costs 22 ms ([measurements](measurements.md)) |
| Authority | `contact_https` per Command, consented hosts per Plugin, Credential Uses | A Capability (`control_external_app` or a new one, section 14 Q4) and the Automation System Permission, decided by macOS per target App | A Capability or none (section 14 Q3); no System Permission |
| Failure modes | Network, status, malformed JSON, timeout | Not installed; not running (an Apple Event would *launch* it, `tell application id`, `Sources/SpinnetHost/AppleEventSender.swift`); Automation not yet asked, denied; operation unsupported; timeout | Value unavailable (no battery, no swap); first CPU sample needs a previous one |
| How results change | Rarely; the service decides | Position every second while playing; track every few minutes; state on user action | Continuously |
| Push available | No | Possibly: Spotify has posted a `com.spotify.client.PlaybackStateChanged` distributed notification; unverified on 1.3.3 (#85) | No (CPU and memory are only sampled) |
| Natural interval | Minutes, or once | 1 s for position, otherwise on change | 1–5 s |
| Result size | ≤ 128 KiB | ~1–2 KiB bounded strings (artwork data excluded) | 340 bytes measured |
| Plugin needs the value in script? | Sometimes (`deliver`) | Rarely: for its own data, such as "favourite" from Plugin Storage on track change | No |

What they share: a definition the Host can perform without the script; a
latest value that matters and history that does not; display that needs no
Plugin logic per update; and authority that must be read again at every
sample. What differs: cost, cadence and failure vocabulary, which belong to
each operation's **adapter** (section 7), not to the source contract.

So one contract fits all three: a page lists sources; the Host samples each
on its own cadence only while the page is visible; components bind to the
latest result; the script hears of a result only when it asks to, and then
only when the value it watches changes.

## 5. Visibility

A source samples only while its page is **visible**. A page is visible when
all of these hold:

1. Its View Session is open and the page is the one on screen (not a page
   held in page memory, and not under a Level 1 `view` that replaced it).
2. Its panel is on screen: ordered in, and its `NSWindow.occlusionState`
   contains `.visible`. This covers a pinned panel behind another floating
   window, on another Space (the panel is `.singleDesktop`), or minimised
   by the system.
3. The user's session is active and the displays are awake: none of
   `NSWorkspace.screensDidSleepNotification`, `.sessionDidResignActiveNotification`
   (fast user switching, lock) is in effect. System sleep stops everything
   anyway.

The Host already knows (1); (2) and (3) are new observers (#82). An
unpinned panel closes when it loses focus, so it is visible for its whole
life unless the screen sleeps; the rule matters for pinned views (#80).

On **becoming hidden**, the Host stops scheduling samples, cancels samples
in flight and drops what they return; bound components keep showing their
last result, marked stale (section 6.3). On **becoming visible again**, each
repeating source samples at once (subject to its minimum interval since its
last sample *start*) and resumes its cadence; a source that samples once
and already has its result does not sample again. Hidden time is not made
up: there is no backlog.

Occlusion can flap during a Space switch or Mission Control. Restarting a
local source costs microseconds (section 10), so the Host does not debounce
hiding; it does honour each adapter's minimum interval on restart, which
bounds the cost of flapping for HTTPS.

A Plugin never learns whether its view is visible (no event, no
`environment` member): visibility is Host scheduling, not Plugin state.

## 6. The page member, bindings and deliveries

### 6.1 Declaring sources

A page may carry `sources`, up to 8 (section 10). Each:

```json
{"id": "metrics", "perform": "system.metrics", "input": {"metrics": ["cpu", "memory", "disk", "battery"]}, "every": 2}
```

| Member | Meaning |
| --- | --- |
| `id` | Unique among the page's sources; components bind to it and deliveries name it |
| `perform` | A catalogue ID whose `source` entry point is offered at Level 2: `http.request` with #82, later `system.metrics` (#86) and Spotify's read (#85) |
| `input` | That operation's input, as its catalogue entry publishes it. For `http.request` it is the `https_request` input, Credential Uses included |
| `every` | Seconds between the end of one sample and the start of the next, at least the adapter's minimum; absent: sample once while visible |
| `deliver` | Absent: the script never sees the result (as `mode: "show"`). `{}`: deliver each result that differs from the last delivered; `{"pointer": "/track/id"}`: deliver when the value there changes |
| `error_pointer`, `status_messages` | `http.request` only, as a show section's: what a bound component shows for a failed response |

A page with sources is otherwise a Level 2 page; a Level 1 `view` has no
sources (it keeps Host-Fetched Sections) and pages still have no Host-Fetched
Sections (`PluginAPI/reference/pages.md`, "Not in Level 2"). A source the
Host would not run (an unknown `perform`, one not offered as a source, an
input its schema refuses, `every` below the minimum) ends the View Session
as a protocol violation, like any page the Host would not draw; a
well-formed source whose request the Host refuses when it samples (an
unconsented host, a denied Capability) fails only that source, as a
malformed `fetch` fails only its section.

### 6.2 Fixed delay and latest-result coalescing

Scheduling is **fixed delay**: the next sample starts `every` seconds after
the previous one *finished* (or failed, or timed out). So a source has at
most one sample in flight, slow services stretch their own cadence instead
of piling up, and there is never a queue of results to coalesce at the
sampling end. Timers carry 10 % leeway so the system can coalesce wakeups.

At the delivering end each source has **at most one delivery waiting** in
the session's queue. A newer result replaces a waiting one in place, as a
newer `load_range` replaces a waiting one (`PluginViewEvent.replaces`,
`Sources/SpinnetCore/PluginViewAnswer.swift:66`); one already running is
answered first. The script therefore sees the latest result, never a
backlog, and a slow script stretches deliveries rather than the queue.

### 6.3 Bindings: shown without the script

A `text` component may bind to a source:

```json
{"kind": "text", "id": "cpu", "title": "CPU", "text": "—",
 "bind": {"source": "metrics", "pointer": "/cpu/busy", "format": "percent"}}
```

The Host shows the value at `pointer` in the source's latest result,
formatted by `format`, as plain text, in place of `text`; `text` is shown
until the first result arrives. Formats, rendered in the user's locale:
`text` (a string, or a number as written; the default), `integer`,
`decimal` (one fraction digit), `percent` (a fraction from 0 to 1),
`bytes` (an integer number of bytes, file-size style) and `duration`
(seconds, as `m:ss` or `h:mm:ss`). A value that is absent, `null` or of the
wrong type shows `unavailable` (default "Unavailable"), which is how a Mac
without a battery shows battery. Bound text is at most 4,096 characters
and cut short beyond.

Showing a result is not an event: no invocation, no change to `state`, no
effect on Immediate State; it may happen while an event is in flight, and a
page answer that keeps the component and its binding keeps the value shown.
A failure shows its message in the bound component, unless the component
has a last good value, which then stays with a **stale** mark: the Host
dims it and VoiceOver reads "out of date". A value is stale too while the
page is hidden and returns, until the next sample. Each bound component's
accessibility label is its title and the shown value.

`show` mode in Level 1 extracts one string at a pointer; a binding is the
same idea with a number format, so a Monitor needs no script at all after
its page is drawn, and its helper retires 30 seconds later while the view
keeps updating (section 13, scenario S9).

Bindings are the extension point for #81: a Progress component may bind its
value to a fraction, and an image its URL, under #81's own rules. Neither is
proposed here.

### 6.4 Deliveries: to the script, only on change

With `deliver`, a result also reaches the script, as a View Event:

```json
{"type": "source_delivered", "page": "player", "source": "playback", "sequence": 14,
 "result": {"state": "playing", "position": 73.2, "track": {"id": "spotify:track:…", "name": "…"}}}
```

or, for a failure, `"failure": {"category": "external_app_not_running",
"message": "Spotify is not running"}` in place of `result`.

- **Change-gated.** The first result after the source starts is delivered;
  after that a result is delivered only when the value at `deliver.pointer`
  (the whole result without one) differs from the last one delivered, and a
  failure only when its category differs from the last delivered outcome's.
  A repeated sample with an unchanged watched value runs nothing.
- **Rate-floored.** Deliveries of one source are at least the **delivery
  floor** apart (section 14 Q2); a change inside the floor waits, and a
  later change replaces it (6.2).
- **Not a gesture.** Like `load_range`, its answer may not request an
  operation, and it does not wait for the operation slot.
- **Answer like any event.** The answer may re-describe the page, change
  `state`, or change the source definitions; Immediate State is kept as for
  any answer.

The script never runs because time passed: it runs because a value it
watches changed, at most once per floor per source, and only while the page
is visible. That is the line #68 draws between a Host-run source and a
helper timer or perpetual execution (section 12).

### 6.5 Level 1 Host-Fetched Sections, mapped

| Host-Fetched Section | Source |
| --- | --- |
| `fetch.request` | `perform: "http.request"`, `input` |
| `mode: "show"`, `pointer` | No `deliver`; a `text` component bound to `/json` + pointer (the HTTPS adapter's result carries the parsed body as `json`, section 7) |
| `mode: "deliver"` | `deliver: {}`, no `every` |
| `error_pointer`, `status_messages` | The same members on the source |
| `cache: true` | Not offered: section 7 |
| Sent while the view is open | Sampled while the page is visible |
| Kept while `id` and `fetch` are unchanged | Kept while the definition is unchanged (section 8) |

Level 1 sections are unchanged; this mapping is how a Level 2 page gets the
same behaviour, and the rules agree wherever both apply.

## 7. Adapters

Each operation offered as a source has a Host **adapter** that fixes what
the contract leaves to it, published with the operation's catalogue entry:

| Adapter property | `http.request` (#82) | Spotify read (#85, illustrative) | `system.metrics` (#86, illustrative) |
| --- | --- | --- | --- |
| Result | `{status, headers, body, json?}`: `http.request`'s result plus `json`, the body parsed when it is JSON | Bounded: `state`, `position`, `volume`, `shuffling`, `repeating`, `track {id, name, artist, album, duration, url}`, strings ≤ 256 characters; never `artwork` image data | `{cpu {user, system, busy}, memory {total_bytes, used_bytes, compressed_bytes}, disk {total_bytes, available_bytes}, battery {fraction, charging, on_ac} \| null}` |
| Minimum `every` | 60 s (Q1) | 1 s (Q1) | 1 s (Q1) |
| Sample deadline | 15 s, as sections | 2 s | 1 s |
| Authority read per sample | As sections: enabled, Command declares `contact_https`, grant, consented host, Credential Uses | Capability, Automation decision read *without asking* (`AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: false)`), Spotify running (checked first; never launches it) | Capability if Q3 says so |
| Failures | `capability_denied`, `host_service_failed`, `timed_out` | `external_app_missing`, `external_app_not_running` (new), `automation_permission_needed` (new, Q4), `automation_permission_denied`, `external_app_operation_unsupported`, `timed_out` | `host_service_failed` (per metric: `null`) |
| Cache | Never answers from `FetchedResponseCache`: a repeating source that hit a 10-minute cache would show the same answer for 10 minutes | None | Shared Host sampler (below) |

Two adapter rules are general:

- **A sample never asks the user anything.** It may not raise a System
  Permission prompt, a Host Confirmation or a consent dialog: a sample is
  not a gesture. Where macOS would prompt (Automation, decided per target
  App), the adapter fails with a category whose repair route is a page
  action the user clicks, which asks. #85 decides the action (Q4).
- **Host-local samplers may be shared across Plugins.** Two Plugins showing
  CPU read the same Host sample; each delivery and each binding still
  checks its own Plugin's authority. Sharing is invisible to Plugins and is
  #82's or #86's engineering choice.

## 8. Source identity and what is kept

A source's **definition** is everything that decides what it reads, under
what authority, and when:

| Input | In the definition as |
| --- | --- |
| Which Plugin (and version) | The View Session's Plugin; an update ends the session |
| Which Command's authority | The session's handler Command; a handler of another Command ends every source (as sections, section 2) |
| Which page | The page ID and page instance on screen; another page, or `reset: "page"`, ends the page's sources |
| Which source | `id` |
| What is read | `perform` and the whole `input`: URL, method, headers, body, Credential Use references, metric list, target App |
| When | `every` |
| What the script hears | `deliver` and its `pointer` |
| What a failure shows | `error_pointer`, `status_messages` |
| Stored secrets the input references | A per-Plugin **credential generation** the Host advances whenever a secret of that Plugin is stored or removed |

Plugin Settings, Menu Item overrides and the Action's input reach a source
only through the `input` and other members the script wrote, so they are in
the definition already. A source never reads Plugin Settings itself. Grants,
consented hosts and System Permissions are not in the definition: they are
**read afresh at every sample start and again before a result is shown or
delivered**, because a sample can take up to 15 s and a decision can change
inside it. Locale and appearance change only formatting.

**Retention.** When an answer keeps the same page (same ID, not reset as a
page) under the same handler Command, each source whose `id` it keeps with
an equal definition (JSON-equal members, credential generation unchanged)
**is kept**: its cadence, its sample in flight, its last result and what its
bindings show, and its waiting delivery. Anything else is a new source,
started from nothing; the one it replaces is cancelled, its sample in
flight dropped, its waiting delivery discarded. A source the answer omits is
cancelled. This is section 2's rule (`id` and whole `fetch` equal, same
Command) with the inputs a repeating, non-HTTPS source adds, and nothing
taken away: where both apply, they agree. A handler change to another Action
of the **same** Command keeps equal sources, overrides aside, exactly as
sections are kept, because authority is per Command and grants per Plugin
(`authorize`, line 798) and overrides change only `input`.

**No self-sustaining restarts.** A new source starts sampling at once only
when it appears in the answer to a presentation, a gesture or an Explicit
Call, or when its page becomes visible. A source that a non-gesture answer
(to `source_delivered`, `load_range`, `field_changed`, `operation_finished`)
starts or redefines begins after its adapter's minimum interval, and every
source ID's deliveries keep the delivery floor across redefinitions. So a
script that answers each delivery with a new definition still runs at most
once per floor per source, and only while visible.

## 9. Provenance, stale results and endings

### 9.1 Deliveries in the queue

A `source_delivered` event is stamped, when queued, with the page instance
and the source instance (its definition generation). At dispatch it runs
only if both are still current; otherwise it is dropped without a run, as
page events are (`PageIdentity`, `Sources/SpinnetCore/PluginViewSession.swift:437`
and the struct at the end of that file). Unlike `section_delivered`
(section 2), a dropped delivery is **not** delivered again: the next sample
of a still-current source supersedes it, and a source that ended has nothing
to say.

| Waiting when … | `source_delivered` | Page events | `called` | `setting_changed`, `settings_swapped` | `operation_finished` |
| --- | --- | --- | --- | --- | --- |
| An answer keeps the page and the source's definition | Runs | Run if their component is current | Runs | Runs | Runs |
| An answer redefines or drops that source | Dropped | (their own rule) | Runs | Runs | Runs |
| The page changes or resets | Dropped | Dropped | Runs | Runs | Runs |
| An Explicit Call commits the same Command, same page and definition | Runs, under the new handler | Run if current | — | Runs | To its requester |
| An Explicit Call commits another Command | Dropped (sources end) | Run if current | — | Runs | To its requester |
| The page becomes hidden | Kept: it describes a result already shown | Kept | Kept | Kept | Kept |
| The session ends | Dropped | Dropped | Cancelled with feedback | Dropped | Per ADR 0018 |

Settings notifications stay deliverable whatever happens to sources: the
Host has already stored the setting. They come only from a Level 1 view's
setting controls (pages have none), so a source and a setting control are
never on screen together; a setting change does not restart a source,
because a source reads no setting (section 8). A Plugin Setting changed in
the Settings window delivers nothing today, to sections or sources alike;
the source keeps the input it was given until the next answer re-describes
it (Q6).

A delivery waiting while the page is hidden still runs: hiding stops
*sampling*, not the session, and the result it carries was taken while the
page was visible.

### 9.2 Stale and late results

A sample's result is **applied** (shown, compared, possibly queued for
delivery) only if, when it arrives: the session is open, the page and source
instances it was started for are current, the page is visible, the Plugin
is enabled, and the authority read at its start still holds. Otherwise it is
dropped without effect, like a late answer to an event. A sample that
outlives its deadline is cancelled and counts as a `timed_out` failure.

### 9.3 Revoke, update, disable, removal

These already end the View Session (`PluginViewSessions.observe`, line
783): any Capability revocation, including narrowing a scope or removing a
consented host (`PluginCapabilityGrantStore.setDecision`,
`Sources/SpinnetCore/PluginCapabilities.swift:253`), and any registry
invalidation (update, disable, removal). Ending the session ends every
source with it: samples in flight cancelled, waiting deliveries dropped,
nothing applied later. A grant *added* while a source is failing for want
of it does not end the session; a repeating source succeeds at its next
sample, and a once source whose last outcome was an authority failure
samples again on the grant change.

Storing or removing a credential advances the Plugin's credential
generation, so every source whose input references a credential is
redefined and starts again (section 8). This does not end the session.

## 10. Resource limits

All numbers below are proposals for #82 to pin in code and in
`DocumentedBudgetsTests`; the measured ones are in
[`measurements.md`](measurements.md) and the rest are labelled as choices.
No existing budget changes.

| Limit | Proposed | Basis |
| --- | --- | --- |
| Sources per page | 8 | Same as sections per view; the Monitor needs 1 (one `system.metrics` source returns all four metrics, 340 bytes), Spotify 1–2 |
| Samples in flight per source | 1 | Fixed delay (6.2) |
| Minimum `every`, local adapters | 1 s | A full metrics snapshot costs 55 µs p50 / 90 µs p95, about 0.01 % of one core at 1 Hz; 1 s is the finest refresh a person reads (Q1) |
| Minimum `every`, `http.request` | 60 s | Remote rate limits and the user's network, not Host cost (Q1) |
| Sample deadline | HTTPS 15 s (existing); local 1 s; Apple Events 2 s | HTTPS unchanged; local reads measured in µs; Apple Events unmeasured, #85 measures |
| Bound text | 4,096 characters | An item's `text` bound in pages (`pages.md`) |
| Result size | HTTPS 128 KiB (existing); local adapters bounded by their result schemas | A delivery must fit the 1 MiB helper message with 64 KiB of state |
| Waiting deliveries per source | 1 | Latest-result coalescing (6.2) |
| Delivery floor per source | Q2 (recommended 15 s) | Helper residency: section 10.1 |
| Sources sampled Host-wide | 8 × open visible pages | At most one View Session per Plugin |

### 10.1 What deliveries cost

A delivery is a View Event: a helper invocation of 9.0 ms p95 warm and
49.3 ms p95 cold (ADR 0010's W13 run), and while any arrive less than 30
seconds apart the helper never retires, holding about 5.7 MiB
(`activeHelperIncrementalFootprintBytes` is 6 MiB). Bindings cost no
invocation at all. That is why bindings are the default and deliveries are
change-gated and floored: a Monitor in bindings costs nothing in the helper;
a Spotify page that delivers only on `/track/id` runs the script about once
per track; a page that delivers a value changing every second is held to
the floor.

## 11. Sources, Coffee effects and Brew tasks

ADR 0017 keeps three lifetimes apart and shares their machinery:

| | Host-run source (#71, #82) | Keep-awake effect (#84) | Reviewed long task (#72, #88) |
| --- | --- | --- | --- |
| Owner | The visible page of a View Session | The Plugin, through a Host-owned effect | The Plugin, through a Host-owned task |
| Starts | Page visible with the source declared | A gesture's committed request (ADR 0018) | A gesture's committed request, after a Host Confirmation |
| Runs while | Visible | Until stop, expiry, bound App exit, Plugin change, revoke, Host exit | Until done, cancelled or Host exit |
| View closed | Ends | Continues | Continues |
| Hidden | Pauses | Continues | Continues |
| Status Item activity entry | Never | Yes | Yes |
| Changes the system | Never: reads only | Yes (power assertion) | Yes (installs, upgrades) |
| Cancelled | Silently, by hiding/closing/redefining | Stop | Attempted cancel, never rollback |
| Survives Host restart | No | No | No; normal exit offers wait or stop |

Shared, and to be written once in #82/#84: the owner-invalidation observers
(registry and grant), authority read at start and again before applying a
result, the cancellation token, and dropping late results. Not shared: a
source has no activity entry, no stop control and no exit policy, because
it does nothing that outlives being seen.

**Where tasks and sources meet (for #72/#88).** A reopened Brew view must
show a running task's stage without polling a script. The natural shape is
an `activities` read offered at the `source` entry point: the Host already
holds the task's status, so the adapter answers from Host state instead of
sampling anything, and the page binds the stage text (and later, under
#81, a Progress) to it. Whether that adapter samples on a short interval or
is pushed when the task's Host-held status changes is #88's choice; either
way the contract here applies unchanged (visible only, latest result,
change-gated delivery), the task's lifetime stays the task's, and closing
the view stops only the observation. Nothing in this design starts, stops or
cancels a task or an effect.

## 12. What this is not

- **No helper timer.** The Host owns every clock. A script never asks to be
  run later; `every` schedules *Host* reads.
- **No arbitrary subscription.** A source names a catalogue operation the
  Host offers at the `source` entry point, with a Host-reviewed adapter. No
  Plugin-chosen notification name, file path, process, URL scheme or event
  stream. A push mechanism an adapter may use internally (a Spotify
  distributed notification, a task's status) is the adapter's, reviewed with
  it, and invisible to the Plugin.
- **No perpetual script execution.** Bindings run no script; deliveries are
  change-gated, floored, visible-only and coalesced to the latest. A view
  nobody sees costs nothing; a closed view costs nothing.
- **No background schedule.** Nothing samples for a hidden page, a page held
  in page memory, a closed view or a Plugin without a session, and nothing a
  source does is persisted. Plugin Storage written while answering a
  delivery is the Plugin's business data, not a schedule.
- **No new presentation surface.** Sources update components of the Plugin
  View; they add nothing to the Status Item or the Menu (Live Command
  metadata stays "not offered").

## 13. Verification

### 13.1 Test-kit seams (public; #82 publishes them)

The kit runs scripts in the real helper and answers Host Services from
recordings (`Sources/SpinnetPluginTestKit/README.md`); sources need the same
for samples, time and visibility, without the network or a real clock:

- **`RecordedHostSources`**: a recorded sample sequence per catalogue ID,
  each `.result(json)`, `.failure(category, message)` or `.hang` (reaches
  the deadline); `http.request` goes through the broker with recorded
  transport responses, as `RecordedHostFetchedSections` does, so consent and
  Credential Uses are the Host's.
- **`PluginTestPage` additions**: `sources` (the recordings), `advance(by:)`
  (a virtual clock that fires due samples and the floor), `hide()` /
  `show()` (visibility), `revoke(_:)` and `storeCredential(_:)`; reading
  `shown(component:)` (what a bound component shows, with `isStale`),
  `samples` (each sample started, with source ID, definition and virtual
  time) and `deliveries` (each `source_delivered` run, or dropped with its
  reason). Deliveries run through the real helper and their answers through
  the same page memory the Host uses.
- **The Host seam it stands on**: a `HostSourceAdapter` protocol (result
  schema, minimum interval, deadline, `sample(input, authority,
  cancellation)`) and a scheduler taking a clock and a visibility signal, so
  the kit and the Host share the scheduling, retention and provenance code
  as `PluginTestPage` already shares page memory. A deterministic non-HTTP
  adapter for #82's own tests (its acceptance asks for one) is a recorded
  adapter, not a Host Service.

The scenarios in [`fixtures/scenarios/`](fixtures/scenarios/) are written
as these recordings and steps, so #82 can turn each into a kit test.

### 13.2 Measurement scenarios (#82, #85, #86)

[`measurements.md`](measurements.md) records what was measured here (S1)
and specifies the rest, each with its method and pass condition: Monitor
visible for 10 minutes at 1 s (Host CPU, wakeups, zero helper launches after
the first page), hide/show counts and first-sample latency, delivery
residency against the floor, Spotify Apple Event cost and every Automation
state, HTTPS repeat counts with the cache bypassed, many pinned views, and
revocation during an in-flight sample.

### 13.3 Native checks (#82, #85, #86, actual Host)

Occlusion by another floating window and by a Space switch; screen lock
and display sleep; pinned and unpinned; VoiceOver reading bound values and
"out of date"; Spotify not installed, not running (never launched by a
sample), Automation not yet decided (no prompt from a sample), denied and
granted.

## 14. Open product choices

User decisions (2026-10-08):

- **Metrics authority (#86):** a new Capability `read_system_status`.
- **Spotify Automation (#85):** reuse `control_external_app`; a sample never
  launches Spotify or raises the Automation prompt and fails with
  `automation_permission_needed`, repaired by a page action the user
  chooses.

The remaining choices stay open until #82.

Each is the user's to decide (#68: "new product choices or permissions
return to the user with evidence"). The recommendation keeps work moving
and is what the drafts assume.

**Q1. Minimum sampling intervals.** Options: (a) 1 s local, 60 s HTTPS;
(b) 2 s local, 5 min HTTPS; (c) a single 5 s minimum. Measured: local
sampling is not the cost (55 µs per snapshot); rendering and wakeups are,
and #82 measures them (S2). *Recommend (a)*, revisited if S2 shows
drawing at 1 Hz exceeds budget; HTTPS at 60 s because the cost falls on the
remote service and the user's network, which the Host cannot measure.

**Q2. Delivery floor.** Options: (a) 5 s, the helper stays resident while a
watched value changes faster than every 30 s; (b) 15 s; (c) 60 s, twice the
helper's idle exit, so even a constantly changing value lets the helper
retire between deliveries; (d) no repeating deliveries at all (only once
sources deliver). *Recommend (b)* with change-gating: Spotify track
changes (minutes apart) deliver promptly, bound values update instantly
regardless, and S4 measures residency to confirm.

**Q3. Authority for basic metrics.** Options: (a) no Capability, like
`text.detectLanguage`: CPU, memory, disk and battery reveal little;
(b) a new Capability (`read_system_status`) the user grants, as for every
other read of the Mac's state; (c) a Capability with a Sensitive Data
Collection-style Host opt-in. A metric read alone is low risk, but with
`contact_https` it fingerprints the Mac and tracks presence (battery
draining, CPU activity). *Recommend (b)*: one more disclosure line, and it
keeps "every read of the Mac's state is granted" true. #86 owns the answer.

**Q4. Spotify and Automation.** Options: (a) reuse `control_external_app`
with a Spotify Reviewed App Interface, and let macOS prompt the first time
any Spotify operation is sent, including from a sample; (b) as (a), but a
sample never prompts: it reads the decision without asking and fails with
`automation_permission_needed`, whose repair route is a page action that
sends one harmless Apple Event on the user's click, so the macOS prompt
follows a gesture; (c) a new Spinnet-side consent step before the macOS
one. Measured: the decision cannot even be read while Spotify is not
running (`AEDeterminePermissionToAutomateTarget` returned `procNotFound`,
-600), so "not running" must be checked first. *Recommend (b)*: no prompt
ever appears from something the user did not do, and no new Spinnet
permission is invented. #85 owns the answer; reading playback state may
also want a narrower operation family in the scope than transport control.

**Q5. HTTPS sources repeating at all.** Options: (a) offer `every` on
`http.request` with the 60 s minimum; (b) only once sources for HTTPS at
first (the Level 1 section behaviour on pages), repeating added when a
probe needs it. No current probe needs repeating HTTPS. *Recommend (b)*
for #82, keeping (a)'s shape in the schema so adding it is a Level 2
addition, not a reshaping.

**Q6. Plugin Settings changed in the Settings window while a page with
sources is open.** Options: (a) nothing, as today for sections: the page
keeps its sources until the script answers again; (b) deliver a
non-gesture `settings_changed` event so the script can redefine its
sources. *Recommend (a)* now; (b) is a separate addition if a probe needs
it.

**Q7. Stale presentation.** Options: (a) dimmed value plus VoiceOver "out
of date"; (b) also a Host-drawn "as of 12:03" line; (c) nothing until the
next sample. *Recommend (a)*: honest without adding Host chrome to
Plugin pages.

# Historical Source measurements (#82)

Recorded 2026-10-09/10 on macOS 27.0.1 (26A434), arm64, SwiftPM debug.
The original report did not pin an exact Host commit; hardware/idleness were
not certified and compilation sometimes ran concurrently. These are historical
observations, not current release acceptance or performance guarantees.

Twenty real-helper `source_delivered` samples measured warm p50/p95/max
1.899/2.148/2.420 ms and cold 14.994/15.556/15.559 ms. Automatic helper idle
retirement occurred after 31.567 s; the next delivery launched a new helper,
while the bound value stayed visible without another HTTPS read.

Regression reasons retained in `HostRunSourcesContractTests`,
`HostRunSourcesTests` and `HostRunSourcesNativeTests`:

- Sources do not sample while hidden, catch up hidden time or keep invoking
  a helper for binding-only updates; only one sample runs at once.
- Cancellation, replaced registration/credentials and changed page provenance
  drop stale results. Denied authority reads no data; regrant retries a once read.
- Once-only reads survive hide/show after success. Delivery coalesces independently
  of sampling. Earlier Levels retain their delivery floor; Level 4's activity
  exception is specified in [Level 4](../../reference/level-4.md).
- Closing releases shown data. Bounded source results leave room in the helper
  message; numerical limits live in [Sources](../../reference/sources.md) and
  `DocumentedBudgetsTests`.

The native panel was initially reported occluded under SwiftPM; a later
integration/Xcode run passed visibility/observer cleanup checks. Actual sleep,
lock, fast user switching, redraw latency and VoiceOver speech were not tested.
The real helper exercised JavaScript builders; TypeScript compilation was not
available in that run. Rerunning current tests is required for current claims.

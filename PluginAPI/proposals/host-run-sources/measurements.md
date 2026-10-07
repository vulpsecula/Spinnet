# Measurements and measurement scenarios

Proposal only (#71). S1 was measured for this design; S2–S10 are the
scenarios #82, #85 and #86 run before pinning numbers. Each records the
Host commit, machine, macOS build, power source and load, and keeps every
sample (p50, p95, max), as ADR 0007 asks.

## S1. Cost of one metrics read (measured)

[`measure-metrics.swift`](measure-metrics.swift), built with `swiftc -O`,
run 2026-10-07 on an M1 Pro MacBookPro18,1, 10 cores, 16 GiB, macOS 27.0.1
(26A434), on AC power with the battery at 78 %, Host baseline `c440132`.
The machine was busy (load average 5.6–14.5 on 10 cores across the runs),
so the figures are conservative. Microseconds per call:

| Read | n | p50 | p95 | max |
| --- | --- | --- | --- | --- |
| `host_statistics` `HOST_CPU_LOAD_INFO` | 20,000 | 0.79 | 0.92 | 36 |
| `host_processor_info` `PROCESSOR_CPU_LOAD_INFO` (per core) | 20,000 | 4.83 | 7.46 | 191 |
| `host_statistics64` `HOST_VM_INFO64` | 20,000 | 0.79 | 0.83 | 40 |
| `sysctl vm.swapusage` | 20,000 | 0.75 | 0.83 | 16 |
| `statfs("/")` | 20,000 | 0.83 | 0.88 | 34 |
| `URL.resourceValues` `volumeAvailableCapacityForImportantUsage` (cache cleared) | 2,000 | 23,070 | 29,183 | 76,556 (471,126 in the first run) |
| `IOPSCopyPowerSourcesInfo` + list + description | 2,000 | 53.1 | 82.1 | 185 |
| `IOPSGetTimeRemainingEstimate` | 20,000 | 33.9 | 74.2 | 3,128 |
| `NSRunningApplication` by bundle ID (Spotify) | 2,000 | 1.54 | 1.67 | 28.5 |
| **Whole snapshot**: CPU + VM + `statfs` + power source | 5,000 | 55.2 (54.5) | 82.5 (64.6) | 419 |

The snapshot a `system.metrics` source would answer encodes to 340 bytes:

```json
{"battery":{"charging":false,"current":78,"max":100,"state":"AC Power","time_to_empty":0},
 "cpu":{"idle":0.517,"system":0.306,"user":0.177},
 "disk":{"available_bytes":556781801472,"total_bytes":994662584320},
 "memory":{"compressed_bytes":6185566208,"total_bytes":17179869184,"used_bytes":12799754240}}
```

What it means:

- **Sampling is not the cost.** At 1 Hz the whole snapshot is about
  0.006 % of one core (55 µs per second). The minimum interval is chosen
  by what a person reads and by drawing and wakeup cost (S2), not by
  reading.
- **Except "important usage" disk capacity**, which Finder shows and which
  counts purgeable space: 23 ms p50 and up to 0.47 s. `statfs`'s
  `f_bavail` (1 µs) excludes purgeable space and so reads lower. #86
  chooses: `statfs` every sample, or the important-usage figure off the
  main thread at most once a minute and reused between.
- **CPU busy needs two readings.** `HOST_CPU_LOAD_INFO` gives cumulative
  ticks; a fraction needs the previous reading. A shared Host sampler that
  keeps the last ticks answers the first sample of a new source at once;
  otherwise the first result has `cpu: null` (or waits for a second
  reading). #86 decides.
- **Battery** is one IOKit call; a Mac without a battery has an empty
  power source list, which the adapter answers as `battery: null`.

**Spotify.** Installed (`/Applications/Spotify.app`, 1.3.3.264) but not
running. No Apple Event was sent: sending one would launch Spotify and,
the first time, raise the macOS Automation prompt, both changing the
user's state. `AEDeterminePermissionToAutomateTarget(com.spotify.client,
typeWildCard, typeWildCard, askUserIfNeeded: false)` returned `-600`
(`procNotFound`): the Automation decision cannot be read while the target
is not running. Checking that Spotify runs costs 1.5 µs and must come
first (design section 7). The read's cost is S5.

## Scenarios still to measure

| # | Scenario | Method | Pass condition |
| --- | --- | --- | --- |
| S2 | System Monitor pinned and visible for 10 minutes, one `system.metrics` source every 1 s, four bound texts | Release Host, `top -l` / `powermetrics --samplers tasks` for Host CPU and wakeups; helper launch count | Host CPU and wakeups recorded against the idle Host; **zero** helper launches after the page's first answer; the helper exits 30.25 s after its last event while the page keeps updating |
| S3 | Hide and show: cover the pinned panel with another floating window, switch Space, lock the screen, sleep the displays | Count samples per source with a Host log | **Zero** samples while hidden; first sample after showing starts within one frame plus the adapter's minimum interval; values marked stale until then |
| S4 | Delivery residency | A fixture source whose watched value changes every 1 s, delivery floors 5, 15, 30, 60 s; `phys_footprint` of the helper | Deliveries per minute equal 60 / floor; helper footprint within the existing 6 MiB p95 budget; with a 60 s floor the helper retires between deliveries |
| S5 | Spotify read (#85) | Spotify running, Automation granted: one read of state, position and current track, 200 samples | Cost per sample p50 / p95 / max recorded; sample deadline set from it; bounded result size recorded |
| S6 | Spotify states (#85) | Not installed, installed and not running, Automation not yet decided, denied, granted, quit while visible | The right failure category each time; **never launched** by a sample; **no Automation prompt** from a sample |
| S7 | HTTPS once and repeating (#82) | Recorded transport; a once source answered and re-described 100 times; a repeating source for 10 minutes if Q5 allows it | One request for the once source; `ceil(600 / every)` requests for the repeating one; none answered from the response cache |
| S8 | Many views | Six Plugins pinned, each with 8 visible sources (local fixture adapter, 1 s) | Host CPU, wakeups and main-thread time per second recorded; drawing p95 per update recorded |
| S9 | Revoke and change during a sample | A sample held in flight by the fixture adapter, then revoke the Capability, update the Plugin, store a credential, change page, hide | Nothing applied after any of them; revocation and update end the session; a credential store restarts only the sources that reference credentials |
| S10 | Latency from result to screen | Fixture adapter answering at a known time; measure until the bound text draws | p95 recorded; proposed acceptance target of one frame plus 16 ms, set from the measurement |

The fixture scenarios in [`fixtures/scenarios/`](fixtures/scenarios/)
state the behaviour S3, S4, S7 and S9 check, as test-kit steps.

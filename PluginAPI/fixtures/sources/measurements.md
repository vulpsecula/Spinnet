# Source verification and measurements (#82)

Recorded 2026-10-09, macOS 27.0.1 (26A434), arm64, SwiftPM debug build.
Hardware sysctl was unavailable in the execution sandbox; hardware and desktop
idleness were not independently certified. Other ticket compilation was active
at times. These numbers describe this run, rather than an idle release benchmark.

## Reproduce

```sh
swift test --filter 'HostRunSourcesContractTests|HostRunSourcesTests|HostServiceCatalogueTests|LevelTwoPublishedContractTests'
swift test --filter HostRunSourcesNativeTests
```

The external `Tests/Fixtures/SourcesProbe.spinnetplugin` uses the published
Level 2 SDK through the real `SpinnetPluginHelper` and public Plugin test kit.
`RecordedHostSources` uses the real Capability-checked HTTPS broker with recorded
responses and a deterministic source clock; it performs no actual network request.
The non-HTTP `fixture.counter` adapter exercises the engine's independently
injected source offering. It is a fixture, never a published operation.

## Observed

- 22 focused tests passed in 33.279 s before the final owner/refusal additions;
  eight focused owner/source/refusal tests passed in 0.010 s afterward.
- Real helper `source_delivered` round trip, 20 samples each, ms:

| Helper | p50 | p95 | max | Existing bound |
| --- | ---: | ---: | ---: | ---: |
| warm | 1.899 | 2.148 | 2.420 | 150 |
| cold | 14.994 | 15.556 | 15.559 | 300 |

- Automatic production idle retirement verified after 31.567 seconds: helper
  launch count changed from 21 to 22 on the next delivered event. During the idle
  interval the Host retained the bound value `24.5` with one HTTPS request and no
  helper invocation from the binding.
- Once-only HTTPS: no read while hidden; one recorded read on show; no repeat on
  a successful hide/show or after advancing the source clock 60 seconds.
- Non-HTTP counter: one source, at most one sample in flight, fixed delay at 1 s,
  two deliveries at source times 0 and 15 s, latest change coalesced. A source
  below its adapter's 2 s minimum is refused. Floor-held data waits while hidden;
  showing dispatches the latest retained value. Samples do not catch up hidden time.
- Inflight cancellation, secret replacement and replaced registration drop late
  results; complete equal definitions retain the read. Queued source results
  replace each other, and changed source/page provenance drops them before script
  dispatch. Denied authority emits only bounded failure metadata, reads no data;
  granting it retries the once source. Closing stops reads and releases shown data.
- Published recordings exercise bound pages, successful and failed deliveries,
  repeating HTTPS refusal, pointer syntax, missing source reference and count limits.
  Source results cap encoded JSON at 512 KiB so they leave space in the existing
  1 MiB helper message; the HTTPS body still caps at 128 KiB. Eight sources/page,
  one pending delivery/source, 15 s delivery floor, 4,096-character bound text,
  512-character pointers/failures, and existing state/page bounds are retained.

## Native limits

The actual NSPanel test uses the Host's `.accessory` activation policy,
NSApplication event pumping, WindowServer occlusion and real NSWorkspace
notification observers. Under the initial SwiftPM runner, the ordered-in panel
was reported occluded; actual visible-desktop scenarios therefore require a
rerun, and the guarded native test skips rather than asserting visibility.
No actual machine sleep, lock or fast user switch was induced. Native redraw
latency, visual alignment and VoiceOver speech have not been measured in this
run; model/text formatter values are not screen-rendering evidence.
TypeScript `tsc` was not present; the same SDK builders were evaluated by the
real JavaScriptCore helper, while catalogue/schema tests checked published shape.
Full integration regressions and Xcode-native validation run on the integration
branch after these ticket branches merge. No prior performance budget is loosened.

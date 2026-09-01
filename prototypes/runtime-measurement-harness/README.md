# Runtime measurement harness prototype

This is a disposable harness for **Establish the idle and menu-open measurement harness**. It establishes a repeatable method for comparing a native Host baseline with future Plugin runtime candidates. It does not select a runtime or set production budgets.

## Run

From the repository root:

```sh
./prototypes/runtime-measurement-harness/run.sh \
  --iterations 30 \
  --idle-runs 10 \
  --idle-ms 250 \
  --output prototypes/runtime-measurement-harness/measurements/latest
```

The one command compiles two disposable Swift fixtures, generates deterministic installed Plugin manifests from `fixtures/fixture-spec.json`, runs the accepted AppKit Menu benchmark, and writes `raw.jsonl` plus `summary.json`. Python orchestration uses only the standard library and runs through `uv`.

## Scenarios and boundaries

| Scenario | Measured boundary | Separation |
| --- | --- | --- |
| Installed but idle | Native fixture Host after loading 0 and 200 deterministic Plugin manifests and waiting the configured delay | Host `phys_footprint`; child-process count sampled separately |
| Menu open | Accepted native AppKit Host process-side open/draw boundary | Host only; no Plugin runtime is wired into this path |
| Cold Action invocation | Host starts a fresh helper, receives a deterministic result, and waits for process exit | End-to-end latency plus independently reported Host and helper `phys_footprint` |
| Return to baseline | Host sampled before Action and after helper exit plus the configured delay | Host delta plus child-process count after inactivity |

`TASK_VM_INFO.phys_footprint` is a private-memory proxy, not uniquely private dirty pages. Menu-open measurements still exclude global input-device delay, WindowServer compositing, display scanout, and photon latency. The deterministic helper is a measurement fixture, not a proposed Plugin runtime.

## Conditions and repetition

- Default measured iterations: 30.
- AppKit Menu warmups: 5.
- Cold means a new helper process for every Action invocation; the Host remains resident.
- Installed-idle samples use 10 fresh Host processes each for 0 and 200 Plugin manifests by default, producing paired footprint deltas.
- The default 250 ms delay confirms helper teardown and samples allocator settling. It does not choose a production inactivity timeout.
- Hardware, CPU, macOS, kernel, Python, power state, fixture spec, run counts, and delay are captured in every summary.

Do not compare runs unless their fixture spec, iteration count, idle delay, hardware/OS conditions, and measurement boundaries match or the differences are explicitly reported.

## Acceptance method for runtime candidates

A runtime candidate is measurable with this harness when it can preserve these observations without changing their meaning:

1. report Host and helper private memory separately;
2. prove installed-but-idle Plugins have no child/helper process;
3. prove Menu-open starts no Plugin runtime;
4. measure cold Action invocation from runtime start through result availability;
5. prove helper processes terminate after inactivity; and
6. report the Host footprint delta after teardown rather than claiming exact memory ownership.

The harness reports distributions and invariants. A later Wayfinder decision may accept budgets from evidence; this prototype deliberately assumes none.

## Prototype result on 2026-09-02

The checked-in run under `measurements/automated-2026-09-02/` used 10 paired installed-idle Host launches, 30 cold Action invocations, and a 250 ms post-helper delay on a MacBookPro18,1 with an Apple M1 Pro and macOS 26.6.2.

- Installed-idle Host footprint was 2,441,696 bytes p50 with zero Plugin manifests and 2,785,760 bytes p50 with 200 deterministic Plugin manifests. The paired delta was 344,064 bytes p50 and 426,032 bytes p95. All 20 fresh Host samples had zero child/helper processes while idle.
- Accepted AppKit Menu-open process-side latency was 1.248 ms p50 and 6.604 ms p95 in this run. No Plugin runtime is wired into that path.
- Cold deterministic helper invocation was 67.647 ms p50 and 68.065 ms p95. One 266.669 ms maximum outlier is retained in the raw evidence.
- Helper-reported private memory was approximately 1.38 MiB p50 and 1.41 MiB p95.
- Host footprint delta after helper exit plus 250 ms was 16 KiB p50 and 48 KiB p95; all 30 post-idle child-process counts were zero.

The result demonstrates that the harness separates component costs, preserves raw outliers, and proves process-lifecycle invariants. It does not establish product budgets.

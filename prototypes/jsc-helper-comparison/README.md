# JavaScriptCore boundary comparison prototype

This is a disposable prototype for **Compare in-Host JavaScriptCore with a shared helper**. It asks whether representative Plugin workloads give Spinnet enough comparative evidence to choose between a fresh JavaScriptCore context inside the Host and a fresh on-demand shared-helper process.

It does not select the production Plugin process boundary or set performance budgets.

## Run

From the repository root:

```sh
./prototypes/jsc-helper-comparison/run.sh \
  --iterations 30 \
  --idle-runs 10 \
  --idle-ms 250 \
  --output prototypes/jsc-helper-comparison/measurements/latest
```

The command compiles two candidate Hosts and one JavaScriptCore helper, runs the accepted native Menu benchmark, and writes `raw.jsonl` plus `summary.json`. The Python orchestration uses only the standard library and runs through `uv`.

The in-Host candidate links JavaScriptCore; the shared-helper Host does not. This keeps installed-idle Host measurements representative of each candidate boundary.

## Equivalent fixtures

Each candidate receives the same input and executes the same JavaScript source:

- `transform-text.js` performs a string transformation and checksum;
- `structured-data.js` parses, filters, sorts, and serializes JSON; and
- `capability-probe.js` requests the `selection.read` and `process.spawn` Host Services.

Every Action uses a fresh JavaScriptCore context. The shared-helper candidate also starts a fresh process for each cold Action. Result checksums must match across candidates.

Both candidates return Host Service requests to the same Host-side broker. The fixture grants the `selection-read` Capability and withholds `process-execution`, so `selection.read` must be allowed and `process.spawn` denied. The prototype measures the policy decision, not real Host Service execution or production IPC.

## Accepted measurement boundaries

| Scenario | Boundary |
| --- | --- |
| Installed but idle | Ten paired fresh launches per candidate with 0 and 200 deterministic Plugin manifests; Host `TASK_VM_INFO.phys_footprint` and child-process count are sampled separately. |
| Menu open | Five warmups plus 30 measurements through the accepted native AppKit Host baseline. No Plugin runtime is wired into the path. |
| Cold Action | In-Host context creation through result, or helper launch through result and process exit. Host and helper footprints are reported separately. |
| Teardown | Candidate Host footprint before Action and after context release or helper exit plus 250 ms; child processes are sampled after the delay. |
| Crash containment | `SIGABRT` is injected at each runtime boundary in a fresh candidate Host. This is a process-fault probe, not a claim that ordinary JavaScript can call `abort`. |

Raw samples and evidence records are retained. Summaries report p50, p95, and max without trimming outliers.

## Recorded run: 2026-09-02

The checked-in run used a MacBookPro18,1 with an Apple M1 Pro, macOS 26.6.2, AC power, 10 paired idle launches per candidate and installed count, 30 cold Actions per candidate, five Menu warmups, and a 250 ms teardown delay.

| Observation | In-Host JavaScriptCore | Shared helper |
| --- | ---: | ---: |
| Cold Action latency p50 / p95 / max | 1.295 / 2.533 / 3.652 ms | 82.364 / 236.365 / 301.981 ms |
| Active Host + runtime footprint p50 / p95 | 4.92 / 5.36 MiB | 8.10 / 9.27 MiB |
| Runtime footprint increment p50 / p95 | 16 KiB / 0.97 MiB | 4.34 / 5.27 MiB |
| Host delta 250 ms after teardown p50 / p95 | 16 / 384 KiB | 32 / 192 KiB |
| Installed 0→200 Plugin Host delta p50 / p95 | 368 / 480 KiB | 400 / 464 KiB |
| Injected fatal runtime fault | Host terminated with `SIGABRT` | Helper terminated; Host remained responsive |

The native Menu-open baseline measured 0.915 ms p50, 1.360 ms p95, and 7.393 ms max. All installed-idle and post-helper child-process observations were zero. Both variants produced equivalent checksums and Capability decisions; every JavaScript workload completed without exception.

## Comparative answer

The evidence does not produce a universal winner:

- in-Host JavaScriptCore is decisively better for this prototype's cold latency and active private memory;
- the shared helper is the only candidate that contains an injected process-fatal runtime fault;
- both preserve installed-idle and Menu-open lifecycle invariants;
- both can enforce the same Host-side Capability policy; and
- both approach the Host baseline after teardown, with allocator noise and first-use effects retained in the distributions.

If process-fatal runtime containment is a production requirement, the shared helper is the evidence-backed boundary despite its measured startup and memory cost. If that containment is not required, this run gives no performance or memory reason to prefer it. The final production-boundary decision must make that value tradeoff explicitly.

## Risks this prototype does not measure

- malicious CPU or memory exhaustion and cancellation of non-terminating JavaScript;
- real Documented Plugin Interface IPC, payload serialization, and Host Service execution costs;
- concurrent or long-lived Actions, helper reuse, and a production inactivity timeout;
- code signing, sandbox profiles, XPC interruption/reconnection, and hostile message validation; and
- device-to-photon Menu latency or performance on other supported hardware and macOS versions.

The 250 ms delay is a comparable teardown sampling point, not a selected production inactivity timeout. These are fixture observations, not accepted budgets.

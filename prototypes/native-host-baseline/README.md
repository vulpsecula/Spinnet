# Native Host radial Menu baseline

This is disposable prototype evidence for GitHub issue #2. It measures the process-side baseline of a minimal Swift/AppKit **Host** opening a radial **Menu**, updating a pointer-selected **Menu Item**, acknowledging its no-op **Primary Action**, and dismissing the Menu. It is not production implementation.

There is no Plugin, Plugin runtime, persistence, settings UI, or real Command execution. That keeps the baseline aligned with ADR-0001 and ADR-0004: native Host work is measured before any runtime is introduced.

## One-command build and run

From the repository root:

```sh
./prototypes/native-host-baseline/run.sh
```

The script compiles an optimized Swift/AppKit executable when needed and starts interactive mode. Control-Option-Space globally opens or dismisses the Menu at the pointer. Move across Menu Items and release over one to acknowledge its Primary Action and dismiss. An outside click or Escape also dismisses. Control-Option-Q saves measurements and quits.

The executable is an accessory application using a borderless `NSPanel` with the `.nonactivatingPanel` style mask. The public Carbon hotkey API is used only to isolate global invocation from event-tap permission overhead; this prototype does not select the production input mechanism.

## Repeatable automated measurement

```sh
./prototypes/native-host-baseline/measure.sh \
  --iterations 200 \
  --warmups 20 \
  --output prototypes/native-host-baseline/measurements/automated-2026-09-02
```

This performs one cold cycle, 20 unrecorded warmups, and 200 recorded warm cycles. The output directory receives `raw.jsonl` and `summary.json`. The command is non-interactive, does not synthesize input, does not request System Permission, and makes the real AppKit panel nearly transparent while it exercises ordering, drawing, selection, and dismissal.

Each raw JSONL sample records its phase (`cold`, `warm`, or `human`), iteration, metric, value, unit, timestamp, and whether it was automated. The summary contains min/mean/p50/p95/max distributions and machine conditions.

| Metric | Process-side boundary |
| --- | --- |
| `host_ready_latency_ms` | process entry to `applicationDidFinishLaunching`, after the controller and panel exist |
| `menu_open_latency_ms` | invocation enters the Host to panel ordered front, Menu synchronously drawn, and Core Animation flushed |
| `pointer_selection_latency_ms` | pointer update enters the Menu to selected Menu Item synchronously drawn and Core Animation flushed |
| `primary_action_latency_ms` | pointer release handling begins to no-op Primary Action acknowledged |
| `menu_close_latency_ms` | dismissal enters the Host to panel ordered out and Core Animation flushed |
| `*_private_memory_*_bytes` | `TASK_VM_INFO.phys_footprint` before open, after open, and after close |

`ContinuousClock` is monotonic. The rendering boundary excludes input-device delay, WindowServer compositing, display scanout, and photon latency. `phys_footprint` is a useful process private-memory proxy, but it is not uniquely private dirty pages.

## Automated evidence

The checked-in run is under `measurements/automated-2026-09-02/`. Treat `summary.json` as the authoritative values and `raw.jsonl` as the audit trail. Automated evidence covers the real panel lifecycle, Menu drawing, pointer-selection geometry, no-op Primary Action acknowledgement, dismissal, and memory sampling.

The run used a MacBookPro18,1 with an Apple M1 Pro (10 CPU cores) and 16 GiB physical memory, macOS 26.6.2 (25G83), Apple Swift 6.3.3 with `-O`, an Aqua session on AC power, nominal thermal state, and one 1920×1080-pixel 144 Hz display at backing scale 2. Load averages at summary time were 6.48, 6.04, and 4.01.

Observed process-side results:

| Observation | Result |
| --- | --- |
| Host ready, single cold process | 183.799 ms; 9,863,888 bytes physical footprint |
| First Menu open | 4.577 ms; footprint 11,764,432 bytes before and 11,895,504 bytes open |
| First pointer selection / close | 17.128 ms / 5.080 ms; footprint 15,336,144 bytes closed |
| Warm Menu open, p50 / p95 | 6.043 ms / 6.600 ms |
| Warm pointer selection, p50 / p95 | 0.864 ms / 5.210 ms |
| Warm close, p50 / p95 | 6.040 ms / 7.373 ms |
| Warm footprint, mean before / open / closed | 35,202,293 / 35,240,796 / 35,247,923 bytes |

In this run, the mean open-minus-before footprint was about 37.6 KiB and the mean closed-minus-before footprint was about 44.6 KiB. These deltas are observations of the whole instrumented process, not memory attributed exclusively to the Menu. The no-op Primary Action p50 was 0.000542 ms, which only confirms negligible acknowledgement work; it says nothing about real Action execution.

It does **not** prove global OS input delivery, non-activation relative to another foreground application, physical pointer behavior, display-edge placement, permission behavior, or end-to-end visual latency. Those are human checks below; do not combine human samples with automated samples.

## HITL validation on 2026-09-02

The interactive prototype was exercised by a human in the same logged-in Aqua session. The run was saved with Control-Option-Q under `measurements/manual-2026-09-02/` and contains 25 Menu invocations.

Validated behavior:

- Control-Option-Space reliably invoked and toggled the Menu.
- The Menu remained non-activating, appeared at the pointer, was readable, and stayed inside the visible frame at screen edges and corners.
- The center dead zone selected no Menu Item and at most one Menu Item was highlighted.
- Selecting a Menu Item with the pointer, clicking outside, and pressing Control-Option-Space again all dismissed the Menu.
- macOS requested no System Permission during the run.

Two failures kept that revision from establishing a faithful interaction baseline:

- The highlighted Menu Item did not match the pointer direction. A deterministic replay of all eight drawn Menu Item centers through the prototype's hit-test formula produced eight mismatches. The drawing code numbers sectors clockwise from the upper-right, while the hit-test rotates the pointer angle by 90 degrees and numbers it in the opposite mapping.
- Escape did not dismiss the Menu. The non-activating panel does not receive local key events, while the global key monitor cannot receive keyboard events when Input Monitoring and Accessibility trust are both absent. Both trust checks were false during validation.

The human run observed Menu-open p50/p95 of 4.122/5.332 ms and Menu-close p50/p95 of 0.546/4.727 ms. These remain process-side measurements and do not supersede the limitations above. At that checkpoint, the prototype required both failures to be corrected and revalidated before its boundary could be accepted for subsequent runtime comparisons.

## Fix and HITL revalidation on 2026-09-02

The hit-test now numbers pointer angles clockwise from the top, matching the drawing geometry. `verify.sh` compiles the real prototype source, replays every drawn Menu Item center through the production hit-test seam, and verifies that a permission-free Escape hotkey can be registered and unregistered:

```sh
./prototypes/native-host-baseline/verify.sh
```

All eight geometry checks pass. Escape no longer relies on global or local `NSEvent` keyboard monitors: the Host dynamically registers an unmodified Carbon Escape hotkey only while the Menu is open and unregisters it on every dismissal path.

The repaired prototype was then exercised again by a human. The 12-invocation run is saved under `measurements/manual-fixed-2026-09-02/`. The human confirmed:

- highlighted Menu Items matched the pointer direction;
- Escape dismissed the Menu;
- Escape continued to work normally in the foreground application after the Menu closed;
- the foreground application remained active while the Menu was shown;
- pointer selection, outside click, and Control-Option-Space dismissal still worked; and
- macOS did not request Accessibility, Input Monitoring, or any other System Permission. Neither HITL run requested a System Permission.

The repaired run observed Menu-open p50/p95 of 4.275/5.896 ms and Menu-close p50/p95 of 4.324/4.759 ms. These are process-side observations from a small human sample, not acceptance budgets. With the two interaction failures corrected and revalidated, this minimal Host behavior is faithful enough to serve as the native baseline for the subsequent runtime measurement harness.

## Exact HITL review checklist

Run the one-command interactive mode in a logged-in macOS GUI session, then perform every item:

- [ ] Keep a different application frontmost; press Control-Option-Space and confirm the Host does not become active and the other application remains frontmost.
- [ ] Confirm the Menu appears centered at the pointer and is visually readable.
- [ ] Invoke at the center and near every edge and corner of each connected display; confirm the full Menu remains inside the visible frame.
- [ ] Perform at least 30 global invocations from varied pointer positions.
- [ ] Move through every Menu Item; confirm exactly one Menu Item highlights according to pointer direction and the center dead zone selects none.
- [ ] Release over at least 10 Menu Items; confirm the selected Menu Item's no-op Primary Action is acknowledged by immediate dismissal.
- [ ] Dismiss at least 10 times with an outside click.
- [ ] Dismiss at least 10 times with Escape.
- [ ] Dismiss at least 10 times by pressing Control-Option-Space again.
- [ ] Record whether macOS requested Input Monitoring, Accessibility, or any other System Permission; if requested, record whether denial and grant alter Escape/outside-click behavior.
- [ ] Press Control-Option-Q, confirm `raw.jsonl` and `summary.json` are written under `measurements/manual-latest/`, and retain human results separately from automated evidence.
- [ ] Decide whether these process-side boundaries are faithful enough for subsequent runtime comparisons; do not infer a production budget without that review.

## Conditions, limitations, and comparison rules

- The prototype is an unsigned command-line executable, not an application bundle. Rebuilds can affect how macOS associates System Permission with it.
- Automated invocation calls the Host controller directly. It deliberately excludes synthetic global input overhead and uses a nearly transparent panel, so it is not an end-to-end user latency measurement.
- The Menu has eight numbered Menu Items, no animation, and no Plugin or Command execution. A later comparison must use equivalent boundaries or report differences.
- Cold means the first Menu cycle in a newly launched Host process. Warm samples follow explicit warmups in the same process. Neither represents cold Action invocation because there is no Action runtime.
- Back-to-back warm cycles favor cache-hot drawing and can amplify scheduler noise. Compare distributions and recorded conditions, not a single minimum.
- Panel ordering plus `displayIfNeeded` and `CATransaction.flush` is a process-side proxy. It does not establish when the Menu becomes visible to a person.
- `phys_footprint` can include framework and allocator effects and can remain elevated after dismissal. Report open and closed observations rather than claiming exact Menu ownership.
- This prototype establishes evidence, not latency or private-memory budgets. Budget acceptance remains a separate human decision under ADR-0004.

No canonical term or architectural decision is changed by this prototype.

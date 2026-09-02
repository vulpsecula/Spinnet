#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import platform
import statistics
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
BUILD = ROOT / ".build"
FIXTURE_SPEC = ROOT / "fixtures" / "fixture-spec.json"
VARIANTS = ("in_host", "shared_helper")


def command(*parts: str) -> str:
    return subprocess.run(parts, check=True, text=True, capture_output=True).stdout.strip()


def compile_swift(source: Path, output: Path, *extra: str) -> None:
    subprocess.run(
        ["xcrun", "swiftc", "-warnings-as-errors", "-O", *extra, str(source), "-o", str(output)],
        check=True,
    )


def fixtures(count: int, spec: dict[str, object]) -> list[dict[str, str]]:
    kinds = list(spec["command_kinds"])
    payload_bytes = int(spec["payload_bytes"])
    seed = str(spec["seed"])
    return [
        {
            "id": f"fixture.plugin.{index:04d}",
            "commandKind": str(kinds[index % len(kinds)]),
            "payload": (f"{seed}:{index}:" * payload_bytes)[:payload_bytes],
        }
        for index in range(count)
    ]


def write_fixture_files(spec: dict[str, object]) -> dict[int, Path]:
    paths: dict[int, Path] = {}
    for raw_count in spec["installed_counts"]:
        count = int(raw_count)
        path = BUILD / f"fixtures-{count}.json"
        path.write_text(json.dumps(fixtures(count, spec), sort_keys=True), encoding="utf-8")
        paths[count] = path
    return paths


def read_event(process: subprocess.Popen[str]) -> dict[str, object]:
    assert process.stdout is not None
    line = process.stdout.readline()
    if not line:
        raise RuntimeError(f"fixture Host exited unexpectedly with {process.poll()}")
    return json.loads(line)


def send(process: subprocess.Popen[str], value: str) -> dict[str, object]:
    assert process.stdin is not None
    process.stdin.write(value + "\n")
    process.stdin.flush()
    return read_event(process)


def stop(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    assert process.stdin is not None
    process.stdin.write("quit\n")
    process.stdin.flush()
    process.wait(timeout=5)


def child_count(pid: int) -> int:
    result = subprocess.run(
        ["/usr/bin/pgrep", "-P", str(pid)], text=True, capture_output=True, check=False
    )
    return len([line for line in result.stdout.splitlines() if line.strip()])


def start_host(
    fixture_path: Path, host: Path, helper: Path
) -> tuple[subprocess.Popen[str], dict[str, object]]:
    process = subprocess.Popen(
        [str(host), "--fixtures", str(fixture_path), "--helper", str(helper)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
        text=True,
        bufsize=1,
    )
    return process, read_event(process)


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[round((len(ordered) - 1) * fraction)]


def summarize(rows: list[dict[str, object]]) -> dict[str, object]:
    groups: dict[str, list[float]] = defaultdict(list)
    units: dict[str, str] = {}
    for row in rows:
        key = str(row["metric"])
        groups[key].append(float(row["value"]))
        units[key] = str(row["unit"])
    return {
        key: {
            "count": len(values),
            "unit": units[key],
            "min": min(values),
            "mean": statistics.fmean(values),
            "p50": percentile(values, 0.50),
            "p95": percentile(values, 0.95),
            "max": max(values),
        }
        for key, values in sorted(groups.items())
    }


def decisions(invocation: dict[str, object]) -> list[dict[str, object]]:
    return list(invocation["host_service_decisions"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=30)
    parser.add_argument("--idle-runs", type=int, default=10)
    parser.add_argument("--idle-ms", type=int, default=250)
    parser.add_argument("--output", type=Path, default=ROOT / "measurements" / "latest")
    args = parser.parse_args()
    if args.iterations < 1 or args.idle_runs < 1 or args.idle_ms < 0:
        parser.error("--iterations and --idle-runs must be positive; --idle-ms must not be negative")

    BUILD.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    spec = json.loads(FIXTURE_SPEC.read_text(encoding="utf-8"))
    fixture_paths = write_fixture_files(spec)
    host_source = ROOT / "Sources" / "FixtureHost.swift"
    helper = BUILD / "jsc-helper"
    hosts = {
        "in_host": BUILD / "in-host-jsc-host",
        "shared_helper": BUILD / "shared-helper-host",
    }
    compile_swift(ROOT / "Sources" / "FixtureHelper.swift", helper, "-framework", "JavaScriptCore")
    compile_swift(host_source, hosts["in_host"], "-D", "IN_HOST_JSC", "-framework", "JavaScriptCore")
    compile_swift(host_source, hosts["shared_helper"])

    workload_paths = [ROOT / "fixtures" / f"{kind}.js" for kind in spec["command_kinds"]]
    records: list[dict[str, object]] = []
    sequence = 0

    def record(
        scenario: str,
        iteration: int,
        metric: str,
        value: float,
        unit: str,
        component: str,
        variant: str | None = None,
        workload: str | None = None,
    ) -> None:
        nonlocal sequence
        sequence += 1
        row: dict[str, object] = {
            "schema_version": 1,
            "record_type": "sample",
            "sequence": sequence,
            "scenario": scenario,
            "iteration": iteration,
            "metric": metric,
            "value": value,
            "unit": unit,
            "component": component,
        }
        if variant is not None:
            row["variant"] = variant
        if workload is not None:
            row["workload"] = workload
        records.append(row)

    def evidence(record_type: str, **fields: object) -> None:
        nonlocal sequence
        sequence += 1
        records.append({
            "schema_version": 1,
            "record_type": record_type,
            "sequence": sequence,
            **fields,
        })

    idle_observations: dict[str, dict[int, list[dict[str, object]]]] = {
        variant: {count: [] for count in fixture_paths} for variant in VARIANTS
    }
    for variant in VARIANTS:
        for run_index in range(1, args.idle_runs + 1):
            for count, fixture_path in sorted(fixture_paths.items()):
                process, ready = start_host(fixture_path, hosts[variant], helper)
                time.sleep(args.idle_ms / 1_000)
                sample = send(process, "sample")
                children = child_count(process.pid)
                idle_observations[variant][count].append(
                    {"ready": ready, "sample": sample, "child_process_count": children}
                )
                record(
                    "installed_idle",
                    run_index,
                    f"{variant}.host_private_memory_{count}_plugins_bytes",
                    float(sample["private_memory_bytes"]),
                    "bytes",
                    "Host",
                    variant,
                )
                record(
                    "installed_idle",
                    run_index,
                    f"{variant}.child_process_count_{count}_plugins",
                    float(children),
                    "count",
                    "Plugin runtime",
                    variant,
                )
                stop(process)

    installed_counts = sorted(fixture_paths)
    low, high = installed_counts[0], installed_counts[-1]
    for variant in VARIANTS:
        for run_index in range(args.idle_runs):
            idle_delta = float(idle_observations[variant][high][run_index]["sample"]["private_memory_bytes"]) - float(
                idle_observations[variant][low][run_index]["sample"]["private_memory_bytes"]
            )
            record(
                "installed_idle",
                run_index + 1,
                f"{variant}.installed_plugin_private_memory_delta_bytes",
                idle_delta,
                "bytes",
                "Host",
                variant,
            )

    action_observations: dict[str, list[dict[str, object]]] = {variant: [] for variant in VARIANTS}
    for variant in VARIANTS:
        process, _ = start_host(fixture_paths[high], hosts[variant], helper)
        for iteration in range(1, args.iterations + 1):
            workload_path = workload_paths[(iteration - 1) % len(workload_paths)]
            workload = workload_path.stem
            before = send(process, "sample")
            invocation = send(process, f"invoke {variant} {iteration} {workload_path}")
            time.sleep(args.idle_ms / 1_000)
            after_idle = send(process, "sample")
            children = child_count(process.pid)
            action_observations[variant].append(invocation)
            evidence(
                "invocation_evidence",
                scenario="cold_action",
                iteration=iteration,
                variant=variant,
                workload=workload,
                result=invocation["result"],
                host_service_decisions=invocation["host_service_decisions"],
                exception=invocation["exception"],
            )
            record("cold_action", iteration, f"{variant}.cold_action_invocation_latency_ms", float(invocation["cold_action_invocation_latency_ms"]), "ms", "Host + runtime", variant, workload)
            if variant == "in_host":
                runtime_memory = float(invocation["host_private_memory_runtime_peak_bytes"]) - float(invocation["host_private_memory_before_bytes"])
                active_boundary_memory = float(invocation["host_private_memory_runtime_peak_bytes"])
                record("cold_action", iteration, f"{variant}.host_private_memory_runtime_peak_bytes", float(invocation["host_private_memory_runtime_peak_bytes"]), "bytes", "Host", variant, workload)
            else:
                runtime_memory = float(invocation["helper_private_memory_bytes"])
                active_boundary_memory = float(invocation["host_private_memory_before_bytes"]) + runtime_memory
                record("cold_action", iteration, f"{variant}.helper_private_memory_bytes", runtime_memory, "bytes", "Plugin runtime", variant, workload)
            record("cold_action", iteration, f"{variant}.runtime_private_memory_increment_bytes", runtime_memory, "bytes", "Plugin runtime boundary", variant, workload)
            record("cold_action", iteration, f"{variant}.active_boundary_private_memory_bytes", active_boundary_memory, "bytes", "Host + Plugin runtime", variant, workload)
            record("return_to_baseline", iteration, f"{variant}.host_private_memory_delta_after_idle_bytes", float(after_idle["private_memory_bytes"]) - float(before["private_memory_bytes"]), "bytes", "Host", variant, workload)
            record("return_to_baseline", iteration, f"{variant}.child_process_count_after_idle", float(children), "count", "Plugin runtime", variant, workload)
        stop(process)

    helper_crash_host, _ = start_host(fixture_paths[high], hosts["shared_helper"], helper)
    helper_crash = send(helper_crash_host, "crash-helper")
    helper_host_after_crash = send(helper_crash_host, "sample")
    stop(helper_crash_host)

    in_host_crash_host, _ = start_host(fixture_paths[high], hosts["in_host"], helper)
    assert in_host_crash_host.stdin is not None
    in_host_crash_host.stdin.write("crash-in-host\n")
    in_host_crash_host.stdin.flush()
    in_host_crash_host.wait(timeout=5)
    in_host_crash = {
        "variant": "in_host",
        "host_survived": in_host_crash_host.returncode == 0,
        "host_returncode": in_host_crash_host.returncode,
        "fault": "SIGABRT injected at the runtime boundary",
    }
    evidence("crash_probe", **helper_crash)
    evidence("post_crash_host_sample", variant="shared_helper", **helper_host_after_crash)
    evidence("crash_probe", **in_host_crash)

    menu_output = BUILD / "menu-baseline"
    subprocess.run(
        [
            str(REPO / "prototypes" / "native-host-baseline" / "measure.sh"),
            "--iterations", str(args.iterations),
            "--warmups", "5",
            "--output", str(menu_output),
        ],
        check=True,
    )
    menu_summary = json.loads((menu_output / "summary.json").read_text(encoding="utf-8"))
    for source, target in [
        ("warm.menu_open_latency_ms", "menu_open_latency_ms"),
        ("warm.private_memory_before_open_bytes", "host_private_memory_before_menu_open_bytes"),
        ("warm.private_memory_open_bytes", "host_private_memory_menu_open_bytes"),
    ]:
        metric = menu_summary["metrics"][source]
        for name in ["min", "mean", "p50", "p95", "max"]:
            record("menu_open_summary", 0, f"{target}_{name}", float(metric[name]), str(metric["unit"]), "Host")

    checksum_equivalent = all(
        str(left["result"]["checksum"]) == str(right["result"]["checksum"])
        for left, right in zip(action_observations["in_host"], action_observations["shared_helper"], strict=True)
    )
    capability_equivalent = all(
        decisions(left) == decisions(right)
        for left, right in zip(action_observations["in_host"], action_observations["shared_helper"], strict=True)
    )
    capability_probes = [
        observation
        for observations in action_observations.values()
        for observation in observations
        if observation["workload"] == "capability-probe"
    ]
    capability_policy_passed = all(
        [decision["allowed"] for decision in decisions(observation)] == [True, False]
        for observation in capability_probes
    )
    no_exceptions = all(
        observation["exception"] is None
        for observations in action_observations.values()
        for observation in observations
    )

    raw_path = args.output / "raw.jsonl"
    raw_path.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in records), encoding="utf-8")
    metrics = summarize([record for record in records if record["record_type"] == "sample"])
    summary = {
        "schema_version": 1,
        "record_type": "summary",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "iterations_per_variant": args.iterations,
        "idle_runs_per_variant_and_installed_count": args.idle_runs,
        "idle_ms": args.idle_ms,
        "fixture_spec": spec,
        "workloads": [path.name for path in workload_paths],
        "metrics": metrics,
        "crash_probes": {
            "in_host": in_host_crash,
            "shared_helper": helper_crash,
            "shared_helper_host_sample_after_fault": helper_host_after_crash,
        },
        "invariants": {
            "installed_idle_has_no_runtime_process": all(
                observation["child_process_count"] == 0
                for variants in idle_observations.values()
                for observations in variants.values()
                for observation in observations
            ),
            "menu_open_starts_no_runtime": True,
            "all_helper_processes_terminated_after_idle": metrics["shared_helper.child_process_count_after_idle"]["max"] == 0,
            "equivalent_workload_checksums": checksum_equivalent,
            "equivalent_capability_decisions": capability_equivalent,
            "capability_policy_allowed_selection_and_denied_process": capability_policy_passed,
            "all_javascript_workloads_completed_without_exception": no_exceptions,
            "shared_helper_contained_injected_fatal_fault": helper_crash["host_survived"] is True and helper_crash["helper_termination_reason"] == "signal",
            "in_host_did_not_contain_injected_fatal_fault": in_host_crash["host_survived"] is False,
        },
        "measurement_method": {
            "private_memory": "TASK_VM_INFO.phys_footprint reported independently by each candidate Host and by the helper while its JavaScriptCore context is alive",
            "menu_open": "Accepted native AppKit Host baseline; synchronous process-side draw boundary with no Plugin runtime wired in",
            "cold_action": "Fresh JavaScriptCore context per invocation; in-Host context creation through result, or helper launch through result and process exit",
            "return_to_baseline": "Candidate Host phys_footprint sampled before Action and after context release or helper exit plus the configured idle delay",
            "process_presence": "pgrep -P against each candidate Host while installed-idle and after Action teardown",
            "crash_containment": "Explicit SIGABRT injection at each runtime boundary; this is a process-fault probe, not a claim that ordinary JavaScript can invoke abort",
            "capability_enforcement": "Identical JavaScript records Host Service requests; the Host applies the same service-to-Capability policy for both variants",
        },
        "conditions": {
            "hardware_model": command("/usr/sbin/sysctl", "-n", "hw.model"),
            "cpu": command("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"),
            "operating_system": command("/usr/bin/sw_vers", "-productVersion"),
            "kernel": platform.platform(),
            "python": sys.version,
            "power": command("/usr/bin/pmset", "-g", "batt"),
        },
        "raw": str(raw_path.relative_to(ROOT)) if raw_path.is_relative_to(ROOT) else str(raw_path),
        "unmeasured_risks": [
            "Malicious CPU or memory exhaustion and cancellation of non-terminating JavaScript",
            "Real Documented Plugin Interface IPC, payload serialization, and Host Service execution costs",
            "Concurrent or long-lived Actions, helper reuse, and production inactivity timeout behavior",
            "Code signing, sandbox profiles, XPC interruption/reconnection, and hostile message validation",
            "Device-to-photon Menu latency and performance on other supported hardware or macOS versions",
        ],
        "notes": [
            "This is disposable comparative evidence, not a production runtime implementation or an accepted budget.",
            "Each candidate uses a separately compiled Host so the shared-helper Host does not link JavaScriptCore.",
            "The same JavaScript source, inputs, result checks, and Host-side Capability policy are used for both variants.",
            "The 250 ms delay is a comparable teardown sampling point, not a production inactivity timeout.",
        ],
    }
    summary_path = args.output / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"raw={raw_path}")
    print(f"summary={summary_path}")
    print(json.dumps({
        "invariants": summary["invariants"],
        "key_metrics": {
            key: metrics[key]
            for key in [
                "in_host.cold_action_invocation_latency_ms",
                "shared_helper.cold_action_invocation_latency_ms",
                "in_host.runtime_private_memory_increment_bytes",
                "shared_helper.runtime_private_memory_increment_bytes",
                "in_host.active_boundary_private_memory_bytes",
                "shared_helper.active_boundary_private_memory_bytes",
                "in_host.host_private_memory_delta_after_idle_bytes",
                "shared_helper.host_private_memory_delta_after_idle_bytes",
                "menu_open_latency_ms_p95",
            ]
        },
    }, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

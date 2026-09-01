#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
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


def command(*parts: str) -> str:
    return subprocess.run(parts, check=True, text=True, capture_output=True).stdout.strip()


def compile_swift(source: Path, output: Path) -> None:
    subprocess.run(
        ["xcrun", "swiftc", "-warnings-as-errors", "-O", str(source), "-o", str(output)],
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
    for count in spec["installed_counts"]:
        count = int(count)
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


def start_host(fixture_path: Path, host: Path, helper: Path) -> tuple[subprocess.Popen[str], dict[str, object]]:
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
        groups[str(row["metric"])].append(float(row["value"]))
        units[str(row["metric"])] = str(row["unit"])
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
    host = BUILD / "fixture-host"
    helper = BUILD / "fixture-helper"
    compile_swift(ROOT / "Sources" / "FixtureHost.swift", host)
    compile_swift(ROOT / "Sources" / "FixtureHelper.swift", helper)

    rows: list[dict[str, object]] = []
    sequence = 0

    def record(scenario: str, iteration: int, metric: str, value: float, unit: str, component: str) -> None:
        nonlocal sequence
        sequence += 1
        rows.append(
            {
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
        )

    idle_observations: dict[int, list[dict[str, object]]] = {
        count: [] for count in fixture_paths
    }
    for run_index in range(1, args.idle_runs + 1):
        for count, fixture_path in sorted(fixture_paths.items()):
            process, ready = start_host(fixture_path, host, helper)
            time.sleep(args.idle_ms / 1_000)
            sample = send(process, "sample")
            children = child_count(process.pid)
            idle_observations[count].append(
                {"ready": ready, "sample": sample, "child_process_count": children}
            )
            record("installed_idle", run_index, f"host_private_memory_{count}_plugins_bytes", float(sample["private_memory_bytes"]), "bytes", "Host")
            record("installed_idle", run_index, f"child_process_count_{count}_plugins", float(children), "count", "Plugin helper")
            stop(process)

    installed_counts = sorted(fixture_paths)
    low, high = installed_counts[0], installed_counts[-1]
    for run_index in range(args.idle_runs):
        idle_delta = float(idle_observations[high][run_index]["sample"]["private_memory_bytes"]) - float(
            idle_observations[low][run_index]["sample"]["private_memory_bytes"]
        )
        record("installed_idle", run_index + 1, "installed_plugin_private_memory_delta_bytes", idle_delta, "bytes", "Host")

    process, ready = start_host(fixture_paths[high], host, helper)
    for iteration in range(1, args.iterations + 1):
        before = send(process, "sample")
        invocation = send(process, f"invoke {iteration}")
        time.sleep(args.idle_ms / 1_000)
        after_idle = send(process, "sample")
        record("cold_action", iteration, "cold_action_invocation_latency_ms", float(invocation["cold_action_invocation_latency_ms"]), "ms", "Host + helper")
        record("cold_action", iteration, "helper_private_memory_bytes", float(invocation["helper_private_memory_bytes"]), "bytes", "Plugin helper")
        record("cold_action", iteration, "host_private_memory_before_action_bytes", float(before["private_memory_bytes"]), "bytes", "Host")
        record("cold_action", iteration, "host_private_memory_after_action_bytes", float(invocation["host_private_memory_after_bytes"]), "bytes", "Host")
        record("return_to_baseline", iteration, "host_private_memory_after_idle_bytes", float(after_idle["private_memory_bytes"]), "bytes", "Host")
        record("return_to_baseline", iteration, "host_private_memory_delta_after_idle_bytes", float(after_idle["private_memory_bytes"]) - float(before["private_memory_bytes"]), "bytes", "Host")
        record("return_to_baseline", iteration, "child_process_count_after_idle", float(child_count(process.pid)), "count", "Plugin helper")
    stop(process)

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

    raw_path = args.output / "raw.jsonl"
    raw_path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")
    metrics = summarize(rows)
    summary = {
        "schema_version": 1,
        "record_type": "summary",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "iterations": args.iterations,
        "idle_runs": args.idle_runs,
        "idle_ms": args.idle_ms,
        "fixture_spec": json.loads(FIXTURE_SPEC.read_text(encoding="utf-8")),
        "metrics": metrics,
        "invariants": {
            "installed_idle_has_no_helper_process": all(
                observation["child_process_count"] == 0
                for observations in idle_observations.values()
                for observation in observations
            ),
            "all_helpers_terminated_after_idle": metrics["child_process_count_after_idle"]["max"] == 0,
            "menu_open_starts_no_runtime": True,
            "menu_open_runtime_basis": "The accepted native Host baseline has no Plugin runtime or helper wired into its Menu-open path.",
        },
        "measurement_method": {
            "private_memory": "TASK_VM_INFO.phys_footprint reported independently by the Host and helper",
            "menu_open": "Accepted native AppKit Host baseline; synchronous process-side draw boundary",
            "cold_action": "Monotonic time from Process launch through deterministic helper result and exit",
            "return_to_baseline": "Host phys_footprint sampled before Action and after helper exit plus the configured idle delay",
            "process_presence": "pgrep -P against the fixture Host while idle",
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
        "notes": [
            "This prototype establishes a repeatable method; it does not set acceptance budgets.",
            "The deterministic helper is a fixture, not a proposed Plugin runtime.",
            "The short idle delay confirms process teardown and samples allocator settling; it does not choose a production inactivity timeout.",
        ],
    }
    summary_path = args.output / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"raw={raw_path}")
    print(f"summary={summary_path}")
    print(json.dumps({"invariants": summary["invariants"], "key_metrics": {
        "installed_plugin_private_memory_delta_bytes": metrics["installed_plugin_private_memory_delta_bytes"],
        "menu_open_latency_ms_p95": metrics["menu_open_latency_ms_p95"],
        "cold_action_invocation_latency_ms": metrics["cold_action_invocation_latency_ms"],
        "host_private_memory_delta_after_idle_bytes": metrics["host_private_memory_delta_after_idle_bytes"],
    }}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

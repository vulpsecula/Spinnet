#!/usr/bin/env python3
# PROPOSAL ONLY (#72). SPDX-License-Identifier: MIT
#
# Measures the read operations the draft Homebrew profile would run, on this
# Mac, with the profile's fixed executable, argv and environment: output
# sizes, durations, the process tree each one starts, its peak memory, and
# how the process group answers SIGINT, SIGTERM and SIGKILL. It also fetches
# single-package and full-catalogue metadata from formulae.brew.sh to compare
# with the 128 KiB HTTPS response ceiling.
#
# It never changes Homebrew: every argv is checked against READ_ONLY before
# it runs, `tap` only lists, and HOMEBREW_NO_AUTO_UPDATE is always set,
# because `brew outdated` otherwise runs `brew update` first. Signals are
# only ever sent to read operations it started itself.
#
#   python3 PluginAPI/proposals/reviewed-tool-tasks/measure-brew.py [--runs N] [--json OUT]

import argparse
import json
import os
import signal
import statistics
import subprocess
import sys
import time
from pathlib import Path

CANDIDATES = [Path("/opt/homebrew/bin/brew"), Path("/usr/local/bin/brew")]

# The subcommands this script may run, and what each may be given.
READ_ONLY = {"--version", "--prefix", "tap", "tap-info", "list", "info", "outdated", "search"}

PROFILE_ENV_FIXED = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8",
    "HOMEBREW_NO_AUTO_UPDATE": "1",
    "HOMEBREW_NO_ANALYTICS": "1",
    "HOMEBREW_NO_ENV_HINTS": "1",
    "HOMEBREW_NO_COLOR": "1",
    "HOMEBREW_NO_EMOJI": "1",
    "HOMEBREW_NO_GITHUB_API": "1",
    "HOMEBREW_NO_SUDO": "1",
    "HOMEBREW_NO_INSECURE_REDIRECT": "1",
    "NONINTERACTIVE": "1",
}

READS = [
    ("version", ["--version"]),
    ("prefix", ["--prefix"]),
    ("taps", ["tap"]),
    ("list formulae", ["list", "--formula", "-1", "--full-name"]),
    ("list casks", ["list", "--cask", "-1", "--full-name"]),
    ("installed info", ["info", "--json=v2", "--installed"]),
    ("outdated", ["outdated", "--json=v2"]),
    ("outdated greedy", ["outdated", "--json=v2", "--greedy"]),
    ("search lib", ["search", "lib"]),
    ("search py", ["search", "py"]),
    ("search formula py", ["search", "--formula", "py"]),
    ("search cask firefox", ["search", "--cask", "firefox"]),
    ("search wget", ["search", "wget"]),
    ("search no match", ["search", "zzqxnotapackage"]),
    ("search regex", ["search", "/^lib.*ssl/"]),
    ("search desc ssl", ["search", "--desc", "ssl"]),
    ("info formula wget", ["info", "--json=v2", "--formula", "wget"]),
    ("info formula python@3.13", ["info", "--json=v2", "--formula", "python@3.13"]),
    ("info formula ffmpeg", ["info", "--json=v2", "--formula", "ffmpeg"]),
    ("info cask firefox", ["info", "--json=v2", "--cask", "firefox"]),
    ("info ambiguous docker", ["info", "--json=v2", "docker"]),
    ("info missing", ["info", "--json=v2", "--formula", "zzqxnotapackage"]),
    ("info third-party tap", ["info", "--json=v2", "hashicorp/tap/terraform"]),
]

HTTPS = [
    ("formula wget", "https://formulae.brew.sh/api/formula/wget.json"),
    ("formula python@3.13", "https://formulae.brew.sh/api/formula/python@3.13.json"),
    ("formula ffmpeg", "https://formulae.brew.sh/api/formula/ffmpeg.json"),
    ("cask firefox", "https://formulae.brew.sh/api/cask/firefox.json"),
    ("cask visual-studio-code", "https://formulae.brew.sh/api/cask/visual-studio-code.json"),
    ("formula missing", "https://formulae.brew.sh/api/formula/zzqxnotapackage.json"),
    ("all formulae", "https://formulae.brew.sh/api/formula.json"),
    ("all casks", "https://formulae.brew.sh/api/cask.json"),
]

HTTPS_CEILING = 128 * 1024


def brew_path():
    for path in CANDIDATES:
        if path.is_file() and os.access(path, os.X_OK):
            return path
    return None


def profile_env():
    env = dict(PROFILE_ENV_FIXED)
    for name in ("HOME", "USER", "LOGNAME", "TMPDIR"):
        if name in os.environ:
            env[name] = os.environ[name]
    return env


def guard(argv):
    sub = argv[0]
    if sub not in READ_ONLY:
        raise SystemExit(f"refusing to run brew {sub}: not a read operation")
    if sub == "tap" and len(argv) != 1:
        raise SystemExit("refusing to run brew tap with arguments: that adds a tap")


def group_snapshot(pgid):
    """Processes in the group: (count, total RSS KiB, command names)."""
    out = subprocess.run(["/bin/ps", "-axo", "pid=,pgid=,rss=,comm="], capture_output=True, text=True).stdout
    count, rss, names = 0, 0, set()
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[1] == str(pgid):
            count += 1
            rss += int(parts[2])
            names.add(os.path.basename(parts[3]))
    return count, rss, names


def group_alive(child):
    """Whether any process of the child's group still runs. The leader is
    reaped first: an unreaped leader keeps the group "present" as a zombie,
    and a group of zombies answers EPERM rather than ESRCH."""
    child.poll()
    try:
        os.killpg(child.pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def run_once(brew, argv, sample=True):
    guard(argv)
    started = time.monotonic()
    child = subprocess.Popen([str(brew), *argv], env=profile_env(), stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                             cwd="/")
    peak_count, peak_rss, names = 0, 0, set()
    if sample:
        import threading

        def poll():
            nonlocal peak_count, peak_rss
            while child.poll() is None:
                count, rss, seen = group_snapshot(child.pid)
                peak_count, peak_rss = max(peak_count, count), max(peak_rss, rss)
                names.update(seen)
                time.sleep(0.05)

        sampler = threading.Thread(target=poll, daemon=True)
        sampler.start()
    out, err = child.communicate()
    elapsed = time.monotonic() - started
    if sample:
        sampler.join()
    return {
        "argv": argv, "exit": child.returncode, "seconds": round(elapsed, 3),
        "stdout_bytes": len(out), "stderr_bytes": len(err),
        "stderr_head": err.decode("utf-8", "replace")[:300],
        "peak_processes": peak_count, "peak_rss_kib": peak_rss, "commands": sorted(names),
        "_stdout": out,
    }


def project(formula=None, cask=None):
    """The package record the draft profile returns (reviewed-tools.schema.json#/$defs/package)."""
    entry = formula if formula is not None else cask
    if "installed_versions" in entry:  # brew outdated's shape
        return {"kind": "formula" if formula is not None else "cask", "name": entry["name"],
                "installed_version": entry["installed_versions"][-1], "version": entry["current_version"],
                "outdated": True}
    if formula is not None:
        installed = formula.get("installed") or []
        record = {"kind": "formula", "name": formula["full_name"], "tap": formula["tap"],
                  "description": formula.get("desc"), "version": (formula.get("versions") or {}).get("stable"),
                  "installed_version": installed[-1]["version"] if installed else None,
                  "outdated": formula.get("outdated"), "pinned": formula.get("pinned"),
                  "deprecated": formula.get("deprecated"), "disabled": formula.get("disabled")}
    else:
        record = {"kind": "cask", "name": cask["full_token"], "tap": cask["tap"],
                  "title": (cask.get("name") or [None])[0], "description": cask.get("desc"),
                  "version": cask.get("version"), "installed_version": cask.get("installed"),
                  "outdated": cask.get("outdated"), "auto_updates": cask.get("auto_updates"),
                  "deprecated": cask.get("deprecated"), "disabled": cask.get("disabled")}
    return {key: value for key, value in record.items() if value not in (None, False)}


def describe(name, stdout):
    """Item counts for the JSON and list outputs."""
    text = stdout.decode("utf-8", "replace")
    try:
        data = json.loads(text)
    except ValueError:
        lines = [line for line in text.splitlines() if line.strip() and not line.startswith("==>")]
        return {"lines": len(lines)}
    if isinstance(data, dict) and ("formulae" in data or "casks" in data):
        formulae, casks = data.get("formulae", []), data.get("casks", [])
        found = {"formulae": len(formulae), "casks": len(casks)}
        total = len(formulae) + len(casks)
        if total:
            found["bytes_per_item"] = round(len(stdout) / total)
            item = (formulae or casks)[0]
            found["first_item_bytes"] = len(json.dumps(item, separators=(",", ":")))
            found["first_item_top_level_members"] = len(item)
            projected = [project(formula=f) for f in formulae] + [project(cask=c) for c in casks]
            found["projected_bytes"] = len(json.dumps({"packages": projected}, separators=(",", ":"),
                                                      ensure_ascii=False).encode())
            found["projected_bytes_per_item"] = round(found["projected_bytes"] / total)
        return found
    return {"json": type(data).__name__}


def measure_reads(brew, runs):
    results = []
    for name, argv in READS:
        attempts = [run_once(brew, argv, sample=(index == 0)) for index in range(runs)]
        seconds = [a["seconds"] for a in attempts]
        first = attempts[0]
        results.append({
            "name": name, "argv": argv, "exit": first["exit"],
            "first_seconds": seconds[0],
            "median_seconds": round(statistics.median(seconds), 3),
            "max_seconds": max(seconds),
            "stdout_bytes": first["stdout_bytes"], "stderr_bytes": first["stderr_bytes"],
            "stderr_head": first["stderr_head"] if first["exit"] != 0 or first["stderr_bytes"] else "",
            "peak_processes": first["peak_processes"], "peak_rss_kib": first["peak_rss_kib"],
            "commands": first["commands"],
            "items": describe(name, first["_stdout"]),
            "stable_output": len({a["stdout_bytes"] for a in attempts}) == 1,
        })
        print(f"  {name}: exit {first['exit']}, {first['stdout_bytes']} B, "
              f"median {results[-1]['median_seconds']} s", file=sys.stderr)
    return results


def measure_batches(brew):
    """Exact info for many search results in one process, as a page of results would need."""
    names = run_once(brew, ["search", "--formula", "lib"], sample=False)["_stdout"].decode().split()
    results = []
    for count in (10, 50, 150):
        argv = ["info", "--json=v2", "--formula", *names[:count]]
        attempts = [run_once(brew, argv, sample=False) for _ in range(3)]
        first = attempts[0]
        results.append({"names": count, "exit": first["exit"], "stdout_bytes": first["stdout_bytes"],
                        "median_seconds": round(statistics.median(a["seconds"] for a in attempts), 3),
                        "items": describe("batch", first["_stdout"])})
        print(f"  batch info {count}: {first['stdout_bytes']} B, {results[-1]['median_seconds']} s", file=sys.stderr)
    return results


def stop_experiment(brew, argv, delay, plan):
    """Starts a read, then signals its process group by plan [(signal, grace)]."""
    guard(argv)
    child = subprocess.Popen([str(brew), *argv], env=profile_env(), stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True, cwd="/")
    time.sleep(delay)
    before = group_snapshot(child.pid)
    if child.poll() is not None:
        return {"argv": argv, "delay": delay, "finished_before_signal": True}
    sent, started, leader_seconds = [], time.monotonic(), None
    for sig, grace in plan:
        if not group_alive(child):
            break
        try:
            os.killpg(child.pid, sig)
        except (ProcessLookupError, PermissionError):
            break
        sent.append(signal.Signals(sig).name)
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline and group_alive(child):
            if leader_seconds is None and child.returncode is not None:
                leader_seconds = time.monotonic() - started
            time.sleep(0.005)
    leader_exit = child.wait()
    if leader_seconds is None:
        leader_seconds = time.monotonic() - started
    group_empty = time.monotonic() - started
    err = child.stderr.read().decode("utf-8", "replace")
    return {
        "argv": argv, "delay": delay, "processes_at_signal": before[0], "commands_at_signal": sorted(before[2]),
        "signals_sent": sent, "returncode": leader_exit,
        "seconds_to_leader_exit": round(leader_seconds, 3),
        "seconds_to_group_empty": round(group_empty, 3),
        "group_left_behind": group_alive(child),
        "stderr_tail": err[-200:],
    }


def measure_stops(brew):
    long_read = ["info", "--json=v2", "--installed"]
    experiments = []
    for delay in (0.05, 0.6):
        for name, plan in (
            ("SIGINT", [(signal.SIGINT, 3.0)]),
            ("SIGTERM", [(signal.SIGTERM, 3.0)]),
            ("SIGKILL", [(signal.SIGKILL, 3.0)]),
            ("SIGINT→SIGTERM→SIGKILL", [(signal.SIGINT, 2.0), (signal.SIGTERM, 2.0), (signal.SIGKILL, 1.0)]),
        ):
            result = stop_experiment(brew, long_read, delay, plan)
            result["plan"] = name
            experiments.append(result)
            print(f"  stop {name} at {delay}s: {result.get('seconds_to_group_empty')} s", file=sys.stderr)
    return experiments


def measure_https():
    results = []
    for name, url in HTTPS:
        row = {"name": name, "url": url}
        for mode, extra in (("identity", []), ("compressed", ["--compressed"])):
            out = subprocess.run(
                ["/usr/bin/curl", "-sS", "-o", "/dev/null", "--max-time", "60", *extra,
                 "-w", "%{http_code} %{size_download} %{time_total}", url],
                capture_output=True, text=True,
            )
            parts = out.stdout.split()
            if len(parts) == 3:
                row[mode] = {"status": int(parts[0]), "bytes": int(parts[1]), "seconds": float(parts[2]),
                             "over_ceiling": int(parts[1]) > HTTPS_CEILING}
            else:
                row[mode] = {"error": out.stderr.strip()[:200]}
        results.append(row)
        print(f"  https {name}: {row.get('identity')}", file=sys.stderr)
    return results


def cache_files():
    root = Path.home() / "Library/Caches/Homebrew/api"
    if not root.is_dir():
        return []
    return sorted(({"file": str(p.relative_to(root)), "bytes": p.stat().st_size}
                   for p in root.rglob("*") if p.is_file() and not p.name.endswith(".before.txt")),
                  key=lambda f: -f["bytes"])[:8]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--skip-https", action="store_true")
    options = parser.parse_args()

    brew = brew_path()
    record = {"brew": str(brew) if brew else None, "profile_env": sorted(profile_env())}
    if brew is None:
        record["note"] = "Homebrew is not installed at /opt/homebrew or /usr/local"
    else:
        version = run_once(brew, ["--version"], sample=False)
        record["version"] = version["_stdout"].decode().strip().splitlines()
        record["machine"] = subprocess.run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"],
                                           capture_output=True, text=True).stdout.strip()
        record["macos"] = subprocess.run(["/usr/bin/sw_vers", "-productVersion"],
                                         capture_output=True, text=True).stdout.strip()
        record["reads"] = measure_reads(brew, options.runs)
        record["batches"] = measure_batches(brew)
        record["stops"] = measure_stops(brew)
        record["api_cache"] = cache_files()
    if not options.skip_https:
        record["https"] = measure_https()

    text = json.dumps(record, indent=2, ensure_ascii=False)
    if options.json:
        options.json.write_text(text + "\n", encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()

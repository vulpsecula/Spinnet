#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# ///
"""Disposable PopClip Extension corpus scanner for issue #5."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
TEXT_SUFFIXES = {".applescript", ".bash", ".js", ".json", ".md", ".plist", ".sh", ".ts", ".txt", ".yaml", ".yml"}
CONFIG_NAMES = {
    "Config.plist": "plist",
    "Config.json": "json",
    "Config.yaml": "yaml",
    "Config.yml": "yaml",
    "Config.js": "javascript",
    "Config.ts": "typescript",
    "Config.applescript": "applescript",
}

COMMON_POPCLIP_APIS = {
    "copyText",
    "modifiers",
    "openUrl",
    "options",
    "pasteText",
    "pressKey",
    "showFailure",
    "showSuccess",
    "showText",
}

BEHAVIOR_CATEGORIES = (
    "applescript",
    "apple_shortcut",
    "authentication_flow",
    "common_popclip_bridge",
    "dom_processing",
    "external_javascript_dependency",
    "invocation_context",
    "javascript_execution",
    "key_press",
    "macos_service",
    "native_executable",
    "network_access",
    "options",
    "popclip_util_api",
    "requirements",
    "retained_runtime_state",
    "rich_selected_content",
    "selection_regex",
    "shell_script",
    "static_url",
    "unclassified",
    "uncommon_popclip_api",
)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def snapshot_tree_sha256(root: Path) -> str:
    inventory = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        inventory.append(f"{relative}\0{sha256_bytes(path.read_bytes())}\n")
    return sha256_bytes("".join(inventory).encode())


def ensure_source(manifest: dict[str, Any], source: Path | None) -> Path:
    expected = manifest["upstream"]["commit"]
    if source is None:
        snapshot = ROOT / manifest["input_snapshot"]["root"]
        actual = snapshot_tree_sha256(snapshot)
        expected_snapshot = manifest["input_snapshot"]["tree_sha256"]
        if actual != expected_snapshot:
            raise SystemExit(f"input snapshot hash {actual} does not match manifest hash {expected_snapshot}")
        return snapshot

    source = source.resolve()
    actual = subprocess.run(
        ["git", "-C", str(source), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if actual != expected:
        raise SystemExit(f"source commit {actual} does not match manifest commit {expected}")
    return source


def text_files(package: Path, selected_files: list[str]) -> tuple[list[tuple[Path, str]], list[dict[str, Any]]]:
    texts: list[tuple[Path, str]] = []
    inventory: list[dict[str, Any]] = []
    for relative in selected_files:
        path = package / relative
        if not path.is_file():
            raise SystemExit(f"missing corpus input: {path}")
        data = path.read_bytes()
        relative = path.relative_to(package).as_posix()
        is_text = path.suffix.lower() in TEXT_SUFFIXES or (b"\x00" not in data[:4096] and path.stat().st_size < 2_000_000)
        inventory.append(
            {
                "path": relative,
                "bytes": len(data),
                "sha256": sha256_bytes(data),
                "scanned_as_text": is_text,
            }
        )
        if is_text:
            texts.append((path, data.decode("utf-8", errors="replace")))
    return texts, inventory


def config_metadata(config_path: Path, text: str, container: str) -> dict[str, Any]:
    metadata: dict[str, Any] = {}
    try:
        if container == "plist":
            data = plistlib.loads(config_path.read_bytes())
            metadata["identifier"] = data.get("Extension Identifier")
            name = data.get("Extension Name")
            metadata["name"] = name.get("en") if isinstance(name, dict) else name
        elif container == "json":
            data = json.loads(text)
            metadata["identifier"] = data.get("identifier")
            metadata["name"] = data.get("name")
    except (ValueError, plistlib.InvalidFileException) as error:
        metadata["parse_warning"] = str(error)

    if not metadata.get("identifier"):
        match = re.search(r"(?im)^\s*(?://|--)?\s*(?:identifier|# identifier)\s*:\s*['\"]?([^'\"\s]+)", text)
        if match:
            metadata["identifier"] = match.group(1).rstrip(",")
    if not metadata.get("name"):
        match = re.search(r"(?im)^\s*(?://|--)?\s*(?:name|# name)\s*:\s*['\"]?([^\n'\"]+)", text)
        if match:
            metadata["name"] = match.group(1).strip().rstrip(",")
    return {key: value for key, value in metadata.items() if value is not None}


def has(pattern: str, text: str, flags: int = re.IGNORECASE | re.MULTILINE) -> bool:
    return re.search(pattern, text, flags) is not None


def behavior_findings(
    config_text: str,
    executable_text: str,
    javascript_text: str,
    container: str,
    inventory: list[dict[str, Any]],
) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []

    def add(category: str, status: str, boundary: str, evidence: str) -> None:
        findings.append({"category": category, "status": status, "process_boundary": boundary, "evidence": evidence})

    if has(r"<key>URL</key>|^\s*url\s*:|\"url\"\s*:", config_text):
        add("static_url", "supported", "Host only", "Declarative URL field")
    if has(r"Key Combo|keyCombo|key combo", config_text):
        add("key_press", "supported", "Host only", "Declarative key-combination field")
    if has(r"Service Name|serviceName|service name", config_text):
        add("macos_service", "supported", "Host only", "Declarative Service field")
    if has(r"Shortcut Name|shortcutName|shortcut name", config_text):
        add("apple_shortcut", "supported", "Host only", "Declarative Shortcut field")
    if has(r"shell script\s*:|Shell Script|script interpreter|^\s*interpreter\s*:", config_text):
        add("shell_script", "degraded", "Invocation-only interpreter process", "Shell Script declaration")
    if container == "applescript" or has(r"^\s*applescript\s*:", config_text):
        add("applescript", "degraded", "Invocation-only interpreter process", "AppleScript configuration or declaration")

    module_reference = has(r"[\"']?module[\"']?\s*[:=]", config_text)
    javascript = container in {"javascript", "typescript"} or module_reference
    if javascript:
        add("javascript_execution", "degraded", "Shared JavaScript runtime facility", "JavaScript/TypeScript configuration or module")

    if has(r"Regular Expression|\bregex\s*[:=]", executable_text):
        add("selection_regex", "supported", "Host only", "Selection regular expression")
    if has(r"<key>Requirements?</key>|\brequirements?\b\s*[\"']?\s*[:=]", executable_text):
        add("requirements", "supported", "Host only", "Requirements declaration")
    if has(r"\boptions?\b\s*[\"']?\s*[:=]", executable_text):
        add("options", "supported", "Host settings with values passed across the boundary", "Options declaration")
    if has(r"captureHtml|input\.html|input\.markdown", executable_text):
        add("rich_selected_content", "degraded", "Host captures and passes rich selected content", "HTML/Markdown input usage")
    if has(r"\bcontext\.[A-Za-z_]", executable_text):
        add("invocation_context", "degraded", "Host passes Invocation Context across the boundary", "Context field usage")

    popclip_apis = sorted(
        set(re.findall(r"\bpopclip\.([A-Za-z_$][\w$]*)", javascript_text)) - {"extension"}
    )
    common = sorted(set(popclip_apis) & COMMON_POPCLIP_APIS)
    uncommon = sorted(set(popclip_apis) - COMMON_POPCLIP_APIS)
    if common:
        add("common_popclip_bridge", "degraded", "Capability-checked JavaScript bridge", ", ".join(common))
    if uncommon:
        add("uncommon_popclip_api", "unsupported", "Unresolved JavaScript bridge", ", ".join(uncommon))
    util_apis = sorted(set(re.findall(r"\butil\.([A-Za-z_$][\w$]*)", javascript_text)))
    if util_apis:
        add("popclip_util_api", "unsupported", "Unresolved JavaScript bridge", ", ".join(util_apis))

    imports = set(re.findall(r"\b(?:require\s*\(\s*|from\s+)[\"']([^\"']+)", javascript_text))
    external = sorted(item for item in imports if not item.startswith((".", "/", "@popclip/")))
    if external:
        add("external_javascript_dependency", "unsupported", "Dependency packaging and runtime unresolved", ", ".join(external))
    if has(r"\b(entitlements?\s*[\"']?\s*[:=][^\n]*network|fetch\s*\(|axios\b|XMLHttpRequest|\.post\s*\()", executable_text):
        add("network_access", "unsupported", "Capability and network bridge unresolved", "Network entitlement or client usage")
    if has(
        r"\b(?:export\s+(?:const|function)\s+auth\b|exports\.auth\b|auth\s*:\s*(?:async\s*)?(?:function|\())",
        javascript_text,
    ):
        add("authentication_flow", "unsupported", "Authentication UI, secrets, and callback handling unresolved", "Exported authentication handler")
    if has(r"\b(?:const|let|var)\s+\w+\s*:\s*(?:Array|Map|Set)<|\b(?:const|let|var)\s+\w+\s*=\s*\[\]", javascript_text) and has(r"\.push\s*\(", javascript_text):
        add("retained_runtime_state", "unsupported", "Requires defined lifetime and isolation for JavaScript state", "Module-level mutable collection")
    if has(r"parseHTML|JSDOM|\bdocument\b", javascript_text):
        add("dom_processing", "unsupported", "DOM implementation and isolation unresolved", "DOM construction or document usage")
    if any(item["path"].endswith((".dylib", ".so", ".bundle", ".exe")) for item in inventory):
        add("native_executable", "unsupported", "No Plugin execution", "Native executable content")

    if not findings:
        add("unclassified", "unsupported", "No Plugin execution", "No recognized behavior")
    return sorted(findings, key=lambda item: item["category"])


def classify(findings: list[dict[str, str]]) -> tuple[str, str]:
    categories = {item["category"] for item in findings}
    if "native_executable" in categories or "unclassified" in categories:
        return "reject", "unsupported"
    extended = {
        "authentication_flow",
        "dom_processing",
        "external_javascript_dependency",
        "network_access",
        "popclip_util_api",
        "retained_runtime_state",
        "uncommon_popclip_api",
    }
    if categories & extended:
        return "extended-javascript", "unsupported"
    if "javascript_execution" in categories:
        return "common-javascript", "degraded"
    if categories & {"applescript", "shell_script"}:
        return "invocation-script", "degraded"
    return "host-adapter", "supported"


def scan_extension(repo: Path, entry: dict[str, Any], manifest: dict[str, Any]) -> dict[str, Any]:
    package = repo / entry["path"]
    if not package.is_dir():
        raise SystemExit(f"missing corpus package: {entry['path']}")
    texts, inventory = text_files(package, entry["files"])
    configs = [(path, text) for path, text in texts if path.name in CONFIG_NAMES]
    if len(configs) != 1:
        raise SystemExit(f"expected one Config file in {entry['path']}, found {len(configs)}")
    config_path, config_text = configs[0]
    container = CONFIG_NAMES[config_path.name]
    executable_text = "\n".join(
        text for path, text in texts if not path.name.lower().startswith("readme")
    )
    javascript_text = "\n".join(
        text for path, text in texts if path.suffix.lower() in {".js", ".ts"}
    )
    findings = behavior_findings(config_text, executable_text, javascript_text, container, inventory)
    level_id, disposition = classify(findings)
    rejected = level_id == "reject"
    level = (
        manifest["reject_outcome"]
        if rejected
        else next(item for item in manifest["compatibility_levels"] if item["id"] == level_id)
    )
    tree_hash_input = "".join(f"{item['path']}\0{item['sha256']}\n" for item in inventory).encode()
    return {
        "schema_version": 2,
        "source": {
            "repository": manifest["upstream"]["web_url"],
            "commit": manifest["upstream"]["commit"],
            "path": entry["path"],
            "input_tree_sha256": sha256_bytes(tree_hash_input),
            "input_scope": manifest["input_snapshot"]["scope"],
            "upstream_licence": manifest["upstream"]["licence"],
        },
        "corpus": {"stratum": entry["stratum"], "selection_reason": entry["reason"]},
        "popclip_extension": {
            "manifest_name": entry["name"],
            "config_container": container,
            **config_metadata(config_path, config_text, container),
        },
        "compatibility_report": {
            "compatibility_level": None if rejected else {"id": level_id, "name": level["name"]},
            "import_outcome": {"id": "reject", "name": "Reject"} if rejected else {"id": "classified", "name": "Classified"},
            "disposition": disposition,
            "process_boundary": level["boundary"],
            "findings": findings,
        },
        "file_inventory": inventory,
    }


def write_reports(reports: list[dict[str, Any]], manifest: dict[str, Any], output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    expected = {f"{report['popclip_extension']['manifest_name']}.json" for report in reports} | {"aggregate.json"}
    for stale in output.glob("*.json"):
        if stale.name not in expected:
            stale.unlink()
    for report in reports:
        name = report["popclip_extension"]["manifest_name"]
        (output / f"{name}.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    observed_levels = Counter(
        report["compatibility_report"]["compatibility_level"]["id"]
        for report in reports
        if report["compatibility_report"]["compatibility_level"] is not None
    )
    levels = {level["id"]: observed_levels[level["id"]] for level in manifest["compatibility_levels"]}
    import_outcomes = Counter(report["compatibility_report"]["import_outcome"]["id"] for report in reports)
    observed_dispositions = Counter(report["compatibility_report"]["disposition"] for report in reports)
    dispositions = {name: observed_dispositions[name] for name in ("supported", "degraded", "unsupported")}
    config_containers = Counter(report["popclip_extension"]["config_container"] for report in reports)
    observed_categories = Counter(
        finding["category"]
        for report in reports
        for finding in report["compatibility_report"]["findings"]
    )
    categories = {name: observed_categories[name] for name in BEHAVIOR_CATEGORIES}
    boundaries = Counter(report["compatibility_report"]["process_boundary"] for report in reports)
    aggregate = {
        "schema_version": 2,
        "question": manifest["question"],
        "source_commit": manifest["upstream"]["commit"],
        "input_snapshot_tree_sha256": manifest["input_snapshot"]["tree_sha256"],
        "sample": {
            "size": len(reports),
            "selection_method": manifest["selection_method"],
            "not_a_coverage_estimate": True,
        },
        "counts": {
            "by_config_container": dict(sorted(config_containers.items())),
            "by_compatibility_level": dict(sorted(levels.items())),
            "by_disposition": dict(sorted(dispositions.items())),
            "by_import_outcome": {name: import_outcomes[name] for name in ("classified", "reject")},
            "by_process_boundary": dict(sorted(boundaries.items())),
            "behavior_categories": dict(sorted(categories.items())),
        },
        "extensions": [
            {
                "name": report["popclip_extension"]["manifest_name"],
                "compatibility_level": report["compatibility_report"]["compatibility_level"],
                "disposition": report["compatibility_report"]["disposition"],
                "import_outcome": report["compatibility_report"]["import_outcome"],
                "process_boundary": report["compatibility_report"]["process_boundary"],
                "report": f"{report['popclip_extension']['manifest_name']}.json",
            }
            for report in reports
        ],
    }
    (output / "aggregate.json").write_text(json.dumps(aggregate, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=ROOT / "corpus.json")
    parser.add_argument("--source", type=Path, help="optional PopClip-Extensions checkout at the pinned commit")
    parser.add_argument("--output", type=Path, default=ROOT / "reports")
    args = parser.parse_args()
    manifest = read_json(args.manifest)
    repo = ensure_source(manifest, args.source)
    reports = [scan_extension(repo, entry, manifest) for entry in manifest["extensions"]]
    write_reports(reports, manifest, args.output)
    aggregate = read_json(args.output / "aggregate.json")
    print(json.dumps(aggregate["counts"], indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# PROPOSAL ONLY (#72). SPDX-License-Identifier: MIT
#
# Checks that the draft schema is well formed and uses only the JSON Schema
# (draft 2020-12) keywords Spinnet's JSONSchemaSubsetValidator implements;
# that every fixture is accepted or refused as fixtures/index.json says; that
# every value a scenario states satisfies the definition it names and every
# scenario's manifest excerpt declares only the proposed Capabilities and a
# valid reviewed_tools scope; that additions.json proposes only IDs
# PluginAPI/catalogue.json reserves today, at entry points it reserves or
# names as a catalogue change, and no Capability that already exists; and
# that the proposed bounds agree with the Host's own budget constants and
# with what measure-brew.py recorded in measurements.json. It needs nothing
# beyond Python 3.
#
#   python3 PluginAPI/proposals/reviewed-tool-tasks/check.py

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = HERE / "reviewed-tools.schema.json"
API = (HERE / "../..").resolve()
SOURCES = (API / "../Sources/SpinnetCore").resolve()

ANNOTATIONS = {"$schema", "$id", "$comment", "$defs", "title", "description", "examples"}
ASSERTIONS = {
    "$ref", "type", "const", "enum", "properties", "required", "additionalProperties",
    "items", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength", "pattern", "minimum", "maximum",
    "allOf", "oneOf", "if", "then", "propertyNames", "maxProperties",
}

_documents = {}


def document(path):
    path = Path(path).resolve()
    if path not in _documents:
        _documents[path] = json.loads(path.read_text(encoding="utf-8"))
    return _documents[path]


def resolve(ref, base):
    """Returns (schema, document path) for a $ref written in the document at base."""
    file_part, _, pointer = ref.partition("#")
    path = (base.parent / file_part).resolve() if file_part else base
    node = document(path)
    for token in [t for t in pointer.split("/") if t]:
        token = token.replace("~1", "/").replace("~0", "~")
        node = node[token]
    return node, path


def json_type(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "integer" if value.is_integer() else "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    return "object"


def same(a, b):
    # JSON equality: booleans are not numbers.
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    return a == b


def errors(instance, schema, base, path=""):
    if schema is True:
        return []
    if schema is False:
        return [f"{path or '/'}: is not allowed here"]
    unknown = set(schema) - ANNOTATIONS - ASSERTIONS
    if unknown:
        return [f"{path or '/'}: the schema uses unsupported keywords {sorted(unknown)}"]
    found = []
    if "$ref" in schema:
        target, target_base = resolve(schema["$ref"], base)
        found += errors(instance, target, target_base, path)
    if "type" in schema:
        allowed = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        actual = json_type(instance)
        if actual not in allowed and not (actual == "integer" and "number" in allowed):
            found.append(f"{path or '/'}: is {actual}, expected {allowed}")
    if "const" in schema and not same(instance, schema["const"]):
        found.append(f"{path or '/'}: must be {json.dumps(schema['const'])}")
    if "enum" in schema and not any(same(instance, option) for option in schema["enum"]):
        found.append(f"{path or '/'}: {json.dumps(instance, ensure_ascii=False)} is not one of {schema['enum']}")
    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            found.append(f"{path or '/'}: is shorter than {schema['minLength']}")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            found.append(f"{path or '/'}: is longer than {schema['maxLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            found.append(f"{path or '/'}: does not match {schema['pattern']}")
    if json_type(instance) in ("integer", "number"):
        if "minimum" in schema and instance < schema["minimum"]:
            found.append(f"{path or '/'}: is below {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            found.append(f"{path or '/'}: is above {schema['maximum']}")
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            found.append(f"{path or '/'}: has fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            found.append(f"{path or '/'}: has more than {schema['maxItems']} items")
        if schema.get("uniqueItems"):
            encoded = [json.dumps(item, sort_keys=True) for item in instance]
            if len(set(encoded)) != len(encoded):
                found.append(f"{path or '/'}: has duplicate items")
        if "items" in schema:
            for index, item in enumerate(instance):
                found += errors(item, schema["items"], base, f"{path}/{index}")
    if isinstance(instance, dict):
        for name in schema.get("required", []):
            if name not in instance:
                found.append(f"{path or '/'}: is missing {name}")
        if "maxProperties" in schema and len(instance) > schema["maxProperties"]:
            found.append(f"{path or '/'}: has more than {schema['maxProperties']} members")
        properties = schema.get("properties", {})
        for name, value in instance.items():
            if name in properties:
                found += errors(value, properties[name], base, f"{path}/{name}")
            elif "additionalProperties" in schema:
                found += errors(value, schema["additionalProperties"], base, f"{path}/{name}")
            if "propertyNames" in schema:
                found += [f"{path}/{name}: member name {message.split(': ', 1)[-1]}"
                          for message in errors(name, schema["propertyNames"], base, f"{path}/{name}")]
    for sub in schema.get("allOf", []):
        found += errors(instance, sub, base, path)
    if "oneOf" in schema:
        passing = [sub for sub in schema["oneOf"] if not errors(instance, sub, base, path)]
        if len(passing) != 1:
            found.append(f"{path or '/'}: matches {len(passing)} of oneOf's schemas, not exactly 1")
    if "if" in schema and not errors(instance, schema["if"], base, path) and "then" in schema:
        found += errors(instance, schema["then"], base, path)
    return found


def walk(schema, base, where, problems):
    """Refuses unsupported keywords and unresolvable $refs anywhere in the draft."""
    if isinstance(schema, bool):
        return
    if not isinstance(schema, dict):
        problems.append(f"{where}: is not a schema")
        return
    unknown = set(schema) - ANNOTATIONS - ASSERTIONS
    if unknown:
        problems.append(f"{where}: unsupported keywords {sorted(unknown)}")
    if "$ref" in schema:
        try:
            resolve(schema["$ref"], base)
        except (KeyError, FileNotFoundError, json.JSONDecodeError) as error:
            problems.append(f"{where}: $ref {schema['$ref']} does not resolve ({error})")
    for key in ("properties", "$defs"):
        for name, sub in schema.get(key, {}).items():
            walk(sub, base, f"{where}/{key}/{name}", problems)
    for key in ("items", "additionalProperties", "if", "then", "propertyNames"):
        if key in schema:
            walk(schema[key], base, f"{where}/{key}", problems)
    for key in ("allOf", "oneOf"):
        for index, sub in enumerate(schema.get(key, [])):
            walk(sub, base, f"{where}/{key}/{index}", problems)




def check_against(definition, instance):
    target, base = resolve("#/$defs/" + definition, SCHEMA)
    return errors(instance, target, base)


def scenario_errors(path, additions):
    scenario = json.loads(path.read_text(encoding="utf-8"))
    found = []
    proposed = {c["name"] for c in additions["capabilities"]}
    manifest = scenario.get("manifest")
    if not isinstance(manifest, dict):
        return ["has no manifest excerpt"]
    if manifest.get("api_level") != 2:
        found.append("manifest: these additions belong to Level 2")
    unknown = set(manifest) - {"api_level", "capabilities", "reviewed_tools"}
    if unknown:
        found.append(f"manifest: unexpected members {sorted(unknown)}")
    if not set(manifest.get("capabilities", [])) <= proposed:
        found.append("manifest: declares a Capability this proposal does not define")
    for scope in manifest.get("reviewed_tools", []):
        found += [f"manifest/reviewed_tools{m}" for m in check_against("reviewed_tool_scope", scope)]
    for index, step in enumerate(scenario.get("steps", [])):
        if not ({"given", "when", "then"} & set(step)):
            found.append(f"step {index}: says neither given, when nor then")
        for value in step.get("values", []):
            found += [f"step {index}: {value['definition']}{m}"
                      for m in check_against(value["definition"], value["value"])]
    return found


def catalogue_errors(additions):
    catalogue = json.loads((API / "catalogue.json").read_text(encoding="utf-8"))
    operations = {o["id"]: o for o in catalogue["operations"]}
    namespaces = {n["name"]: n for n in catalogue["namespaces"]}
    changes = " ".join(additions.get("catalogue_changes", []))
    found = []
    for addition in additions["operations"]:
        op_id = addition["id"]
        reserved = operations.get(op_id)
        if reserved is None or reserved.get("status") != "reserved":
            found.append(f"{op_id}: catalogue.json does not reserve it")
            continue
        if namespaces.get(op_id.split(".")[0], {}).get("holds") != "reserved":
            found.append(f"{op_id}: its namespace is not reserved")
        for point in addition["entry_points"]:
            status = reserved["entry_points"].get(point, {}).get("status")
            if status != "reserved" and not (point in changes and op_id in changes):
                found.append(f"{op_id}: catalogue.json does not reserve its {point} entry point ({status})")
        for key in ("input", "result", "outcome"):
            if key in addition:
                file_part, _, pointer = addition[key].partition("#")
                try:
                    resolve("#" + pointer, HERE / file_part)
                except KeyError:
                    found.append(f"{op_id}: {key} {addition[key]} does not resolve")
    existing = {c["name"] for c in catalogue["capabilities"]}
    for capability in additions["capabilities"]:
        if capability["name"] in existing:
            found.append(f"{capability['name']}: is already a Capability")
    reasons = set(document(SCHEMA)["$defs"]["reason"]["enum"])
    for addition in additions["operations"]:
        if not set(addition["failures"]) <= reasons:
            found.append(f"{addition['id']}: failures outside the schema's reasons")
    return found


def constant(file, name):
    text = (SOURCES / file).read_text(encoding="utf-8")
    match = re.search(rf"static (?:let|var) {name}(?:: \w+)? = ([0-9_ *]+)", text)
    if not match:
        raise SystemExit(f"{file} no longer defines {name}")
    return eval(match.group(1).replace("_", ""), {})  # digits, spaces and * only


def budget_errors(additions):
    """The bounds sit inside the Host's existing budgets and above what was measured."""
    b = additions["budgets"]
    found = []
    deadline = constant("ScriptedActionBudgets.swift", "actionDeadline")
    message = constant("ScriptedActionBudgets.swift", "maximumMessageBytes")
    view = constant("ScriptedActionBudgets.swift", "viewDescriptionBytes")
    fetched = constant("ScriptedActionBudgets.swift", "hostFetchedSectionDeadline")
    https_timeout = constant("PluginHTTPSRequest.swift", "timeout")
    https_ceiling = constant("PluginHTTPSRequest.swift", "maximumResponseBodyBytes")
    if not b["read_call_timeout_seconds"] < deadline:
        found.append("a read call must end inside the four-second invocation")
    if b["read_call_timeout_seconds"] != https_timeout:
        found.append("a read call's timeout should match http.request's, which fits the same deadline")
    if b["read_source_timeout_seconds"] > fetched:
        found.append("a source read may not outlast a Host-Fetched Section")
    if not b["result_bytes"] < message:
        found.append("a result must fit one helper message")
    schema = document(SCHEMA)["$defs"]
    if schema["tools.read.result"]["properties"]["packages"]["maxItems"] != b["result_packages"]:
        found.append("result_packages differs from the schema")
    if schema["tools.read.input"]["properties"]["names"]["maxItems"] != b["info_names"]:
        found.append("info_names differs from the schema")
    if schema["search_query"]["maxLength"] != b["search_query_characters"]:
        found.append("search_query_characters differs from the schema")
    if schema["activity"]["properties"]["log"]["maxItems"] != b["task_log_lines_to_plugin"]:
        found.append("task_log_lines_to_plugin differs from the schema")
    if schema["short_text"]["maxLength"] != b["task_log_line_characters"]:
        found.append("task_log_line_characters differs from the schema")
    if schema["activities.list.result"]["properties"]["activities"]["maxItems"] != b["ended_tasks_listed"]:
        found.append("ended_tasks_listed differs from the schema")

    measured_path = HERE / "measurements.json"
    measured = json.loads(measured_path.read_text(encoding="utf-8"))
    if not measured.get("brew"):
        return found + ["measurements.json records no Homebrew; re-measure on a Mac that has it"]
    reads = {r["name"]: r for r in measured["reads"]}
    slowest = max(r["max_seconds"] for r in measured["reads"])
    if not slowest < b["read_call_timeout_seconds"]:
        found.append(f"the slowest measured read ({slowest} s) does not fit the read timeout")
    if not reads["installed info"]["stdout_bytes"] < b["read_stdout_bytes"]:
        found.append("the measured installed listing exceeds the raw output bound")
    projected = reads["installed info"]["items"]["projected_bytes"]
    if not projected < min(b["result_bytes"], view):
        found.append("the measured installed listing does not fit a result and a view once projected")
    if not reads["search lib"]["items"]["lines"] <= b["result_packages"]:
        found.append("the measured broad search exceeds result_packages")
    if not reads["installed info"]["stdout_bytes"] > https_ceiling:
        found.append("the measured raw listing no longer shows why the Host must project it")
    batch = {x["names"]: x for x in measured["batches"]}
    if not batch[b["info_names"]]["median_seconds"] < b["read_call_timeout_seconds"]:
        found.append("an info read of info_names names does not fit the read timeout")
    https = {h["name"]: h for h in measured.get("https", [])}
    for name in ("all formulae", "all casks"):
        if https and not https[name]["identity"]["bytes"] > https_ceiling:
            found.append(f"{name}: the full catalogue now fits the HTTPS ceiling; revisit section 4")
    for name in ("formula wget", "cask firefox"):
        if https and not https[name]["identity"]["bytes"] < https_ceiling:
            found.append(f"{name}: single-package metadata no longer fits the HTTPS ceiling")
    for stop in measured["stops"]:
        if stop.get("group_left_behind"):
            found.append(f"a stop experiment left processes behind: {stop['plan']}")
    if any(r["argv"][0] not in ("--version", "--prefix", "tap", "list", "info", "outdated", "search") for r in measured["reads"]):
        found.append("measurements.json records a command that is not a read")
    return found


def main():
    failures = []
    walk(document(SCHEMA), SCHEMA, "reviewed-tools.schema.json", failures)

    index = json.loads((HERE / "fixtures/index.json").read_text(encoding="utf-8"))
    listed = set()
    for entry in index["fixtures"]:
        listed.add(entry["file"])
        instance = json.loads((HERE / "fixtures" / entry["file"]).read_text(encoding="utf-8"))
        found = check_against(entry["definition"], instance)
        if entry["valid"] and found:
            failures.append(f"{entry['file']} should be accepted: " + "; ".join(found))
        if not entry["valid"] and not found:
            failures.append(f"{entry['file']} should be refused ({entry['note']})")
    on_disk = {str(p.relative_to(HERE / "fixtures")) for p in (HERE / "fixtures").rglob("*.json")
               if p.parent.name != "scenarios" and p.name != "index.json"}
    for missing in sorted(on_disk - listed):
        failures.append(f"fixtures/{missing} is not in index.json")

    additions = json.loads((HERE / "additions.json").read_text(encoding="utf-8"))
    scenarios = sorted((HERE / "fixtures/scenarios").glob("*.json"))
    for path in scenarios:
        failures += [f"scenarios/{path.name}: {m}" for m in scenario_errors(path, additions)]

    failures += catalogue_errors(additions)
    failures += budget_errors(additions)

    if failures:
        print("\n".join(failures))
        return 1
    print(f"ok: schema well formed, {len(index['fixtures'])} fixtures and {len(scenarios)} scenarios agree, "
          f"{len(additions['operations'])} additions reserved in catalogue.json, bounds agree with the Host and measurements.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())

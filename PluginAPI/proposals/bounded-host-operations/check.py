#!/usr/bin/env python3
# PROPOSAL ONLY (#70). SPDX-License-Identifier: MIT
#
# Checks that the draft schema is well formed and that every fixture is
# accepted or refused as fixtures/index.json says. It implements only the
# JSON Schema (draft 2020-12) keywords Spinnet's own JSONSchemaSubsetValidator
# implements, and refuses any other keyword, so the draft can move into a real
# candidate without a richer validator. It needs nothing beyond Python 3.
#
#   python3 PluginAPI/proposals/bounded-host-operations/check.py

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = HERE / "host-operations.schema.json"
LEVEL1_VIEW = (HERE / "../../schemas/plugin-view.schema.json").resolve()
LEVEL1_SESSION = (HERE / "../../schemas/view-session.schema.json").resolve()

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


def view_errors(answer):
    """A candidate view is its Level 1 view plus view_additions."""
    if not isinstance(answer, dict) or not isinstance(answer.get("view"), dict):
        return []
    view = dict(answer["view"])
    found = check_against("view_additions", {k: v for k, v in view.items() if k == "shows_insertion_target"})
    view.pop("shows_insertion_target", None)
    target, base = resolve("#/$defs/view", LEVEL1_VIEW)
    return found + [f"/view{message}" for message in errors(view, target, base)]


def scenario_values(node):
    """Every answer and event a scenario step states, with the definition it must satisfy."""
    if isinstance(node, list):
        for item in node:
            yield from scenario_values(item)
    elif isinstance(node, dict):
        for key, value in node.items():
            if key in ("script_answers", "answer"):
                yield "answer", value
            elif key == "event":
                yield "event", value
            elif key == "event_illustrative":
                yield "illustrative/$defs/start_task_finished", value
            elif key == "script_answers_illustrative":
                continue
            else:
                yield from scenario_values(value)


def main():
    failures = []
    walk(document(SCHEMA), SCHEMA, "host-operations.schema.json", failures)

    index = json.loads((HERE / "fixtures/index.json").read_text(encoding="utf-8"))
    for entry in index["fixtures"]:
        instance = json.loads((HERE / "fixtures" / entry["file"]).read_text(encoding="utf-8"))
        found = check_against(entry["definition"], instance)
        if entry["definition"] == "answer":
            found += view_errors(instance)
        if entry["valid"] and found:
            failures.append(f"{entry['file']} should be accepted: " + "; ".join(found))
        if not entry["valid"] and not found:
            failures.append(f"{entry['file']} should be refused ({entry['note']})")

    # Level 1 is unchanged: its own answer schema still refuses `operation`.
    level1_answer, level1_base = resolve("#/$defs/answer", LEVEL1_SESSION)
    candidate = json.loads((HERE / "fixtures/answers/insert-without-view.json").read_text(encoding="utf-8"))
    if not errors(candidate, level1_answer, level1_base):
        failures.append("Level 1's view-session answer accepts `operation`; Level 1 must stay unchanged")

    scenarios = sorted((HERE / "fixtures/scenarios").glob("*.json"))
    for path in scenarios:
        for definition, value in scenario_values(json.loads(path.read_text(encoding="utf-8"))):
            found = check_against(definition, value)
            if definition == "answer":
                found += view_errors(value)
            if found:
                failures.append(f"scenarios/{path.name}: a stated {definition} is invalid: " + "; ".join(found))

    if failures:
        print("\n".join(failures))
        return 1
    print(f"ok: schema well formed, {len(index['fixtures'])} fixtures and {len(scenarios)} scenarios agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())

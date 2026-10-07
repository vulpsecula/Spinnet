#!/usr/bin/env python3
# PROPOSAL ONLY (#71). SPDX-License-Identifier: MIT
#
# Checks that the draft schema is well formed; that every fixture is
# accepted or refused as fixtures/index.json says, a page's sources and
# bindings against the draft and the rest of the answer against Level 2's
# published pages schema, with the checks the Host makes beyond shape
# (unique source IDs, bindings naming a source, only text components
# binding, only operations offered at the catalogue's source entry point);
# that Level 2 as published still refuses sources; that every scenario
# declares api_level 2 and no Candidate Contract, since this is a Level 2
# addition; and that level-2-addition.json adds only members Level 2 lacks
# and names catalogue IDs that exist. It implements only the JSON Schema
# (draft 2020-12) keywords Spinnet's JSONSchemaSubsetValidator implements
# and refuses any other keyword, so the draft can move into
# PluginAPI/schemas/ unchanged. It needs nothing beyond Python 3.
#
#   python3 PluginAPI/proposals/host-run-sources/check.py

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = HERE / "host-run-sources.schema.json"
LEVEL2_PAGES = (HERE / "../../schemas/pages.schema.json").resolve()
CATALOGUE = (HERE / "../../catalogue.json").resolve()
ILLUSTRATIVE_PLAYBACK = "apps.readPlayback"
KINDS = {"behaviour", "view_component", "view_event", "source"}

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


def check_against(definition, instance, schema=SCHEMA):
    target, base = resolve("#/$defs/" + definition, schema)
    return errors(instance, target, base)


def components(page):
    """Every component of a page, row children included."""
    for component in page.get("content", []) if isinstance(page.get("content"), list) else []:
        if isinstance(component, dict):
            yield component
            if component.get("kind") == "row" and isinstance(component.get("content"), list):
                yield from (child for child in component["content"] if isinstance(child, dict))


def answer_errors(answer, illustrative):
    """A Level 2 answer whose page may carry sources and bindings: the
    additions are checked here, the rest against Level 2's own answer."""
    if not isinstance(answer, dict) or not isinstance(answer.get("page"), dict):
        return check_against("answer", answer, LEVEL2_PAGES)
    answer = json.loads(json.dumps(answer))
    page = answer["page"]
    found = []
    sources = page.pop("sources", None)
    ids = []
    if sources is not None:
        found += [f"/page/sources{m}" for m in
                  check_against("illustrative_sources" if illustrative else "sources", sources)]
        ids = [s.get("id") for s in sources if isinstance(s, dict)]
        if len(set(ids)) != len(ids):
            found.append("/page/sources: source IDs are not unique in the page")
        for source in sources:
            if isinstance(source, dict) and source.get("perform") not in offered_as_source():
                found.append(f"/page/sources: {source.get('perform')} is not offered at the source entry point")
    for component in components(page):
        if "bind" not in component:
            continue
        bind = component.pop("bind")
        if component.get("kind") != "text":
            found.append(f"/page: {component.get('kind')} {component.get('id')} binds; only text components bind")
            continue
        found += [f"/page/{component.get('id')}/bind{m}" for m in check_against("binding", bind)]
        if isinstance(bind, dict) and bind.get("source") not in ids:
            found.append(f"/page/{component.get('id')}/bind: names no source of the page")
    found += check_against("answer", answer, LEVEL2_PAGES)
    return found


_offered = None


def offered_as_source():
    """Catalogue IDs whose source entry point is offered or reserved for an owner."""
    global _offered
    if _offered is None:
        catalogue = document(CATALOGUE)
        _offered = {op["id"] for op in catalogue["operations"]
                    if op["entry_points"].get("source", {}).get("status", "not_offered") != "not_offered"}
        # Spotify's read is #85's to name; the fixtures use apps.readPlayback.
        _offered.add(ILLUSTRATIVE_PLAYBACK)
    return _offered


def addition_errors(addition):
    """level-2-addition.json: members new to Level 2, and catalogue IDs that exist."""
    found = []
    catalogue = document(CATALOGUE)
    events = {e["name"] for e in catalogue["events"]}
    builders = {b["id"] for b in catalogue["builders"]}
    operations = {op["id"]: op for op in catalogue["operations"]}
    for member in addition["members"]:
        kind, name = member["kind"], member["name"]
        if kind not in KINDS:
            found.append(f"level-2-addition.json: unknown member kind {kind}")
        if kind == "view_event" and name in events:
            found.append(f"level-2-addition.json: {name} is already a Level 2 event")
        if kind == "source":
            op = operations.get(name)
            if op is None:
                found.append(f"level-2-addition.json: source {name} is no catalogue ID")
            elif op["entry_points"].get("source", {}).get("status") in (None, "not_offered"):
                found.append(f"level-2-addition.json: {name} is not offered at the source entry point")
    for builder in addition["builders"]:
        if builder["id"] in builders:
            found.append(f"level-2-addition.json: builder {builder['id']} already exists")
    for later in addition["later"]:
        op = operations.get(later["source"])
        if later["source"] != ILLUSTRATIVE_PLAYBACK and (op is None or op.get("status") != "reserved"):
            found.append(f"level-2-addition.json: later source {later['source']} is not a reserved catalogue ID")
    return found


def walk_steps(node):
    """Every answer and event a scenario step states."""
    if isinstance(node, list):
        for item in node:
            yield from walk_steps(item)
    elif isinstance(node, dict):
        for key, value in node.items():
            if key in ("script_answers", "answer"):
                yield "answer", value
            elif key == "event" or key == "queue" or key in ("deliveries", "dropped", "runs_next"):
                for item in (value if isinstance(value, list) else [value]):
                    yield "event", item
            else:
                yield from walk_steps(value)


def event_errors(event):
    if isinstance(event, dict) and event.get("type") == "source_delivered":
        return check_against("source_delivered", event)
    return check_against("event", event, LEVEL2_PAGES)


def main():
    failures = []
    walk(document(SCHEMA), SCHEMA, "host-run-sources.schema.json", failures)

    addition = json.loads((HERE / "level-2-addition.json").read_text(encoding="utf-8"))
    failures += addition_errors(addition)

    index = json.loads((HERE / "fixtures/index.json").read_text(encoding="utf-8"))
    for entry in index["fixtures"]:
        instance = json.loads((HERE / "fixtures" / entry["file"]).read_text(encoding="utf-8"))
        if entry["definition"] == "answer":
            found = answer_errors(instance, entry["illustrative"])
        else:
            found = event_errors(instance)
        if entry["valid"] and found:
            failures.append(f"{entry['file']} should be accepted: " + "; ".join(found))
        if not entry["valid"] and not found:
            failures.append(f"{entry['file']} should be refused ({entry['note']})")

    # Level 2 as published is unchanged: its page refuses sources and its
    # text component refuses bind until #82 appends them.
    monitor = json.loads((HERE / "fixtures/answers/https-once-show.json").read_text(encoding="utf-8"))
    if not check_against("answer", monitor, LEVEL2_PAGES):
        failures.append("Level 2's published answer already accepts sources; this draft is out of date")

    scenarios = sorted((HERE / "fixtures/scenarios").glob("*.json"))
    for path in scenarios:
        scenario = json.loads(path.read_text(encoding="utf-8"))
        manifest = scenario.get("manifest")
        if manifest != {"api_level": 2}:
            failures.append(f"scenarios/{path.name}: declares {manifest}, not api_level 2 without candidates")
        for definition, value in walk_steps(scenario.get("steps", [])):
            found = answer_errors(value, scenario.get("illustrative") is True) if definition == "answer" \
                else event_errors(value)
            if found:
                failures.append(f"scenarios/{path.name}: a stated {definition} is invalid: " + "; ".join(found))

    if failures:
        print("\n".join(failures))
        return 1
    print(f"ok: schema well formed, Level 2 addition new and in the catalogue, "
          f"{len(index['fixtures'])} fixtures and {len(scenarios)} scenarios agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())

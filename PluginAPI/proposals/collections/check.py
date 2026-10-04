#!/usr/bin/env python3
# PROPOSAL ONLY (#74). SPDX-License-Identifier: MIT
#
# Checks the draft `collections` candidate: that the draft schema is well
# formed and uses only the JSON Schema keywords Spinnet's own
# JSONSchemaSubsetValidator implements; that every fixture is accepted or
# refused as fixtures/index.json says, by the schema and by the page rules a
# schema cannot express (the Host's checks, written out below); that Level 1's
# published schemas still refuse everything the candidate adds; that the draft
# candidate.json satisfies #75's metadata schema, requires the draft
# host_operations and namespaces revisions that exist beside it, and is not
# published; that page and item actions perform the namespace catalogue's
# IDs (#99) as its draft schema defines them; that
# every scenario declares its manifest as #75 specifies; and that the budgets
# stated in reference.md are the ones the schema enforces. It needs nothing
# beyond Python 3.
#
#   python3 PluginAPI/proposals/collections/check.py

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = HERE / "collections.schema.json"
REFERENCE = HERE / "reference.md"
LEVEL1_VIEW = (HERE / "../../schemas/plugin-view.schema.json").resolve()
LEVEL1_SESSION = (HERE / "../../schemas/view-session.schema.json").resolve()
HOST_OPERATIONS = (HERE / "../bounded-host-operations").resolve()
NAMESPACES = (HERE / "../namespaces").resolve()
CANDIDATES = (HERE / "../../candidates").resolve()
CANDIDATE_METADATA = CANDIDATES / "schemas/candidate-metadata.schema.json"
CANDIDATE_DECLARATIONS = CANDIDATES / "schemas/candidate-contracts.schema.json"
DRAFT = HERE / "candidate.json"

# The limits a page description is held to beyond its shape.
MAX_DESCRIPTION_BYTES = 256 * 1024
MAX_COMPONENTS = 40
MAX_ITEMS = 2000

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


# ---------------------------------------------------------------- page rules

def components(page):
    """Every component of a page, row children included, in order."""
    for component in page.get("content", []):
        if not isinstance(component, dict):
            continue
        yield component
        if component.get("kind") == "row":
            for child in component.get("content", []):
                if isinstance(child, dict):
                    yield child


def items(collection):
    """Every item of a collection with the section it is in."""
    if isinstance(collection.get("items"), list):
        for item in collection["items"]:
            yield None, item
    for section in collection.get("sections", []) or []:
        for item in section.get("items", []) if isinstance(section, dict) else []:
            yield section.get("id"), item


def page_rule_errors(page):
    """The Host's checks on a page that its schema cannot state (design 4.4)."""
    if not isinstance(page, dict):
        return []
    found = []
    every = list(components(page))
    ids = [c.get("id") for c in every]
    duplicates = sorted({i for i in ids if ids.count(i) > 1 and i is not None})
    if duplicates:
        found.append(f"/page: component IDs {duplicates} are not unique")
    if len(every) > MAX_COMPONENTS:
        found.append(f"/page: {len(every)} components, more than {MAX_COMPONENTS}")
    collections = [c for c in every if c.get("kind") in ("list", "grid")]
    if len(collections) > 1:
        found.append("/page: more than one collection")
    collection = collections[0] if collections else None
    for field in every:
        if field.get("kind") == "text_field" and "collection" in field:
            if collection is None or field["collection"] != collection.get("id"):
                found.append(f"/page: text_field {field.get('id')} searches {field['collection']}, which is not the page's collection")
    if "focus" in page and page["focus"] not in ids:
        found.append(f"/page: focus names {page['focus']}, which is not on the page")
    if isinstance(page.get("reset"), list):
        unknown = [i for i in page["reset"] if i not in ids]
        if unknown:
            found.append(f"/page: reset names {unknown}, which are not on the page")
    if collection is not None:
        actions = [a for a in collection.get("actions", []) if isinstance(a, dict)]
        action_ids = [a.get("id") for a in actions]
        if len(set(action_ids)) != len(action_ids):
            found.append("/page: item action IDs are not unique")
        if sum(1 for a in actions if a.get("default") is True) > 1:
            found.append("/page: more than one default item action")
        sections = [s.get("id") for s in collection.get("sections", []) or [] if isinstance(s, dict)]
        if len(set(sections)) != len(sections):
            found.append("/page: section IDs are not unique")
        seen = []
        for _, item in items(collection):
            if not isinstance(item, dict):
                continue
            seen.append(item.get("id"))
            for name in item.get("actions", []):
                if name not in action_ids:
                    found.append(f"/page: item {item.get('id')} offers {name}, which the collection does not declare")
        if len(set(seen)) != len(seen):
            found.append("/page: item IDs are not unique in the collection")
        if len(seen) > MAX_ITEMS:
            found.append(f"/page: {len(seen)} items, more than {MAX_ITEMS}")
        if "selected" in collection and collection["selected"] not in seen:
            found.append(f"/page: selected names {collection['selected']}, which is not an item")
    size = len(json.dumps(page, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    if size > MAX_DESCRIPTION_BYTES:
        found.append(f"/page: {size} bytes, more than {MAX_DESCRIPTION_BYTES}")
    return found


def view_errors(answer):
    """A Level 1 view in a candidate answer: Level 1's view plus host_operations' view_additions."""
    if not isinstance(answer, dict) or not isinstance(answer.get("view"), dict):
        return []
    view = dict(answer["view"])
    additions = HOST_OPERATIONS / "host-operations.schema.json"
    target, base = resolve("#/$defs/view_additions", additions)
    found = errors({k: v for k, v in view.items() if k == "shows_insertion_target"}, target, base)
    view.pop("shows_insertion_target", None)
    target, base = resolve("#/$defs/view", LEVEL1_VIEW)
    return found + [f"/view{message}" for message in errors(view, target, base)]


def answer_errors(answer):
    found = check_against("answer", answer)
    found += view_errors(answer)
    if isinstance(answer, dict) and "page" in answer and not check_against("page", answer["page"]):
        found += page_rule_errors(answer["page"])
    return found


def instance_errors(definition, instance):
    if definition == "answer":
        return answer_errors(instance)
    found = check_against(definition, instance)
    if definition == "page" and not found:
        found += page_rule_errors(instance)
    return found


# ------------------------------------------------------- candidate metadata

def draft_candidate_errors(draft):
    """The draft follows #75's metadata schema, requires the draft host_operations
    revision beside it, and is provided by no Host."""
    found = [f"candidate.json{message}" for message in errors(draft, document(CANDIDATE_METADATA), CANDIDATE_METADATA)]
    if not isinstance(draft, dict):
        return found
    name, revision = draft.get("name"), draft.get("revision")
    if draft.get("tag") != f"plugin-api-candidate/{name}/r{revision}":
        found.append("candidate.json: tag does not name its own name and revision")
    operations = json.loads((HOST_OPERATIONS / "candidate.json").read_text(encoding="utf-8"))
    wanted = {"name": operations["name"], "revision": operations["revision"]}
    if wanted not in draft.get("requires", []):
        found.append(f"candidate.json: does not require {wanted}, the first new UI contract's insertion rules")
    if draft.get("base_level") != operations.get("base_level"):
        found.append("candidate.json: builds on another Level than host_operations")
    names = json.loads((NAMESPACES / "candidate.json").read_text(encoding="utf-8"))
    wanted = {"name": names["name"], "revision": names["revision"]}
    if wanted not in draft.get("requires", []):
        found.append(f"candidate.json: does not require {wanted}, whose catalogue IDs page and item actions perform")
    # namespaces r1 (#100) and host_operations r1 (#76) are published; this
    # draft is not.
    for candidate in (name,):
        if (CANDIDATES / str(candidate)).exists():
            found.append(f"candidate.json: candidates/{candidate} exists; a draft must not be published as a candidate")
    provided = (CANDIDATES / "README.md").read_text(encoding="utf-8")
    table = provided.split("## Candidate Contracts this Host provides", 1)[-1].split("\n## ", 1)[0]
    if re.search(rf"^\|\s*`?{re.escape(str(name))}`?\s*\|", table, re.MULTILINE):
        found.append(f"candidate.json: candidates/README.md lists {name} as provided; this proposal is a draft")
    return found


def manifest_errors(manifest, draft):
    """A scenario's manifest excerpt: api_level, and candidate_contracts as #75 declares them."""
    if not isinstance(manifest, dict):
        return ["has no manifest excerpt"]
    found = []
    level = manifest.get("api_level")
    if json_type(level) != "integer" or level < 1:
        found.append("manifest: api_level is not a stable Level")
    if "candidate_contracts" in manifest:
        found += [f"manifest{message}" for message in
                  errors(manifest, document(CANDIDATE_DECLARATIONS), CANDIDATE_DECLARATIONS)]
        declared = manifest["candidate_contracts"]
        names = [d.get("name") for d in declared if isinstance(d, dict)]
        if len(set(names)) != len(names):
            found.append("manifest: declares a candidate twice")
        mine = {"name": draft["name"], "revision": draft["revision"]}
        if mine in declared:
            for required in draft["requires"]:
                if required not in declared:
                    found.append(f"manifest: declares {draft['name']} without the {required} it requires")
        if json_type(level) == "integer" and level < draft["base_level"]:
            found.append("manifest: api_level is below the draft's base_level")
    unknown = set(manifest) - {"api_level", "candidate_contracts"}
    if unknown:
        found.append(f"manifest: unexpected members {sorted(unknown)}")
    return found


def manifests(node):
    if isinstance(node, list):
        for item in node:
            yield from manifests(item)
    elif isinstance(node, dict):
        if "manifest" in node:
            yield node["manifest"]
        for key, value in node.items():
            if key != "manifest":
                yield from manifests(value)


def declares_candidate(manifest, draft):
    return {"name": draft["name"], "revision": draft["revision"]} in manifest.get("candidate_contracts", [])


def scenario_values(node, candidate):
    """Every answer and event a scenario step states. Steps under a Level 1
    manifest are checked against Level 1's schemas, the rest against the draft."""
    if isinstance(node, list):
        for item in node:
            yield from scenario_values(item, candidate)
    elif isinstance(node, dict):
        if "manifest" in node:
            candidate = node["_candidate"]
        for key, value in node.items():
            if key in ("answer", "answers"):
                for answer in (value if key == "answers" else [value]):
                    yield ("answer" if candidate else "level1/answer"), answer
            elif key == "event":
                yield ("event" if candidate else "level1/event"), value
            elif key in ("answer_illustrative", "manifest", "_candidate"):
                continue
            else:
                yield from scenario_values(value, candidate)


def level1_errors(definition, instance):
    name = definition.split("/", 1)[1]
    target, base = resolve(f"#/$defs/{name}", LEVEL1_SESSION)
    found = errors(instance, target, base)
    if name == "answer" and isinstance(instance, dict) and isinstance(instance.get("view"), dict):
        target, base = resolve("#/$defs/view", LEVEL1_VIEW)
        found += errors(instance["view"], target, base)
    return found


def mark(node, draft):
    """Annotates each node holding a manifest with whether it declares the draft."""
    if isinstance(node, list):
        for item in node:
            mark(item, draft)
    elif isinstance(node, dict):
        if isinstance(node.get("manifest"), dict):
            node["_candidate"] = declares_candidate(node["manifest"], draft)
        for key, value in list(node.items()):
            if key != "manifest":
                mark(value, draft)


# ----------------------------------------------------------------- budgets

def pointer(path):
    node = document(SCHEMA)
    for token in path.strip("/").split("/"):
        node = node[int(token)] if isinstance(node, list) else node[token]
    return node


# (what, schema location, value, words reference.md must say)
BUDGETS = [
    ("items per collection", "$defs/list/properties/items/maxItems", 2000, "2,000 items"),
    ("items per section", "$defs/section/properties/items/maxItems", 2000, "2,000 items"),
    ("sections per collection", "$defs/grid/properties/sections/maxItems", 32, "32 sections"),
    ("item actions per collection", "$defs/grid/properties/actions/maxItems", 6, "6 item actions"),
    ("buttons per actions component", "$defs/actions/properties/actions/maxItems", 8, "8 buttons"),
    ("children per row", "$defs/row/properties/content/maxItems", 4, "4 components"),
    ("top-level components", "$defs/page/properties/content/maxItems", 40, "40 components"),
    ("grid columns", "$defs/grid/properties/columns/maximum", 12, "2 to 12 columns"),
    ("visible rows", "$defs/list/properties/rows/maximum", 12, "1 to 12"),
    ("item title", "$defs/item/properties/title/maxLength", 256, "256"),
    ("item symbol", "$defs/item/properties/symbol/maxLength", 32, "32"),
    ("item accessory", "$defs/item/properties/accessory/maxLength", 64, "64"),
    ("item text", "$defs/item/properties/text/maxLength", 4096, "4,096"),
    ("loaded count", "$defs/page_event/allOf/4/then/properties/loaded/maximum", 2000, "2,000 items"),
]


def budget_errors():
    found = []
    reference = REFERENCE.read_text(encoding="utf-8")
    for what, location, value, words in BUDGETS:
        try:
            actual = pointer(location)
        except (KeyError, IndexError, TypeError):
            found.append(f"budget {what}: {location} is not in the schema")
            continue
        if actual != value:
            found.append(f"budget {what}: the schema says {actual}, the check expects {value}")
        if words not in reference:
            found.append(f"budget {what}: reference.md does not say \"{words}\"")
    for what, value in (("components", MAX_COMPONENTS), ("items", MAX_ITEMS)):
        if f"{value:,} {what}" not in reference and f"{value} {what}" not in reference:
            found.append(f"budget {what}: reference.md does not state the Host's limit of {value}")
    if "256 KiB" not in reference:
        found.append("budget: reference.md does not state the 256 KiB description limit")
    return found


# -------------------------------------------------------------------- main

def main():
    failures = []
    walk(document(SCHEMA), SCHEMA, "collections.schema.json", failures)

    draft = json.loads(DRAFT.read_text(encoding="utf-8"))
    failures += draft_candidate_errors(draft)
    failures += budget_errors()

    index = json.loads((HERE / "fixtures/index.json").read_text(encoding="utf-8"))
    for entry in index["fixtures"]:
        instance = json.loads((HERE / "fixtures" / entry["file"]).read_text(encoding="utf-8"))
        found = instance_errors(entry["definition"], instance)
        if entry["valid"] and found:
            failures.append(f"{entry['file']} should be accepted: " + "; ".join(found))
        if not entry["valid"] and not found:
            failures.append(f"{entry['file']} should be refused ({entry['note']})")
        if entry.get("level1") is not None:
            level1 = level1_errors(f"level1/{entry['definition']}", instance)
            if entry["level1"] and level1:
                failures.append(f"{entry['file']} should stay valid Level 1: " + "; ".join(level1))
            if not entry["level1"] and not level1:
                failures.append(f"{entry['file']} is accepted by Level 1's schema; Level 1 must stay unchanged")

    scenarios = sorted((HERE / "fixtures/scenarios").glob("*.json"))
    for path in scenarios:
        scenario = json.loads(path.read_text(encoding="utf-8"))
        declared = list(manifests(scenario))
        if not declared:
            failures.append(f"scenarios/{path.name}: declares no manifest")
        for manifest in declared:
            failures += [f"scenarios/{path.name}: {message}" for message in manifest_errors(manifest, draft)]
        mark(scenario, draft)
        for definition, value in scenario_values(scenario, False):
            found = level1_errors(definition, value) if definition.startswith("level1/") else instance_errors(definition, value)
            if found:
                failures.append(f"scenarios/{path.name}: a stated {definition} is invalid: " + "; ".join(found))

    if failures:
        print("\n".join(failures))
        return 1
    print(f"ok: schema well formed, draft candidate.json valid, unpublished and requiring host_operations and namespaces, "
          f"budgets agree with reference.md, {len(index['fixtures'])} fixtures and {len(scenarios)} scenarios agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())

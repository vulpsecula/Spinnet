#!/usr/bin/env python3
# PROPOSAL ONLY (#99). SPDX-License-Identifier: MIT
#
# Checks the draft namespace catalogue:
#
# - catalogue.json has the shape catalogue.schema.json describes, and the
#   draft schemas use only the JSON Schema (draft 2020-12) keywords Spinnet's
#   own JSONSchemaSubsetValidator implements, with every $ref resolving;
# - every name Plugin API Level 1 publishes (Host Commands, Host Services,
#   standard actions, Capabilities, SDK wrappers and builders,
#   spinnet.environment, answer members, View Events, script globals) is
#   mapped, read from Level 1's own files, and level1-mapping.md lists it;
# - each operation is consistent: one ID in its namespace, no ID reusing a
#   Level 1 name, every main entry point stated, Level 1 names where Level 1
#   offers it, input and result definitions in namespaces.schema.json, the
#   Capability table derived from the operations, failure categories that
#   match its authority;
# - namespaces.schema.json's ID lists, namespaces.d.ts's @id and @entry tags
#   and the draft candidate.json all equal what the catalogue offers;
# - every fixture is accepted or refused as fixtures/index.json says, and
#   every scenario declares its manifest as #75 specifies;
# - the host_operations (#70) and collections (#74) proposals use the
#   catalogue's IDs and require this candidate, and Level 1's schemas still
#   refuse every ID here.
#
# It needs nothing beyond Python 3.
#
#   python3 PluginAPI/proposals/namespaces/check.py

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
API = (HERE / "../..").resolve()
SCHEMA = HERE / "namespaces.schema.json"
CATALOGUE_SCHEMA = HERE / "catalogue.schema.json"
CATALOGUE = HERE / "catalogue.json"
TYPES = HERE / "namespaces.d.ts"
MAPPING = HERE / "level1-mapping.md"
DRAFT = HERE / "candidate.json"
HOST_OPERATIONS = (HERE / "../bounded-host-operations").resolve()
COLLECTIONS = (HERE / "../collections").resolve()
LEVEL1_MANIFEST = API / "schemas/manifest.schema.json"
LEVEL1_VIEW = API / "schemas/plugin-view.schema.json"
LEVEL1_SESSION = API / "schemas/view-session.schema.json"
CANDIDATES = API / "candidates"
CANDIDATE_METADATA = CANDIDATES / "schemas/candidate-metadata.schema.json"
CANDIDATE_DECLARATIONS = CANDIDATES / "schemas/candidate-contracts.schema.json"

MAIN_ENTRIES = ("call", "command", "view_action", "request")
OFFERED = ("level1", "candidate")
# The draft candidate that provides the catalogue-ID form at each entry point.
PROVIDER = {"call": "namespaces", "command": "namespaces", "view_action": "collections",
            "request": "host_operations", "answer": "namespaces", "source": "namespaces"}
# The kind of Level 1 name that offers an operation at each entry point.
LEVEL1_KIND = {"call": "host_service", "command": "host_command", "view_action": "standard_action",
               "answer": "answer_member", "source": "view_member"}
SDK_ENTRIES = ("call", "view_action", "request")

ANNOTATIONS = {"$schema", "$id", "$comment", "$defs", "title", "description", "examples"}
ASSERTIONS = {
    "$ref", "type", "const", "enum", "properties", "required", "additionalProperties",
    "items", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength", "pattern", "minimum", "maximum",
    "allOf", "oneOf", "if", "then", "propertyNames", "maxProperties",
}

_documents = {}


# ------------------------------------------------------------ the validator
# The same subset as the other proposals' check.py and the Spinnet test
# suite's JSONSchemaSubsetValidator.

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
        found.append(f"{path or '/'}: {json.dumps(instance, ensure_ascii=False)} is not one of the allowed values")
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
    """Refuses unsupported keywords and unresolvable $refs anywhere in a draft schema."""
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


def defined(name, path=SCHEMA):
    target, base = resolve("#/$defs/" + name, path)
    return target, base


def check_against(name, instance, path=SCHEMA):
    target, base = defined(name, path)
    return errors(instance, target, base)


# -------------------------------------------------------------- Level 1 names

def level1_names():
    """Every name Level 1 publishes, by kind, read from Level 1's own files."""
    manifest = document(LEVEL1_MANIFEST)["$defs"]
    view = document(LEVEL1_VIEW)["$defs"]
    session = document(LEVEL1_SESSION)["$defs"]
    names = {
        "host_command": list(manifest["hostCommand"]["enum"]),
        "capability": list(manifest["capability"]["enum"]),
        "standard_action": list(view["action"]["properties"]["perform"]["enum"]),
        "answer_member": list(session["answer"]["properties"].keys()),
        "view_event": list(session["event"]["properties"]["type"]["enum"]),
    }
    source = (API / "spinnet.js").read_text(encoding="utf-8")
    wrappers, builders, environment, area = {}, [], [], None
    for line in source.splitlines():
        opened = re.match(r"^    (\w+): area\(\{", line)
        if opened:
            area = opened.group(1)
            continue
        wrapped = re.match(r'^\s+(\w+): service\("(\w+)"\)', line)
        if wrapped and area:
            wrappers[f"spinnet.{area}.{wrapped.group(1)}"] = wrapped.group(2)
            continue
        if area == "ui":
            member = re.match(r"^      (\w+): ", line)
            if member:
                builders.append(f"spinnet.ui.{member.group(1)}")
        if area == "environment":
            member = re.match(r"^      (\w+): environment\.", line)
            if member:
                environment.append(f"spinnet.environment.{member.group(1)}")
    names["sdk_wrapper"] = list(wrappers)
    names["sdk_builder"] = builders
    names["environment"] = environment
    types = (API / "spinnet.d.ts").read_text(encoding="utf-8")
    types = re.sub(r"/\*.*?\*/", "", types, flags=re.DOTALL)
    union = types.split("export type HostServiceName =", 1)[1].split(";", 1)[0]
    names["host_service"] = re.findall(r'\|\s*"(\w+)"', union)
    scripts = (API / "reference/scripts.md").read_text(encoding="utf-8")
    table = scripts.split("## Globals", 1)[1].split("\n## ", 1)[0]
    names["global"] = []
    for row in re.findall(r"^\| ([^|]+) \|", table, re.MULTILINE):
        names["global"] += [n.split("(")[0] for n in re.findall(r"`([^`]+)`", row)]
    names["view_member"] = ["detail.sections[].fetch.request"]
    return names, wrappers


def level1_errors(catalogue):
    found = []
    names, wrappers = level1_names()
    if set(wrappers.values()) != set(names["host_service"]):
        found.append("Level 1: spinnet.js's wrappers and spinnet.d.ts's HostServiceName name different Host Services")
    mapped = {}
    sections = [("operations", "id"), ("builders", "id"), ("values", "id"), ("globals", "name"),
                ("answer_members", "name"), ("events", "name"), ("capabilities", "name")]
    for section, key in sections:
        for record in catalogue[section]:
            for name in record["level1"]:
                mapped.setdefault((name["kind"], name["name"]), []).append((record[key], name.get("note")))
    for kind, published in names.items():
        for name in published:
            if (kind, name) not in mapped:
                found.append(f"Level 1 {kind} {name} is not mapped in catalogue.json")
    for (kind, name), targets in mapped.items():
        if name not in names.get(kind, []):
            found.append(f"catalogue.json maps {kind} {name}, which Level 1 does not publish")
        if len(targets) > 1 and any(note is None for _, note in targets):
            found.append(f"Level 1 {kind} {name} maps to {[t for t, _ in targets]} without a note telling them apart")
        if kind in ("host_service", "standard_action", "sdk_wrapper") and len(targets) > 1:
            found.append(f"Level 1 {kind} {name} maps to more than one operation")
    mapping = MAPPING.read_text(encoding="utf-8")
    for kind, published in names.items():
        for name in published:
            if f"`{name}`" not in mapping:
                found.append(f"level1-mapping.md does not list Level 1 {kind} {name}")
    # Level 1 is unchanged: its schemas refuse every catalogue ID.
    ids = {o["id"] for o in catalogue["operations"]}
    for kind in ("host_command", "host_service", "standard_action"):
        clash = ids & set(names[kind])
        if clash:
            found.append(f"catalogue IDs {sorted(clash)} reuse Level 1 {kind} names")
    return found, names


# ---------------------------------------------------------------- operations

def offered(operation, entry):
    point = operation["entry_points"].get(entry)
    return point is not None and point["status"] in OFFERED


def ids_at(catalogue, entry):
    return [o["id"] for o in catalogue["operations"] if o["status"] != "reserved" and offered(o, entry)]


def object_alternative(schema, base):
    """The object form of an input definition: (properties, required) or None."""
    if "$ref" in schema:
        target, target_base = resolve(schema["$ref"], base)
        return object_alternative(target, target_base)
    if schema.get("type") == "object" and "properties" in schema:
        return schema["properties"], schema.get("required", [])
    for alternative in schema.get("oneOf", []):
        found = object_alternative(alternative, base)
        if found:
            return found
    return None


def operation_errors(catalogue):
    found = []
    namespaces = {n["name"]: n["holds"] for n in catalogue["namespaces"]}
    seen = set()
    schema_defs = document(SCHEMA)["$defs"]
    for o in catalogue["operations"]:
        where = f"operation {o['id']}"
        if o["id"] in seen:
            found.append(f"{where}: appears twice")
        seen.add(o["id"])
        if o["namespace"] != o["id"].split(".")[0]:
            found.append(f"{where}: namespace {o['namespace']} is not its ID's first segment")
        if namespaces.get(o["namespace"]) not in ("operations", "reserved"):
            found.append(f"{where}: namespace {o['namespace']} is not declared as holding operations")
        if o["status"] == "reserved":
            if any(o["entry_points"][e]["status"] in OFFERED for e in o["entry_points"]):
                found.append(f"{where}: a reserved operation is offered at an entry point")
            continue
        if o["status"] == "level1" and not o["level1"]:
            found.append(f"{where}: status level1 without a Level 1 name")
        if o["status"] == "candidate" and o["level1"]:
            found.append(f"{where}: status candidate with Level 1 names")
        if not any(o["entry_points"][e]["status"] in OFFERED for e in o["entry_points"]):
            found.append(f"{where}: offered at no entry point")
        kinds = {n["kind"] for n in o["level1"]}
        for entry, point in o["entry_points"].items():
            if point["status"] in OFFERED and point.get("candidate") != PROVIDER[entry]:
                found.append(f"{where}: {entry} is provided by {PROVIDER[entry]}, not {point.get('candidate')}")
            if point["status"] == "level1" and LEVEL1_KIND.get(entry) not in kinds:
                found.append(f"{where}: {entry} is level1 but no Level 1 {LEVEL1_KIND.get(entry)} is named")
            if point["status"] == "candidate" and LEVEL1_KIND.get(entry) in kinds and entry != "view_action":
                found.append(f"{where}: {entry} is candidate although a Level 1 {LEVEL1_KIND[entry]} is named")
            if "capabilities" in point and entry != "command":
                found.append(f"{where}: only the command entry point may differ in Capabilities")
        for entry, kind in LEVEL1_KIND.items():
            if kind in kinds and o["entry_points"].get(entry, {}).get("status") != "level1":
                found.append(f"{where}: Level 1 offers it as a {kind}, but {entry} is not level1")
        if ("default_title" in o) != offered(o, "view_action"):
            found.append(f"{where}: default_title belongs to exactly the operations a page action may perform")
        if o.get("item_action") and (not offered(o, "view_action") or o["primary_member"] != "text"):
            found.append(f"{where}: an item action performs it on the item's text, so it needs a view_action and primary member text")
        needs = set(o["capabilities"])
        for entry in MAIN_ENTRIES:
            point = o["entry_points"][entry]
            if point["status"] in OFFERED:
                needs |= set(point.get("capabilities", o["capabilities"]))
        if bool(o["capabilities"]) != ("capability_denied" in o["failures"]):
            found.append(f"{where}: capability_denied is a failure exactly when the operation names a Capability")
        permission_failure = {"accessibility": "system_permission_denied", "screen_recording": "system_permission_denied",
                              "automation": "automation_permission_denied"}.get(o["system_permission"])
        for failure in ("system_permission_denied", "automation_permission_denied"):
            if (failure in o["failures"]) != (failure == permission_failure):
                found.append(f"{where}: {failure} does not match its System Permission {o['system_permission']}")
        if "host_service_failed" not in o["failures"]:
            found.append(f"{where}: every operation can fail with host_service_failed")
        for member in ("input", "result"):
            ref = o[member]
            name = ref.split("#/$defs/", 1)[1]
            if name != f"{o['id']}.{member}" or name not in schema_defs:
                found.append(f"{where}: {member} {ref} is not its own definition in namespaces.schema.json")
        if o["primary_member"]:
            alternative = object_alternative(schema_defs[o["id"] + ".input"], SCHEMA)
            if not alternative or o["primary_member"] not in alternative[1]:
                found.append(f"{where}: primary member {o['primary_member']} is not a required member of its input")
        elif "oneOf" in schema_defs[o["id"] + ".input"] and any(
                alt.get("type") == "string" for alt in schema_defs[o["id"] + ".input"]["oneOf"]):
            found.append(f"{where}: its input takes a bare string but names no primary member")
    rows = {row["name"]: row for row in catalogue["capabilities"]}
    for row in catalogue["capabilities"]:
        derived = [o["id"] for o in catalogue["operations"] if o["status"] != "reserved" and row["name"] in o["capabilities"]]
        if row["operations"] != derived:
            found.append(f"capability {row['name']}: lists {row['operations']}, the operations name {derived}")
    for o in catalogue["operations"]:
        for capability in o["capabilities"]:
            if capability not in rows:
                found.append(f"operation {o['id']}: Capability {capability} is not in the capability table")
    ids = {o["id"]: o for o in catalogue["operations"]}
    for builder in catalogue["builders"]:
        target = ids.get(builder.get("operation"))
        if "operation" in builder and (target is None or not (offered(target, "answer") or offered(target, "view_action"))):
            found.append(f"builder {builder['id']}: builds {builder['operation']}, which has no answer or view_action entry point")
    return found


# ------------------------------------------------------------------ the schema

def schema_errors(catalogue):
    found = []
    walk(document(SCHEMA), SCHEMA, "namespaces.schema.json", found)
    walk(document(CATALOGUE_SCHEMA), CATALOGUE_SCHEMA, "catalogue.schema.json", found)
    defs = document(SCHEMA)["$defs"]
    lists = {"call_id": ids_at(catalogue, "call"), "host_command_id": ids_at(catalogue, "command"),
             "view_action_id": ids_at(catalogue, "view_action"), "request_id": ids_at(catalogue, "request"),
             "item_action_id": [o["id"] for o in catalogue["operations"] if o.get("item_action")],
             "operation_id": [o["id"] for o in catalogue["operations"] if o["status"] != "reserved"]}
    for name, expected in lists.items():
        if defs.get(name, {}).get("enum") != expected:
            found.append(f"namespaces.schema.json {name} is not the catalogue's {expected}")
    performed = set(lists["view_action_id"]) | set(lists["request_id"])
    covered = {clause["if"]["properties"]["perform"]["const"] for clause in defs["perform_input"]["allOf"]}
    if covered != performed:
        found.append(f"perform_input covers {sorted(covered)}, the catalogue performs {sorted(performed)}")
    called = {clause["if"]["properties"]["service"]["const"] for clause in defs["call"]["allOf"]}
    if called != set(lists["call_id"]):
        found.append("call does not check the input of exactly the catalogue's call IDs")
    return found


# -------------------------------------------------------------------- fixtures

def candidate_metadata():
    drafts = {}
    for path in (DRAFT, HOST_OPERATIONS / "candidate.json", COLLECTIONS / "candidate.json"):
        draft = json.loads(path.read_text(encoding="utf-8"))
        drafts[draft["name"]] = draft
    return drafts


def manifest_errors(manifest, drafts):
    """A manifest excerpt: api_level and candidate_contracts as #75 declares them."""
    if not isinstance(manifest, dict):
        return ["has no manifest excerpt"]
    found = []
    level = manifest.get("api_level")
    if json_type(level) != "integer" or level < 1:
        found.append("manifest: api_level is not a stable Level")
    declared = manifest.get("candidate_contracts", [])
    if "candidate_contracts" in manifest:
        found += [f"manifest{m}" for m in errors({"candidate_contracts": declared}, document(CANDIDATE_DECLARATIONS),
                                                 CANDIDATE_DECLARATIONS)]
    names = [d.get("name") for d in declared if isinstance(d, dict)]
    if len(set(names)) != len(names):
        found.append("manifest: declares a candidate twice")
    for declaration in declared:
        draft = drafts.get(declaration.get("name"))
        if draft is None:
            found.append(f"manifest: declares {declaration}, which no draft beside this one defines")
            continue
        if declaration.get("revision") != draft["revision"]:
            found.append(f"manifest: declares {declaration}, the draft is r{draft['revision']}")
        for required in draft["requires"]:
            if required not in declared:
                found.append(f"manifest: declares {draft['name']} without the {required} it requires")
        if json_type(level) == "integer" and level < draft["base_level"]:
            found.append("manifest: api_level is below a declared draft's base_level")
    return found


def command_rule_errors(command, catalogue):
    """What a shape cannot say about a Command that names an operation."""
    operation = next((o for o in catalogue["operations"] if o["id"] == command.get("host_command")), None)
    if operation is None:
        return []
    found = []
    fixed = command.get("input", {}) if isinstance(command.get("input"), dict) else {}
    alternative = object_alternative(document(SCHEMA)["$defs"][operation["id"] + ".input"], SCHEMA)
    members = alternative[0] if alternative else {}
    for name in fixed:
        if name not in members:
            found.append(f"command {command.get('id')}: input fixes {name}, which {operation['id']} does not take")
    configured = set()
    if "configuration_field" in command:
        if not operation["primary_member"]:
            found.append(f"command {command.get('id')}: {operation['id']} has no primary member for a single configuration_field")
        else:
            configured.add(operation["primary_member"])
    nested = operation["id"] in ("apps.perform", "apps.openDeepLink")
    for field in command.get("configuration_fields", []):
        key = field.get("key")
        if not nested and key not in members:
            found.append(f"command {command.get('id')}: configuration field {key} is not a member of {operation['id']}'s input")
        if not nested:
            configured.add(key)
    twice = configured & set(fixed)
    if twice:
        found.append(f"command {command.get('id')}: {sorted(twice)} are both fixed in input and configured")
    if not configured and not nested and command.get("is_configurable") is not True:
        # Nothing is configured, so the fixed input is the operation's whole input.
        whole = fixed if fixed else None
        target, base = defined(operation["id"] + ".input")
        problems = errors(whole, target, base)
        if problems:
            found.append(f"command {command.get('id')}: its fixed input is not {operation['id']}'s input: " + "; ".join(problems))
    return found


def manifest_fixture_errors(manifest, catalogue, drafts):
    found = manifest_errors(manifest, drafts)
    if not any(d.get("name") == "namespaces" for d in manifest.get("candidate_contracts", [])):
        found.append("manifest: does not declare namespaces")
    capabilities, _ = resolve("#/$defs/capability", LEVEL1_MANIFEST)
    for capability in manifest.get("capabilities", []):
        if errors(capability, capabilities, LEVEL1_MANIFEST):
            found.append(f"manifest: {capability} is not a Capability")
    for command in manifest.get("commands", []):
        found += [f"command {command.get('id')}{m}" for m in check_against("command", command)]
        found += command_rule_errors(command, catalogue)
    return found


def operation_fixture_errors(value):
    return check_against("operation", value, HOST_OPERATIONS / "host-operations.schema.json")


def value_errors(definition, value, catalogue, drafts):
    if definition == "manifest":
        return manifest_fixture_errors(value, catalogue, drafts)
    if definition == "operation":
        return operation_fixture_errors(value)
    if definition == "command":
        return check_against("command", value) + command_rule_errors(value, catalogue)
    if definition == "level1_command":
        target, base = resolve("#/$defs/command", LEVEL1_MANIFEST)
        return errors(value, target, base)
    if definition == "level1_action":
        target, base = resolve("#/$defs/action", LEVEL1_VIEW)
        return errors(value, target, base)
    return check_against(definition, value)


def scenario_values(node):
    checked = ("call", "command", "view_action", "operation", "level1_command", "level1_action")
    if isinstance(node, list):
        for item in node:
            yield from scenario_values(item)
    elif isinstance(node, dict):
        for key, value in node.items():
            if key in checked:
                yield key, value
            elif key != "manifest":
                yield from scenario_values(value)


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


def fixture_errors(catalogue):
    found = []
    drafts = candidate_metadata()
    index = json.loads((HERE / "fixtures/index.json").read_text(encoding="utf-8"))
    for entry in index["fixtures"]:
        value = json.loads((HERE / "fixtures" / entry["file"]).read_text(encoding="utf-8"))
        problems = value_errors(entry["definition"], value, catalogue, drafts)
        if entry["valid"] and problems:
            found.append(f"{entry['file']} should be accepted: " + "; ".join(problems))
        if not entry["valid"] and not problems:
            found.append(f"{entry['file']} should be refused ({entry['note']})")
    scenarios = sorted((HERE / "fixtures/scenarios").glob("*.json"))
    for path in scenarios:
        scenario = json.loads(path.read_text(encoding="utf-8"))
        declared = list(manifests(scenario))
        if not declared:
            found.append(f"scenarios/{path.name}: declares no manifest")
        for manifest in declared:
            found += [f"scenarios/{path.name}: {m}" for m in manifest_errors(manifest, drafts)]
        for definition, value in scenario_values(scenario):
            problems = value_errors(definition, value, catalogue, drafts)
            if problems:
                found.append(f"scenarios/{path.name}: a stated {definition} is invalid: " + "; ".join(problems))
    return found, len(index["fixtures"]), len(scenarios)


# ----------------------------------------------------------------- the types

def types_errors(catalogue):
    found = []
    text = TYPES.read_text(encoding="utf-8")
    tagged = {}
    for match in re.finditer(r"@id ([\w.]+) @entry ([\w ]+?)\s*\*/\s*readonly (\w+):", text):
        identifier, entries, member = match.group(1), match.group(2).split(), match.group(3)
        if identifier in tagged:
            found.append(f"namespaces.d.ts tags {identifier} twice")
        tagged[identifier] = entries
        if member != identifier.split(".")[-1]:
            found.append(f"namespaces.d.ts declares {identifier} as {member}; its member is its ID's last segment")
    for o in catalogue["operations"]:
        if o["status"] == "reserved":
            continue
        expected = [e for e in SDK_ENTRIES if offered(o, e)]
        if expected and tagged.get(o["id"]) != expected:
            found.append(f"namespaces.d.ts: {o['id']} should be tagged @entry {' '.join(expected)}, is {tagged.get(o['id'])}")
        if not expected and o["id"] in tagged:
            found.append(f"namespaces.d.ts: {o['id']} has no SDK entry point but is declared")
    block = text.split("export interface Operations {", 1)[1].split("\n}", 1)[0]
    typed = re.findall(r'^\s+"([\w.]+)": \{', block, re.MULTILINE)
    expected = [o["id"] for o in catalogue["operations"] if o["status"] != "reserved"]
    if typed != expected:
        found.append(f"namespaces.d.ts Operations lists {typed}, the catalogue {expected}")
    for name, entry in (("CallID", "call"), ("PerformID", "request"), ("HostCommandID", "command")):
        union = text.split(f"export type {name} =", 1)[1].split(";", 1)[0]
        if re.findall(r'"([\w.]+)"', union) != ids_at(catalogue, entry):
            found.append(f"namespaces.d.ts {name} is not the catalogue's {entry} IDs")
    if set(ids_at(catalogue, "view_action")) != set(ids_at(catalogue, "request")):
        found.append("PerformID stands for page actions and requests, which the catalogue offers differently")
    return found


# ------------------------------------------------------- candidate metadata

def draft_errors(catalogue):
    found = []
    draft = json.loads(DRAFT.read_text(encoding="utf-8"))
    found += [f"candidate.json{m}" for m in errors(draft, document(CANDIDATE_METADATA), CANDIDATE_METADATA)]
    if draft.get("tag") != f"plugin-api-candidate/{draft['name']}/r{draft['revision']}":
        found.append("candidate.json: tag does not name its own name and revision")
    if {"name": draft["name"], "revision": draft["revision"]} != catalogue["candidate"]:
        found.append("candidate.json and catalogue.json name different revisions")
    members = [(m["kind"], m["name"]) for m in draft["members"]]
    expected = [("host_service", i) for i in ids_at(catalogue, "call")]
    expected += [("behaviour", "host_command:" + i) for i in ids_at(catalogue, "command")]
    listed = [m for m in members if m[0] == "host_service" or m[1].startswith("host_command:")]
    if listed != expected:
        found.append("candidate.json's host_service and host_command members are not the catalogue's call and command IDs")
    for name in ("namespaces", "host_operations", "collections"):
        if (CANDIDATES / name).exists():
            found.append(f"candidates/{name} exists; a draft must not be published as a candidate")
        provided = (CANDIDATES / "README.md").read_text(encoding="utf-8")
        table = provided.split("## Candidate Contracts this Host provides", 1)[-1].split("\n## ", 1)[0]
        if re.search(rf"^\|\s*`?{name}`?\s*\|", table, re.MULTILINE):
            found.append(f"candidates/README.md lists {name} as provided; it is a draft")
    return found


# --------------------------------------------------------- the other proposals

LEVEL1_PERFORMS = {"copy_text", "open_url", "insert_text", "open_plugin_settings"}
OLD_KINDS = {"insert_text", "quit_app", "start_task"}


def performs(node, inside_view=False):
    """Every perform and operation kind in answers and events outside a Level 1 view."""
    if isinstance(node, list):
        for item in node:
            yield from performs(item, inside_view)
    elif isinstance(node, dict):
        for key, value in node.items():
            if key == "view":
                continue
            if key == "perform" and isinstance(value, str) and not inside_view:
                yield "perform", value
            if key == "kind" and value in OLD_KINDS:
                yield "kind", value
            yield from performs(value, inside_view)


def answers_and_events(node):
    if isinstance(node, list):
        for item in node:
            yield from answers_and_events(item)
    elif isinstance(node, dict):
        for key, value in node.items():
            if key in ("answer", "answers", "script_answers", "event", "operation", "event_illustrative",
                       "answer_illustrative", "script_answers_illustrative"):
                yield value
            else:
                yield from answers_and_events(value)


def proposal_errors(catalogue):
    found = []
    drafts = candidate_metadata()
    namespaces = {"name": "namespaces", "revision": 1}
    operations = {"name": "host_operations", "revision": drafts["host_operations"]["revision"]}
    if namespaces not in drafts["host_operations"]["requires"]:
        found.append("host_operations' candidate.json does not require namespaces r1")
    for required in (namespaces, operations):
        if required not in drafts["collections"]["requires"]:
            found.append(f"collections' candidate.json does not require {required}")
    if drafts["namespaces"]["requires"]:
        found.append("namespaces requires nothing: the names are what the other two build on")
    requested = [m["name"].split(":", 1)[1] for m in drafts["host_operations"]["members"] if m["name"].startswith("request:")]
    if requested != ids_at(catalogue, "request"):
        found.append(f"host_operations' request members {requested} are not the catalogue's request IDs")
    actions = [m["name"] for m in drafts["collections"]["members"] if m["kind"] == "standard_action"]
    if actions != ids_at(catalogue, "view_action"):
        found.append(f"collections' standard_action members {actions} are not the catalogue's view_action IDs")
    operation = document(HOST_OPERATIONS / "host-operations.schema.json")["$defs"]["operation"]
    if operation["properties"]["perform"].get("$ref") != "../namespaces/namespaces.schema.json#/$defs/request_id":
        found.append("host_operations' operation.perform does not take the catalogue's request IDs")
    if {"$ref": "../namespaces/namespaces.schema.json#/$defs/perform_input"} not in operation.get("allOf", []):
        found.append("host_operations' operation does not take its input from the catalogue")
    finished = document(HOST_OPERATIONS / "host-operations.schema.json")["$defs"]["operation_finished"]
    if finished["properties"].get("perform", {}).get("$ref") != "../namespaces/namespaces.schema.json#/$defs/request_id":
        found.append("host_operations' operation_finished does not name the operation by its catalogue ID")
    collections = document(COLLECTIONS / "collections.schema.json")["$defs"]
    page_action = json.dumps(collections["page_action"])
    if "../namespaces/namespaces.schema.json#/$defs/view_action" not in page_action:
        found.append("collections' page_action does not perform through the catalogue's view_action")
    if collections["item_action"]["properties"]["perform"].get("$ref") != "../namespaces/namespaces.schema.json#/$defs/item_action_id":
        found.append("collections' item_action does not perform the catalogue's item action IDs")
    known = {o["id"] for o in catalogue["operations"]}
    for proposal in (HOST_OPERATIONS, COLLECTIONS):
        for path in sorted((proposal / "fixtures").rglob("*.json")):
            if path.name == "index.json":
                continue
            value = json.loads(path.read_text(encoding="utf-8"))
            sources = [value] if path.parent.name != "scenarios" else list(answers_and_events(value))
            for source in sources:
                for kind, name in performs(source):
                    where = f"{proposal.name}/{path.relative_to(proposal)}"
                    if kind == "kind":
                        found.append(f"{where}: names an operation by kind {name}; use perform and its catalogue ID")
                    elif name not in known:
                        found.append(f"{where}: performs {name}, which is not a catalogue ID")
            if path.parent.name == "scenarios":
                for call in re.findall(r'"script_calls": "([^"]+)"', path.read_text(encoding="utf-8")):
                    if call not in ids_at(catalogue, "call"):
                        found.append(f"{proposal.name}/{path.relative_to(proposal)}: script_calls {call} is not a catalogue call ID")
    return found


# ------------------------------------------------------------------------ main

def main():
    failures = []
    catalogue = json.loads(CATALOGUE.read_text(encoding="utf-8"))
    failures += [f"catalogue.json{m}" for m in errors(catalogue, document(CATALOGUE_SCHEMA), CATALOGUE_SCHEMA)]
    found, _ = level1_errors(catalogue)
    failures += found
    failures += operation_errors(catalogue)
    failures += schema_errors(catalogue)
    failures += types_errors(catalogue)
    failures += draft_errors(catalogue)
    found, fixtures, scenarios = fixture_errors(catalogue)
    failures += found
    failures += proposal_errors(catalogue)
    if failures:
        print("\n".join(failures))
        return 1
    live = [o for o in catalogue["operations"] if o["status"] != "reserved"]
    print(f"ok: {len(live)} operations in {len({o['namespace'] for o in live})} namespaces "
          f"({len(catalogue['operations']) - len(live)} reserved) map every Level 1 name; schema, types and "
          f"candidate.json agree with the catalogue; {fixtures} fixtures and {scenarios} scenarios agree; "
          f"host_operations and collections use the catalogue's IDs")
    return 0


if __name__ == "__main__":
    sys.exit(main())

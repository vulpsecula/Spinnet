# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema==4.26.0", "referencing==0.37.0"]
# ///
"""Check the shared current-interface matrix with the standard Draft 2020-12 validator."""
import argparse
import json
from pathlib import Path
import sys

from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

INDEX_SCHEMA = {
    "type": "object", "required": ["cases"],
    "properties": {"cases": {"type": "array", "minItems": 1, "items": {
        "type": "object", "required": ["name", "value", "checks"],
        "properties": {
            "name": {"type": "string", "minLength": 1}, "value": {},
            "sdk_script": {"type": "string", "minLength": 1},
            "host_versions": {"type": "array", "minItems": 1, "items": {
                "type": "object", "required": ["version", "compatible"],
                "properties": {"version": {"type": "string", "minLength": 1},
                               "compatible": {"type": "boolean"}}, "additionalProperties": False}},
            "checks": {"type": "array", "minItems": 1, "items": {
                "type": "object", "required": ["schema", "valid"],
                "properties": {
                    "schema": {"type": "string", "minLength": 1},
                    "definition": {"type": "string", "minLength": 1},
                    "valid": {"type": "boolean"},
                }, "additionalProperties": False,
            }},
        }, "additionalProperties": False,
    }}},
}
FORMAT_NOTE = (
    "format annotations are not asserted, including meta-schema regex format: "
    "Python re cannot validate ICU Unicode properties. Payload patterns still run; "
    "an unsupported pattern is an execution error, never an expected refusal."
)


def read_json(path):
    def reject_constant(value):
        raise ValueError(f"non-JSON numeric constant: {value}")

    def unique_members(pairs):
        value = {}
        for name, member in pairs:
            if name in value:
                raise ValueError(f"duplicate JSON member: {name}")
            value[name] = member
        return value

    try:
        return json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant,
                          object_pairs_hook=unique_members)
    except ValueError as error:
        raise ValueError(f"{path}: {error}") from error


def check(api):
    api = api.resolve()
    schema_root = (api / "schemas").resolve()
    index = read_json(api / "fixtures/conformance/index.json")
    Draft202012Validator(INDEX_SCHEMA).validate(index)
    paths = sorted(schema_root.rglob("*.json"))
    if not paths:
        raise ValueError(f"no schemas in {schema_root}")
    schemas = {}
    for path in paths:
        if not path.resolve().is_relative_to(schema_root):
            raise ValueError(f"schema escapes schemas directory: {path}")
        schema = read_json(path)
        # Draft 2020-12 format is optional. Its regex format checker uses Python
        # re, which rejects the public ICU patterns; structural checks still run.
        try:
            Draft202012Validator.check_schema(schema, format_checker=None)
        except Exception as error:
            raise ValueError(f"{path}: {error}") from error
        schemas[path.relative_to(schema_root).as_posix()] = schema
    registry = Registry().with_resources(
        ((schema_root / name).as_uri(), Resource.from_contents(schema, default_specification=DRAFT202012))
        for name, schema in schemas.items()
    )
    names = set()
    failures = []
    count = 0
    for fixture in index["cases"]:
        name = fixture["name"]
        if name in names:
            raise ValueError(f"duplicate case name: {name}")
        names.add(name)
        entries = set()
        for entry in fixture["checks"]:
            schema_name = entry["schema"]
            # Only canonical repository-relative schema paths are accepted.
            if schema_name not in schemas or Path(schema_name).as_posix() != schema_name:
                raise ValueError(f"{name}: unknown or unsafe schema path: {schema_name}")
            key = (schema_name, entry.get("definition"))
            if key in entries:
                raise ValueError(f"{name}: duplicate check: {key}")
            entries.add(key)
            uri = (schema_root / schema_name).as_uri()
            if "definition" in entry:
                # Escape the JSON Pointer member, rather than interpreting it as a path.
                member = entry["definition"].replace("~", "~0").replace("/", "~1")
                uri += "#/$defs/" + member
            validator = Draft202012Validator({"$ref": uri}, registry=registry)
            try:
                errors = list(validator.iter_errors(fixture["value"]))
            except Exception as error:
                # A missing reference or unsupported regex is a broken check,
                # even when the fixture's expected answer is invalid.
                raise ValueError(f"{name}, {schema_name}: {error}") from error
            count += 1
            if (not errors) != entry["valid"]:
                failures.append({"case": name, **entry, "actual": not errors,
                                 "errors": [error.message for error in errors]})
    return {"payloads": len(names), "checks": count, "schemaMetaChecks": len(schemas),
            "formatNote": FORMAT_NOTE, "failures": failures}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-dir", type=Path,
                        default=Path(__file__).resolve().parents[1] / "PluginAPI",
                        help="PluginAPI directory (default: beside this script's repository)")
    args = parser.parse_args()
    try:
        report = check(args.api_dir)
    except Exception as error:
        print(f"Plugin schema check could not complete: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2))
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())

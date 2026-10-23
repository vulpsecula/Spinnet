"""Black-box regression checks for the standard schema check's failure behavior."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]
CHECKER = REPOSITORY / "script/check_plugin_schemas.py"


class PluginSchemaCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spinnet-schema-check-")
        self.addCleanup(self.temp.cleanup)
        self.api = Path(self.temp.name) / "PluginAPI"
        (self.api / "schemas").mkdir(parents=True)
        (self.api / "fixtures/stable-levels").mkdir(parents=True)
        self.schema = {"$schema": "https://json-schema.org/draft/2020-12/schema",
                       "$defs": {"answer": {"type": "string"}}}
        self.index = {"cases": [{"name": "example", "value": "hello", "checks": [
            {"schema": "answer.json", "definition": "answer", "level": 1, "valid": True}
        ]}]}

    def run_check(self):
        (self.api / "schemas/answer.json").write_text(json.dumps(self.schema))
        (self.api / "fixtures/stable-levels/index.json").write_text(json.dumps(self.index))
        return subprocess.run(["uv", "run", "--locked", "--script", str(CHECKER),
                               "--api-dir", str(self.api)], cwd=self.temp.name,
                              text=True, capture_output=True)

    def test_default_finds_current_matrix_from_an_unrelated_working_directory(self):
        result = subprocess.run(["uv", "run", "--locked", "--script", str(CHECKER)],
                                cwd=self.temp.name, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        report = json.loads(result.stdout)
        index = json.loads((REPOSITORY / "PluginAPI/fixtures/stable-levels/index.json").read_text())
        self.assertEqual(report["payloads"], len(index["cases"]))
        self.assertEqual(report["checks"], sum(len(case["checks"]) for case in index["cases"]))
        self.assertEqual(report["schemaMetaChecks"], len(list((REPOSITORY / "PluginAPI/schemas").rglob("*.json"))))
        self.assertEqual(report["failures"], [])

    def test_both_unexpected_acceptance_and_refusal_fail_with_case_diagnostics(self):
        for value, expected in [(12, True), ("hello", False)]:
            with self.subTest(value=value):
                self.index["cases"][0]["value"] = value
                self.index["cases"][0]["checks"][0]["valid"] = expected
                result = self.run_check()
                self.assertEqual(result.returncode, 1, result.stderr)
                failure = json.loads(result.stdout)["failures"][0]
                self.assertEqual(failure["case"], "example")
                self.assertEqual(failure["actual"], not expected)

    def test_broken_schema_fails_even_for_an_expected_refusal(self):
        self.schema["$defs"]["answer"] = {"type": "unknown"}
        self.index["cases"][0]["checks"][0]["valid"] = False
        result = self.run_check()
        self.assertEqual(result.returncode, 2)
        self.assertIn("is not valid", result.stderr)

    def test_resolution_errors_cannot_count_as_an_expected_refusal(self):
        self.index["cases"][0]["checks"][0]["valid"] = False
        for reference in ["missing.json", "https://example.invalid/schema.json", "../outside.json"]:
            with self.subTest(reference=reference):
                self.schema["$defs"]["answer"] = {"$ref": reference}
                result = self.run_check()
                self.assertEqual(result.returncode, 2)
                self.assertIn("example, Level 1", result.stderr)

    def test_unsafe_missing_or_alias_schema_paths_are_rejected(self):
        for path in ["../outside.json", "/tmp/answer.json", "./answer.json",
                     "missing.json", "https://example.invalid/schema.json"]:
            with self.subTest(path=path):
                self.index["cases"][0]["checks"][0]["schema"] = path
                result = self.run_check()
                self.assertEqual(result.returncode, 2)
                self.assertIn("unknown or unsafe schema path", result.stderr)

    def test_schema_symlink_cannot_escape_the_schema_directory(self):
        outside = Path(self.temp.name) / "outside.json"
        outside.write_text('{}')
        (self.api / "schemas/outside.json").symlink_to(outside)
        result = self.run_check()
        self.assertEqual(result.returncode, 2)
        self.assertIn("schema escapes", result.stderr)

    def test_malformed_empty_or_duplicate_matrix_fails(self):
        original = copy.deepcopy(self.index)
        malformed = [{"cases": []}, {"cases": [{"name": "incomplete", "checks": []}]}]
        wrong_type = copy.deepcopy(original)
        wrong_type["cases"][0]["checks"][0]["valid"] = 1
        duplicate_name = {"cases": original["cases"] * 2}
        duplicate_check = copy.deepcopy(original)
        duplicate_check["cases"][0]["checks"] *= 2
        for index in malformed + [wrong_type, duplicate_name, duplicate_check]:
            with self.subTest(index=index):
                self.index = index
                result = self.run_check()
                self.assertEqual(result.returncode, 2)
                self.assertIn("could not complete", result.stderr)

    def test_optional_regex_format_is_not_confused_with_pattern_execution(self):
        self.schema["$defs"]["unused"] = {"pattern": r"\p{Cc}"}
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("format annotations are not asserted", result.stdout)
        self.schema["$defs"]["answer"] = {"pattern": r"\p{Cc}"}
        self.index["cases"][0]["checks"][0]["valid"] = False
        result = self.run_check()
        self.assertEqual(result.returncode, 2)
        self.assertIn("bad escape", result.stderr)

    def test_invalid_json_is_reported_as_an_incomplete_check(self):
        self.run_check()
        for text in ['{"cases": [], "cases": []}', '{"cases": NaN}', '{']:
            with self.subTest(text=text):
                (self.api / "fixtures/stable-levels/index.json").write_text(text)
                result = subprocess.run(["uv", "run", "--locked", "--script", str(CHECKER),
                                         "--api-dir", str(self.api)], cwd=self.temp.name,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn("index.json", result.stderr)


if __name__ == "__main__":
    unittest.main()

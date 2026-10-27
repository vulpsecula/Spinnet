"""Exercise the measurement tool's real argument parser without launching a Host."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]


class MeasurementOptionsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temp = tempfile.TemporaryDirectory(prefix="spinnet-measurement-options-")
        cls.addClassCleanup(temp.cleanup)
        root = Path(temp.name)
        main = root / "main.swift"
        main.write_text('''import Foundation
do {
    let options = try MeasurementOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    print("pid=\\(options.hostProcessID ?? 0);intervals=\\(options.keystrokeIntervals)")
} catch {
    fputs("\\(error)\\n", stderr)
    exit(64)
}
''')
        cls.binary = root / "options"
        result = subprocess.run([
            "xcrun", "swiftc", str(REPOSITORY / "Tools/ViewSessionMeasurement/MeasurementOptions.swift"),
            str(main), "-o", str(cls.binary)
        ], text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def parse(self, *arguments):
        return subprocess.run([str(self.binary), *arguments], text=True, capture_output=True)

    def test_pid_outside_the_process_id_range_is_a_usage_error_instead_of_a_trap(self):
        for value in ("0", "2147483648", "9223372036854775807"):
            with self.subTest(value=value):
                result = self.parse("app-footprint", "--host-pid", value)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn("--host-pid", result.stderr)
        result = self.parse("app-footprint", "--host-pid", "2147483647")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pid=2147483647", result.stdout)

    def test_every_keystroke_interval_must_be_present_and_valid(self):
        for value in ("50,invalid,160", "50,,160", ",50", "50,", "0,50", "-1,50"):
            with self.subTest(value=value):
                result = self.parse("--keystroke-intervals", value)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn("--keystroke-intervals", result.stderr)
        result = self.parse("--keystroke-intervals", "50, 160")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("intervals=[50, 160]", result.stdout)


if __name__ == "__main__":
    unittest.main()

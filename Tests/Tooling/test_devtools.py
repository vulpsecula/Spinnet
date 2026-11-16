"""Exercise developer-tool entry points against isolated fake system state."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]


class DeveloperToolEntryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spinnet devtools ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "script").mkdir()
        shutil.copy2(REPOSITORY / "script/ax_insertion_matrix.sh", self.root / "script/ax_insertion_matrix.sh")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.trace = self.root / "trace"
        self.state = self.root / "status"
        self.state.write_text("0\n")
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        DEVTOOLS_TRACE=str(self.trace), DEVTOOLS_STATE=str(self.state))
        for name in ("swift", "security", "ditto", "open"):
            self.command(name, 'printf "%s\\n" "$0 $*" >> "$DEVTOOLS_TRACE"; exit 93')
        self.command("codesign", "exit 0")

    def command(self, name, contents):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + contents + "\n")
        path.chmod(0o755)
        return path

    def test_ax_help_identifies_current_default_and_historical_option(self):
        result = subprocess.run(["bash", str(self.root / 'script/ax_insertion_matrix.sh'), '--help'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('current (default)', result.stdout)
        self.assertIn('--host a2', result.stdout)
        self.assertFalse(self.trace.exists())

    def test_default_ax_stages_current_nested_sources_without_retired_resources(self):
        core = self.root / 'Sources/SpinnetCore'
        (core / 'Nested').mkdir(parents=True)
        (core / 'Nested/Example.swift').write_text('struct Example {}\n')
        host = self.root / 'Sources/SpinnetHost/Services'
        host.mkdir(parents=True)
        for name in ['HostTextInserter.swift', 'InsertionTargets.swift', 'HostAccessibility.swift']:
            shutil.copy2(REPOSITORY / 'Sources/SpinnetHost/Services' / name, host / name)
        template = self.root / 'Tools/AXInsertionProbe'
        template.mkdir(parents=True)
        shutil.copy2(REPOSITORY / 'Tools/AXInsertionProbe/Package.swift', template / 'Package.swift')
        staged = self.root / '.build/verification/ax-insertion/package-current'
        stale = staged / 'Sources/AXInsertionProbe/HostCurrent/Stale.swift'
        stale.parent.mkdir(parents=True)
        stale.write_text('outdated generated staging\n')
        self.command('git', '''
shift 2
case "$1" in
rev-parse) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
hash-object) echo example-blob ;;
status) echo ' M Sources/SpinnetCore/Nested/Example.swift' ;;
*) exit 92 ;;
esac
''')
        result = subprocess.run(['bash', str(self.root / 'script/ax_insertion_matrix.sh'), '--build-only'],
                                cwd=self.root, env=dict(self.env, SPINNET_CODESIGN_IDENTITY='fixture'),
                                text=True, capture_output=True)
        # Stop at the first fake compiler call; no app, signing or UI runs.
        self.assertEqual(result.returncode, 93, result.stdout + result.stderr)
        self.assertEqual((staged / 'Sources/SpinnetCore/Nested/Example.swift').read_text(), 'struct Example {}\n')
        manifest = (staged / 'Package.swift').read_text()
        self.assertNotIn('resources:', manifest)
        self.assertIn('.define("HOST_CURRENT")', manifest)
        self.assertTrue((staged / 'Sources/AXInsertionProbe/HostCurrent/HostTextInserter.swift').is_file())
        self.assertEqual((staged / 'Sources/AXInsertionProbe/HostCurrent/HostAccessibility.swift').read_bytes(),
                         (host / 'HostAccessibility.swift').read_bytes())
        self.assertFalse(stale.exists())
        self.assertFalse((self.root / 'dist').exists())
        self.assertFalse((self.root / 'tmp').exists())


if __name__ == '__main__':
    unittest.main()

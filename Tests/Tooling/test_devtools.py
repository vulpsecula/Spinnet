"""Exercise developer-tool cleanup against isolated fake system state."""
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
        for name in ("check_background_lifecycle.sh", "ax_insertion_matrix.sh", "emoji_e1_host_checks.sh"):
            shutil.copy2(REPOSITORY / "script" / name, self.root / "script" / name)
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
        self.command("launchctl", '''
read -r value < "$DEVTOOLS_STATE"
if [[ "${DEVTOOLS_JOB:-0}" == 1 && "$value" != 0 && "$value" != 3 ]]; then exit 0; fi
echo 'Could not find service "com.vulpsecula.SpinnetHost.lifecycle-fixture.privileged-tools" in domain for system' >&2
exit 113
''')
        self.command("lsof", 'if [[ "${DEVTOOLS_BUSY:-0}" == 1 ]]; then echo 65432; exit 0; fi; exit 1')
        self.command("pgrep", "exit 1")

    def command(self, name, contents):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + contents + "\n")
        path.chmod(0o755)
        return path

    def fixture(self, status=0):
        app = self.root / "Tools/.state/background-lifecycle/SpinnetLifecycle.app"
        binary = app / "Contents/MacOS/SpinnetBackgroundLifecycleProbe"
        binary.parent.mkdir(parents=True, exist_ok=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.vulpsecula.SpinnetHost.lifecycle-fixture.preview"
        }))
        binary.write_text('''#!/bin/bash
case "$1" in
status) read -r value < "$DEVTOOLS_STATE"; printf '{"status":%s}\\n' "$value" ;;
unregister) echo unregister >> "$DEVTOOLS_TRACE"; echo 0 > "$DEVTOOLS_STATE" ;;
*) echo unexpected >> "$DEVTOOLS_TRACE"; exit 94 ;;
esac
''')
        binary.chmod(0o755)
        self.state.write_text(str(status) + "\n")
        return app

    def run_lifecycle(self, *args, **overrides):
        return subprocess.run(["bash", str(self.root / "script/check_background_lifecycle.sh"), *args],
                              cwd=self.root, env=dict(self.env, **overrides), text=True, capture_output=True)

    def test_help_status_and_invalid_arguments_never_build_or_query_signing_identity(self):
        app = self.fixture()
        for args, expected in [(('--help',), 0), (('--status',), 0), (('',), 64),
                               (('--prepare', 'extra'), 64), (('--status', '--unregister'), 64)]:
            with self.subTest(args=args):
                result = self.run_lifecycle(*args)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertTrue(app.exists())
                self.assertFalse(self.trace.exists(), self.trace.read_text() if self.trace.exists() else '')
                self.assertFalse((self.root / "dist").exists())

    def test_clean_removes_only_unregistered_fixture_and_its_rebuildable_cache(self):
        app = self.fixture()
        cache = self.root / ".build/verification/background-lifecycle"
        cache.mkdir(parents=True)
        (cache / "sample").write_text("rebuildable")
        product = self.root / "dist/SpinnetHost.app/sentinel"
        product.parent.mkdir(parents=True)
        product.write_text("keep")
        result = self.run_lifecycle('--clean')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(app.exists())
        self.assertFalse(cache.exists())
        self.assertEqual(product.read_text(), "keep")
        self.assertFalse(self.trace.exists())

    def test_pending_or_registered_fixture_needs_explicit_unregister(self):
        for status in (1, 2):
            with self.subTest(status=status):
                app = self.fixture(status)
                result = self.run_lifecycle('--clean')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('--unregister', result.stderr)
                self.assertTrue(app.exists())
                self.assertFalse(self.trace.exists())
                result = self.run_lifecycle('--clean', '--unregister', DEVTOOLS_JOB="1")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(app.exists())
                self.assertEqual(self.trace.read_text(), 'unregister\n')
                self.trace.unlink()

    def test_open_files_or_unknown_registration_refuse_cleanup(self):
        app = self.fixture()
        result = self.run_lifecycle('--clean', DEVTOOLS_BUSY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(app.exists())
        self.assertFalse(self.trace.exists())
        self.state.write_text("99\n")
        result = self.run_lifecycle('--clean')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(app.exists())

    def test_unreadable_or_remaining_launchd_job_cannot_be_treated_as_unregistered(self):
        app = self.fixture()
        self.command('sleep', 'exit 0')
        for command in ['echo "permission denied" >&2; exit 77', 'exit 0']:
            with self.subTest(command=command):
                self.command('launchctl', command)
                result = self.run_lifecycle('--clean')
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(app.exists())
                self.assertFalse(self.trace.exists())

    def test_invalid_signature_never_executes_fixture_or_deletes_it(self):
        app = self.fixture()
        binary = app / 'Contents/MacOS/SpinnetBackgroundLifecycleProbe'
        binary.write_text('#!/bin/bash\necho probe-executed >> "$DEVTOOLS_TRACE"\necho \'{"status":0}\'\n')
        self.command('codesign', 'exit 1')
        result = self.run_lifecycle('--clean')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('signature verification failed', result.stderr)
        self.assertTrue(app.exists())
        self.assertFalse(self.trace.exists())

    def test_failed_identity_status_or_json_queries_preserve_fixture(self):
        app = self.fixture()
        binary = app / 'Contents/MacOS/SpinnetBackgroundLifecycleProbe'
        for body in ['echo \'{"status":0}\'; exit 1', 'echo invalid-json; exit 0']:
            with self.subTest(body=body):
                binary.write_text('#!/bin/bash\n' + body + '\n')
                result = self.run_lifecycle('--clean')
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(app.exists())
        self.command('plutil', 'exit 1')
        binary.write_text('#!/bin/bash\necho probe-executed >> "$DEVTOOLS_TRACE"\necho \'{"status":0}\'\n')
        result = self.run_lifecycle('--clean')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cannot read fixture identity', result.stderr)
        self.assertTrue(app.exists())
        self.assertFalse(self.trace.exists())

    def test_ax_help_identifies_current_default_and_historical_option(self):
        result = subprocess.run(["bash", str(self.root / 'script/ax_insertion_matrix.sh'), '--help'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('current (default)', result.stdout)
        self.assertIn('--host a2', result.stdout)
        self.assertFalse(self.trace.exists())

    def test_default_ax_stages_current_nested_sources_and_resources_before_building(self):
        core = self.root / 'Sources/SpinnetCore'
        (core / 'Nested').mkdir(parents=True)
        (core / 'Nested/Example.swift').write_text('struct Example {}\n')
        (core / 'Resources').mkdir()
        (core / 'Resources/example.rb').write_text('# unchanged adapter\n')
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
        self.assertEqual((staged / 'Sources/SpinnetCore/Resources/example.rb').read_text(), '# unchanged adapter\n')
        manifest = (staged / 'Package.swift').read_text()
        self.assertIn('resources: [.process("Resources")]', manifest)
        self.assertIn('.define("HOST_CURRENT")', manifest)
        self.assertTrue((staged / 'Sources/AXInsertionProbe/HostCurrent/HostTextInserter.swift').is_file())
        self.assertEqual((staged / 'Sources/AXInsertionProbe/HostCurrent/HostAccessibility.swift').read_bytes(),
                         (host / 'HostAccessibility.swift').read_bytes())
        self.assertFalse(stale.exists())
        self.assertFalse((self.root / 'dist').exists())


if __name__ == '__main__':
    unittest.main()

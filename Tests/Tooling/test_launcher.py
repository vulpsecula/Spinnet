"""Exercise launcher argument and package boundaries in an isolated fake checkout."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPERS = {
    "SpinnetPluginHelper": None,
    "SpinnetToolTaskRunner": "task-runner",
    "SpinnetHomebrewAskpass": "homebrew-askpass",
    "SpinnetToolAuthorizationClient": "authorization-client",
    "SpinnetPrivilegedToolHelper": "privileged-tools",
    "SpinnetReceiptInventory": "receipt-inventory",
    "SpinnetArchiveBootstrap": "archive-bootstrap",
    "SpinnetArchiveDecoder": "archive-decoder",
    "SpinnetPathInventory": "path-inventory",
    "SpinnetVendorOrigin": "vendor-origin",
    "SpinnetPathRemoval": "path-removal",
    "SpinnetLaunchServiceInventory": "launch-service-inventory",
}
STUB = r'''
import json, os, shutil, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["LAUNCHER_TEST_LOG"], "a") as stream:
    stream.write(json.dumps({"tool": name, "args": args}) + "\n")
if name == "swift":
    if os.environ.get("LAUNCHER_TEST_STOP_AT_BUILD") == "1":
        sys.exit(79)
    build = Path(os.environ["LAUNCHER_TEST_BUILD"])
    build.mkdir(exist_ok=True)
    if "--show-bin-path" in args:
        print(build)
    elif "--product" in args:
        binary = build / args[args.index("--product") + 1]
        binary.write_text("#!" + sys.executable + "\n" + Path(__file__).read_text().split("\n", 1)[1])
        binary.chmod(0o755)
        resource = build / "Spinnet_SpinnetCore.bundle"
        resource.mkdir(exist_ok=True)
        (resource / "resource.rb").write_text("fixture")
elif name == "security":
    print('1) FIXTURE_ID "Apple Development: Fixture"')
elif name == "git":
    if "rev-parse" in args:
        print("fixture")
elif name == "ditto":
    shutil.copytree(args[0], args[1], dirs_exist_ok=True)
elif name == "SpinnetHost" and "--report-installed-plugins" in args:
    print("com.example.fixture 1.2.3 Fixture")
'''


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spinnet launcher ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = self.root / "script/build_and_run.sh"
        self.script.parent.mkdir()
        shutil.copy2(ROOT / "script/build_and_run.sh", self.script)
        self.version_source = self.root / "Sources/SpinnetCore/Plugins/HostCompatibility.swift"
        self.version_source.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "Sources/SpinnetCore/Plugins/HostCompatibility.swift", self.version_source)
        self.log = self.root / "commands.jsonl"
        self.stubs = self.root / "commands"
        self.stubs.mkdir()
        for name in ["swift", "security", "git", "pkill", "codesign", "ditto", "open", "pgrep", "sleep", "lldb"]:
            self.executable(self.stubs / name, STUB)
        # Opening an app is the one absolute command; point it at the stub so
        # no test can open a real app.
        launcher = self.script.read_text()
        self.assertEqual(launcher.count("/usr/bin/open "), 2)
        self.script.write_text(launcher.replace("/usr/bin/open ", shlex.quote(str(self.stubs / "open")) + " "))
        for name in ["check_background_helper.sh", "check_background_lifecycle.sh"]:
            (self.script.parent / name).write_text(
                '#!/bin/bash\nprintf \'{"tool":"' + name + '","args":["%s"]}\\n\' "$*" >> "$LAUNCHER_TEST_LOG"\n')
        self.packages = self.root / "SpinnetPlugins checkout"
        package = self.packages / "Plugins/Example.spinnetplugin"
        package.mkdir(parents=True)
        (package / "manifest.json").write_text('{}')
        resources = self.root / "Resources/LaunchDaemons"
        resources.mkdir(parents=True)
        (resources / "com.vulpsecula.SpinnetHost.privileged-tools.plist").write_text('fixture')
        (resources.parent / "SpinnetHost.entitlements").write_text('fixture')
        self.sentinel = self.root / "dist/SpinnetHost.app/sentinel"
        self.sentinel.parent.mkdir(parents=True)
        self.sentinel.write_text("existing app")

    @staticmethod
    def executable(path, body):
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)

    def launch(self, *args, **overrides):
        self.log.unlink(missing_ok=True)
        env = dict(os.environ, PATH=str(self.stubs) + os.pathsep + os.defpath,
                   LAUNCHER_TEST_LOG=str(self.log), LAUNCHER_TEST_BUILD=str(self.root / "built"),
                   SPINNET_CODESIGN_IDENTITY="", SPINNET_ALLOW_ADHOC_SIGNING="0")
        env.update(overrides)
        result = subprocess.run(["/bin/bash", str(self.script), *args], env=env,
                                cwd=self.temp.name, text=True, capture_output=True)
        commands = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, commands

    def test_help_leaves_the_existing_app_and_invokes_no_external_commands(self):
        for flag in ["--help", "-h"]:
            with self.subTest(flag=flag):
                result, commands = self.launch(flag, LAUNCHER_TEST_STOP_AT_BUILD="1")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("usage:", result.stdout)
                self.assertEqual(commands, [])
                self.assertEqual(self.sentinel.read_text(), "existing app")

    def test_bad_or_extra_arguments_are_rejected_before_any_side_effect(self):
        cases = [("--typo",), ("",), ("--package", "ignored"), ("--help", "ignored"),
                 ("--install-plugins",), ("--install-plugins", ""),
                 ("--install-plugins", str(self.packages), "--package"),
                 ("--install-plugins", str(self.packages), "--help"),
                 ("--install-plugins", str(self.packages), "--background-lifecycle-check"),
                 ("--install-plugins", str(self.packages), "--verify", "ignored"),
                 ("--verify", "--install-plugins", str(self.packages)),
                 ("--background-lifecycle-check", "--typo"),
                 ("--background-lifecycle-check", ""),
                 ("--background-lifecycle-check", "--prepare", "ignored"),
                 ("--background-lifecycle-check", "--clean", "--wrong"),
                 ("--background-lifecycle-check", "--clean", "--unregister", "ignored")]
        for args in cases:
            with self.subTest(args=args):
                result, commands = self.launch(*args, LAUNCHER_TEST_STOP_AT_BUILD="1")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("usage:", result.stderr)
                self.assertEqual(commands, [])
                self.assertEqual(self.sentinel.read_text(), "existing app")

    def test_invalid_release_version_is_rejected_before_touching_the_app(self):
        for source in ['public static let currentString = "01.0.0"\n',
                       'public static let currentString = "1.0.0-beta"\n',
                       'missing version\n']:
            with self.subTest(source=source):
                self.version_source.write_text(source)
                result, commands = self.launch("--package")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cannot read the Host release version", result.stderr)
                self.assertEqual(commands, [])
                self.assertEqual(self.sentinel.read_text(), "existing app")

    def test_lifecycle_delegates_only_its_valid_arguments_without_packaging(self):
        cases = [([], "--prepare"), (["--prepare"], "--prepare"), (["--run"], "--run"),
                 (["--status"], "--status"), (["--clean"], "--clean"),
                 (["--clean", "--unregister"], "--clean --unregister"),
                 (["--help"], "--help"), (["-h"], "-h")]
        for args, expected in cases:
            with self.subTest(args=args):
                result, commands = self.launch("--background-lifecycle-check", *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(commands, [{"tool": "check_background_lifecycle.sh", "args": [expected]}])
                self.assertEqual(self.sentinel.read_text(), "existing app")

    def test_package_preserves_every_helper_and_signing_policy_without_restart(self):
        for identity, optin in [("FIXTURE_ID", "0"), ("-", "1")]:
            with self.subTest(identity=identity):
                result, commands = self.launch("--package", SPINNET_CODESIGN_IDENTITY=identity,
                                               SPINNET_ALLOW_ADHOC_SIGNING=optin)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                products = [call["args"][-1] for call in commands if call["tool"] == "swift" and "--product" in call["args"]]
                self.assertEqual(set(products), {"SpinnetHost", *HELPERS})
                self.assertEqual(len(products), len(HELPERS) + 1)
                contents = self.root / "dist/SpinnetHost.app/Contents"
                self.assertEqual({path.name for path in (contents / "Helpers").iterdir()}, set(HELPERS))
                self.assertFalse((contents / "Resources/Spinnet_SpinnetCore.bundle").exists(),
                                 "An obsolete incremental-build bundle must not ship retired Ruby adapters")
                self.assertFalse((contents / "Resources/Plugins").exists(), "The app contains no Plugins")
                signed = [call["args"] for call in commands if call["tool"] == "codesign" and "--sign" in call["args"]]
                self.assertEqual(len(signed), len(HELPERS) + 1)
                for name, suffix in HELPERS.items():
                    args = next(args for args in signed if args[-1] == str(contents / "Helpers" / name))
                    self.assertEqual(args[args.index("--sign") + 1], identity)
                    self.assertEqual("--options" in args, identity != "-")
                    if suffix:
                        self.assertEqual(args[args.index("--identifier") + 1], "com.vulpsecula.SpinnetHost." + suffix)
                    else:
                        self.assertNotIn("--identifier", args)
                host_sign = next(args for args in signed if args[-1] == str(contents.parent))
                self.assertEqual(host_sign[host_sign.index("--entitlements") + 1], str(self.root / "Resources/SpinnetHost.entitlements"))
                self.assertNotIn("pkill", [call["tool"] for call in commands])
                self.assertFalse(any("--refresh-existing-background-operations" in call["args"] for call in commands))

    def test_install_option_installs_every_package_through_the_host_before_opening(self):
        result, commands = self.launch("--install-plugins", str(self.packages), "--verify",
                                       SPINNET_CODESIGN_IDENTITY="FIXTURE_ID")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        tools = [call["tool"] for call in commands]
        install = next(index for index, call in enumerate(commands)
                       if call["tool"] == "SpinnetHost" and call["args"][:1] == ["--install-plugins"])
        self.assertEqual(commands[install]["args"], ["--install-plugins", str(self.packages)])
        self.assertEqual([call["args"][:1] for call in commands if call["tool"] == "SpinnetHost"].count(["--install-plugins"]), 1)
        self.assertLess(tools.index("pkill"), install, "The running Host quits before its data changes")
        self.assertLess(max(index for index, tool in enumerate(tools) if tool == "codesign"), install)
        self.assertLess(install, tools.index("open"), "Packages install before the app opens")
        report = next(index for index, call in enumerate(commands)
                      if call["tool"] == "SpinnetHost" and call["args"] == ["--report-installed-plugins"])
        self.assertLess(tools.index("open"), report)
        self.assertIn("Running " + str(self.root / "dist/SpinnetHost.app"), result.stdout)
        self.assertIn("Installed Plugins, as saved on disk:\ncom.example.fixture 1.2.3 Fixture", result.stdout)

    def test_verify_reports_installed_plugin_versions_without_installing(self):
        result, commands = self.launch("--verify", SPINNET_CODESIGN_IDENTITY="FIXTURE_ID")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        host_calls = [call["args"] for call in commands if call["tool"] == "SpinnetHost"]
        self.assertNotIn("--install-plugins", [args[0] for args in host_calls if args])
        self.assertIn(["--report-installed-plugins"], host_calls)
        self.assertIn("Installed Plugins, as saved on disk:\ncom.example.fixture 1.2.3 Fixture", result.stdout)

    def test_missing_install_directory_is_rejected_before_building(self):
        result, commands = self.launch("--install-plugins", str(self.root / "missing"), "--verify")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing Plugin package directory", result.stderr)
        self.assertEqual(commands, [])
        self.assertEqual(self.sentinel.read_text(), "existing app")

    def test_ad_hoc_signing_requires_optin_before_building(self):
        result, commands = self.launch("--package", SPINNET_CODESIGN_IDENTITY="-")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ad-hoc signing is disabled", result.stderr)
        self.assertEqual(commands, [])
        self.assertEqual(self.sentinel.read_text(), "existing app")


if __name__ == "__main__":
    unittest.main()

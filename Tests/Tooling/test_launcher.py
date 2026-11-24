"""Exercise launcher argument and package boundaries in an isolated fake checkout."""
import json
import re
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
        strings = build / "Spinnet_SpinnetHost.bundle/Contents/Resources/zh-Hans.lproj"
        strings.mkdir(parents=True, exist_ok=True)
        (strings / "Localizable.strings").write_text("fixture")
        (strings.parent / "StatusItemTemplate.pdf").write_text("fixture template")
elif name == "xcrun" and args[0] == "actool":
    resources = Path(args[args.index("--compile") + 1])
    (resources / "AppIcon.icns").write_text("fixture icon")
    (resources / "Assets.car").write_text("fixture compiled icon")
    Path(args[args.index("--output-partial-info-plist") + 1]).write_text("fixture icon metadata")
elif name == "security":
    print('1) FIXTURE_ID "Apple Development: Fixture"')
    if os.environ.get("LAUNCHER_TEST_RELEASE_IDENTITY"):
        print('2) RELEASE_ID "Vulpsecula Software"')
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
        for name in ["swift", "security", "git", "pkill", "codesign", "ditto", "open", "pgrep", "sleep", "lldb", "xcrun"]:
            self.executable(self.stubs / name, STUB)
        # Opening an app is the one absolute command; point it at the stub so
        # no test can open a real app.
        launcher = self.script.read_text()
        self.assertEqual(launcher.count("/usr/bin/open "), 2)
        self.script.write_text(launcher.replace("/usr/bin/open ", shlex.quote(str(self.stubs / "open")) + " "))
        for name in ["check_background_helper.sh"]:
            (self.script.parent / name).write_text(
                '#!/bin/bash\nprintf \'{"tool":"' + name + '","args":["%s"]}\\n\' "$*" >> "$LAUNCHER_TEST_LOG"\n')
        self.packages = self.root / "SpinnetPlugins checkout"
        package = self.packages / "Plugins/Example.spinnetplugin"
        package.mkdir(parents=True)
        (package / "manifest.json").write_text('{}')
        resources = self.root / "Resources"
        resources.mkdir(parents=True)
        (resources / "SpinnetHost.entitlements").write_text('fixture')
        (resources / "AppIcon.icon").mkdir()
        (resources / "AppIcon.icon/icon.json").write_text('{}')
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
                 ("--install-plugins", str(self.packages), "--verify", "ignored"),
                 ("--verify", "--install-plugins", str(self.packages)),
                 ("--background-lifecycle-check",)]
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
                self.assertTrue((contents / "Resources/zh-Hans.lproj/Localizable.strings").exists(),
                                "The app carries the Host's String Catalog in its own resources")
                self.assertTrue((contents / "Resources/en.lproj").is_dir())
                self.assertEqual((contents / "Resources/AppIcon.icns").read_text(), "fixture icon")
                self.assertEqual((contents / "Resources/Assets.car").read_text(), "fixture compiled icon")
                self.assertEqual((contents / "Resources/StatusItemTemplate.pdf").read_text(), "fixture template")
                self.assertIn("<key>CFBundleIconFile</key>\n  <string>AppIcon</string>",
                              (contents / "Info.plist").read_text())
                self.assertIn("<key>CFBundleIconName</key>\n  <string>AppIcon</string>",
                              (contents / "Info.plist").read_text())
                icon_compile = next(call["args"] for call in commands if call["tool"] == "xcrun")
                self.assertEqual(icon_compile[0], "actool")
                self.assertEqual(icon_compile[icon_compile.index("--minimum-deployment-target") + 1], "13.0")
                self.assertIn(["--verify-localizations"],
                              [call["args"] for call in commands if call["tool"] == "SpinnetHost"])
                signed = [call["args"] for call in commands if call["tool"] == "codesign" and "--sign" in call["args"]]
                self.assertEqual(len(signed), len(HELPERS) + 1)
                for name, suffix in HELPERS.items():
                    args = next(args for args in signed if args[-1] == str(contents / "Helpers" / name))
                    self.assertEqual(args[args.index("--sign") + 1], identity)
                    self.assertEqual("--options" in args, identity != "-")
                    if suffix:
                        self.assertEqual(args[args.index("--identifier") + 1], "com.vulpsecula.SpinnetHost.dev." + suffix)
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

    def test_signs_with_the_release_certificate_when_it_is_installed(self):
        for release, expected in [("", "FIXTURE_ID"), ("1", "RELEASE_ID")]:
            with self.subTest(release=bool(release)):
                result, commands = self.launch("--package", LAUNCHER_TEST_RELEASE_IDENTITY=release)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                identities = {call["args"][call["args"].index("--sign") + 1]
                              for call in commands if call["tool"] == "codesign" and "--sign" in call["args"]}
                self.assertEqual(identities, {expected})

    def test_only_an_official_build_compiles_activation_in_its_own_scratch_directory(self):
        official = ["--scratch-path", ".build/official", "-Xswiftc", "-DSPINNET_OFFICIAL_BUILD"]
        cases = [((), {}, False), (("--official",), {}, True), ((), {"SPINNET_OFFICIAL_BUILD": "1"}, True)]
        for args, env, is_official in cases:
            with self.subTest(args=args, env=env):
                result, commands = self.launch(*args, "--package", SPINNET_CODESIGN_IDENTITY="FIXTURE_ID", **env)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                builds = [call["args"] for call in commands if call["tool"] == "swift"]
                self.assertEqual(len(builds), len(HELPERS) + 2)
                for build in builds:
                    self.assertEqual(build[1:5] == official, is_official, build)
                    self.assertEqual("-DSPINNET_OFFICIAL_BUILD" in build, is_official, build)

    def test_the_release_configuration_reaches_every_build_and_dist_can_move(self):
        dist = self.root / "release dist"
        # The moved release build leaves dist/ alone; the default build then replaces it.
        for configuration, extra in [("release", {"SPINNET_DIST_DIR": str(dist)}), ("", {})]:
            with self.subTest(configuration=configuration):
                result, commands = self.launch("--package", SPINNET_CODESIGN_IDENTITY="FIXTURE_ID",
                                               SPINNET_BUILD_CONFIGURATION=configuration or "debug", **extra)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                builds = [call["args"] for call in commands if call["tool"] == "swift"]
                for build in builds:
                    self.assertIn(["-c", configuration or "debug"], [build[i:i + 2] for i in range(len(build))], build)
                if configuration:
                    self.assertTrue((dist / "SpinnetHost.app/Contents/Info.plist").exists())
                    self.assertEqual(self.sentinel.read_text(), "existing app")

    def test_the_release_configuration_is_spinnet_and_debug_is_a_separate_app(self):
        # SpinnetBuildIdentity.swift holds the same identities for the code.
        identity = (ROOT / "Sources/SpinnetCore/Configuration/SpinnetBuildIdentity.swift").read_text()
        for configuration, bundle_id, prefix in [("release", "com.vulpsecula.SpinnetHost", "com.vulpsecula.SpinnetHost"),
                                                 ("debug", "com.vulpsecula.SpinnetHost.dev", "com.vulpsecula.SpinnetHost.dev")]:
            with self.subTest(configuration=configuration):
                self.assertIn(f'hostBundleIdentifier: "{bundle_id}",\n        identifierPrefix: "{prefix}"', identity)
                result, commands = self.launch("--package", SPINNET_CODESIGN_IDENTITY="FIXTURE_ID",
                                               SPINNET_BUILD_CONFIGURATION=configuration)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                contents = self.root / "dist/SpinnetHost.app/Contents"
                self.assertIn(f"<key>CFBundleIdentifier</key>\n  <string>{bundle_id}</string>",
                              (contents / "Info.plist").read_text())
                signed = [call["args"] for call in commands if call["tool"] == "codesign" and "--identifier" in call["args"]]
                self.assertEqual({args[args.index("--identifier") + 1] for args in signed},
                                 {prefix + "." + suffix for suffix in HELPERS.values() if suffix})
                daemons = list((contents / "Library/LaunchDaemons").iterdir())
                self.assertEqual([path.name for path in daemons], [prefix + ".privileged-tools.plist"])
                daemon = daemons[0].read_text()
                self.assertIn(f"<key>Label</key><string>{prefix}.privileged-tools</string>", daemon)
                self.assertIn(f"<array><string>{bundle_id}</string></array>", daemon)
                for service in ["host", "runner", "client", "inspection.host", "inspection.client"]:
                    self.assertIn(f"<key>{prefix}.reviewed-tools.{service}</key><true/>", daemon)
        result, commands = self.launch("--package", SPINNET_BUILD_CONFIGURATION="fast",
                                       LAUNCHER_TEST_STOP_AT_BUILD="1")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(commands, [])

    def test_release_packaging_rejects_a_label_that_is_not_the_host_version(self):
        version = re.search(r'currentString = "([0-9.]+)"', self.version_source.read_text()).group(1)
        package = self.script.parent / "package_release.sh"
        shutil.copy2(ROOT / "script/package_release.sh", package)
        for label in ["9.9.9", version + "beta", version + "-", "v" + version, ""]:
            with self.subTest(label=label):
                result = subprocess.run(["/bin/bash", str(package), label], text=True, capture_output=True,
                                        env=dict(os.environ, PATH=str(self.stubs) + os.pathsep + os.defpath,
                                                 LAUNCHER_TEST_LOG=str(self.log)))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.log.exists())

    def test_bad_official_build_requests_are_rejected_before_any_side_effect(self):
        for args, env in [(("--official", "--official"), {}), (("--package", "--official"), {}),
                          (("--package",), {"SPINNET_OFFICIAL_BUILD": "yes"})]:
            with self.subTest(args=args, env=env):
                result, commands = self.launch(*args, LAUNCHER_TEST_STOP_AT_BUILD="1", **env)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(commands, [])
                self.assertEqual(self.sentinel.read_text(), "existing app")

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

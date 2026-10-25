"""Exercise packaging's public resolver against real, local Git repositories."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RESOLVER = Path(__file__).resolve().parents[2] / 'script/resolve_bundled_plugins.sh'


class BundledPluginsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='spinnet-packaging-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.git('init', '-b', 'main')
        package = self.source / 'Plugins/Example.spinnetplugin'
        package.mkdir(parents=True)
        (package / 'manifest.json').write_text('{"version":"1.0.0"}')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com', 'commit', '-m', 'First package')
        self.revision = self.git('rev-parse', 'HEAD').strip()
        self.lock = self.root / 'bundled-plugins.lock.json'
        self.lock.write_text(json.dumps({'repository': str(self.source), 'revision': self.revision}))

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'commit.gpgsign=false', '-C', str(self.source), *args], text=True, stderr=subprocess.DEVNULL)

    def resolve(self, **overrides):
        env = {k: v for k, v in os.environ.items() if k != 'SPINNET_BUNDLED_PLUGINS_DIR'}
        env.update(SPINNET_BUNDLED_PLUGINS_CACHE=str(self.root / 'cache'), **overrides)
        return subprocess.run(['bash', str(RESOLVER), str(self.lock)], env=env, text=True, capture_output=True)

    def test_resolves_exact_commit_even_after_source_changes_and_works_offline(self):
        (self.source / 'Plugins/Example.spinnetplugin/manifest.json').write_text('{"version":"2.0.0"}')
        self.git('commit', '-am', 'Second package')
        first = self.resolve()
        self.assertEqual(first.returncode, 0, first.stderr)
        package = Path(first.stdout.strip()) / 'Example.spinnetplugin/manifest.json'
        self.assertEqual(package.read_text(), '{"version":"1.0.0"}')
        self.source.rename(self.root / 'offline')
        again = self.resolve()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual((Path(again.stdout.strip()) / 'Example.spinnetplugin/manifest.json').read_text(), '{"version":"1.0.0"}')

    def test_local_packages_override_does_not_need_a_lock_or_network(self):
        self.lock.unlink()
        result = self.resolve(SPINNET_BUNDLED_PLUGINS_DIR=str(self.source / 'Plugins'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout.strip()).resolve(), (self.source / 'Plugins').resolve())
        self.assertFalse((self.root / 'cache').exists())

    def test_moving_branch_is_rejected_instead_of_being_bundled(self):
        self.lock.write_text(json.dumps({'repository': str(self.source), 'revision': 'main'}))
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('full commit SHA', result.stderr)

    def test_modified_cached_package_is_rejected(self):
        first = self.resolve()
        self.assertEqual(first.returncode, 0, first.stderr)
        (Path(first.stdout.strip()) / 'Example.spinnetplugin/manifest.json').write_text('changed')
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('modified Plugin cache', result.stderr)

    def test_missing_override_fails_instead_of_falling_back_to_release(self):
        result = self.resolve(SPINNET_BUNDLED_PLUGINS_DIR=str(self.root / 'missing'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing development Plugin directory', result.stderr)


if __name__ == '__main__':
    unittest.main()

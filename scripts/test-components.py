#!/usr/bin/env python3
"""Offline fixtures for split archives and the real host component executable."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('packager', ROOT / 'scripts/package-components.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)
smoke_spec = importlib.util.spec_from_file_location('host_smoke', ROOT / 'scripts/prepare-component-host-smoke.py')
host_smoke = importlib.util.module_from_spec(smoke_spec)
smoke_spec.loader.exec_module(host_smoke)


class PackagingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_dir = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.build_dir.name) / 'magicnet-components'
        subprocess.run(['go', 'build', '-trimpath', '-o', str(cls.binary), '.'],
                       cwd=ROOT / 'tools/components', check=True,
                       env={**os.environ, 'GOTOOLCHAIN': 'local'})

    @classmethod
    def tearDownClass(cls):
        cls.build_dir.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'MagicNet.zip'
        self.entries = {
            'module.prop': b'id=MagicNet\nversion=v1.4.8\nversionCode=148\n',
            'customize.sh': b'#!/bin/sh\nimport this\necho done\n',
            'bin/magicnet-components': self.binary.read_bytes(),
            'bin/magicnet-cli': b'cli',
            'bin/magicnet-mcp-server': b'mcp',
            'bin/sing-box': b'sing-box-bytes',
            'bin/jq': b'jq-bytes',
            'bin/yq': b'yq-bytes',
            'bin/ecapture': b'ecapture-bytes',
            'webroot/index.html': b'<main>MagicNet</main>',
            '.config/sing-box/zashboard/index.html': b'<main>dashboard</main>',
            '.config/sing-box/rule-set/default.srs': b'rules',
            '.config/sing-box/config.json': b'{"private":false}',
            '.local/state/tools/yq.asset': b'duplicate-build-download',
            '.local/state/ecapture.archive': b'duplicate-build-archive',
            'lib/kamfw/.git': b'gitdir: private-build-path',
        }

    def build(self):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for p, b in self.entries.items():
                info = zipfile.ZipInfo(p)
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, b)
        with contextlib.redirect_stdout(io.StringIO()):
            return packager.package(self.archive, 'LIghtJUNction/MagicNet')

    def test_layout_and_cache_exclusion(self):
        manifest = self.build()
        with zipfile.ZipFile(self.root / 'MagicNet-core.zip') as core, zipfile.ZipFile(self.archive) as full:
            self.assertNotIn('bin/sing-box', core.namelist())
            self.assertNotIn('webroot/index.html', core.namelist())
            self.assertIn('bin/magicnet-cli', core.namelist())
            self.assertIn('bin/magicnet-components', core.namelist())
            self.assertIn('bin/sing-box', full.namelist())
            self.assertIn(b'/releases/latest/download/update-core.json', core.read('module.prop'))
            self.assertNotIn(b'update-core.json', full.read('module.prop'))
            update = json.loads((self.root / 'update-core.json').read_text())
            self.assertTrue(update['zipUrl'].endswith('/v1.4.8/MagicNet-core.zip'))
            self.assertEqual(update['versionCode'], 148)
            self.assertFalse(any('.local/state/' in p or p.endswith('/.git') for p in full.namelist()))
            script = core.read('customize.sh').decode()
            self.assertLess(script.index('--manifest'), script.index('import this'))
            subprocess.run(['sh', '-n'], input=script, text=True, check=True)
        self.assertEqual(self.archive.read_bytes(), (self.root / 'MagicNet-full.zip').read_bytes())
        self.assertEqual({c['id'] for c in manifest['components']},
                         {'sing-box', 'jq', 'yq', 'ecapture', 'webui', 'dashboard', 'rules'})

    def test_identical_component_contents_reproduce_archives(self):
        manifest = self.build()
        first = {c['id']: (c['version'], c['sha256']) for c in manifest['components']}
        self.entries['module.prop'] = b'id=MagicNet\nversion=v1.4.9\nversionCode=149\n'
        self.entries['customize.sh'] += b'# only core changed\n'
        again = self.build()
        self.assertEqual(first, {c['id']: (c['version'], c['sha256']) for c in again['components']})
        self.assertIn('/v1.4.9/', again['base_url'])

    def test_only_one_changed_component_gets_new_identity(self):
        before = self.build()
        self.entries['bin/jq'] = b'new jq'
        after = self.build()
        changed = [a['id'] for a, b in zip(before['components'], after['components'])
                   if a['sha256'] != b['sha256']]
        self.assertEqual(changed, ['jq'])

    def test_unsafe_archive_paths_fail(self):
        self.entries['../outside'] = b'unsafe'
        with self.assertRaises(ValueError):
            self.build()

    def test_missing_bootstrap_fails(self):
        del self.entries['bin/magicnet-components']
        with self.assertRaises(ValueError):
            self.build()

    def test_changed_customize_anchor_fails(self):
        self.entries['customize.sh'] = b'echo changed\n'
        with self.assertRaises(ValueError):
            self.build()

    def test_host_smoke_repack_preserves_source_index_and_manifest(self):
        self.build()
        work = self.root / 'host-work'
        work.mkdir()
        # A different length shifts every later ZIP header and reproduces the
        # source-index corruption when writestr receives the original ZipInfo.
        binary = b'different-size-host-bootstrap'
        (work / 'magicnet-components').write_bytes(binary)
        original = self.archive.read_bytes()
        host_smoke.prepare(self.archive, work)
        self.assertEqual(self.archive.read_bytes(), original)
        with zipfile.ZipFile(self.archive) as src, zipfile.ZipFile(work / 'host-smoke.zip') as dest:
            self.assertIsNone(src.testzip())
            self.assertIsNone(dest.testzip())
            self.assertEqual(src.namelist(), dest.namelist())
            for name in src.namelist():
                expected = binary if name == 'bin/magicnet-components' else src.read(name)
                self.assertEqual(dest.read(name), expected, name)
            self.assertEqual((work / 'manifest.json').read_bytes(), src.read('.components/manifest.json'))

    def install(self, name, previous):
        archive = self.root / name
        with zipfile.ZipFile(archive) as z:
            manifest = self.root / 'manifest.json'
            manifest.write_bytes(z.read('.components/manifest.json'))
        return subprocess.run([str(self.binary), '--manifest', str(manifest),
                               '--module', str(self.root / 'installed'),
                               '--previous', str(previous), '--bundle', str(archive),
                               '--cache', str(self.root / 'cache')],
                              capture_output=True, text=True, timeout=15)

    def test_real_binary_full_install_offline(self):
        self.build()
        result = self.install('MagicNet-full.zip', self.root / 'not-installed')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count('bundled, no download'), 7)
        self.assertEqual((self.root / 'installed/bin/sing-box').read_bytes(), self.entries['bin/sing-box'])
        self.assertFalse((self.root / 'cache').exists())

    def test_real_binary_core_upgrade_reuses_legacy_bytes(self):
        manifest = self.build()
        old = self.root / 'previous'
        for c in manifest['components']:
            for f in c['files']:
                p = old / f['path']; p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(self.entries[f['path']])
        result = self.install('MagicNet-core.zip', old)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count('reuse previous installation, no download'), 7)
        self.assertFalse((self.root / 'cache').exists())


if __name__ == '__main__':
    unittest.main()

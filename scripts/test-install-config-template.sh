#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

source = (Path(sys.argv[1]) / 'src/MagicNet/customize.sh').read_text()
start = source.index('magicnet_install_config_template() (\n')
end = source.index('\n)\n', start) + 3
helper = source[start:end]
template = b'{"dns":{"servers":[]},"route":{"rules":[]},"outbounds":[],"new_template":true}\n'
shells = [['sh'], ['bash']]
if shutil.which('busybox'):
    shells.append(['busybox', 'ash'])

class InstallTemplate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mod = self.root / 'module with spaces'
        self.config = self.mod / '.config/sing-box'
        self.config.mkdir(parents=True)
        self.active = self.config / 'config.json'
        self.active.write_bytes(b'{"old_template":true}\n')
        self.archive = self.root / 'release.zip'
        self.write_zip(template)

    def write_zip(self, content):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            if content is not None:
                archive.writestr('.config/sing-box/config.json', content)

    def run_helper(self, shell, success=True, prefix='', extra_env=None):
        result = subprocess.run(
            shell + ['-c', helper + '\n' + prefix + '\nmagicnet_install_config_template'],
            env={**os.environ, 'MODPATH': str(self.mod), 'ZIPFILE': str(self.archive),
                 'MAGICNET_BACKUP_READY': '0', **(extra_env or {})},
            capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
        self.assertEqual(list(self.config.glob('.install-template.*')), [])

    def test_upgrade_preserves_subscription_inputs_and_cache(self):
        work = self.mod / '.state/sing-box/subscription-work'
        work.mkdir(parents=True)
        preserved = {
            self.config / 'subscription.url': b'https://example.invalid/a\nhttps://example.invalid/b\n',
            self.config / 'subscription.local': b'local subscription fixture\n',
            self.config / 'subscription.user-agent': b'custom-agent\n',
            self.config / 'subscription-filter.list': b'',
            work / 'outbounds.json': b'[]\n',
        }
        for path, content in preserved.items():
            path.write_bytes(content)
        for shell in shells:
            with self.subTest(shell=shell):
                self.active.write_bytes(b'{"old_template":true}\n')
                (self.config / 'standalone-config').touch()
                (self.config / 'config.json.update').write_bytes(b'old update\n')
                self.run_helper(shell)
                self.assertEqual(self.active.read_bytes(), template)
                self.assertEqual(self.active.stat().st_mode & 0o777, 0o600)
                self.assertFalse((self.config / 'standalone-config').exists())
                self.assertFalse((self.config / 'config.json.update').exists())
                for path, content in preserved.items():
                    self.assertEqual(path.read_bytes(), content)

    def test_manager_path_has_required_file_tools(self):
        tools = self.root / 'manager-bin'
        tools.mkdir()
        for name in ('sh', 'bash', 'busybox', 'chmod', 'mkdir', 'mv', 'rm', 'unzip'):
            path = shutil.which(name)
            if path:
                (tools / name).symlink_to(path)
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_helper(shell, extra_env={'PATH': str(tools)})
                self.assertEqual(self.active.read_bytes(), template)

    def test_upgrade_dispatch_does_not_overwrite_regenerated_config(self):
        library = self.mod / 'lib/magicnet/install_config.sh'
        library.parent.mkdir(parents=True)
        library.write_text(
            'magicnet_refresh_install_config() {\n'
            '  printf \'%s\\n\' \'{"restored_nodes":true}\' >"$MODPATH/.config/sing-box/config.json"\n'
            '}\n'
        )
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_helper(shell, extra_env={'MAGICNET_BACKUP_READY': '1'})
                self.assertEqual(self.active.read_bytes(), b'{"restored_nodes":true}\n')

    def test_failed_upgrade_does_not_install_bare_template(self):
        library = self.mod / 'lib/magicnet/install_config.sh'
        library.parent.mkdir(parents=True)
        library.write_text('magicnet_refresh_install_config() { return 1; }\n')
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_helper(shell, success=False, extra_env={'MAGICNET_BACKUP_READY': '1'})
                self.assertEqual(self.active.read_bytes(), b'{"old_template":true}\n')

    def test_fresh_install(self):
        for shell in shells:
            with self.subTest(shell=shell):
                shutil.rmtree(self.mod)
                self.run_helper(shell)
                self.assertEqual(self.active.read_bytes(), template)

    def test_missing_or_empty_template_keeps_previous_config(self):
        for content in (None, b''):
            self.write_zip(content)
            for shell in shells:
                with self.subTest(shell=shell, content=content):
                    self.run_helper(shell, success=False)
                    self.assertEqual(self.active.read_bytes(), b'{"old_template":true}\n')

    def test_corrupt_archive_keeps_previous_config(self):
        self.archive.write_bytes(b'not a zip')
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_helper(shell, success=False)
                self.assertEqual(self.active.read_bytes(), b'{"old_template":true}\n')

    def test_config_symlink_is_rejected(self):
        outside = self.root / 'outside.json'
        outside.write_bytes(b'must survive')
        self.active.unlink()
        self.active.symlink_to(outside)
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_helper(shell, success=False)
                self.assertEqual(outside.read_bytes(), b'must survive')

    def test_config_directory_is_rejected(self):
        self.active.unlink()
        self.active.mkdir()
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_helper(shell, success=False)
                self.assertTrue(self.active.is_dir())

    def test_no_interactive_old_config_restore(self):
        self.assertNotIn('confirm_update_file ', source)
        self.assertGreater(source.index('magicnet_install_config_template || abort'),
                           source.index('! failed to restore MagicNet migration data:'))

unittest.main(argv=[sys.argv[0]], verbosity=2)
PY

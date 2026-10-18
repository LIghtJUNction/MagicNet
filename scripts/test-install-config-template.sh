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
library_source = (Path(sys.argv[1]) / 'src/MagicNet/lib/magicnet/install_config.sh').read_bytes()
start = source.index('magicnet_install_config_template() (\n')
end = source.index('\n)\n', start) + 3
helper = source[start:end]
backup_start = source.index('MAGICNET_BACKUP_DIR=')
backup_setup = source[backup_start:source.index('\nat_exit_register_trap', backup_start)]
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
        self.install_tools()
        self.write_zip(template)

    def install_tools(self):
        tools = self.mod / 'bin'
        core = self.mod / 'bin'
        tools.mkdir(parents=True, exist_ok=True)
        core.mkdir(parents=True, exist_ok=True)
        library = self.mod / 'lib/magicnet/install_config.sh'
        library.parent.mkdir(parents=True, exist_ok=True)
        library.write_bytes(library_source)
        shutil.copyfile(shutil.which('jq'), tools / 'jq')
        (tools / 'jq').chmod(0o755)
        binary = core / 'sing-box'
        binary.write_text('''#!/bin/sh
[ "${REJECT_CONFIG:-0}" != 1 ] || { echo "fixture-secret" >&2; exit 1; }
[ "$1" = check ] && [ "$2" = -c ] && [ "$4" = -D ] || exit 1
[ -s "$5/rules/fixture.srs" ] || exit 1
printf '%s\\n' checked >"$MODPATH/core-called"
"${MODPATH}/bin/jq" -e 'type == "object"' "$3" >/dev/null
''')
        binary.chmod(0o755)

    def write_zip(self, content):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for checker in ('jq', 'sing-box'):
                archive.write(self.mod / 'bin' / checker, 'bin/' + checker)
            archive.writestr('.config/sing-box/rules/fixture.srs', b'fixture')
            if content is not None:
                archive.writestr('.config/sing-box/config.json', content)

    def run_helper(self, shell, success=True, prefix='', extra_env=None):
        result = subprocess.run(
            shell + ['-c', helper + '\n' + prefix + '\nmagicnet_install_config_template'],
            env={**os.environ, 'MODPATH': str(self.mod), 'ZIPFILE': str(self.archive),
                 'MAGICNET_BACKUP_READY': '0', **(extra_env or {})},
            capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr.decode() + ((self.mod / 'core-test.log').read_text() if (self.mod / 'core-test.log').exists() else ''))
        self.assertNotIn(b'fixture-secret', result.stderr + result.stdout)
        self.assertEqual(list(self.config.glob('.install-template.*')), [])
        return result

    def test_empty_manager_directory_extracts_checkers_before_validation(self):
        bootstrap = source[source.index('export SKIPUNZIP=1'):source.index('\nimport __customize__')]
        core = (self.mod / 'bin/sing-box').read_bytes()
        self.mod = self.root / 'MagicNet'
        self.mod.mkdir()
        self.config = self.mod / '.config/sing-box'
        self.active = self.config / 'config.json'
        with zipfile.ZipFile(self.archive, 'w') as archive:
            payloads = {
                'bin/jq': ('#!/bin/sh\nexec "' + shutil.which('jq') + '" "$@"\n').encode(),
                'bin/sing-box': core,
                '.config/sing-box/rules/fixture.srs': b'fixture',
                '.config/sing-box/config.json': template,
                '.config/kamfw/.envrc': b'',
                'lib/kamfw/.kamfwrc': b'',
                'lib/kamfw/helper.sh': b'',
                'lib/kamfw-web/helper.sh': b'',
                'lib/magicnet/helper.sh': b'',
                'lib/magicnet/install_config.sh': library_source,
                'lib/magicnet_singbox_subscribe.sh': b'',
            }
            for name, content in payloads.items():
                entry = zipfile.ZipInfo(name)
                entry.external_attr = 0o100755 << 16
                archive.writestr(entry, content)
        for shell in shells:
            with self.subTest(shell=shell):
                shutil.rmtree(self.mod)
                self.mod.mkdir()
                self.run_helper(shell, prefix='abort() { exit 1; }\n' + bootstrap)
                self.assertEqual(self.active.read_bytes(), template)
                self.assertTrue((self.mod / 'bin/sing-box').is_file())

    @unittest.skipUnless(os.environ.get('MAGICNET_TEST_REAL_CORE'), 'real-core acceptance is opt-in')
    def test_release_template_with_real_core_and_rule_sets(self):
        release = Path(sys.argv[1]) / 'src/MagicNet/.config/sing-box'
        rules = [rule for rule in (release / 'rules').rglob('*') if rule.is_file()]
        self.assertTrue(rules, 'prepared release rule sets are required')
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.write(release / 'config.json', '.config/sing-box/config.json')
            for rule in rules:
                archive.write(rule, '.config/sing-box/rules/' + rule.relative_to(release / 'rules').as_posix())
        binary = self.mod / 'bin/sing-box'
        binary.unlink()
        binary.write_text('#!/bin/sh\n"' + os.environ['MAGICNET_TEST_REAL_CORE'] + '" "$@" >"$MODPATH/core-test.log" 2>&1\n')
        binary.chmod(0o755)
        with zipfile.ZipFile(self.archive, 'a') as archive:
            archive.write(self.mod / 'bin/jq', 'bin/jq')
            archive.write(binary, 'bin/sing-box')
        for kind in ('raw', 'component'):
            if kind == 'component':
                shutil.copytree(release / 'rules', self.config / 'rules')
                with zipfile.ZipFile(self.archive, 'w') as archive:
                    archive.writestr('components.json', b'{"schema":1}')
                    archive.write(release / 'config.json', '.config/sing-box/config.json')
            for shell in shells:
                with self.subTest(shell=shell, archive=kind):
                    self.run_helper(shell)
                    self.assertEqual(self.active.read_bytes(), (release / 'config.json').read_bytes())
                    # A checker must not install/modify live rules as a side effect.
                    if kind == 'raw':
                        self.assertFalse((self.config / 'rules').exists())
                    else:
                        for rule in rules:
                            self.assertEqual((self.config / 'rules' / rule.relative_to(release / 'rules')).read_bytes(),
                                             rule.read_bytes())

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
        for name in ('sh', 'bash', 'busybox', 'chmod', 'cp', 'find', 'mkdir', 'mv', 'rm', 'unzip'):
            path = shutil.which(name)
            if path:
                (tools / name).symlink_to(path)
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_helper(shell, extra_env={'PATH': str(tools)})
                self.assertEqual(self.active.read_bytes(), template)

    def test_upgrade_dispatch_does_not_overwrite_regenerated_config(self):
        library = self.mod / 'lib/magicnet/install_config.sh'
        library.parent.mkdir(parents=True, exist_ok=True)
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
        library.parent.mkdir(parents=True, exist_ok=True)
        library.write_text('magicnet_refresh_install_config() { return 1; }\n')
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_helper(shell, success=False, extra_env={'MAGICNET_BACKUP_READY': '1'})
                self.assertEqual(self.active.read_bytes(), b'{"old_template":true}\n')

    def test_fresh_install(self):
        for shell in shells:
            with self.subTest(shell=shell):
                shutil.rmtree(self.mod)
                self.install_tools()
                self.run_helper(shell)
                self.assertEqual(self.active.read_bytes(), template)

    def test_core_archive_uses_verified_installed_rules(self):
        rules = self.config / 'rules'
        rules.mkdir()
        (rules / 'fixture.srs').write_bytes(b'verified component')
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('components.json', b'{"schema":1}')
            archive.writestr('.config/sing-box/config.json', template)
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_helper(shell)
                self.assertEqual(self.active.read_bytes(), template)
                self.assertEqual((rules / 'fixture.srs').read_bytes(), b'verified component')

    def test_missing_component_rules_keeps_previous_config(self):
        with zipfile.ZipFile(self.archive, 'a') as archive:
            archive.writestr('components.json', b'{"schema":1}')
        for shell in shells:
            with self.subTest(shell=shell):
                result = self.run_helper(shell, success=False)
                self.assertIn(b'phase=rules-component', result.stderr)
                self.assertEqual(self.active.read_bytes(), b'{"old_template":true}\n')

    def test_component_rule_links_cannot_escape_validation_tree(self):
        outside = self.root / 'outside.srs'
        outside.write_bytes(b'must survive')
        rules = self.config / 'rules'
        rules.mkdir()
        (rules / 'fixture.srs').symlink_to(outside)
        with zipfile.ZipFile(self.archive, 'a') as archive:
            archive.writestr('components.json', b'{"schema":1}')
        for shell in shells:
            with self.subTest(shell=shell):
                result = self.run_helper(shell, success=False)
                self.assertIn(b'phase=rules-path', result.stderr)
                self.assertFalse((self.mod / 'core-called').exists())
                self.assertEqual(outside.read_bytes(), b'must survive')
                self.assertEqual(self.active.read_bytes(), b'{"old_template":true}\n')

    def test_remote_rules_are_rejected_before_core_can_download(self):
        self.write_zip(b'{"route":{"rule_set":[{"type":"remote","url":"https://fixture-secret.invalid"}]}}')
        for shell in shells:
            with self.subTest(shell=shell):
                result = self.run_helper(shell, success=False)
                self.assertIn(b'phase=rules-offline', result.stderr)
                self.assertFalse((self.mod / 'core-called').exists())
                self.assertEqual(self.active.read_bytes(), b'{"old_template":true}\n')

    def test_missing_or_empty_template_keeps_previous_config(self):
        for content in (None, b''):
            self.write_zip(content)
            for shell in shells:
                with self.subTest(shell=shell, content=content):
                    self.run_helper(shell, success=False)
                    self.assertEqual(self.active.read_bytes(), b'{"old_template":true}\n')

    def test_invalid_or_rejected_template_keeps_previous_config(self):
        for content, env in ((b'{', {}), (b'[]', {}), (template, {'REJECT_CONFIG': '1'})):
            self.write_zip(content)
            for shell in shells:
                with self.subTest(shell=shell, content=content):
                    self.run_helper(shell, success=False, extra_env=env)
                    self.assertEqual(self.active.read_bytes(), b'{"old_template":true}\n')

    def test_missing_core_keeps_previous_config(self):
        (self.mod / 'bin/sing-box').unlink()
        with zipfile.ZipFile(self.archive) as archive:
            payloads = {name: archive.read(name) for name in archive.namelist() if name != 'bin/sing-box'}
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for name, content in payloads.items():
                archive.writestr(name, content)
        for shell in shells:
            self.run_helper(shell, success=False)
            self.assertEqual(self.active.read_bytes(), b'{"old_template":true}\n')

    def test_raw_archive_replaces_old_checker_before_validation(self):
        for shell in shells:
            with self.subTest(shell=shell):
                (self.mod / 'bin/sing-box').write_text('#!/bin/sh\nexit 0\n')
                result = self.run_helper(shell, success=False, extra_env={'REJECT_CONFIG': '1'})
                self.assertIn(b'phase=core-check', result.stderr)
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

    def test_live_backup_survives_failed_owner_probe(self):
        owner = os.getpid()
        self.assertTrue(Path(f'/proc/{owner}').is_dir())
        for shell in shells:
            with self.subTest(shell=shell):
                live = self.mod / f'.install-backup.{owner}'
                dead = self.mod / '.install-backup.2147483647'
                self.assertFalse(Path('/proc/2147483647').exists())
                for directory in (live, dead):
                    directory.mkdir(exist_ok=True)
                    (directory / '.magicnet-install-backup-v1').write_bytes(
                        b'magicnet-install-backup-v1\n')
                    (directory / 'snapshot').write_bytes(b'private migration data')
                harness = r'''
abort() { printf '%s\n' "$*" >&2; exit 1; }
# The owner is alive, but signal permission can be denied by its context.
kill() {
    if [ "$1" = -0 ] && [ "$2" = "$TEST_OWNER" ]; then return 1; fi
    command kill "$@"
}
if kill -0 "$TEST_OWNER"; then exit 2; fi
'''
                result = subprocess.run(shell + ['-c', harness + backup_setup],
                                        env={**os.environ, 'MODPATH': str(self.mod),
                                             'TEST_OWNER': str(owner)},
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((live / 'snapshot').read_bytes(), b'private migration data')
                self.assertFalse(dead.exists(), 'a confirmed dead owner should still be cleaned')

unittest.main(argv=[sys.argv[0]], verbosity=2)
PY

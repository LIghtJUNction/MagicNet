#!/usr/bin/env python3
"""Host-only UID observation failure regressions; not Android acceptance.

Runs real apps.sh/jq in sh, bash and (when installed) BusyBox ash. Android
package services and selected process failures are explicit command doubles.
Set MAGICNET_APP_POLICY_SOURCE to test an unmodified baseline file.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('MAGICNET_APP_POLICY_SOURCE',
                            ROOT / 'src/MagicNet/lib/magicnet/apps.sh')).resolve()
SHELLS = [('sh', ['sh']), ('bash', ['bash'])]
if shutil.which('busybox'):
    SHELLS.append(('busybox-ash', ['busybox', 'ash']))

COMMON = r'''
magicnet_conf_value() { return 1; }
magicnet_warn() { printf '%s\n' "$*" >&2; }
. "$APP_POLICY_SOURCE"
awk() {
    case "$FAULT" in
    filter) printf 'partial.package\n'; return 139 ;;
    direct-filter|proxy-filter|bypass-filter)
        if [ "${2:-}" = "$MODDIR/.config/magicnet/app-${FAULT%-filter}.list" ]; then
            printf 'partial.package\n'; return 139
        fi ;;
    uid-sort)
        if [ "${1:-}" = '/^[0-9]+$/ && !seen[$0]++' ]; then
            _sort_input=$(cat)
            case "$_sort_input" in
            *10042*) printf '10042\n'; return 139 ;;
            esac
            printf '%s\n' "$_sort_input" | command awk "$@"
            return "$?"
        fi ;;
    uid-parser)
        if [ "${1:-}" = -v ]; then printf '10042\n'; return 139; fi ;;
    user-filter)
        case "$1" in *'UserInfo{'*) printf '0\n'; return 139 ;; esac ;;
    exclude-sort)
        case "$1" in 'BEGIN { print 0 }'*) printf '0\n'; return 139 ;; esac ;;
    esac
    command awk "$@"
}
sed() {
    if [ "$FAULT" = user-filter ]; then printf '0\n'; return 139; fi
    command sed "$@"
}
'''
CMD = r'''
cmd() {
    if [ "$1" = user ]; then
        case "$FAULT" in
        users) printf 'UserInfo{0:Owner:13}\n'; return 1 ;;
        empty-users) return 0 ;;
        esac
        printf 'Users:\n\tUserInfo{0:Owner:13}\n\tUserInfo{10:Work:30}\n'
        return 0
    fi
    case "$FAULT" in
    package-query) printf 'package:%s uid:10042\n' "$7"; return 1 ;;
    late-user)
        if [ "$5" = 10 ]; then printf 'private diagnostic\n' >&2; return 139; fi ;;
    absent-packages) return 0 ;;
    esac
    case "$5" in 0) uid=10042 ;; 10) uid=1010042 ;; *) return 1 ;; esac
    printf 'package:%s uid:%s\npackage:%s.extra uid:99999\npackage:%s uid:%s\n' \
        "$7" "$uid" "$7" "$7" "$uid"
}
'''
PM = r'''
pm() {
    if [ "$FAULT" = package-query ]; then
        printf 'package:%s uid:10042\n' "$4"; return 1
    fi
    printf 'package:%s uid:10042\n' "$4"
}
'''


class PolicyFailureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='magicnet-policy-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.module = self.root / 'module'
        for path in ('bin', '.config/magicnet', '.config/sing-box', '.state/app-policy'):
            (self.module / path).mkdir(parents=True, exist_ok=True)
        jq = shutil.which('jq')
        if jq is None:
            self.fail('host jq is required; install jq rather than skipping policy tests')
        (self.module / 'bin/jq').symlink_to(jq)
        self.config = self.module / '.config/sing-box/config.json'
        self.config.write_text(json.dumps({
            'inbounds': [{'type': 'tun', 'tag': 'tun-in', 'exclude_uid': [0, 777, 999]},
                         {'type': 'ebpf', 'tag': 'ebpf-in', 'mode': 'local',
                          'local': {'exclude_uid': [0, 777, 999]}}],
            'outbounds': [{'type': 'direct', 'tag': 'direct'},
                          {'type': 'selector', 'tag': 'proxy', 'outbounds': ['direct']}],
            'route': {'rules': [], 'final': 'direct'},
            'dns': {'servers': [], 'rules': []},
        }) + '\n')
        for role in ('direct', 'proxy', 'bypass'):
            self.list_path(role).write_text('com.example.app\n')
        (self.module / '.state/app-policy/include-uids.list').write_text('')
        (self.module / '.state/app-policy/exclude-uids.list').write_text('0\n777\n')

    def list_path(self, role):
        return self.module / f'.config/magicnet/app-{role}.list'

    def run_shell(self, shell, code, fault='', mode='blacklist', backend='cmd'):
        provider = CMD if backend == 'cmd' else PM if backend == 'pm' else ''
        env = dict(os.environ, APP_POLICY_SOURCE=str(SOURCE), MODDIR=str(self.module),
                   FAULT=fault, MAGICNET_APP_MODE=mode, ASH_STANDALONE='1')
        return subprocess.run([*shell, '-c', COMMON + provider + '\n' + code],
                              env=env, text=True, capture_output=True, timeout=10)

    def snapshot(self):
        return {str(p.relative_to(self.module)): p.read_bytes()
                for folder in ('.config', '.state')
                for p in (self.module / folder).rglob('*') if p.is_file()}

    def assert_no_staging(self):
        self.assertFalse([p.name for p in self.config.parent.iterdir()
                          if p.name != 'config.json'])

    def test_filter_crash_preserves_status_and_emits_no_partial_list(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                result = self.run_shell(shell,
                    'magicnet_app_proxy_packages "$MODDIR/.config/magicnet/app-proxy.list"',
                    fault='filter')
                self.assertEqual(result.returncode, 139, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_package_lists_trim_comments_deduplicate_and_preserve_utf8(self):
        self.list_path('proxy').write_text(' \n# comment\n  # comment\n 测试 \n测试\n'
                                          ' com.example.app \ncom.example.app\n')
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                result = self.run_shell(shell,
                    'magicnet_app_proxy_packages "$MODDIR/.config/magicnet/app-proxy.list"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '测试\ncom.example.app\n')

    def test_optional_missing_list_is_empty_but_invalid_paths_fail(self):
        for name, shell in SHELLS:
            for kind in ('missing', 'directory', 'broken-symlink'):
                path = self.root / f'{name}-{kind}'
                if kind == 'directory':
                    path.mkdir()
                elif kind == 'broken-symlink':
                    path.symlink_to(self.root / 'does-not-exist')
                with self.subTest(shell=name, kind=kind):
                    result = self.run_shell(shell, 'magicnet_app_proxy_packages ' + shlex.quote(str(path)))
                    self.assertEqual(result.returncode == 0, kind == 'missing')
                    self.assertEqual(result.stdout, '')

    def test_successful_uid_resolution_is_exact_multiuser_and_unique(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                result = self.run_shell(shell,
                    'magicnet_package_uids "$MODDIR/.config/magicnet/app-proxy.list"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '10042\n1010042\n')

    def test_uid_observation_errors_never_emit_partial_results(self):
        faults = ('filter', 'users', 'empty-users', 'user-filter',
                  'package-query', 'late-user', 'uid-parser', 'uid-sort')
        for name, shell in SHELLS:
            for fault in faults:
                with self.subTest(shell=name, fault=fault):
                    result = self.run_shell(shell,
                        'magicnet_package_uids "$MODDIR/.config/magicnet/app-proxy.list"', fault=fault)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, '')
                    self.assertNotIn('private diagnostic', result.stderr)

    def test_user_parser_crash_discards_partial_user_ids(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                result = self.run_shell(shell, 'magicnet_android_user_ids', fault='user-filter')
                self.assertEqual(result.returncode, 139, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_pm_fallback_propagates_query_errors(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                result = self.run_shell(shell,
                    'magicnet_package_uids "$MODDIR/.config/magicnet/app-proxy.list"', backend='pm')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '10042\n')
                result = self.run_shell(shell,
                    'magicnet_package_uids "$MODDIR/.config/magicnet/app-proxy.list"',
                    fault='package-query', backend='pm')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_no_package_service_only_accepts_empty_selection(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                self.list_path('proxy').write_text('com.example.app\n')
                code = 'magicnet_package_uids "$MODDIR/.config/magicnet/app-proxy.list"'
                result = self.run_shell(shell, code, backend='none')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.list_path('proxy').write_text('')
                result = self.run_shell(shell, code, backend='none')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_resolution_failure_preserves_config_state_and_cleans_staging(self):
        initial = self.snapshot()
        faults = ('bypass-filter', 'users', 'empty-users', 'user-filter',
                  'package-query', 'late-user', 'uid-parser', 'uid-sort', 'exclude-sort')
        for name, shell in SHELLS:
            for mode in ('blacklist', 'whitelist'):
                for fault in faults + (('direct-filter', 'proxy-filter') if mode == 'whitelist' else ()):
                    with self.subTest(shell=name, mode=mode, fault=fault):
                        result = self.run_shell(shell, 'magicnet_app_policy_apply_unlocked',
                                                fault=fault, mode=mode)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(self.snapshot(), initial)
                        self.assert_no_staging()

    def test_successful_apply_is_idempotent_and_retains_unmanaged_uids(self):
        for name, shell in SHELLS:
            for mode in ('blacklist', 'whitelist'):
                with self.subTest(shell=name, mode=mode):
                    first = self.run_shell(shell, 'magicnet_app_policy_apply_unlocked', mode=mode)
                    self.assertEqual(first.returncode, 0, first.stderr)
                    initial = self.snapshot()
                    second = self.run_shell(shell, 'magicnet_app_policy_apply_unlocked', mode=mode)
                    self.assertEqual(second.returncode, 0, second.stderr)
                    after = self.snapshot()
                    # Existing jq renders may reorder object keys on a second
                    # apply. Require semantic config equality, and byte-exact
                    # equality for every other state/config file. Failure-path
                    # preservation above remains entirely byte-exact.
                    config_path = '.config/sing-box/config.json'
                    self.assertEqual(json.loads(after.pop(config_path)),
                                     json.loads(initial.pop(config_path)))
                    self.assertEqual(after, initial)
                    config = json.loads(self.config.read_text())
                    for inbound in config['inbounds']:
                        policy = inbound if inbound['type'] == 'tun' else inbound['local']
                        self.assertIn(999, policy['exclude_uid'])
                        self.assertNotIn(777, policy['exclude_uid'])
                        if mode == 'whitelist':
                            self.assertEqual(policy['include_uid'], [10042, 1010042])
                        else:
                            self.assertNotIn('include_uid', policy)
                            self.assertEqual(policy['exclude_uid'], [0, 999, 10042, 1010042])
                    self.assert_no_staging()

    def test_successful_empty_resolution_keeps_whitelist_closed(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                result = self.run_shell(shell, 'magicnet_app_policy_apply_unlocked',
                                        mode='whitelist', fault='absent-packages')
                self.assertEqual(result.returncode, 0, result.stderr)
                config = json.loads(self.config.read_text())
                self.assertEqual(config['inbounds'][0]['include_uid'], [4294967294])
                self.assertEqual(config['inbounds'][1]['local']['include_uid'], [4294967294])
                self.assert_no_staging()

    def test_shell_variables_do_not_escape_observation_or_apply(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                result = self.run_shell(shell, r'''
_config=caller_config
_uid_users=caller_users
_packages=caller_packages
_old_umask=$(umask)
magicnet_app_policy_apply_unlocked || exit 1
[ "$_config" = caller_config ] && [ "$_uid_users" = caller_users ] &&
    [ "$_packages" = caller_packages ] && [ "$(umask)" = "$_old_umask" ]
''')
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)

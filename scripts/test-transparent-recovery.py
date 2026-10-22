#!/usr/bin/env python3
"""Exercise shipped transparent recovery with isolated lifecycle/I/O failures.

Process and network effects are inert fixture files. The actual recovery,
startup preamble, network-stop preparation and configuration writers execute.
The Rust integration target supplies MAGICNET_RECOVERY_TEST_CLI for CLI cases.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = os.environ.get('MAGICNET_RECOVERY_TEST_CLI')
SHELLS = [['sh'], ['bash']]
if shutil.which('busybox'):
    SHELLS.append(['busybox', 'ash'])
CONFIG = '.config/sing-box/config.json'
MODE = '.config/magicnet/transparent-mode.conf'
JOURNAL = '.state/transparent-transaction'
CURRENT_CONFIG = b'{"inbounds":[{"type":"ebpf","tag":"tun-in"}]}\n'
OLD_CONFIG = b'{"inbounds":[{"type":"tun","tag":"tun-in"}]}\n'
CURRENT_MODE = b'MAGICNET_TRANSPARENT_MODE=ebpf\n'
OLD_MODE = b'MAGICNET_TRANSPARENT_MODE=tun\n'
STATE_FILES = {'capability': 'capability', 'probe': 'probe.json',
               'shared-pending': 'shared.pending', 'shared-interfaces': 'shared-interfaces.list'}
METADATA_FILES = ('old-mode-present', 'old-config-present', 'old-mode', 'old-ebpf-state-version',
                  *(f'old-ebpf-{name}-present' for name in STATE_FILES))
BACKUP_FILES = ('old-config.json', *(f'old-ebpf-{name}' for name in STATE_FILES))
METADATA_DAMAGE = ('missing', 'directory', 'fifo', 'symlink', 'dangling', 'empty',
                   'invalid', 'nul', 'extra-lf', 'oversized', 'read-error', 'stat-error')
BACKUP_DAMAGE = ('missing', 'directory', 'fifo', 'symlink', 'dangling', 'absent-with-backup')
ROOT_DAMAGE = ('regular', 'fifo', 'symlink', 'dangling', 'empty')


class Fixture:
    def __init__(self, root: Path, failure: str = '', *, legacy: bool = False):
        self.root = root
        self.write(CONFIG, CURRENT_CONFIG)
        self.write(MODE, CURRENT_MODE)
        self.write('core-live', b'fixture\n')
        self.write('failure', failure.encode())
        for resource in ('hotspot', 'dns', 'guard'):
            self.write(resource, b'installed\n')
        for name, value in {'old-mode-present': b'1\n', 'old-mode': b'tun\n',
                            'old-config-present': b'1\n', 'old-config.json': OLD_CONFIG,
                            'phase': b'candidate-starting\n'}.items():
            self.write(f'{JOURNAL}/{name}', value)
        if not legacy:
            self.write(f'{JOURNAL}/old-ebpf-state-version', b'1\n')
            for name in ('capability', 'probe', 'shared-pending', 'shared-interfaces'):
                self.write(f'{JOURNAL}/old-ebpf-{name}-present', b'1\n')
                self.write(f'{JOURNAL}/old-ebpf-{name}', f'old-{name}\n'.encode())
        for name in ('primitives.sh', 'common.sh', 'subscribe_bootstrap.sh',
                     'singbox_subscribe/bootstrap.sh', 'network.sh', 'core.sh', 'transparent.sh'):
            self.write('lib/magicnet/' + name, (ROOT / 'src/MagicNet/lib/magicnet' / name).read_bytes())
        self.write('lib/kamfw/.kamfwrc', b'import() { :; }\n')
        self.write('lib/magicnet_singbox_subscribe.sh', b':\n')
        self.script('bin/pidof', '#!/bin/sh\nexit 1\n')
        self.script('cli', '#!/bin/sh\nexit 0\n')
        self.write('lib/magicnet.sh', rb'''
import() { :; }
. "$MODDIR/lib/magicnet/primitives.sh"
. "$MODDIR/lib/magicnet/common.sh"
. "$MODDIR/lib/magicnet/network.sh"
. "$MODDIR/lib/magicnet/core.sh"
. "$MODDIR/lib/magicnet/transparent.sh"
event() { printf '%s\n' "$*" >>"$MODDIR/events"; }
fails() { [ "$(cat "$MODDIR/failure")" = "$1" ]; }
magicnet_warn() { event "warn:$*"; }
magicnet_cmd_exists() { [ "$1" = sing-box ] || command -v "$1" >/dev/null 2>&1; }
magicnet_hotspot_watchdog_stop() { event watchdog-stop; ! fails watchdog; }
magicnet_kernel_running() { [ -e "$MODDIR/core-live" ]; }
magicnet_hotspot_route_cleanup() {
    event hotspot-clean
    fails hotspot && return 2
    rm -f "$MODDIR/hotspot"
}
magicnet_disable_dns_capture() {
    event dns-clean
    fails dns && return 2
    rm -f "$MODDIR/dns"
}
magicnet_disable_dns_leak_guard() {
    event guard-clean
    fails guard && return 2
    rm -f "$MODDIR/guard"
}
singbox_stop() {
    event stop
    fails stop && return 2
    for resource in hotspot dns guard; do
        [ ! -e "$MODDIR/$resource" ] || event "stopped-before-clean:$resource"
    done
    rm -f "$MODDIR/core-live"
}
magicnet_detach_pid_from_app_cgroup() { :; }
magicnet_require_subscription_or_stop() { :; }
magicnet_start_singbox_ready() { event start; : >"$MODDIR/core-live"; }
magicnet_singbox_record_runtime_fingerprint() { :; }
magicnet_notify() { :; }
magicnet_supervisors_start_detached() { event supervisors-start; }
magicnet_lifecycle_after_stop() { event finalized; }
magicnet_singbox_update_lock_active() { return 1; }
magicnet_apply_runtime_config() { event materialize; }
magicnet_prepare_singbox_candidate_unlocked() { event candidate; return 1; }
cp() {
    if fails config-copy && [ "$1" = "$MODDIR/.state/transparent-transaction/old-config.json" ]; then return 1; fi
    if fails state-copy && [ "$1" = "$MODDIR/.state/transparent-transaction/old-ebpf-probe" ]; then return 1; fi
    command cp "$@"
}
mv() {
    for last; do :; done
    if fails mode-write && [ "$last" = "$MODDIR/.config/magicnet/transparent-mode.conf" ]; then return 1; fi
    if fails config-rename && [ "$last" = "$MODDIR/.config/sing-box/config.json" ]; then return 1; fi
    command mv "$@"
}
rm() {
    if fails journal-delete && [ "$*" = "-rf $MODDIR/.state/transparent-transaction" ]; then return 1; fi
    command rm "$@"
}
MAGICNET_STOP_CLEANUP_ATTEMPTS=1
MAGICNET_STOP_CLEANUP_DELAY=0
''')
        self.journal_before = self.snapshot()

    def write(self, name: str, data: bytes):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def script(self, name: str, text: str):
        self.write(name, text.encode())
        (self.root / name).chmod(0o700)

    def snapshot(self, relative=JOURNAL):
        root = self.root / relative
        result = {}
        if not os.path.lexists(root):
            return result
        pending = [root]
        while pending:
            path = pending.pop()
            kind = path.lstat().st_mode
            name = str(path.relative_to(root))
            if stat.S_ISLNK(kind):
                result[name] = ('symlink', os.readlink(path))
            elif stat.S_ISREG(kind):
                result[name] = ('file', path.read_bytes())
            elif stat.S_ISDIR(kind):
                result[name] = ('directory',)
                pending.extend(path.iterdir())
            else:
                result[name] = ('special', stat.S_IFMT(kind))
        return result

    def prepare_damaged_journal(self, name, damage):
        for state_name, destination in STATE_FILES.items():
            self.write('.state/transparent-ebpf/' + destination,
                       f'active-{state_name}\n'.encode())
        path = self.root / JOURNAL / name
        if not name:
            if damage == 'symlink':
                target = self.root / 'external-journal'
                path.rename(target)
                path.symlink_to(target, target_is_directory=True)
            else:
                shutil.rmtree(path)
                if damage == 'regular':
                    path.write_bytes(b'invalid journal\n')
                elif damage == 'fifo':
                    os.mkfifo(path)
                elif damage == 'dangling':
                    path.symlink_to(self.root / 'missing-journal')
                elif damage == 'empty':
                    path.mkdir()
                else:
                    raise AssertionError(damage)
        elif damage in ('missing', 'directory', 'fifo', 'symlink', 'dangling'):
            data = path.read_bytes()
            path.unlink()
            if damage == 'directory':
                path.mkdir()
            elif damage == 'fifo':
                os.mkfifo(path)
            elif damage == 'symlink':
                target = self.root / ('external-' + name)
                target.write_bytes(data)
                path.symlink_to(target)
            elif damage == 'dangling':
                path.symlink_to(self.root / 'missing-backup')
        elif damage == 'absent-with-backup':
            marker = 'old-config-present' if name == 'old-config.json' else name + '-present'
            self.write(JOURNAL + '/' + marker, b'0\n')
        elif damage in ('read-error', 'stat-error'):
            # Both readers return otherwise-valid bytes and then an I/O error.
            # Recovery must propagate the error instead of accepting stdout.
            commands = ('cat', 'head') if damage == 'read-error' else ('stat',)
            with (self.root / 'lib/magicnet.sh').open('a') as script:
                for command in commands:
                    script.write(f'''\n{command}() {{
    for argument; do
        if [ "$argument" = "$MODDIR/{JOURNAL}/{name}" ]; then
            command {command} "$@"
            return 1
        fi
    done
    command {command} "$@"
}}\n''')
        else:
            value = path.read_bytes()
            replacements = {'empty': b'', 'invalid': b'auto\n' if name == 'old-mode' else b'2\n',
                            'nul': value.rstrip(b'\n') + b'\0\n',
                            'extra-lf': value + b'\n', 'oversized': value + b'\n' * 128}
            path.write_bytes(replacements[damage])
        self.journal_before = self.snapshot()
        self.state_before = self.snapshot('.state/transparent-ebpf')

    def env(self):
        return dict(os.environ, MODDIR=str(self.root), MAGICNET_API='http://127.0.0.1:1',
                    MAGICNET_COMMAND_TIMEOUT='3',
                    PATH=str(self.root / 'bin') + ':' + os.environ.get('PATH', '/usr/bin:/bin'))

    def run(self, command: str, shell=None, *, timeout=10):
        script = '. "$MODDIR/lib/magicnet.sh"\n' + command
        return self.run_process((shell or ['sh']) + ['-c', script], timeout)

    def cli(self, *args):
        return self.run_process([CLI, *args], 12)

    def run_process(self, args, timeout):
        process = subprocess.Popen(args, env=self.env(), text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate(timeout=3)
        result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
        result.timed_out = timed_out
        return result

    def events(self):
        path = self.root / 'events'
        return path.read_text().splitlines() if path.exists() else []


class RecoveryAssertions:
    def assert_preserved(self, fixture):
        self.assertEqual((fixture.root / CONFIG).read_bytes(), CURRENT_CONFIG)
        self.assertEqual((fixture.root / MODE).read_bytes(), CURRENT_MODE)
        self.assertTrue((fixture.root / JOURNAL).is_dir())
        self.assertEqual(fixture.snapshot(), fixture.journal_before)

    def assert_restored(self, fixture):
        self.assertEqual((fixture.root / CONFIG).read_bytes(), OLD_CONFIG)
        self.assertEqual((fixture.root / MODE).read_bytes(), OLD_MODE)
        self.assertFalse((fixture.root / JOURNAL).exists())
        self.assertFalse(any(event.startswith('stopped-before-clean:') for event in fixture.events()),
                         fixture.events())

    def assert_invalid_journal_preserved(self, fixture, result):
        self.assertFalse(result.timed_out, 'recovery blocked while reading damaged journal')
        self.assertNotIn('timed out', result.stderr, result.stderr)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((fixture.root / CONFIG).is_file(), 'active config was removed')
        self.assertTrue((fixture.root / MODE).is_file(), 'active mode was removed')
        self.assertEqual((fixture.root / CONFIG).read_bytes(), CURRENT_CONFIG)
        self.assertEqual((fixture.root / MODE).read_bytes(), CURRENT_MODE)
        self.assertEqual(fixture.snapshot(), fixture.journal_before)
        self.assertEqual(fixture.snapshot('.state/transparent-ebpf'), fixture.state_before)
        self.assertTrue((fixture.root / 'core-live').exists())
        for event in ('watchdog-stop', 'hotspot-clean', 'dns-clean', 'guard-clean',
                      'stop', 'start', 'candidate', 'materialize'):
            self.assertNotIn(event, fixture.events())


class ShellRecoveryTests(RecoveryAssertions, unittest.TestCase):
    def test_invalid_journal_roots_block_recovery_and_start(self):
        for shell in SHELLS:
            for entry in ('magicnet_recover_interrupted_transparent_transaction',
                          'magicnet_start_kernel'):
                for damage in ROOT_DAMAGE:
                    with self.subTest(shell=shell, entry=entry, damage=damage), \
                            tempfile.TemporaryDirectory(prefix='magicnet-recovery-root-') as td:
                        fixture = Fixture(Path(td))
                        fixture.prepare_damaged_journal('', damage)
                        result = fixture.run(entry, shell, timeout=2)
                        self.assert_invalid_journal_preserved(fixture, result)

    def test_all_metadata_is_validated_before_cleanup_or_stop(self):
        for shell in SHELLS:
            for name in METADATA_FILES:
                for damage in METADATA_DAMAGE:
                    with self.subTest(shell=shell, name=name, damage=damage), \
                            tempfile.TemporaryDirectory(prefix='magicnet-recovery-metadata-') as td:
                        fixture = Fixture(Path(td))
                        fixture.prepare_damaged_journal(name, damage)
                        result = fixture.run('magicnet_recover_interrupted_transparent_transaction',
                                             shell, timeout=2)
                        self.assert_invalid_journal_preserved(fixture, result)

    def test_all_backups_are_validated_before_cleanup_or_stop(self):
        for shell in SHELLS:
            for name in BACKUP_FILES:
                for damage in BACKUP_DAMAGE:
                    with self.subTest(shell=shell, name=name, damage=damage), \
                            tempfile.TemporaryDirectory(prefix='magicnet-recovery-backup-') as td:
                        fixture = Fixture(Path(td))
                        fixture.prepare_damaged_journal(name, damage)
                        result = fixture.run('magicnet_recover_interrupted_transparent_transaction',
                                             shell, timeout=2)
                        self.assert_invalid_journal_preserved(fixture, result)

    def test_partial_snapshot_is_not_legacy_when_caller_disables_globbing(self):
        for shell in SHELLS:
            for name in ('old-ebpf-probe', 'old-ebpf-unknown'):
                with self.subTest(shell=shell, name=name), \
                        tempfile.TemporaryDirectory(prefix='magicnet-recovery-partial-') as td:
                    fixture = Fixture(Path(td), legacy=True)
                    fixture.write(JOURNAL + '/' + name, b'orphan snapshot\n')
                    fixture.journal_before = fixture.snapshot()
                    fixture.state_before = fixture.snapshot('.state/transparent-ebpf')
                    result = fixture.run('set -f\nmagicnet_recover_interrupted_transparent_transaction', shell)
                    self.assert_invalid_journal_preserved(fixture, result)

    def test_absent_components_bare_tokens_and_empty_backups_remain_compatible(self):
        for shell in SHELLS:
            for case in ('absent-mode', 'absent-config', 'absent-state', 'bare-tokens', 'empty-backups'):
                with self.subTest(shell=shell, case=case), \
                        tempfile.TemporaryDirectory(prefix='magicnet-recovery-compatible-') as td:
                    fixture = Fixture(Path(td))
                    journal = fixture.root / JOURNAL
                    if case == 'absent-mode':
                        (journal / 'old-mode-present').write_bytes(b'0\n')
                    elif case == 'absent-config':
                        (journal / 'old-config-present').write_bytes(b'0\n')
                        (journal / 'old-config.json').unlink()
                    elif case == 'absent-state':
                        for name, destination in STATE_FILES.items():
                            (journal / f'old-ebpf-{name}-present').write_bytes(b'0\n')
                            (journal / f'old-ebpf-{name}').unlink()
                            fixture.write('.state/transparent-ebpf/' + destination, b'active\n')
                    elif case == 'bare-tokens':
                        for name in METADATA_FILES:
                            path = journal / name
                            path.write_bytes(path.read_bytes().rstrip(b'\n'))
                    elif case == 'empty-backups':
                        for name in BACKUP_FILES:
                            (journal / name).write_bytes(b'')
                    result = fixture.run('magicnet_recover_interrupted_transparent_transaction', shell)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(journal.exists())
                    if case == 'absent-mode':
                        self.assertFalse((fixture.root / MODE).exists())
                    else:
                        self.assertEqual((fixture.root / MODE).read_bytes(), OLD_MODE)
                    if case == 'absent-config':
                        self.assertFalse((fixture.root / CONFIG).exists())
                    else:
                        expected = b'' if case == 'empty-backups' else OLD_CONFIG
                        self.assertEqual((fixture.root / CONFIG).read_bytes(), expected)
                    for name, destination in STATE_FILES.items():
                        path = fixture.root / '.state/transparent-ebpf' / destination
                        if case == 'absent-state':
                            self.assertFalse(path.exists())
                        else:
                            expected = b'' if case == 'empty-backups' else f'old-{name}\n'.encode()
                            self.assertEqual(path.read_bytes(), expected)

    def test_cleanup_and_stop_failures_preserve_recovery_for_both_entrypoints(self):
        for shell in SHELLS:
            for entry in ('magicnet_recover_interrupted_transparent_transaction',
                          'magicnet_start_kernel'):
                for failure in ('watchdog', 'hotspot', 'dns', 'guard', 'stop'):
                    with self.subTest(shell=shell, entry=entry, failure=failure), \
                            tempfile.TemporaryDirectory(prefix='magicnet-recovery-') as td:
                        fixture = Fixture(Path(td), failure)
                        result = fixture.run(entry, shell)
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assert_preserved(fixture)
                        self.assertTrue((fixture.root / 'core-live').exists())
                        self.assertNotIn('start', fixture.events())
                        if failure != 'stop':
                            self.assertNotIn('stop', fixture.events())

    def test_valid_recovery_cleans_before_stop_restores_and_allows_restart(self):
        for shell in SHELLS:
            for entry in ('magicnet_recover_interrupted_transparent_transaction',
                          'magicnet_start_kernel'):
                for legacy in (True, False):
                    with self.subTest(shell=shell, entry=entry, legacy=legacy), \
                            tempfile.TemporaryDirectory(prefix='magicnet-recovery-') as td:
                        fixture = Fixture(Path(td), legacy=legacy)
                        result = fixture.run(entry, shell)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assert_restored(fixture)
                        self.assertEqual(fixture.events().count('stop'), 1, fixture.events())
                        self.assertEqual('start' in fixture.events(), entry == 'magicnet_start_kernel')
                        if not legacy:
                            self.assertEqual((fixture.root / '.state/transparent-ebpf/probe.json').read_bytes(),
                                             b'old-probe\n')

    def test_restore_io_failure_retains_snapshot_and_retry_succeeds(self):
        for shell in SHELLS:
            for failure in ('mode-write', 'config-copy', 'config-rename', 'state-copy', 'journal-delete'):
                with self.subTest(shell=shell, failure=failure), \
                        tempfile.TemporaryDirectory(prefix='magicnet-recovery-') as td:
                    fixture = Fixture(Path(td), failure)
                    result = fixture.run('magicnet_recover_interrupted_transparent_transaction', shell)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(fixture.snapshot(), fixture.journal_before)
                    self.assertTrue((fixture.root / JOURNAL).is_dir())
                    self.assertNotIn('start', fixture.events())
                    self.assertFalse(any('Recovered an interrupted' in event for event in fixture.events()))
                    fixture.write('failure', b'')
                    result = fixture.run('magicnet_start_kernel', shell)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assert_restored(fixture)
                    self.assertEqual(fixture.events().count('start'), 1)


@unittest.skipUnless(CLI, 'CLI cases run in the Rust transparent_recovery integration target')
class CliRecoveryTests(RecoveryAssertions, unittest.TestCase):
    def test_invalid_journal_roots_block_apply_switch_and_start(self):
        for args in [('config', 'apply'), ('transparent', 'set', 'tun'), ('service', 'start')]:
            for damage in ROOT_DAMAGE:
                with self.subTest(args=args, damage=damage), \
                        tempfile.TemporaryDirectory(prefix='magicnet-recovery-cli-root-') as td:
                    fixture = Fixture(Path(td))
                    fixture.prepare_damaged_journal('', damage)
                    result = fixture.cli(*args)
                    self.assert_invalid_journal_preserved(fixture, result)

    def test_invalid_journal_contents_block_apply_switch_and_start(self):
        cases = [('old-mode-present', 'fifo'), ('old-ebpf-state-version', 'fifo'),
                 ('old-config.json', 'missing'), ('old-ebpf-shared-interfaces', 'missing'),
                 ('old-ebpf-state-version', 'missing'), ('old-config.json', 'symlink'),
                 ('old-config.json', 'absent-with-backup'), ('old-mode-present', 'nul'),
                 ('old-mode', 'directory'), ('old-ebpf-state-version', 'read-error'),
                 ('old-ebpf-shared-interfaces-present', 'stat-error')]
        for args in [('config', 'apply'), ('transparent', 'set', 'tun'), ('service', 'start')]:
            for name, damage in cases:
                with self.subTest(args=args, name=name, damage=damage), \
                        tempfile.TemporaryDirectory(prefix='magicnet-recovery-cli-metadata-') as td:
                    fixture = Fixture(Path(td))
                    fixture.prepare_damaged_journal(name, damage)
                    result = fixture.cli(*args)
                    self.assert_invalid_journal_preserved(fixture, result)

    def test_recovery_failures_block_apply_switch_and_start(self):
        for args in [('config', 'apply'), ('transparent', 'set', 'tun'), ('service', 'start')]:
            for failure in ('watchdog', 'hotspot', 'dns', 'guard', 'stop'):
                with self.subTest(args=args, failure=failure), \
                        tempfile.TemporaryDirectory(prefix='magicnet-recovery-cli-') as td:
                    fixture = Fixture(Path(td), failure)
                    result = fixture.cli(*args)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assert_preserved(fixture)
                    self.assertTrue((fixture.root / 'core-live').exists())
                    for event in ('materialize', 'candidate', 'start'):
                        self.assertNotIn(event, fixture.events())
                    if failure != 'stop':
                        self.assertNotIn('stop', fixture.events())

    def test_recovered_config_apply_and_service_start_restart_successfully(self):
        for args in [('config', 'apply'), ('service', 'start')]:
            with self.subTest(args=args), tempfile.TemporaryDirectory(prefix='magicnet-recovery-cli-') as td:
                fixture = Fixture(Path(td))
                result = fixture.cli(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_restored(fixture)
                self.assertTrue((fixture.root / 'core-live').exists())
                self.assertEqual(fixture.events().count('start'), 1)


if __name__ == '__main__':
    unittest.main()

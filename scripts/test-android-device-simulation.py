#!/usr/bin/env python3
"""Host regressions for the destructive AVD harness, not Android acceptance.

--check-core PATH validates the offline config using the actual built sing-box.
The default suite has no SDK, network, root or third-party Python dependency.
"""
from __future__ import annotations

import copy
import importlib.util
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import warnings
import xml.etree.ElementTree as ET
import zipfile

PATH = Path(__file__).with_name('android-device-simulation.py')
SPEC = importlib.util.spec_from_file_location('simulation', PATH)
SIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIM)
ENV = {'MAGICNET_DISPOSABLE_AVD': '1', 'ANDROID_SERIAL': 'emulator-5554'}
BOOT = '01234567-0123-0123-0123-0123456789ab'
READY = {'schema': 1, 'ok': True, 'command': 'service.status', 'data': {
    'core': {'sing_box': {'process_state': 'running'}}, 'api': {'ready': True},
    'readiness': {'dataplane': True, 'overall': True}}}


def elf(machine=62):
    value = bytearray(64)
    value[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<HH', value, 16, 3, machine)
    return bytes(value)


def cp(output='', rc=0, stderr=''):
    return subprocess.CompletedProcess(['adb'], rc, output, stderr)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'release.zip'
        self.output = self.root / 'fixture.zip'
        self.replacements = {}
        for name in SIM.PAYLOADS:
            path = self.root / name.replace('/', '-')
            path.write_bytes(elf() + name.encode())
            self.replacements[name] = path
        self.entries = {name: elf(183) for name in SIM.PAYLOADS} | {
            'module.prop': b'id=MagicNet\n', 'customize.sh': b'export SKIPUNZIP=1\n',
            'service.sh': b'#!/system/bin/sh\nexit 0\n',
            '.config/magicnet/example.conf': b'keep=this\n'}

    def archive(self, entries=None):
        with zipfile.ZipFile(self.source, 'w') as stream:
            for name, value in (self.entries if entries is None else entries).items():
                item = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
                item.create_system = 3
                item.external_attr = (stat.S_IFREG | (0o755 if name.endswith('.sh') else 0o600)) << 16
                stream.writestr(item, value)

    def build(self):
        return SIM.prepare_archive(self.source, self.output, self.replacements)

    def test_only_executables_and_provenance_change(self):
        self.archive()
        before = self.source.read_bytes()
        manifest = self.build()
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(manifest['production_zip_sha256'], SIM.digest(self.source))
        self.assertEqual(manifest['fixture_zip_sha256'], SIM.digest(self.output))
        with zipfile.ZipFile(self.source) as original, zipfile.ZipFile(self.output) as result:
            self.assertEqual(set(result.namelist()), set(original.namelist()) | {SIM.PROVENANCE})
            for name in original.namelist():
                if name in SIM.PAYLOADS:
                    self.assertEqual(result.read(name), self.replacements[name].read_bytes())
                    self.assertEqual((result.getinfo(name).external_attr >> 16) & 0o777, 0o755)
                else:
                    self.assertEqual(result.read(name), original.read(name))
                    self.assertEqual(result.getinfo(name).external_attr, original.getinfo(name).external_attr)
                    self.assertEqual(result.getinfo(name).date_time, original.getinfo(name).date_time)

    def test_release_zip_cannot_be_overwritten(self):
        self.archive()
        before = self.source.read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'never overwrite'):
            SIM.prepare_archive(self.source, self.source, self.replacements)
        self.assertEqual(self.source.read_bytes(), before)

    def test_missing_or_extra_payload_is_rejected(self):
        self.archive()
        for changes in ({k: v for k, v in self.replacements.items() if k != SIM.PAYLOADS[0]},
                        self.replacements | {'bin/extra': self.replacements[SIM.PAYLOADS[0]]}):
            with self.subTest(changes=list(changes)), self.assertRaises(RuntimeError):
                SIM.prepare_archive(self.source, self.output, changes)

    def test_foreign_or_truncated_replacements_are_rejected(self):
        self.archive()
        for content in (b'#!/bin/sh\nexit 0', elf(183), elf()[:24], elf().replace(b'\x02\x01', b'\x01\x01', 1)):
            with self.subTest(content=content[:6]):
                self.replacements[SIM.PAYLOADS[0]].write_bytes(content)
                with self.assertRaises(RuntimeError):
                    self.build()
                self.assertFalse(self.output.exists())

    def test_unreplaced_foreign_elf_fails_instead_of_booting_broken_fixture(self):
        self.archive(self.entries | {'bin/forgotten-helper': elf(183)})
        with self.assertRaisesRegex(RuntimeError, 'unreplaced foreign ELF'):
            self.build()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.output.with_suffix('.zip.partial').exists())

    def test_path_traversal_and_ambiguous_members_rejected(self):
        for name in ('../outside', '/absolute', 'bin/../outside', 'bin\\outside',
                     'bin//outside', 'bin/./outside', 'C:/outside'):
            with self.subTest(name=name):
                self.archive(self.entries | {name: b'bad'})
                with self.assertRaisesRegex(RuntimeError, 'unsafe ZIP'):
                    self.build()
                self.assertFalse(self.output.exists())

    def test_duplicates_are_rejected(self):
        self.archive()
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.source, 'a') as stream:
                stream.writestr('module.prop', b'id=Other\n')
        with self.assertRaisesRegex(RuntimeError, 'duplicate'):
            self.build()

    def test_incomplete_or_repackaged_module_rejected(self):
        for removed in (*SIM.PAYLOADS, 'module.prop', 'customize.sh'):
            with self.subTest(removed=removed):
                self.archive({k: v for k, v in self.entries.items() if k != removed})
                with self.assertRaises(RuntimeError):
                    self.build()
        self.archive(self.entries | {SIM.PROVENANCE: b'{}'})
        with self.assertRaisesRegex(RuntimeError, 'existing fixture'):
            self.build()

    def test_symlink_payload_is_not_replaced_silently(self):
        with zipfile.ZipFile(self.source, 'w') as stream:
            for name, data in self.entries.items():
                item = zipfile.ZipInfo(name)
                item.external_attr = (stat.S_IFLNK | 0o777) << 16 if name == SIM.PAYLOADS[0] else 0
                stream.writestr(item, data)
        with self.assertRaisesRegex(RuntimeError, 'regular file'):
            self.build()


class ReadinessTests(unittest.TestCase):
    def test_all_independent_readiness_facts_are_required(self):
        self.assertTrue(SIM.is_ready(json.dumps(READY)))
        for field, parent in (('process_state', ['core', 'sing_box']), ('ready', ['api']),
                              ('dataplane', ['readiness']), ('overall', ['readiness'])):
            for value in (None, False, 'unknown', 1):
                candidate = copy.deepcopy(READY)
                location = candidate['data']
                for key in parent:
                    location = location[key]
                location[field] = value
                self.assertFalse(SIM.is_ready(json.dumps(candidate)), (field, value))

    def test_malformed_machine_envelopes_are_not_ready(self):
        for value in ('', '{}', '[]', 'not JSON', 'banner\n' + json.dumps(READY),
                      json.dumps(READY | {'schema': True}), json.dumps(READY | {'ok': False}),
                      json.dumps(READY | {'command': 'core.status'}),
                      json.dumps(READY | {'data': {'core': None}}),
                      json.dumps(READY).replace('\"ok\": true', '\"ok\": false, \"ok\": true')):
            with self.subTest(value=value):
                self.assertFalse(SIM.is_ready(value))

    def test_stale_owned_network_is_detected_in_both_families(self):
        for value in ('-A OUTPUT -j magicnet-dns-output', 'lookup 2022',
                      'default dev magicnet0 table 2022', '-A OUTPUT -j sing-box-output'):
            self.assertTrue(SIM.has_owned_network(value))
        self.assertFalse(SIM.has_owned_network('0: from all lookup local\n32766: from all lookup main'))

    def test_offline_config_has_no_remote_resolver_proxy_or_rule_download(self):
        value = SIM.fixture_config()
        text = json.dumps(value)
        self.assertNotIn('https://', text)
        self.assertEqual([s['type'] for s in value['dns']['servers']], ['hosts'])
        self.assertEqual(value['inbounds'][0]['exclude_uid'], [0])
        self.assertEqual(value['inbounds'][0]['interface_name'], 'magicnet0')
        self.assertEqual(value['outbounds'], [{'type': 'direct', 'tag': 'direct'}])


class DeviceTests(unittest.TestCase):
    def device(self):
        with patch.dict(os.environ, ENV):
            return SIM.Device()

    def test_explicit_disposable_serial_required_before_adb(self):
        with patch.object(SIM.subprocess, 'run', side_effect=AssertionError('no ADB')):
            for env in ({}, {'MAGICNET_DISPOSABLE_AVD': '1', 'ANDROID_SERIAL': 'usb-phone'},
                        {'MAGICNET_DISPOSABLE_AVD': '0', 'ANDROID_SERIAL': 'emulator-5554'}):
                with patch.dict(os.environ, env, clear=True), self.assertRaises(RuntimeError):
                    SIM.Device()

    def test_physical_permissive_and_wrong_abi_refused_before_root(self):
        for values in ({'getprop ro.kernel.qemu': '0'},
                       {'getprop ro.kernel.qemu': '1', 'getprop ro.product.cpu.abi': 'arm64-v8a'},
                       {'getprop ro.kernel.qemu': '1', 'getprop ro.product.cpu.abi': 'x86_64',
                        'getenforce': 'Permissive'}):
            device = self.device()
            with patch.object(device, 'wait_boot'), patch.object(device, 'root') as root, \
                 patch.object(device, 'shell', side_effect=lambda cmd, **_: cp(values[cmd])), \
                 self.assertRaises(RuntimeError):
                device.identify()
            root.assert_not_called()
            self.assertFalse(device.verified)

    def test_mutation_requires_verified_identity(self):
        device = self.device()
        with patch.object(device, 'run', side_effect=AssertionError('no mutation')):
            with self.assertRaises(RuntimeError):
                device.kshell('true')
            with self.assertRaises(RuntimeError):
                device.reboot()

    def test_adb_timeout_and_missing_tool_cannot_pass(self):
        device = self.device()
        for error, code in ((subprocess.TimeoutExpired('adb', 1), 124), (OSError('missing'), 127)):
            with patch.object(SIM.subprocess, 'run', side_effect=error):
                self.assertEqual(device.run('shell', 'true', check=False).returncode, code)
                with self.assertRaises(RuntimeError):
                    device.run('shell', 'true')

    def test_adb_uses_exact_serial_and_bounded_deadline(self):
        device = self.device()
        with patch.object(SIM.subprocess, 'run', return_value=cp()) as run:
            device.shell('true', timeout=3)
        self.assertEqual(run.call_args.args[0], ['adb', '-s', 'emulator-5554', 'shell', 'true'])
        self.assertEqual(run.call_args.kwargs['timeout'], 3)
        for invalid in (0, -1, 301):
            with self.assertRaises(RuntimeError):
                device.shell('true', timeout=invalid)

    def test_kernel_su_shell_preserves_standalone_semantics_without_fake_su_flag(self):
        device = self.device()
        device.verified = True
        with patch.object(device, 'run', return_value=cp()) as run:
            device.kshell('exit 17')
        self.assertEqual(run.call_args.args, ('shell', '-T', SIM.KSUD + ' debug su'))
        self.assertIn('ASH_STANDALONE=1', run.call_args.kwargs['input_text'])
        self.assertIn("exec /data/adb/ksu/bin/busybox sh -c 'exit 17'", run.call_args.kwargs['input_text'])

    def test_pinned_kernel_userspace_late_load_requires_active_kernel_and_real_ksu_domain(self):
        device = self.device()
        device.verified = True
        calls = []

        def shell(command, **_):
            command = command.removeprefix('PATH=/data/adb/ksu/bin:/system/bin:/system/xbin ')
            calls.append(command)
            values = {
                'mkdir -p /data/adb/ksu/bin': '',
                SIM.KSUD + ' debug extract-binary busybox ' + SIM.BB: '',
                f'chmod 0755 {SIM.BB} && {SIM.BB} --install -s /data/adb/ksu/bin': '',
                'getenforce': 'Enforcing\n',
                SIM.KSUD + ' boot-info current-kmi': 'android15-6.6\n',
                f'cp {SIM.KSUD} {SIM.KSUD_LAUNCH} && chmod 0755 {SIM.KSUD_LAUNCH}': '',
                SIM.KSUD_LAUNCH + ' late-load': '',
                SIM.KSUD + ' debug version': 'Kernel Version: 32389\n',
                f'test -x {SIM.BB}': '',
            }
            return cp(values[command])

        def kshell(command, **_):
            return cp(SIM.KSU_DOMAIN + '\n' if command == 'id -Z' else 'Enforcing\n')

        with patch.object(device, 'shell', side_effect=shell), \
             patch.object(device, 'kshell', side_effect=kshell), \
             patch.object(device, 'check_busybox') as preflight:
            evidence = device.late_load_kernelsu()
        self.assertEqual(evidence, {
            'mode': 'pinned-kernel-userspace-late-load',
            'kmi': 'android15-6.6',
            'kernel_version': 'Kernel Version: 32389',
        })
        self.assertEqual([call.args for call in preflight.call_args_list], [('extracted',), ('activated',)])
        self.assertEqual([call.kwargs for call in preflight.call_args_list],
                         [{'activated': False}, {'activated': True}])
        self.assertTrue(device.late_load_on_reboot)
        self.assertIn(SIM.KSUD_LAUNCH + ' late-load', calls)
        self.assertNotIn(SIM.KSUD + ' late-load', calls)
        self.assertNotIn(SIM.KSUD + ' boot-info supported-kmis', calls)

    def test_userspace_late_load_rejects_missing_kernel_interface_before_activation(self):
        device = self.device()
        device.verified = True
        calls = []

        def shell(command, **_):
            calls.append(command)
            values = {
                'getenforce': 'Enforcing\n',
                SIM.KSUD + ' debug version': 'Kernel Version: 0\n',
            }
            return cp(values[command])

        with patch.object(device, 'shell', side_effect=shell), \
             self.assertRaisesRegex(RuntimeError, 'pinned KernelSU kernel is not active'):
            device.late_load_kernelsu()
        self.assertNotIn(SIM.KSUD + ' late-load', calls)
        self.assertFalse(device.late_load_on_reboot)

    def test_reboot_reactivates_late_load_only_after_android_boot(self):
        device = self.device()
        device.verified = True
        device.late_load_on_reboot = True
        order = []
        def shell(command, **_):
            if command == 'cat /proc/sys/kernel/random/boot_id':
                return cp(BOOT)
            if command == 'getenforce':
                return cp('Enforcing\n')
            raise AssertionError(command)
        with patch.object(device, 'shell', side_effect=shell), \
             patch.object(device, 'run', return_value=cp()) as run, \
             patch.object(device, 'wait_boot', side_effect=lambda **_: order.append('boot')), \
             patch.object(device, 'root', side_effect=lambda: order.append('root')), \
             patch.object(device, 'late_load_kernelsu',
                          side_effect=lambda: order.append('late-load') or {}) as late:
            device.reboot()
        self.assertEqual(order, ['boot', 'root', 'late-load'])
        self.assertEqual(run.call_args.args, ('reboot',))
        late.assert_called_once_with()

    def test_root_waits_for_restarted_adbd_and_checks_real_uid(self):
        device = self.device()
        # A stale wait-for-device succeeds before the old adbd disconnects.
        # Neither an offline read nor a still-unprivileged daemon is root.
        with patch.object(device, 'run', return_value=cp()) as run, \
             patch.object(device, 'shell', side_effect=[cp('', 1, 'error: device offline'),
                                                       cp('2000\n'), cp('0\n')]) as shell, \
             patch.object(SIM.time, 'monotonic', return_value=0), \
             patch.object(SIM.time, 'sleep'):
            device.root()
        self.assertEqual([call.args for call in run.call_args_list].count(('root',)), 1)
        self.assertEqual(shell.call_count, 3)
        self.assertTrue(all(call.args == ('id -u',) and call.kwargs['check'] is False
                            and call.kwargs['timeout'] <= 5 for call in shell.call_args_list))

    def test_root_reconnect_timeout_or_root_request_failure_stays_failed(self):
        device = self.device()
        with patch.object(device, 'run', return_value=cp()), \
             patch.object(device, 'shell', return_value=cp('2000\n')), \
             patch.object(SIM.time, 'monotonic', side_effect=[0, 0, 0, 0, 0, 30, 30, 30]), \
             patch.object(SIM.time, 'sleep'), \
             self.assertRaisesRegex(RuntimeError, 'reconnect before deadline'):
            device.root()
        with patch.object(device, 'run', side_effect=RuntimeError('root denied')), \
             patch.object(device, 'shell') as shell, \
             self.assertRaisesRegex(RuntimeError, 'root denied'):
            device.root()
        shell.assert_not_called()

    def test_root_transport_failure_retries_only_after_nonroot_observation(self):
        for error in ('error: device offline', "error: device 'emulator-5554' not found",
                      'adb: unable to connect for root: device offline',
                      'adb: unable to connect for root: device offline (no transport)',
                      'error: device offline (transport offline)',
                      'error: device disconnected', 'error: connection reset by peer',
                      'error: closed', 'error: unexpected EOF',
                      "error: protocol fault (couldn't read status): Success",
                      "error: protocol fault (couldn't read status length): Success",
                      "error: protocol fault (couldn't read status message): EOF"):
            with self.subTest(error=error):
                device = self.device()
                roots = iter([cp('', 1, error), cp()])
                def run(operation, **options):
                    self.assertFalse(options['check'])
                    self.assertLessEqual(options['timeout'], 5)
                    return next(roots) if operation == 'root' else cp()
                with patch.object(device, 'run', side_effect=run) as runner, \
                     patch.object(device, 'shell', side_effect=[cp('2000\n'), cp('0\n')]) as shell, \
                     patch.object(SIM.time, 'monotonic', return_value=0), \
                     patch.object(SIM.time, 'sleep'):
                    device.root()
                self.assertEqual([c.args[0] for c in runner.call_args_list],
                                 ['root', 'wait-for-device', 'root', 'wait-for-device'])
                self.assertEqual(shell.call_count, 2)
                evidence = device.root_checks[0]
                self.assertEqual(evidence['status'], 'passed')
                self.assertTrue(evidence['root_requests'][0]['diagnostic'].startswith('transport_'))
                self.assertTrue(evidence['root_requests'][0]['stderr_present'])
                self.assertNotIn(error, json.dumps(evidence))

    def test_lost_root_reply_does_not_repeat_an_already_effective_request(self):
        device = self.device()
        with patch.object(device, 'run', side_effect=[cp('', 1, 'error: EOF'), cp()]) as run, \
             patch.object(device, 'shell', return_value=cp('0\n')) as shell, \
             patch.object(SIM.time, 'monotonic', return_value=0):
            device.root()
        self.assertEqual([c.args[0] for c in run.call_args_list], ['root', 'wait-for-device'])
        shell.assert_called_once()

    def test_production_root_refusal_cannot_be_overridden_by_transport_or_uid_zero(self):
        for code, denial in ((0, 'adbd cannot run as root in production builds'),
                             (1, 'adbd cannot run as root in production builds'),
                             (1, 'root access is disabled'), (1, 'permission denied'),
                             (1, 'operation not permitted')):
            device = self.device()
            denial += '\nerror: device offline'
            with self.subTest(code=code), \
                 patch.object(device, 'run', return_value=cp('', code, denial)) as run, \
                 patch.object(device, 'shell', return_value=cp('0\n')) as shell, \
                 self.assertRaisesRegex(RuntimeError, 'root refused'):
                device.root()
            run.assert_called_once()
            shell.assert_not_called()
            self.assertEqual(device.root_checks[0]['root_requests'][0]['diagnostic'], 'root_denied')

    def test_unknown_missing_timeout_and_abnormal_root_errors_are_not_retried(self):
        for failure in (cp('', 1), cp('', 1, 'permission denied'), cp('', 1, 'unknown failure'),
                        cp('', 124, 'ADB deadline exceeded'), cp('', 127, 'ADB unavailable'),
                        cp('', -11, 'error: device offline'), cp('', 139, 'error: EOF')):
            device = self.device()
            with self.subTest(failure=failure), \
                 patch.object(device, 'run', return_value=failure) as run, \
                 patch.object(device, 'shell', return_value=cp('0\n')) as shell, \
                self.assertRaisesRegex(RuntimeError, 'ADB root (failed|refused)'):
                device.root()
            run.assert_called_once()
            shell.assert_not_called()

    def test_transport_words_do_not_hide_unknown_or_authorization_errors(self):
        for error in ('permission denied: unexpected EOF',
                      'error: unauthorized device; connection closed',
                      'access denied\nerror: device offline',
                      'unknown failure\nerror: device offline',
                      'adb: unable to connect for root: unknown failure',
                      'error: device offline (unknown failure)',
                      'error: unexpected EOF while applying an unknown operation'):
            device = self.device()
            with self.subTest(error=error), \
                 patch.object(device, 'run', return_value=cp('', 1, error)) as run, \
                 patch.object(device, 'shell', return_value=cp('0\n')) as shell, \
                 self.assertRaisesRegex(RuntimeError, 'ADB root (failed|refused)'):
                device.root()
            run.assert_called_once()
            shell.assert_not_called()

    def test_unknown_reconnect_or_identity_errors_do_not_become_root_success(self):
        for operation in ('wait-for-device', 'id -u'):
            device = self.device()
            results = [cp(), cp('', 1, 'unexpected permission denied')
                       if operation == 'wait-for-device' else cp()]
            with self.subTest(operation=operation), \
                 patch.object(device, 'run', side_effect=results) as run, \
                 patch.object(device, 'shell', return_value=cp('', 1, 'unknown shell failure')) as shell, \
                 self.assertRaisesRegex(RuntimeError, 'ADB (reconnect|root identity) failed'):
                device.root()
            self.assertEqual(run.call_count, 2)
            self.assertEqual(shell.call_count, int(operation == 'id -u'))

    def test_root_global_deadline_covers_first_request_and_permanent_disconnect(self):
        device = self.device()
        elapsed = [0.0]
        calls = []
        def run(operation, **options):
            remaining = 30 - elapsed[0]
            self.assertGreater(remaining, 0)
            self.assertLessEqual(options['timeout'], min(5, remaining))
            calls.append(operation)
            elapsed[0] += options['timeout']
            return cp('', 1, 'error: device offline') if operation == 'root' else cp('', 124)
        with patch.object(device, 'run', side_effect=run), \
             patch.object(device, 'shell') as shell, \
             patch.object(SIM.time, 'monotonic', side_effect=lambda: elapsed[0]), \
             patch.object(SIM.time, 'sleep', side_effect=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds)), \
             self.assertRaisesRegex(RuntimeError, 'reconnect before deadline'):
            device.root()
        self.assertEqual(elapsed[0], 30)
        self.assertEqual(calls.count('root'), 1)
        self.assertEqual(calls.count('wait-for-device'), 5)
        shell.assert_not_called()

    def test_no_read_or_success_is_allowed_after_root_operation_deadline(self):
        for operation in ('root', 'wait-for-device', 'id -u'):
            device = self.device()
            elapsed = [0.0]
            def run(name, **options):
                if name == operation:
                    elapsed[0] = 30
                return cp()
            def identity(command, **options):
                elapsed[0] = 30
                return cp('0\n')
            with self.subTest(operation=operation), \
                 patch.object(device, 'run', side_effect=run) as runner, \
                 patch.object(device, 'shell', side_effect=identity) as shell, \
                 patch.object(SIM.time, 'monotonic', side_effect=lambda: elapsed[0]), \
                 patch.object(SIM.time, 'sleep'), \
                 self.assertRaisesRegex(RuntimeError, 'deadline'):
                device.root()
            self.assertEqual(runner.call_count, 1 if operation == 'root' else 2)
            self.assertEqual(shell.call_count, int(operation == 'id -u'))

    def test_old_boot_completed_flag_does_not_count_as_reboot(self):
        device = self.device()
        with patch.object(device, 'shell', return_value=cp('1\n' + BOOT)), \
             patch.object(SIM.time, 'monotonic', side_effect=[0, 0, 0, 1, 1]), \
             patch.object(SIM.time, 'sleep'), self.assertRaisesRegex(RuntimeError, 'boot deadline'):
            device.wait_boot(previous=BOOT, timeout=1)

    def test_abi_failure_stops_before_adb_deadline(self):
        device = self.device()
        with tempfile.TemporaryDirectory() as tmp:
            device.boot_log = Path(tmp) / 'emulator.log'
            device.boot_log.write_text('virtio_blk: disagrees about version of symbol module_layout\n'
                                       "init: Failed to insmod '/lib/modules/virtio_blk.ko'\n")
            with patch.object(device, 'shell') as shell, \
                 self.assertRaisesRegex(RuntimeError, 'kernel_module_abi_mismatch'):
                device.wait_boot()
            shell.assert_not_called()

    def test_boot_log_is_bounded_and_requires_failure_evidence(self):
        device = self.device()
        with tempfile.TemporaryDirectory() as tmp:
            device.boot_log = Path(tmp) / 'emulator.log'
            self.assertIsNone(device.boot_failure())
            device.boot_log.write_bytes(b'init: InitFatalReboot: signal 6\n' * 2)
            self.assertEqual(device.boot_failure(), 'early_init_reboot_loop')
            with device.boot_log.open('ab') as stream:
                stream.write(b'x' * 262144)
            self.assertIsNone(device.boot_failure())
            device.boot_log.write_text('init: InitFatalReboot: signal 6\n')
            self.assertIsNone(device.boot_failure())

    def test_previous_boot_failures_do_not_poison_reboot(self):
        device = self.device()
        with tempfile.TemporaryDirectory() as tmp:
            device.boot_log = Path(tmp) / 'emulator.log'
            device.boot_log.write_text('init: InitFatalReboot: signal 6\n' * 2)
            with patch.object(device, 'shell', return_value=cp('1\n' + BOOT)):
                device.wait_boot(previous='different', timeout=1)

    def test_new_boot_identity_completes_reboot(self):
        device = self.device()
        with patch.object(device, 'shell', return_value=cp('1\n' + BOOT)), \
             patch.object(SIM.time, 'monotonic', return_value=0):
            device.wait_boot(previous='different', timeout=1)

    def test_ready_timeout_is_not_accepted(self):
        device = self.device()
        with patch.object(device, 'kshell', return_value=cp('{}')), \
             patch.object(SIM.time, 'monotonic', side_effect=[0, 0, 0, 1, 1]), \
             patch.object(SIM.time, 'sleep'), self.assertRaisesRegex(RuntimeError, 'did not become ready'):
            device.ready(timeout=1)

    def test_network_cleanup_failure_is_not_suppressed(self):
        device = self.device()
        for observation in ('-A OUTPUT -j magicnet-dns-output', 'lookup 2022'):
            with patch.object(device, 'kshell', side_effect=[cp(), cp(observation)]), \
                 self.assertRaisesRegex(RuntimeError, 'survived stop'):
                device.stopped()
        with patch.object(device, 'kshell', side_effect=RuntimeError('iptables denied')), \
             self.assertRaisesRegex(RuntimeError, 'denied'):
            device.stopped()

    def test_stop_check_does_not_mask_live_interface_or_missing_pidof(self):
        device = self.device()
        commands = []
        with patch.object(device, 'kshell', side_effect=lambda command, **_: commands.append(command) or cp()):
            device.stopped()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bb = root / 'busybox'
            tun = root / 'magicnet0'
            command = commands[0].replace(SIM.BB, str(bb)).replace('/sys/class/net/magicnet0', str(tun))
            for live, pid_rc, output, expected in ((True, 1, '', 1), (False, 127, '', 1),
                                                  (False, 0, '123', 1), (False, 1, '', 0)):
                if live:
                    tun.touch()
                else:
                    tun.unlink(missing_ok=True)
                bb.write_text(f'#!/bin/sh\nprintf "%s" "{output}"\nexit {pid_rc}\n')
                bb.chmod(0o755)
                result = subprocess.run(['sh', '-c', command], timeout=2)
                self.assertEqual(result.returncode, expected, (live, pid_rc))


class BusyboxPreflightTests(unittest.TestCase):
    def device(self):
        with patch.dict(os.environ, ENV):
            device = SIM.Device()
        device.verified = True
        return device

    def results(self):
        return [cp('a' * 64 + '  ' + SIM.BB + '\n'),
                subprocess.CompletedProcess([], 0, '', 'BusyBox v1.36.1.1 topjohnwu multi-call binary.\n')] + [
                    cp(expected, rc) for _, _, _, rc, expected
                    in SIM.busybox_regex_cases() + SIM.system_sed_cases()]

    def test_valid_runtime_records_only_bounded_identity_and_statuses(self):
        for activated in (False, True):
            device = self.device()
            answers = iter(self.results())
            with patch.object(device, 'shell', side_effect=lambda *a, **k: next(answers)) as shell, \
                 patch.object(device, 'kshell', side_effect=lambda *a, **k: next(answers)) as kshell:
                device.check_busybox('activated' if activated else 'extracted', activated=activated)
            record = device.busybox_checks[0]
            self.assertEqual(record['status'], 'passed')
            self.assertEqual(record['sha256'], 'a' * 64)
            self.assertEqual(record['version'], '1.36.1.1')
            self.assertEqual(record['sed_provider'], '/system/bin/sed')
            self.assertEqual(record['checks']['nodes_absent']['exit_code'], 1)
            self.assertEqual(record['checks']['nodes']['provider'], 'kernelsu_busybox')
            self.assertEqual(record['checks']['sed_lines']['provider'], 'android_system_sed')
            calls = shell.call_args_list + kshell.call_args_list
            case_count = len(SIM.busybox_regex_cases()) + len(SIM.system_sed_cases())
            self.assertEqual(len(calls), 2 + case_count)
            for call in calls:
                self.assertFalse(call.kwargs['check'])
                self.assertGreater(call.kwargs['timeout'], 0)
                self.assertLessEqual(call.kwargs['timeout'], 3)
            self.assertEqual(kshell.call_count, 1 + case_count if activated else 0)
            self.assertNotIn('测试', json.dumps(record, ensure_ascii=False))
            self.assertNotIn('multi-call', json.dumps(record))

    def test_crash_nomatch_timeout_and_wrong_output_fail_closed(self):
        for failure in (cp(rc=139), cp(rc=-11), cp(rc=1), cp(rc=124), cp('private config')):
            device = self.device()
            answers = self.results()
            answers[2] = failure
            with patch.object(device, 'shell', side_effect=answers), \
                 self.assertRaisesRegex(RuntimeError, 'Module shell tool preflight failed'):
                device.check_busybox('extracted', activated=False)
            record = device.busybox_checks[0]
            self.assertEqual(record['status'], 'failed')
            self.assertEqual(record['checks']['nodes']['exit_code'], failure.returncode)
            self.assertNotIn('private config', json.dumps(record))

    def test_missing_identity_and_false_negative_control_fail_closed(self):
        for index, replacement in ((0, cp('bad hash')), (1, cp('not BusyBox')),
                                   (1, cp('BusyBox v1.36.1 ', rc=139)), (5, cp(rc=0))):
            device = self.device()
            answers = self.results()
            answers[index] = replacement
            with patch.object(device, 'shell', side_effect=answers), self.assertRaises(RuntimeError):
                device.check_busybox('extracted', activated=False)
            self.assertEqual(device.busybox_checks[0]['status'], 'failed')

    def test_total_deadline_prevents_further_adb_calls(self):
        device = self.device()
        case_count = len(SIM.busybox_regex_cases()) + len(SIM.system_sed_cases())
        with patch.object(SIM.time, 'monotonic',
                          side_effect=[0] + [21] * (2 + case_count)), \
             patch.object(device, 'shell') as shell, self.assertRaises(RuntimeError):
            device.check_busybox('extracted', activated=False)
        shell.assert_not_called()
        self.assertTrue(all(item['exit_code'] == 124
                            for item in device.busybox_checks[0]['checks'].values()))

    def test_unverified_device_and_excess_history_are_rejected(self):
        device = self.device()
        device.verified = False
        with patch.object(device, 'shell') as shell, self.assertRaises(RuntimeError):
            device.check_busybox('extracted', activated=False)
        shell.assert_not_called()
        device.verified = True
        device.busybox_checks = [{}] * 16
        with patch.object(device, 'shell') as shell, self.assertRaises(RuntimeError):
            device.check_busybox('extracted', activated=False)
        shell.assert_not_called()

    def test_regex_cases_match_existing_startup_patterns_and_host_tools(self):
        bootstrap = (SIM.ROOT / 'src/MagicNet/lib/magicnet/singbox_subscribe/bootstrap.sh').read_text()
        common = (SIM.ROOT / 'src/MagicNet/lib/magicnet/common.sh').read_text()
        self.assertIn('any(.outbounds[]?', bootstrap)
        self.assertIn('magicnet_singbox_config_shape_valid "$_config"', common)
        apps = (SIM.ROOT / 'src/MagicNet/lib/magicnet/apps.sh').read_text()
        self.assertIn('index($0, "UserInfo{")', apps)
        self.assertNotIn('gsub(/^[[:space:]]+', apps)
        for name, args, sample, rc, output in SIM.busybox_regex_cases():
            with self.subTest(case=name):
                result = subprocess.run(args, input=sample, text=True, capture_output=True, timeout=3)
                self.assertEqual(result.returncode, rc)
                self.assertEqual(result.stdout, output)
        for name, args, sample, rc, output in SIM.system_sed_cases():
            with self.subTest(case=name):
                result = subprocess.run(['sed', *args], input=sample, text=True,
                                        capture_output=True, timeout=3)
                self.assertEqual(result.returncode, rc)
                self.assertEqual(result.stdout, output)
        envrc = (SIM.ROOT / 'src/MagicNet/.config/kamfw/.envrc').read_text()
        runtime = (SIM.ROOT / 'src/MagicNet/lib/magicnet.sh').read_text()
        for source in (envrc, runtime):
            self.assertIn('sed() { /system/bin/sed "$@"; }', source)

    def test_config_diagnostics_retain_exit_codes_not_output(self):
        device = self.device()
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(device, 'kshell', return_value=cp('private config', 139)) as run, \
             patch.object(device, 'shell', return_value=cp()):
            SIM.diagnostics(device, Path(tmp))
            result = (Path(tmp) / 'config-regex-exit-codes.json').read_text()
        self.assertEqual(json.loads(result), dict.fromkeys(SIM.CONFIG_PATTERNS, 139))
        self.assertNotIn('private', result)
        for call in run.call_args_list:
            self.assertIn('>/dev/null 2>&1', call.args[0])
            self.assertLessEqual(call.kwargs['timeout'], 3)

    def test_exit_codes_are_bounded_and_preserve_signal_forms(self):
        for code in (0, 1, 2, 124, 127, 139, -11):
            self.assertEqual(SIM.bounded_exit_code(code), code)
        for code in (True, 'secret', 99999, -256):
            self.assertIsNone(SIM.bounded_exit_code(code))


class TunControlTests(unittest.TestCase):
    def test_failed_device_commands_reach_proof_without_raising(self):
        device = Mock()
        device.kshell.return_value = cp(rc=1)
        def verify(adb, *_):
            self.assertEqual(adb('fixture-command', timeout=15).returncode, 1)
            device.kshell.assert_called_once_with('fixture-command', timeout=15, check=False)
            return {'status': 'not_verified', 'failure_operation': 'config_save',
                    'failure_exit_code': 1}
        proof = Mock(verify=verify)
        benchmark = Mock()
        with tempfile.TemporaryDirectory() as tmp, patch.object(
                SIM, 'load_script', side_effect=[proof, benchmark]):
            with self.assertRaisesRegex(RuntimeError, 'app-UID TUN controls failed'):
                SIM.tun_controls(device, Path(tmp), 'upgrade-preservation')
            report = json.loads((Path(tmp) / 'tun-controls-upgrade-preservation.json').read_text())
            self.assertEqual(report['failure_operation'], 'config_save')
            self.assertEqual(report['failure_exit_code'], 1)


class InvalidConfigTests(unittest.TestCase):
    def device(self, reject_rc=1, changed=False, deny_valid=False,
               core_reject_rc=1, deny_core_valid=False):
        calls = []
        reads = 0
        saves = 0
        validations = 0

        def shell(command, **options):
            nonlocal reads, saves, validations
            calls.append(command)
            if 'config-editor save-file' in command:
                saves += 1
                if saves == 1:
                    if deny_valid:
                        raise RuntimeError('valid payload path denied')
                    return cp()
                self.assertIs(options.get('check'), False)
                return cp(rc=reject_rc)
            if '/bin/sing-box check' in command:
                validations += 1
                if validations == 1:
                    if deny_core_valid:
                        raise RuntimeError('valid core control failed')
                    return cp()
                self.assertIs(options.get('check'), False)
                return cp(rc=core_reject_rc)
            if 'config-editor get' in command:
                reads += 1
                return cp(json.dumps({'fixture': 2 if changed and reads > 1 else 1}))
            return cp()

        return Mock(kshell=Mock(side_effect=shell)), calls

    def test_valid_same_path_control_precedes_malformed_rejection(self):
        device, calls = self.device()
        report = SIM.invalid_config_rollback(device)
        saves = [i for i, c in enumerate(calls) if 'config-editor save-file' in c]
        malformed = next(i for i, c in enumerate(calls) if 'printf "{"' in c)
        self.assertLess(saves[0], malformed)
        self.assertLess(malformed, saves[1])
        self.assertEqual(calls[saves[0]], calls[saves[1]])
        validators = [i for i, c in enumerate(calls) if '/bin/sing-box check' in c]
        self.assertLess(validators[0], malformed)
        self.assertLess(malformed, validators[1])
        self.assertLess(validators[1], saves[1])
        self.assertEqual(calls[validators[0]], calls[validators[1]])
        self.assertEqual(report, {'core_rejection_exit_code': 1,
                                  'save_rejection_exit_code': 1, 'active_config_preserved': True})
        self.assertTrue(calls[-1].startswith('rm -f '))
        self.assertEqual(device.ready.call_count, 2)

    def test_path_permission_failure_cannot_count_as_invalid_json_rejection(self):
        device, calls = self.device(deny_valid=True)
        with self.assertRaisesRegex(RuntimeError, 'valid payload path denied'):
            SIM.invalid_config_rollback(device)
        self.assertFalse(any('printf "{"' in c for c in calls))
        self.assertTrue(calls[-1].startswith('rm -f '))

    def test_cli_crashes_and_nonstandard_failures_are_not_rejection(self):
        for code in (0, 2, 101, 124, 126, 127, 134, 137, 139, 255, -6, -11):
            with self.subTest(code=code):
                device, calls = self.device(reject_rc=code)
                with self.assertRaises(RuntimeError):
                    SIM.invalid_config_rollback(device)
                self.assertTrue(calls[-1].startswith('rm -f '))

    def test_abnormal_core_control_fails_even_when_cli_would_return_one(self):
        for code in (0, 2, 101, 124, 126, 127, 134, 137, 139, 255, -6, -11):
            with self.subTest(code=code):
                device, calls = self.device(core_reject_rc=code)
                with self.assertRaisesRegex(RuntimeError, 'core validator'):
                    SIM.invalid_config_rollback(device)
                self.assertEqual(sum('config-editor save-file' in c for c in calls), 1)
                self.assertTrue(calls[-1].startswith('rm -f '))

    def test_unavailable_positive_core_control_never_reaches_malformed_payload(self):
        device, calls = self.device(deny_core_valid=True)
        with self.assertRaisesRegex(RuntimeError, 'valid core control failed'):
            SIM.invalid_config_rollback(device)
        self.assertFalse(any('printf "{"' in c for c in calls))
        self.assertTrue(calls[-1].startswith('rm -f '))

    def test_failed_validation_must_not_change_active_config(self):
        device, calls = self.device(changed=True)
        with self.assertRaisesRegex(RuntimeError, 'changed the active configuration'):
            SIM.invalid_config_rollback(device)
        self.assertTrue(calls[-1].startswith('rm -f '))


class ReportTests(unittest.TestCase):
    def test_unexecuted_cases_are_failures_not_green_skips(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = SIM.Report(Path(tmp))
            report.write()
            data = json.loads((Path(tmp) / 'simulation.json').read_text())
            self.assertEqual(data['status'], 'failed')
            self.assertFalse(report.complete())
            self.assertTrue(all(c['status'] == 'not_run' for c in data['cases']))
            xml = ET.parse(Path(tmp) / 'simulation-junit.xml').getroot()
            self.assertEqual(int(xml.get('failures')), len(SIM.PHASES))
            self.assertFalse(xml.findall('.//skipped'))

    def test_fault_is_recorded_and_propagated(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = SIM.Report(Path(tmp))
            with self.assertRaisesRegex(RuntimeError, 'injected'):
                with report.phase('cold-boot'):
                    raise RuntimeError('injected startup failure')
            data = json.loads((Path(tmp) / 'simulation.json').read_text())
            self.assertEqual(data['status'], 'failed')
            failed = next(c for c in data['cases'] if c['name'] == 'cold-boot')
            self.assertEqual(failed['status'], 'failed')
            self.assertIn('injected startup failure', failed['reason'])

    def test_only_all_executed_passes_make_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = SIM.Report(Path(tmp))
            for name in SIM.PHASES:
                with report.phase(name):
                    pass
            data = json.loads((Path(tmp) / 'simulation.json').read_text())
            self.assertEqual(data['status'], 'passed')
            self.assertTrue(report.complete())
            self.assertIn('ARM64 execution', data['not_tested'])
            with self.assertRaises(RuntimeError):
                with report.phase(SIM.PHASES[0]):
                    pass


def check_core(binary: str):
    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / 'config.json'
        config.write_text(json.dumps(SIM.fixture_config()))
        subprocess.run([str(Path(binary).resolve()), 'check', '-c', str(config)],
                       check=True, timeout=30, cwd=tmp)
        config.write_text('{')
        rejected = subprocess.run([str(Path(binary).resolve()), 'check', '-c', str(config)],
                                  capture_output=True, timeout=30, cwd=tmp)
        SIM.require(rejected.returncode == 1, 'core validator did not reject malformed JSON normally')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--check-core':
        check_core(sys.argv[2])
    else:
        unittest.main()

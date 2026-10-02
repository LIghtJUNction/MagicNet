#!/usr/bin/env python3
"""Sentinel isolation/rollback regressions; --check-core validates the exact build."""
from __future__ import annotations

import base64
import copy
import importlib.util
import json
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('proof', ROOT / 'scripts/android-tun-proof.py')
assert spec and spec.loader
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)

BASE = {'inbounds': [{'type': 'tun', 'tag': 'tun-in', 'interface_name': 'magicnet0',
                     'address': ['172.19.0.1/30'], 'auto_route': True, 'exclude_uid': [0]}],
        'outbounds': [{'type': 'direct', 'tag': 'direct'}], 'route': {'rules': []}}


class TunProofTests(unittest.TestCase):
    def test_fixture_does_not_mutate_base_or_drop_root_exclusion(self):
        before = copy.deepcopy(BASE)
        candidate = proof.fixture_config(BASE, 10123, 23456, blocked=False)
        self.assertEqual(BASE, before)
        self.assertEqual(candidate['inbounds'][0]['exclude_uid'], [0])
        rule = candidate['route']['rules'][0]
        self.assertEqual(rule['inbound'], ['tun-in'])
        self.assertEqual(rule['user_id'], [10123])
        self.assertEqual(rule['ip_cidr'], ['198.18.0.42/32'])
        self.assertEqual(rule['override_address'], '127.0.0.1')
        self.assertEqual(rule['override_port'], 23456)

    def test_reject_control_cannot_keep_positive_route_override(self):
        rule = proof.fixture_config(BASE, 10123, 23456, blocked=True)['route']['rules'][0]
        self.assertEqual(rule['action'], 'reject')
        self.assertNotIn('outbound', rule)
        self.assertNotIn('override_address', rule)
        self.assertTrue(rule['no_drop'])

    def test_root_and_excluded_uids_are_not_forced_into_tun(self):
        for uid, changes in ((0, {}), (True, {}), (10123, {'exclude_uid': [0, 10123]}),
                             (10123, {'include_uid': [10124]}), (10123, {'exclude_uid': []})):
            with self.subTest(uid=uid, changes=changes):
                value = copy.deepcopy(BASE)
                value['inbounds'][0].update(changes)
                with self.assertRaises(ValueError):
                    proof.fixture_config(value, uid, 23456, blocked=False)

    def test_physical_device_is_rejected_before_any_mutation(self):
        calls = []
        def adb(command, **_):
            calls.append(command)
            return subprocess.CompletedProcess(['adb'], 0, '0' if 'qemu' in command else 'arm64-v8a')
        with patch.object(proof.subprocess, 'run', side_effect=AssertionError('no host mutation allowed')):
            result = proof.verify(adb, lambda *_: self.fail('must not launch app'), 'component')
        self.assertEqual(result['status'], 'not_verified')
        self.assertEqual(calls, ['getprop ro.kernel.qemu', 'getprop ro.product.cpu.abi'])

    def test_unconfirmed_app_identity_is_rejected_without_config_write(self):
        def adb(command, **_):
            if command == 'getprop ro.kernel.qemu':
                return subprocess.CompletedProcess(['adb'], 0, '1')
            if command == 'getprop ro.product.cpu.abi':
                return subprocess.CompletedProcess(['adb'], 0, 'x86_64')
            self.assertTrue(command.startswith('cmd package list packages'))
            return subprocess.CompletedProcess(['adb'], 0, 'package:best.lmm.magicnet.probe uid:10124')
        result = proof.verify(adb, lambda *_: {'ok': True, 'uid': 10123}, 'component')
        self.assertEqual(result['reason'], 'app_uid_not_confirmed')

    def test_known_cli_failure_categories_discard_raw_diagnostics(self):
        noise = 'subscription=https://private.invalid/?token=private-value node=private-node'
        cases = (
            ('managed supervisor did not stop after SIGTERM', 'supervisor_stop_timeout'),
            ('managed supervisor did not stop after SIGKILL', 'supervisor_stop_timeout'),
            ('managed supervisor force-stop is unavailable', 'supervisor_force_unavailable'),
            ('managed supervisor process generation changed during inspection', 'supervisor_generation_changed'),
            ('managed supervisor process generation changed during stop', 'supervisor_generation_changed'),
            ('managed supervisor ownership changed during stop', 'supervisor_ownership_changed'),
            ('supervisor PID file changed during stop', 'supervisor_pid_changed'),
            ('supervisor PID file changed during read', 'supervisor_pid_changed'),
            ('prepare network for core stop: child failed', 'network_stop_failed'),
            ('finalize stopped network: child failed', 'network_finalize_failed'),
            ('config apply is still busy after 2000 ms; retry the lifecycle action', 'config_apply_busy'),
            ('config validation failed', 'config_validation'),
            ('No sing-box nodes were found. Configure a subscription URL', 'nodes_unavailable'),
            ('No subscription source is configured, so the kernel cannot start.', 'source_unavailable'),
            ('ADB deadline exceeded', 'adb_deadline'),
            ('unrecognized child failure', 'command_failed'),
        )
        for message, kind in cases:
            with self.subTest(message=message):
                diagnostic = proof.sanitized_failure(
                    noise + '\n[error] ' + message + '\n' + noise, operation='core_restart')
                self.assertEqual(diagnostic, {'kind': kind})

    def test_startup_failure_uses_only_known_stage_and_bounded_exit_code(self):
        self.assertEqual(proof.sanitized_failure(
            '[warn] Startup step failed: stage=route-capture exit=2\nprivate-error',
            operation='core_restart'),
            {'kind': 'startup_step_failed', 'stage': 'route-capture', 'stage_exit_code': 2})
        self.assertEqual(proof.sanitized_failure(
            '[warn] Startup step failed: stage=core-launch exit=139\n'
            '[error] finalize stopped network: private-error', operation='core_restart'),
            {'kind': 'network_finalize_failed', 'stage': 'core-launch', 'stage_exit_code': 139})
        for stage, exit_code in (('private-node', '1'), ('dns', '-1'), ('dns', '0'),
                                 ('dns', '256'), ('dns', '9999'), ('dns', '1private')):
            with self.subTest(stage=stage, exit_code=exit_code):
                self.assertEqual(proof.sanitized_failure(
                    f'Startup step failed: stage={stage} exit={exit_code}', operation='core_restart'),
                    {'kind': 'command_failed'})

    def test_validator_config_text_cannot_forge_service_failure_or_startup_stage(self):
        output = ('config validation failed\n{"tag":"managed supervisor did not stop after SIGTERM"}\n'
                  'Startup step failed: stage=core-launch exit=2 private-secret')
        for operation in ('config_save', 'core_restart'):
            with self.subTest(operation=operation):
                self.assertEqual(proof.sanitized_failure(output, operation=operation),
                                 {'kind': 'config_validation'})
        self.assertEqual(proof.sanitized_failure(
            'managed supervisor did not stop after SIGTERM\n'
            'Startup step failed: stage=core-launch exit=2', operation='config_save'),
            {'kind': 'command_failed'})
        for message in ('managed supervisor force-stop is unavailable',
                        'managed supervisor process generation changed during stop',
                        'managed supervisor ownership changed during stop',
                        'supervisor PID file changed during read'):
            self.assertEqual(proof.sanitized_failure(message, operation='config_save'),
                             {'kind': 'command_failed'})

    def transaction(self, *, reject_timeout=False, failed_save=False, failed_restore=False,
                    failed_reverse_cleanup=False, failed_restart=False,
                    save_error='', restart_error='', restore_error=''):
        # This executes restoration/accounting with an in-memory device and a
        # real local marker server. It is NOT evidence of Android TUN capture.
        active = copy.deepcopy(BASE)
        payloads = {}
        saves = []
        removed_marker = []
        sentinel_operations = []

        def adb(command, **_):
            nonlocal active
            rc, output, error = 0, '', ''
            args = shlex.split(command)
            if command == 'getprop ro.kernel.qemu':
                output = '1'
            elif command == 'getprop ro.product.cpu.abi':
                output = 'x86_64'
            elif command.startswith('cmd package list packages'):
                output = 'package:best.lmm.magicnet.probe uid:10123'
            elif command == proof.CLI + ' config-editor get sing-box':
                output = json.dumps(active)
            elif command.startswith('if [ -f '):
                output = 'absent'
            elif args[1:5] == ['webui', 'payload', 'create', 'tmp']:
                payloads[args[5]] = ''
                output = proof.MODDIR + '/.tmp/webui-payload/' + args[5]
            elif args[1:5] == ['webui', 'payload', 'append', 'tmp']:
                payloads[args[5]] += args[6]
            elif args[1:5] == ['webui', 'payload', 'remove', 'tmp']:
                del payloads[args[5]]
            elif args[1:4] == ['config-editor', 'save-file', 'sing-box']:
                active = json.loads(base64.b64decode(payloads[Path(args[4]).name]))
                saves.append(copy.deepcopy(active))
                if failed_save and len(saves) == 1:
                    rc = 1  # Activation may change the file before reporting failure.
                    error = save_error
            elif args[1:] == ['service', 'restart', 'sing-box']:
                if failed_restore and active == BASE:
                    rc = 1
                    error = restore_error
                elif failed_restart and active != BASE:
                    rc = 1
                    error = restart_error
            elif command == 'rm -f ' + proof.MARKER:
                removed_marker.append(True)
            else:
                self.fail('unexpected device operation: ' + command)
            return subprocess.CompletedProcess(['adb'], rc, output, error)

        def instrument(_component, operation, _timeout, **values):
            if operation == 'identity':
                return {'ok': True, 'uid': 10123}
            sentinel_operations.append(operation)
            blocked = active['route']['rules'][0]['action'] == 'reject'
            if not blocked:
                with socket.create_connection(('127.0.0.1', values['port']), timeout=2) as client:
                    self.assertEqual(client.recv(64).decode(), values['marker'] + '\n')
            return {'ok': not blocked, 'uid': 10123, 'complete': True,
                    'reason': ('timeout' if reject_timeout else 'connect') if blocked else 'sentinel'}

        def host(args, **_):
            self.assertEqual(args[:2], ['adb', 'reverse'])
            if failed_reverse_cleanup and '--remove' in args:
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0, '')

        with patch.object(proof.subprocess, 'run', side_effect=host):
            report = proof.verify(adb, instrument, 'component')
        self.assertEqual(active, BASE)
        self.assertFalse(payloads, 'private staging payloads must be removed')
        if failed_save or failed_restart:
            self.assertFalse(sentinel_operations, 'failed activation must not reach a sentinel probe')
            self.assertEqual(len(saves), 2, 'one activation and one restoration, without write retries')
        if not failed_restore:
            self.assertTrue(removed_marker)
        return report, saves

    def test_full_transaction_requires_both_positive_controls_and_restoration(self):
        report, saves = self.transaction()
        self.assertEqual(report['status'], 'verified', report)
        self.assertEqual(len(saves), 4)
        self.assertEqual(saves[-1], BASE)

    def test_timeout_is_not_a_verified_reject_and_original_is_restored(self):
        report, _ = self.transaction(reject_timeout=True)
        self.assertEqual(report['status'], 'not_verified')
        self.assertTrue(report['restored'])
        self.assertFalse(report['reject'])

    def test_failed_activation_still_restores_original_config(self):
        report, saves = self.transaction(failed_save=True)
        self.assertEqual(report['status'], 'not_verified')
        self.assertTrue(report['restored'])
        self.assertEqual(len(saves), 2)
        self.assertEqual(report['failure_control'], 'positive')
        self.assertEqual(report['failure_operation'], 'config_save')
        self.assertEqual(report['failure_exit_code'], 1)

    def test_failed_restore_cannot_report_verified(self):
        report, _ = self.transaction(failed_restore=True)
        self.assertEqual(report['status'], 'not_verified')
        self.assertFalse(report['restored'])
        self.assertEqual(report['reason'], 'config_restore_failed_discard_avd')
        self.assertEqual(report['failure_control'], 'restore')
        self.assertEqual(report['failure_operation'], 'core_restart')
        self.assertEqual(report['failure_exit_code'], 1)

    def test_first_operation_failure_survives_failed_restoration(self):
        report, _ = self.transaction(failed_save=True, failed_restore=True,
                                    save_error='config validation failed\nprivate-config',
                                    restore_error='Startup step failed: stage=route-capture exit=2\nprivate-config')
        self.assertEqual(report['failure_control'], 'positive')
        self.assertEqual(report['failure_operation'], 'config_save')
        self.assertEqual(report['failure_exit_code'], 1)
        self.assertEqual(report['failure_kind'], 'config_validation')
        self.assertNotIn('failure_stage', report)
        self.assertNotIn('failure_stage_exit_code', report)
        self.assertEqual(report['restore_failure_operation'], 'core_restart')
        self.assertEqual(report['restore_failure_exit_code'], 1)
        self.assertEqual(report['restore_failure_kind'], 'startup_step_failed')
        self.assertEqual(report['restore_failure_stage'], 'route-capture')
        self.assertEqual(report['restore_failure_stage_exit_code'], 2)
        self.assertFalse(report['restored'])
        self.assertEqual(report['reason'], 'config_restore_failed_discard_avd')
        self.assertNotIn('private-config', json.dumps(report))
        self.assertNotIn('argv', report)
        self.assertNotIn('stdout', report)
        self.assertNotIn('stderr', report)

    def test_failed_restart_records_category_and_keeps_restore_independent(self):
        report, _ = self.transaction(
            failed_restart=True, failed_restore=True,
            restart_error='managed supervisor did not stop after SIGTERM\nprivate-token',
            restore_error='supervisor PID file changed during stop\nprivate-token')
        self.assertEqual(report['status'], 'not_verified')
        self.assertEqual(report['failure_control'], 'positive')
        self.assertEqual(report['failure_operation'], 'core_restart')
        self.assertEqual(report['failure_kind'], 'supervisor_stop_timeout')
        self.assertEqual(report['restore_failure_kind'], 'supervisor_pid_changed')
        self.assertEqual(report['restore_failure_operation'], 'core_restart')
        self.assertEqual(report['restore_failure_exit_code'], 1)
        self.assertFalse(report['restored'])
        self.assertEqual(report['reason'], 'config_restore_failed_discard_avd')
        self.assertNotIn('private-token', json.dumps(report))

    def test_failed_restart_stays_failed_after_successful_restoration(self):
        report, _ = self.transaction(
            failed_restart=True, restart_error='prepare network for core stop: private-token')
        self.assertEqual(report['status'], 'not_verified')
        self.assertEqual(report['failure_kind'], 'network_stop_failed')
        self.assertTrue(report['restored'])
        self.assertFalse(any(key.startswith('restore_failure_') for key in report))
        self.assertNotIn('private-token', json.dumps(report))

    def test_failed_reverse_cleanup_cannot_report_verified(self):
        report, _ = self.transaction(failed_reverse_cleanup=True)
        self.assertEqual(report['status'], 'not_verified')
        self.assertFalse(report['restored'])
        self.assertEqual(report['reason'], 'reverse_cleanup_failed_discard_avd')


def check_core(binary):
    with tempfile.TemporaryDirectory(prefix='magicnet-sentinel-core-') as td:
        path = Path(td) / 'config.json'
        for blocked in (False, True):
            path.write_text(json.dumps(proof.fixture_config(BASE, 10123, 23456, blocked=blocked)))
            subprocess.run([binary, 'check', '-c', str(path)], check=True, timeout=15)
    print('Exact compiled core accepts positive and reject sentinel fixtures')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--check-core':
        check_core(sys.argv[2])
    else:
        unittest.main()

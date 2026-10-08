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
SERVICE = {'schema': 1, 'ok': True, 'command': 'service.status', 'data': {
    'lifecycle': 'not_ready',
    'core': {'selected': 'sing-box', 'sing_box': {'running': False, 'process_state': 'stopped',
                                              'pid_summary': 'private-pid', 'rss_kib': 12345}},
    'api': {'ready': False, 'url': 'https://private.invalid/?token=private-value'},
    'readiness': {'dataplane': False, 'overall': False},
    'transparent': {'configured_mode': 'tun', 'effective_type': 'tun', 'effective_mode': 'tun',
                    'capability': 'not_required', 'local_cgroup': 'inactive', 'shared_tc': 'inactive',
                    'shared_interface_count': 0, 'dataplane_ready': False, 'transition': 'idle',
                    'has_recent_error': True, 'reason': 'private-reason'},
    'supervisors': {'fswatch': 'private-pid', 'wifi_policy': 'private-pid'},
    'subscription': {'source': 'remote_url', 'url': 'private-subscription'},
    'webui': 'private-webui', 'unknown_field': 'private-extension',
}}
RESTART_FAILURES = (
    ('Timed out waiting for config lock: private-path', 'config_lock_timeout'),
    ('create config apply lock directory: private-path', 'config_apply_lock_error'),
    ('open config apply lock: private-path', 'config_apply_lock_error'),
    ('lock config apply: private-error', 'config_apply_lock_error'),
    ('managed sing-box process set changed during stop', 'core_generation_changed'),
    ('managed sing-box did not stop after SIGKILL: private-pid', 'core_stop_timeout'),
    ('cannot signal managed process private-pid: private-error', 'core_signal_failed'),
    ('cannot bind sing-box ownership to private-path', 'core_identity_unknown'),
    ('read sing-box candidate private-pid cmdline: private-error', 'core_identity_unknown'),
    ('cannot verify executable identity for live sing-box candidate private-pid', 'core_identity_unknown'),
    ('trusted Android pidof is unavailable', 'core_identity_unknown'),
    ('pid lookup deadline exceeded for sing-box', 'core_identity_unknown'),
    ('pid lookup timed out for sing-box', 'core_identity_unknown'),
    ('pid lookup output was truncated for sing-box', 'core_identity_unknown'),
    ('pid lookup failed for sing-box with status 1', 'core_identity_unknown'),
    ('pid lookup was terminated for sing-box', 'core_identity_unknown'),
    ('pid lookup returned non-UTF-8 output for sing-box', 'core_identity_unknown'),
    ('pid lookup returned malformed output for sing-box', 'core_identity_unknown'),
    ('pid lookup returned an empty success for sing-box', 'core_identity_unknown'),
    ('unable to read supervisor PID file', 'supervisor_identity_unknown'),
    ('unable to inspect supervisor PID file', 'supervisor_identity_unknown'),
    ('invalid supervisor PID file', 'supervisor_identity_unknown'),
    ('unable to inspect live supervisor ownership', 'supervisor_identity_unknown'),
    ('unable to remove stopped supervisor PID file', 'supervisor_identity_unknown'),
    ('managed supervisor survived stop verification', 'supervisor_stop_failed'),
    ('cannot signal managed supervisor: private-error', 'supervisor_signal_failed'),
)


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
        cases = RESTART_FAILURES + (
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
        for message, _ in RESTART_FAILURES:
            with self.subTest(message=message):
                self.assertEqual(proof.sanitized_failure(message, operation='config_save'),
                                 {'kind': 'command_failed'})
                for operation in ('config_save', 'core_restart'):
                    malicious = ('config validation failed\n' + message + '\n'
                                 'Startup step failed: stage=core-launch exit=2 private-secret')
                    self.assertEqual(proof.sanitized_failure(malicious, operation=operation),
                                     {'kind': 'config_validation'})

    def observe(self, envelope=SERVICE, *, returncode=0, stdout=None):
        calls = []
        def adb(command, **kwargs):
            calls.append((command, kwargs))
            return subprocess.CompletedProcess(['adb'], returncode,
                                               json.dumps(envelope) if stdout is None else stdout,
                                               'private-observation-stderr')
        observation = proof.service_observation(adb)
        self.assertEqual(calls, [(proof.CLI + ' --json service status',
                                 {'timeout': proof.SERVICE_OBSERVATION_TIMEOUT})])
        self.assertNotIn('private-', json.dumps(observation))
        self.assertEqual(observation['capture_phase'], 'before_failure_cleanup')
        return observation

    def test_service_observation_projects_only_safe_machine_fields(self):
        observed = self.observe()
        self.assertEqual(observed['status'], 'observed')
        self.assertEqual(observed['service']['lifecycle'], 'not_ready')
        self.assertEqual(observed['service']['core'], {
            'selected': 'sing-box', 'running': False, 'process_state': 'stopped'})
        self.assertEqual(observed['service']['api_ready'], False)
        self.assertEqual(observed['service']['readiness'], {'dataplane': False, 'overall': False})
        self.assertEqual(observed['service']['transparent']['shared_interface_count'], 0)
        for key in ('pid_summary', 'rss_kib', 'supervisors', 'subscription', 'webui', 'url', 'reason'):
            self.assertNotIn('"' + key + '"', json.dumps(observed))

    def test_service_observation_rejects_invalid_envelopes_and_failed_green_output(self):
        invalid = []
        for key, values in (('schema', (True, 1.0, '1', 2)), ('ok', (False, 1, 'true')),
                            ('command', ('private-command', 'service.restart', None)),
                            ('data', (None, [], 'private-data'))):
            for value in values:
                envelope = copy.deepcopy(SERVICE)
                envelope[key] = value
                invalid.append(envelope)
        for envelope in invalid + [[], None]:
            with self.subTest(envelope=envelope):
                observed = self.observe(envelope)
                self.assertEqual(observed['status'], 'unknown')
                self.assertNotIn('service', observed)
        for rc in (1, 124, True, 1.0, 1000000):
            observed = self.observe(returncode=rc)
            self.assertEqual(observed['status'], 'unknown')
            self.assertNotIn('service', observed)
        for output in ('private-malformed', json.dumps(SERVICE) + '\nprivate-trailing',
                       'private-budget' * proof.MAX_SERVICE_STATUS_BYTES):
            observed = self.observe(stdout=output)
            self.assertEqual(observed['status'], 'unknown')
            self.assertNotIn('service', observed)

    def test_service_unknown_fields_do_not_turn_into_successful_values(self):
        for value in ('private-value', [], {}, True, 1, 1.0, -1, 1000000, None):
            with self.subTest(value=value):
                envelope = copy.deepcopy(SERVICE)
                data = envelope['data']
                data['lifecycle'] = value
                data['core']['selected'] = value
                data['core']['sing_box']['process_state'] = value
                for key in ('configured_mode', 'effective_type', 'effective_mode', 'capability',
                            'local_cgroup', 'shared_tc', 'transition'):
                    data['transparent'][key] = value
                projected = self.observe(envelope)['service']
                self.assertEqual(projected['lifecycle'], 'unknown')
                self.assertEqual(projected['core']['selected'], 'unknown')
                self.assertEqual(projected['core']['process_state'], 'unknown')
                for key in ('configured_mode', 'effective_type', 'effective_mode', 'capability',
                            'local_cgroup', 'shared_tc', 'transition'):
                    self.assertEqual(projected['transparent'][key], 'unknown')
        for value in ('true', 1, 0, [], {}, None):
            envelope = copy.deepcopy(SERVICE)
            envelope['data']['core']['sing_box']['running'] = value
            envelope['data']['api']['ready'] = value
            envelope['data']['readiness'] = {'dataplane': value, 'overall': value}
            envelope['data']['transparent']['dataplane_ready'] = value
            envelope['data']['transparent']['has_recent_error'] = value
            projected = self.observe(envelope)['service']
            self.assertIsNone(projected['core']['running'])
            self.assertIsNone(projected['api_ready'])
            self.assertEqual(projected['readiness'], {'dataplane': None, 'overall': None})
            self.assertIsNone(projected['transparent']['dataplane_ready'])
            self.assertIsNone(projected['transparent']['has_recent_error'])
        for value in (True, 1.0, '1', -1, 4097, 10**100, [], None):
            envelope = copy.deepcopy(SERVICE)
            envelope['data']['transparent']['shared_interface_count'] = value
            projected = self.observe(envelope)['service']
            self.assertIsNone(projected['transparent']['shared_interface_count'])

    def test_failure_output_counts_are_bounded_utf8_counts(self):
        counts = proof.output_counts('🌍', '')
        self.assertEqual(counts, {'stdout_present': True, 'stdout_bytes': 4, 'stdout_bytes_capped': False,
                                  'stderr_present': False, 'stderr_bytes': 0, 'stderr_bytes_capped': False})
        counts = proof.output_counts('', '🌍' * proof.MAX_OUTPUT_BYTES)
        self.assertEqual(counts['stderr_bytes'], proof.MAX_OUTPUT_BYTES)
        self.assertTrue(counts['stderr_bytes_capped'])
        self.assertNotIn('🌍', json.dumps(counts))

    def transaction(self, *, reject_timeout=False, failed_save=False, failed_restore=False,
                    failed_reverse_cleanup=False, failed_restart=False,
                    save_error='', restart_error='', restore_error='', restart_output='',
                    observation_result=None, observation_error=None, events=None):
        # This executes restoration/accounting with an in-memory device and a
        # real local marker server. It is NOT evidence of Android TUN capture.
        active = copy.deepcopy(BASE)
        payloads = {}
        saves = []
        removed_marker = []
        sentinel_operations = []

        if events is None:
            events = []

        def adb(command, **kwargs):
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
                events.append(('payload_remove', active == BASE))
                del payloads[args[5]]
            elif args[1:4] == ['config-editor', 'save-file', 'sing-box']:
                active = json.loads(base64.b64decode(payloads[Path(args[4]).name]))
                saves.append(copy.deepcopy(active))
                events.append(('config_save', active == BASE))
                if failed_save and len(saves) == 1:
                    rc = 1  # Activation may change the file before reporting failure.
                    error = save_error
            elif args[1:] == ['service', 'restart', 'sing-box']:
                events.append(('core_restart', active == BASE))
                if failed_restore and active == BASE:
                    rc = 1
                    error = restore_error
                elif failed_restart and active != BASE:
                    rc = 1
                    error = restart_error
                    output = restart_output
            elif args[1:] == ['--json', 'service', 'status']:
                events.append(('service_observation', active == BASE, bool(payloads)))
                self.assertEqual(kwargs, {'timeout': proof.SERVICE_OBSERVATION_TIMEOUT})
                if observation_error is not None:
                    raise observation_error
                if observation_result is not None:
                    return observation_result
                output = json.dumps(SERVICE)
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
        events = []
        report, saves = self.transaction(events=events)
        self.assertEqual(report['status'], 'verified', report)
        self.assertEqual(len(saves), 4)
        self.assertEqual(saves[-1], BASE)
        self.assertFalse(any(event[0] == 'service_observation' for event in events))

    def test_first_failure_observation_precedes_cleanup_and_is_not_replaced_by_restore(self):
        events = []
        report, _ = self.transaction(failed_restart=True, failed_restore=True,
                                    restart_error='managed sing-box process set changed during stop\nprivate-first',
                                    restore_error='private-restore', restart_output='🌍', events=events)
        self.assertEqual(report['failure_kind'], 'core_generation_changed')
        self.assertEqual(report['restore_failure_kind'], 'command_failed')
        self.assertFalse(report['restored'])
        self.assertEqual(report['failure_stdout_bytes'], 4)
        self.assertTrue(report['failure_stdout_present'])
        self.assertTrue(report['failure_stderr_present'])
        self.assertEqual(report['failure_service_observation']['status'], 'observed')
        observations = [event for event in events if event[0] == 'service_observation']
        self.assertEqual(observations, [('service_observation', False, True)])
        observed_at = events.index(observations[0])
        self.assertEqual(events[observed_at - 1], ('core_restart', False))
        self.assertEqual(events[observed_at + 1], ('payload_remove', False))
        self.assertGreater(events.index(('config_save', True)), observed_at)
        self.assertNotIn('private-', json.dumps(report))

    def test_unknown_observation_never_changes_failure_or_obstructs_restore(self):
        cases = (
            {'observation_error': subprocess.TimeoutExpired(['private-command'], 5,
                                                           output='private-timeout', stderr='private-stderr')},
            {'observation_error': RuntimeError('private-observation-error')},
            {'observation_result': subprocess.CompletedProcess(['adb'], 124, 'private-timeout', '')},
            {'observation_result': subprocess.CompletedProcess(['adb'], 0, 'private-malformed', '')},
        )
        for options in cases:
            with self.subTest(options=options):
                events = []
                report, _ = self.transaction(failed_restart=True, restart_error='private-original',
                                            events=events, **options)
                self.assertEqual(report['failure_control'], 'positive')
                self.assertEqual(report['failure_operation'], 'core_restart')
                self.assertEqual(report['failure_kind'], 'command_failed')
                self.assertEqual(report['failure_exit_code'], 1)
                self.assertEqual(report['failure_service_observation']['status'], 'unknown')
                self.assertTrue(report['restored'])
                self.assertEqual(sum(event[0] == 'service_observation' for event in events), 1)
                self.assertNotIn('private-', json.dumps(report))

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

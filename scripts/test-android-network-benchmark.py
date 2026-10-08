#!/usr/bin/env python3
"""Regression tests for fail-closed Android probe accounting (no device needed)."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('benchmark', ROOT / 'scripts/android-network-benchmark.py')
bench = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(bench)


class AndroidBenchmarkTests(unittest.TestCase):
    def wire(self, **updates):
        value = dict(schema=1, operation='https', uid=10123, ok=True, complete=True,
                     http=200, redirects=0, received_bytes=5, elapsed_ms=10, reason='https_response')
        value.update(updates)
        return subprocess.CompletedProcess(['adb'], 0,
            'INSTRUMENTATION_RESULT: magicnet_result=' + json.dumps(value) + '\nINSTRUMENTATION_CODE: -1\n')

    def test_valid_application_result_is_accepted(self):
        result = bench.decode_result(self.wire(), 'https')
        self.assertTrue(result['ok'])
        self.assertEqual(result['uid'], 10123)

    def test_root_malformed_or_ambiguous_result_never_passes(self):
        for updates in ({'uid': 0}, {'uid': True}, {'schema': True}, {'schema': 2},
                        {'ok': 'true'}, {'complete': False}, {'elapsed_ms': -1},
                        {'operation': 'identity'}, {'received_bytes': 10000000}, {'reason': 'invented'}):
            with self.subTest(updates=updates):
                self.assertFalse(bench.decode_result(self.wire(**updates), 'https')['ok'])
        good = self.wire()
        for text in (good.stdout + good.stdout, good.stdout.replace('CODE: -1', 'CODE: 0'),
                     good.stdout.replace('"schema": 1', '"schema": 1, "schema": 1')):
            self.assertFalse(bench.decode_result(subprocess.CompletedProcess(['adb'], 0, text), 'https')['ok'])

    def test_host_independently_checks_expected_status_and_204_shape(self):
        for updates in ({'http': 200}, {'http': 204, 'redirects': 1, 'received_bytes': 0},
                        {'http': 204, 'received_bytes': 1}):
            with self.subTest(updates=updates), patch.object(bench, 'adb_shell', return_value=self.wire(**updates)):
                self.assertFalse(bench.fetch_probe(bench.COMPONENT, 'https://example.invalid/', 1, '204')['ok'])
        with patch.object(bench, 'adb_shell', return_value=self.wire(http=204, received_bytes=0)):
            self.assertTrue(bench.fetch_probe(bench.COMPONENT, 'https://example.invalid/', 1, '204')['ok'])

    def test_adb_timeout_reports_incomplete_and_stops_only_probe_app(self):
        with patch.object(bench, 'adb_shell', return_value=subprocess.CompletedProcess(['adb'], 124, '')) as adb:
            result = bench.fetch_probe(bench.COMPONENT, 'https://example.invalid/private-token', 1)
        self.assertFalse(result['ok'])
        self.assertFalse(result['complete'])
        self.assertEqual(result['reason'], 'adb_timeout')
        self.assertEqual(adb.call_args_list[-1].args[0], 'am force-stop ' + bench.PACKAGE)
        self.assertNotIn('private-token', json.dumps(result))

    def test_failed_adb_transport_cannot_pass(self):
        cp = subprocess.CompletedProcess(['adb'], 1, '0|10|11\n')
        with patch.object(bench, 'adb_shell', return_value=cp):
            self.assertFalse(bench.fetch_probe(bench.COMPONENT, 'https://example.invalid/', 1)['ok'])

    def test_failed_download_cannot_pass_on_byte_count(self):
        cp = subprocess.CompletedProcess(['adb'], 0, '124|10|11|8388608\n')
        with patch.object(bench, 'adb_shell', return_value=cp):
            self.assertFalse(bench.speed_probe(bench.COMPONENT, 'speed', 'https://example.invalid/',
                                               8388608, 1)['ok'])

    def test_empty_duplicate_and_unsafe_targets_are_rejected(self):
        row = 'one|google|https://example.invalid/|204'
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'targets.tsv'
            for text in ('', '# no targets\n', row + '\n' + row,
                         'one|google|http://example.invalid/|200',
                         'one|google|https://user:secret@example.invalid/|200',
                         'one|google|https://example.invalid/|403'):
                with self.subTest(text=text):
                    path.write_text(text)
                    with self.assertRaises(ValueError):
                        bench.parse_targets(path)

    def run_main(self, failed_id: str | None, *, speed: bool = False):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            targets = root / 'targets.tsv'
            targets.write_text('\n'.join([
                'domestic|domestic|https://example.invalid/domestic|200',
                'global|global|https://example.invalid/global|200',
                'google_play|google|https://example.invalid/google_play|204',
            ]))
            def probe(_component, url, _timeout, *args, **kwargs):
                ok = not url.endswith('/' + str(failed_id))
                return dict(ok=ok, complete=True, rc=0 if ok else 7, elapsed_ms=10,
                            uid=10123, http=204 if url.endswith('google_play') else 200,
                            reason='https_response' if ok else 'connect', received_bytes=0)
            bad_speed = dict(name='speed', uid=10123, ok=False, complete=True, rc=28, elapsed_ms=10,
                             requested_bytes=8388608, received_bytes=0, mbps=None, reason='timeout')
            args = ['benchmark', '--targets', str(targets), '--output', str(root / 'out'), '--rounds', '1']
            if speed:
                args.append('--speed')
            with patch.object(sys, 'argv', args), patch.object(bench, 'fetch_probe', side_effect=probe), \
                 patch.object(bench, 'instrument', return_value=dict(ok=True, uid=10123)), \
                 patch.object(bench, 'speed_probe', return_value=bad_speed), \
                 patch.object(bench, 'collect_processes', return_value={'processes': {}}), \
                 patch.object(bench, 'adb_shell', return_value=subprocess.CompletedProcess(['adb'], 0, '')), \
                 patch.object(bench.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
                return bench.main(), json.loads((root / 'out/results.json').read_text())

    def test_one_failed_service_is_not_hidden_by_other_targets(self):
        code, report = self.run_main('google_play')
        self.assertEqual(code, 1, report)
        self.assertEqual(report['success_count'], 2)

    def test_all_successful_probes_pass_the_declared_https_scope(self):
        code, report = self.run_main(None)
        self.assertEqual(code, 0, report)
        self.assertEqual(report['tun_proof']['status'], 'not_verified')
        self.assertIn('play_downloads', report['not_tested'])

    def test_requested_speed_failure_is_not_ignored(self):
        code, report = self.run_main(None, speed=True)
        self.assertNotEqual(code, 0, report)


class PreparedRuntimeBenchmarkTests(unittest.TestCase):
    VERIFIED = dict(status='verified', positive=True, reject=True, positive_after=True, restored=True)
    DEFAULT_PROOF = object()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.targets = self.root / 'targets.tsv'
        self.targets.write_text('one|global|https://example.invalid/private-path?token=private-value|200\n')
        self.output = self.root / 'out'
        self.runtime_dir = self.root / 'runtime'
        self.expected = {'payload_sha256': {'bin/sing-box': 'a' * 64}}
        self.observation = dict(ready=True, identity_verified=True, generation_sha256='b' * 64)
        self.device = Mock()
        self.device.kshell.return_value = subprocess.CompletedProcess(['adb'], 0, '', '')
        self.runtime = SimpleNamespace(
            verify_prepared=Mock(return_value=(self.device, self.expected, self.observation)),
            observe_runtime=Mock(return_value=self.observation))
        self.probe = dict(ok=True, complete=True, rc=0, elapsed_ms=10, uid=10123,
                          http=200, redirects=0, reason='https_response', received_bytes=5)
        self.speed = self.probe | dict(name='test-speed', requested_bytes=bench.SPEED_LIMIT, mbps=1)

    def run_main(self, *, proof=DEFAULT_PROOF, argv=None, identity=None, proof_effect=None):
        args = ['benchmark', '--targets', str(self.targets), '--output', str(self.output),
                '--rounds', '1', '--speed']
        args += argv if argv is not None else [
            '--verify-tun', '--root-mode', 'ksud', '--prepared-runtime-dir', str(self.runtime_dir)]
        with patch.object(sys, 'argv', args), \
             patch.object(bench, 'load_prepared_runtime', return_value=self.runtime) as loader, \
             patch.object(bench, 'instrument', return_value=identity or dict(ok=True, uid=10123)) as instrument, \
             patch.object(bench, 'verify_tun_path', return_value=self.VERIFIED if proof is self.DEFAULT_PROOF else proof,
                          side_effect=proof_effect) as verify, \
             patch.object(bench, 'fetch_probe', return_value=self.probe) as fetch, \
             patch.object(bench, 'speed_probe', return_value=self.speed) as speed, \
             patch.object(bench, 'collect_processes', return_value={'processes': {}}), \
             contextlib.redirect_stdout(io.StringIO()):
            code = bench.main()
        return SimpleNamespace(code=code, report=json.loads((self.output / 'results.json').read_text()),
                               markdown=(self.output / 'summary.md').read_text(), loader=loader,
                               instrument=instrument, verify=verify, fetch=fetch, speed=speed)

    def assert_blocked(self, result, phase):
        self.assertEqual(result.code, 2)
        self.assertEqual(result.report['verdict'], 'INCOMPLETE')
        self.assertEqual(result.report['prepared_runtime']['status'], 'INCOMPLETE')
        self.assertEqual(result.report['prepared_runtime']['phase'], phase)
        result.fetch.assert_not_called()
        result.speed.assert_not_called()
        self.assertIn('INCOMPLETE', result.markdown)
        self.assertNotIn('private-value', json.dumps(result.report))
        self.assertNotIn('private-path', result.markdown)

    def test_verified_handoff_and_restoration_precede_public_requests(self):
        events = []
        self.runtime.verify_prepared.side_effect = lambda *args, **kwargs: (
            events.append('preflight') or (self.device, self.expected, self.observation))
        self.runtime.observe_runtime.side_effect = lambda *args: events.append('after_restore') or self.observation
        def proof(command):
            events.append('proof')
            for operation in ('positive', 'reject', 'positive_after', 'restore'):
                command('/data/adb/modules/MagicNet/cli service restart sing-box', timeout=90)
            return self.VERIFIED
        result = self.run_main(proof_effect=proof)
        self.assertEqual(result.code, 0)
        self.assertEqual(events, ['preflight', 'proof', 'after_restore'])
        self.runtime.verify_prepared.assert_called_once_with(self.runtime_dir, strict_generation=False)
        self.runtime.observe_runtime.assert_called_once_with(self.device, self.expected)
        self.assertEqual(result.report['prepared_runtime']['status'], 'verified')
        self.assertEqual(self.device.kshell.call_count, 4)
        for call in self.device.kshell.call_args_list:
            self.assertEqual(call.kwargs, dict(timeout=90, check=False))
        result.fetch.assert_called_once()
        self.assertEqual(result.speed.call_count, 2)
        result.instrument.assert_called_once_with(bench.COMPONENT, 'identity', 5)

    def test_failed_preflight_never_uses_default_adb_or_probe(self):
        self.runtime.verify_prepared.side_effect = RuntimeError('core_payload_mismatch')
        result = self.run_main()
        self.assert_blocked(result, 'preflight')
        result.instrument.assert_not_called()
        result.verify.assert_not_called()
        self.runtime.observe_runtime.assert_not_called()
        self.assertEqual(result.report['prepared_runtime']['error_code'], 'core_payload_mismatch')

    def test_missing_handoff_or_proof_refuses_without_loading_runtime(self):
        for args in (['--root-mode', 'ksud', '--verify-tun'],
                     ['--root-mode', 'ksud', '--prepared-runtime-dir', str(self.runtime_dir)]):
            with self.subTest(args=args):
                result = self.run_main(argv=args)
                self.assert_blocked(result, 'preflight')
                result.loader.assert_not_called()
                result.instrument.assert_not_called()
                result.verify.assert_not_called()

    def test_each_control_and_restoration_must_be_true_before_probes(self):
        for key in ('status', 'positive', 'reject', 'positive_after', 'restored'):
            for value in (None, False, 'true'):
                with self.subTest(key=key, value=value):
                    result = self.run_main(proof=self.VERIFIED | {key: value})
                    self.assert_blocked(result, 'tun_proof')
                    self.runtime.observe_runtime.assert_not_called()
                    self.assertEqual(result.report['tun_proof'][key], value)

    def test_proof_diagnostic_survives_failed_control(self):
        proof = self.VERIFIED | dict(status='not_verified', positive=False,
                                    failure_operation='core_restart', failure_exit_code=1)
        result = self.run_main(proof=proof)
        self.assert_blocked(result, 'tun_proof')
        self.assertEqual(result.report['tun_proof']['failure_operation'], 'core_restart')
        self.assertEqual(result.report['tun_proof']['failure_exit_code'], 1)

    def test_proof_exception_blocks_requests_and_keeps_report(self):
        result = self.run_main(proof_effect=RuntimeError('private-path private-value'))
        self.assert_blocked(result, 'tun_proof')
        self.assertEqual(result.report['prepared_runtime']['error_code'], 'observation_unknown')

    def test_unknown_proof_shape_replaces_prior_pass_with_incomplete(self):
        for proof in (None, [], ['verified']):
            with self.subTest(proof=proof):
                self.output.mkdir(parents=True, exist_ok=True)
                (self.output / 'results.json').write_text(json.dumps({'verdict': 'PASS'}))
                result = self.run_main(proof=proof)
                self.assert_blocked(result, 'tun_proof')
                self.assertEqual(result.report['tun_proof'], {'status': 'not_verified'})
                self.assertEqual(result.report['prepared_runtime']['error_code'], 'tun_proof_not_verified')
                self.runtime.observe_runtime.assert_not_called()

    def test_post_restore_identity_generation_or_readiness_failure_blocks_requests(self):
        for code in ('core_domain_unknown', 'core_payload_mismatch', 'core_generation_changed',
                     'runtime_not_ready', 'probe_payload_mismatch'):
            with self.subTest(code=code):
                self.runtime.observe_runtime.side_effect = RuntimeError(code)
                result = self.run_main()
                self.assert_blocked(result, 'after_tun_restore')
                self.assertEqual(result.report['prepared_runtime']['error_code'], code)
                self.assertEqual(result.report['tun_proof']['status'], 'verified')

    def test_app_identity_failure_cannot_start_proof_or_public_probes(self):
        result = self.run_main(identity=dict(ok=False, uid=None))
        self.assert_blocked(result, 'preflight')
        result.verify.assert_not_called()
        self.runtime.observe_runtime.assert_not_called()

    def test_default_adb_keeps_existing_transport_without_prepared_helper(self):
        result = self.run_main(argv=['--verify-tun'])
        self.assertEqual(result.code, 0)
        result.loader.assert_not_called()
        result.verify.assert_called_once_with()
        self.assertNotIn('prepared_runtime', result.report)

    def test_proof_callback_executes_real_device_kshell_stdin_semantics(self):
        spec = importlib.util.spec_from_file_location('benchmark_transport_simulation',
                                                      ROOT / 'scripts/android-device-simulation.py')
        simulation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(simulation)
        with patch.dict(os.environ, MAGICNET_DISPOSABLE_AVD='1', ANDROID_SERIAL='emulator-5554'):
            self.device = simulation.Device()
        self.device.verified = True  # The mocked verify_prepared is the tested handoff boundary.
        self.runtime.verify_prepared.return_value = self.device, self.expected, self.observation
        command = "/data/adb/modules/MagicNet/cli config-editor save-file sing-box '/a path/file.json'"
        def proof(root_shell):
            root_shell(command, timeout=90)
            return self.VERIFIED
        with patch.object(simulation.subprocess, 'run',
                          return_value=subprocess.CompletedProcess(['adb'], 0, '', '')) as transport:
            result = self.run_main(proof_effect=proof)
        self.assertEqual(result.code, 0)
        transport.assert_called_once()
        self.assertEqual(transport.call_args.args[0], ['adb', '-s', 'emulator-5554', 'shell', '-T',
                                                      '/data/adb/ksud debug su'])
        self.assertEqual(transport.call_args.kwargs['input'],
                         'export KSU=true ASH_STANDALONE=1\nexec /data/adb/ksu/bin/busybox sh -c '
                         + shlex.quote(command) + '\n')
        self.assertEqual(transport.call_args.kwargs['timeout'], 90)


if __name__ == '__main__':
    unittest.main()

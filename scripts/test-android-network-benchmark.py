#!/usr/bin/env python3
"""Regression tests for fail-closed Android probe accounting (no device needed)."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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


if __name__ == '__main__':
    unittest.main()

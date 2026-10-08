#!/usr/bin/env python3
"""Fail-closed accounting for sustained device observations."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('soak', Path(__file__).with_name('android-network-soak.py'))
soak = importlib.util.module_from_spec(spec)
spec.loader.exec_module(soak)


class SoakTests(unittest.TestCase):
    def summary(self, probes=None, snapshots=None, **kw):
        probe = dict(ok=True, complete=True, elapsed_ms=200)
        sample = dict(known=True, pid=123, generation=42, rss_kib=1000,
                      fds=30, ready=True, configured_mode='tun',
                      effective_mode='tun', transition='idle')
        args = dict(duration=600, elapsed=600, max_latency_ms=1000,
                    max_rss_growth_kib=100, max_fd_growth=5)
        args.update(kw)
        return soak.evaluate(probes if probes is not None else [probe],
                             snapshots if snapshots is not None else [sample], **args)

    def test_later_success_does_not_erase_failure_or_latency_spike(self):
        for probe in (dict(ok=False, complete=True, elapsed_ms=0),
                      dict(ok=True, complete=True, elapsed_ms=1501)):
            report = self.summary(probes=[probe, dict(ok=True, complete=True, elapsed_ms=100)])
            self.assertEqual(report['verdict'], 'FAIL')

    def test_elapsed_time_unknown_state_and_incomplete_probe_never_pass(self):
        self.assertEqual(self.summary(elapsed=599)['verdict'], 'INCOMPLETE')
        self.assertEqual(self.summary(probes=[])['verdict'], 'INCOMPLETE')
        self.assertEqual(self.summary(snapshots=[dict(known=False)])['verdict'], 'INCOMPLETE')
        self.assertEqual(self.summary(probes=[dict(ok=False, complete=False, elapsed_ms=0)])['verdict'], 'INCOMPLETE')

    def test_restart_resource_growth_and_transient_readiness_loss_fail(self):
        baseline = dict(known=True, pid=123, generation=42, rss_kib=1000,
                        fds=30, ready=True, configured_mode='tun', effective_mode='tun', transition='idle')
        for change in ({'generation': 43}, {'pid': 124}, {'rss_kib': 1101}, {'fds': 36},
                       {'ready': False}, {'effective_mode': 'ebpf'}, {'transition': 'pending'}):
            with self.subTest(change=change):
                report = self.summary(snapshots=[baseline, baseline | change, baseline])
                self.assertEqual(report['verdict'], 'FAIL')

    def test_healthy_bounded_run_passes_only_declared_scope(self):
        self.assertEqual(self.summary()['verdict'], 'PASS')

    def test_unavailable_app_replaces_old_pass_before_returning(self):
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            (folder / 'results.json').write_text('{"summary":{"verdict":"PASS"}}')
            corpus = folder / 'targets.tsv'
            corpus.write_text('one|global|https://example.invalid/private-path|204\n')
            argv = ['soak', '--serial', 'test-device', '--targets', str(corpus), '--output', str(folder)]
            with patch.object(sys, 'argv', argv), patch.dict(soak.os.environ), \
                    patch.object(soak.bench, 'instrument', return_value={'ok': False}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(soak.main(), 2)
            report = (folder / 'results.json').read_text()
            self.assertEqual(json.loads(report)['summary']['verdict'], 'INCOMPLETE')
            self.assertNotIn('private-path', report)

    def test_bad_corpus_invalidates_old_results_and_samples(self):
        for invalid in (None, 'invalid-target-row\n'):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as td:
                folder = Path(td)
                (folder / 'results.json').write_text('{"summary":{"verdict":"PASS"}}')
                (folder / 'samples.json').write_text('{"probes":[{"id":"previous"}]}')
                corpus = folder / 'targets.tsv'
                if invalid is not None:
                    corpus.write_text(invalid)
                argv = ['soak', '--serial', 'test-device', '--targets', str(corpus), '--output', str(folder)]
                with patch.object(sys, 'argv', argv), contextlib.redirect_stderr(io.StringIO()), \
                        self.assertRaises(SystemExit) as exit_code:
                    soak.main()
                self.assertEqual(exit_code.exception.code, 2)
                self.assertEqual(json.loads((folder / 'results.json').read_text())['summary']['verdict'], 'INCOMPLETE')
                self.assertEqual(json.loads((folder / 'samples.json').read_text())['probes'], [])

    def test_root_transport_is_explicit_and_preserves_shell_quoting(self):
        command = 'printf "%s" "value with spaces"'
        with patch.object(soak.subprocess, 'run') as run:
            run.return_value.returncode = 0
            run.return_value.stdout = '0\n'
            self.assertEqual(soak.root(command, 'adb'), '0\n')
            self.assertEqual(run.call_args.args[0], ['adb', 'shell', command])
            soak.root(command, 'su')
            self.assertEqual(run.call_args.args[0], ['adb', 'shell', 'su -M -c ' + soak.shlex.quote(command)])


if __name__ == '__main__':
    unittest.main()

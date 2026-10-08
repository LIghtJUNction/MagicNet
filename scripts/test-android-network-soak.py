#!/usr/bin/env python3
"""Fail-closed accounting for sustained device observations."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('soak', Path(__file__).with_name('android-network-soak.py'))
soak = importlib.util.module_from_spec(spec)
spec.loader.exec_module(soak)


class SoakTests(unittest.TestCase):
    def process_fixture(self, folder):
        corpus = folder / 'targets.tsv'
        corpus.write_text('one|global|https://example.invalid/fixture|204\n')
        runner = folder / 'runner.py'
        runner.write_text(textwrap.dedent(f'''
            import importlib.util
            import json
            from pathlib import Path
            import sys
            spec = importlib.util.spec_from_file_location('soak', {str(Path(soak.__file__).resolve())!r})
            soak = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(soak)
            role = sys.argv.pop(1)
            calls = Path({str(folder)!r}) / (role + '-calls')
            def record(name):
                with calls.open('a') as output:
                    output.write(name + '\\n')
            class Clock:
                now = 0
                def monotonic(self):
                    return self.now
            clock = Clock()
            soak.time.monotonic = clock.monotonic
            soak.print = lambda *args, **kwargs: None
            def identity(*args):
                record('identity')
                return {{'ok': True, 'uid': 10001}}
            def root(*args):
                record('root')
                return '0\\n'
            def probe(*args):
                record('probe')
                if role == 'block_probe':
                    print('READY', flush=True)
                    sys.stdin.readline()
                clock.now = 1
                if role == 'host_failure':
                    return soak.bench.failure('invalid_response')
                return dict(ok=True, complete=True, reason='ok', uid=10001, elapsed_ms=100)
            soak.bench.instrument = identity
            soak.root = root
            soak.bench.fetch_probe = probe
            def telemetry(*args):
                record('telemetry')
                return dict(known=True, pid=123, generation=42, rss_kib=1000,
                    threads=3, fds=30, ready=True, configured_mode='tun',
                    effective_mode='tun', transition='idle')
            soak.telemetry = telemetry
            if role == 'block_pass':
                original_write = Path.write_text
                def write(self, data, *args, **kwargs):
                    result = original_write(self, data, *args, **kwargs)
                    if self.name == 'results.json' and json.loads(data)['summary']['verdict'] == 'PASS':
                        print('PASS_READY', flush=True)
                        sys.stdin.readline()
                    return result
                Path.write_text = write
            raise SystemExit(soak.main())
        '''))
        return [sys.executable, str(runner)], [
            '--serial', 'test-device', '--targets', str(corpus), '--duration', '1']

    def start_process(self, command):
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)
        self.addCleanup(cleanup)
        return process

    def wait_ready(self, process, expected):
        self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'fixture never reached barrier')
        self.assertEqual(process.stdout.readline().strip(), expected)

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

    def test_slow_failed_request_keeps_its_latency_and_failure_count(self):
        report = self.summary(probes=[dict(ok=False, complete=True, elapsed_ms=1501),
                                      dict(ok=True, complete=True, elapsed_ms=100)])
        self.assertEqual(report['failures'], 1)
        self.assertEqual(report['slow_probes'], 1)
        self.assertEqual(report['max_latency_ms'], 1501)
        self.assertEqual(report['p95_latency_ms'], 1501)
        self.assertEqual(report['verdict'], 'FAIL')

    def test_unknown_probe_latency_is_not_guessed_as_zero(self):
        for value in (None, float('nan'), float('inf'), -1, True):
            with self.subTest(value=value):
                report = self.summary(probes=[dict(ok=False, complete=True, elapsed_ms=value),
                                              dict(ok=True, complete=True, elapsed_ms=100)])
                self.assertEqual(report['verdict'], 'INCOMPLETE')
                self.assertEqual(report['unknown_elapsed_probes'], 1)
                self.assertEqual(report['failures'], 1)
                self.assertEqual(report['max_latency_ms'], 100)
                self.assertEqual(report['p95_latency_ms'], 100)
                json.dumps(report, allow_nan=False)

    def test_unknown_window_cannot_pass_or_emit_nonfinite_json(self):
        for value in (None, float('nan'), float('inf'), float('-inf'), -1, True):
            with self.subTest(value=value):
                report = self.summary(elapsed=value)
                self.assertEqual(report['verdict'], 'INCOMPLETE')
                self.assertIsNone(report['elapsed_s'])
                json.dumps(report, allow_nan=False)
        self.assertEqual(self.summary(elapsed=599.999)['verdict'], 'INCOMPLETE')

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

    def test_output_lock_rejects_overlapping_processes_without_touching_reports(self):
        for role, ready in (('block_probe', 'READY'), ('block_pass', 'PASS_READY')):
            with self.subTest(stage=role), tempfile.TemporaryDirectory() as td:
                folder = Path(td)
                output = folder / 'output'
                runner, args = self.process_fixture(folder)
                owner = self.start_process(runner + [role] + args + ['--output', str(output)])
                self.wait_ready(owner, ready)
                before = [(output / name).read_bytes() for name in ('results.json', 'samples.json')]
                alias = folder / 'alias'
                alias.symlink_to(output, target_is_directory=True)
                for path in (output, alias, output / '..' / 'output'):
                    contender = subprocess.run(runner + ['contender'] + args + ['--output', str(path)],
                                               capture_output=True, text=True, timeout=5)
                    self.assertEqual(contender.returncode, 2, contender.stdout + contender.stderr)
                    self.assertEqual([(output / name).read_bytes() for name in ('results.json', 'samples.json')], before)
                    self.assertFalse((folder / 'contender-calls').exists())
                stdout, stderr = owner.communicate(input='release\n', timeout=5)
                self.assertEqual(owner.returncode, 0, stdout + stderr)
                self.assertEqual(json.loads((output / 'results.json').read_text())['summary']['verdict'], 'PASS')

    def test_same_process_contender_does_not_reset_owner_reports(self):
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            corpus = folder / 'targets.tsv'
            corpus.write_text('one|global|https://example.invalid/fixture|204\n')
            reports = (folder / 'results.json', folder / 'samples.json')
            reports[0].write_text('{"summary":{"verdict":"PASS"}}')
            reports[1].write_text('{"probes":[{"id":"owner"}]}')
            before = [path.read_bytes() for path in reports]
            argv = ['soak', '--serial', 'test-device', '--targets', str(corpus), '--output', str(folder)]
            with (folder / '.soak.lock').open('a') as owner:
                soak.fcntl.flock(owner, soak.fcntl.LOCK_EX | soak.fcntl.LOCK_NB)
                with patch.object(sys, 'argv', argv), contextlib.redirect_stderr(io.StringIO()), \
                        patch.object(soak.bench, 'instrument') as instrument:
                    self.assertEqual(soak.main(), 2)
                    instrument.assert_not_called()
            self.assertEqual([path.read_bytes() for path in reports], before)

    def test_initialization_error_and_invalid_budget_release_output_lock(self):
        for failing_name in ('results.json', 'samples.json', None):
            with self.subTest(write=failing_name), tempfile.TemporaryDirectory() as td:
                folder = Path(td)
                argv = ['soak', '--serial', 'test-device', '--targets', str(folder / 'missing'),
                        '--output', str(folder), '--duration', '0']
                original_write = Path.write_text
                def write(path, text, *args, **kwargs):
                    if path.name == failing_name:
                        raise OSError('fixture write failure')
                    return original_write(path, text, *args, **kwargs)
                with patch.object(sys, 'argv', argv), patch.object(Path, 'write_text', write), \
                        contextlib.redirect_stderr(io.StringIO()), \
                        patch.object(soak.bench, 'instrument') as instrument:
                    with self.assertRaises(OSError if failing_name else SystemExit):
                        soak.main()
                    instrument.assert_not_called()
                with (folder / '.soak.lock').open('a') as retry:
                    soak.fcntl.flock(retry, soak.fcntl.LOCK_EX | soak.fcntl.LOCK_NB)

    def test_interrupted_new_owner_invalidates_pass_and_crash_releases_lock(self):
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            output = folder / 'output'
            runner, args = self.process_fixture(folder)
            command = runner + ['finish'] + args + ['--output', str(output)]
            first = subprocess.run(command, capture_output=True, text=True, timeout=5)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            lock_inode = (output / '.soak.lock').stat().st_ino
            for signum in (signal.SIGINT, signal.SIGKILL):
                with self.subTest(signal=signum):
                    owner = self.start_process(runner + ['block_probe'] + args + ['--output', str(output)])
                    self.wait_ready(owner, 'READY')
                    self.assertEqual(json.loads((output / 'results.json').read_text())['summary']['verdict'], 'INCOMPLETE')
                    self.assertEqual(json.loads((output / 'samples.json').read_text())['probes'], [])
                    owner.send_signal(signum)
                    owner.communicate(timeout=5)
                    self.assertEqual(owner.returncode, 2 if signum == signal.SIGINT else -signal.SIGKILL)
                    self.assertEqual(json.loads((output / 'results.json').read_text())['summary']['verdict'], 'INCOMPLETE')
                    self.assertEqual((output / '.soak.lock').stat().st_ino, lock_inode)
                    retry = subprocess.run(command, capture_output=True, text=True, timeout=5)
                    self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
                    self.assertEqual((output / '.soak.lock').stat().st_ino, lock_inode)

    def test_host_failure_placeholder_is_not_a_measured_zero(self):
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            output = folder / 'output'
            runner, args = self.process_fixture(folder)
            result = subprocess.run(runner + ['host_failure'] + args + ['--output', str(output)],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            report = json.loads((output / 'results.json').read_text())
            self.assertEqual(report['summary']['verdict'], 'INCOMPLETE')
            self.assertEqual(report['summary']['unknown_elapsed_probes'], 1)
            self.assertIsNone(report['summary']['max_latency_ms'])
            self.assertIsNone(report['summary']['p95_latency_ms'])
            self.assertIsNone(report['probes'][0]['elapsed_ms'])


if __name__ == '__main__':
    unittest.main()

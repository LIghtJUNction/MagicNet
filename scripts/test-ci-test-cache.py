#!/usr/bin/env python3
"""Regression tests for cache invalidation, failure propagation and outputs."""
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('ci_cache', Path(__file__).with_name('ci-test-cache.py'))
CACHE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CACHE)


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.write('.gitignore', 'count\n.cache/\ndist/\n')
        self.write('source', 'one')
        self.write('Cargo.toml', '[workspace]\n')
        self.write('crates/lib.rs', 'one')
        self.write('docs/note.md', 'one')
        self.write('webui/src/app.js', 'one')
        self.write('src/MagicNet/service.sh', 'one')
        self.write('src/MagicNet/network-check.sh', 'one')
        self.write('src/MagicNet/.config/sing-box/config.json', 'one')
        subprocess.run(['git', 'add', '.'], cwd=self.root, check=True)
        self.addCleanup(patch.stopall)
        patch.object(CACHE, 'ROOT', self.root).start()
        patch.object(CACHE, 'tool_fingerprint', return_value={'tool': 'v1'}).start()
        patch.dict(os.environ, CI_TEST_CACHE='1', CI_TEST_FORCE='0').start()
        self.command = [sys.executable, '-c',
                        'from pathlib import Path; p=Path("count"); '
                        'p.write_text(str(int(p.read_text())+1) if p.exists() else "1")']

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def run_check(self, *options, command=None, scope='repo', name='test'):
        args = ['ci-test-cache.py', *options, scope, name, '--', *(command or self.command)]
        with patch.object(sys, 'argv', args):
            return CACHE.main()

    def count(self):
        return int((self.root / 'count').read_text())

    def test_unchanged_success_is_reused(self):
        self.assertEqual(self.run_check(), 0)
        self.assertEqual(self.run_check(), 0)
        self.assertEqual(self.count(), 1)

    def test_lookup_only_never_executes_and_reports_exact_hit(self):
        self.assertEqual(self.run_check('--lookup-only'), 1)
        self.assertFalse((self.root / 'count').exists())
        self.assertEqual(self.run_check(), 0)
        self.assertEqual(self.run_check('--lookup-only'), 0)
        self.assertEqual(self.count(), 1)
        self.write('source', 'changed')
        self.assertEqual(self.run_check('--lookup-only'), 1)
        self.assertEqual(self.count(), 1)
        with patch.dict(os.environ, CI_TEST_FORCE='1'):
            self.assertEqual(self.run_check('--lookup-only'), 1)
        self.assertEqual(self.count(), 1)

    def test_source_edit_add_delete_and_mode_invalidate(self):
        self.run_check()
        self.write('source', 'two')
        self.run_check()
        self.write('new-input', 'new')
        self.run_check()
        (self.root / 'source').chmod(0o755)
        self.run_check()
        (self.root / 'source').unlink()
        self.run_check()
        self.assertEqual(self.count(), 5)

    def test_staged_regular_file_uses_index_blob(self):
        self.run_check()
        self.write('source', 'staged')
        subprocess.run(['git', 'add', 'source'], cwd=self.root, check=True)
        self.run_check()
        self.assertEqual(self.count(), 2)

    def test_rust_does_not_depend_on_docs_but_does_on_sources(self):
        self.run_check(scope='rust')
        self.write('docs/note.md', 'changed')
        self.run_check(scope='rust')
        self.assertEqual(self.count(), 1)
        self.write('crates/lib.rs', 'changed')
        self.run_check(scope='rust')
        self.assertEqual(self.count(), 2)
        self.write('src/MagicNet/.config/sing-box/config.json', 'changed')
        self.run_check(scope='rust')
        self.assertEqual(self.count(), 3)

    def test_rust_fingerprint_tracks_external_integration_test_inputs(self):
        # These are repository files copied/sourced by the actual Rust tests,
        # not operands of the cargo command and not files inside a crate.
        inputs = (
            'scripts/test-transparent-recovery.py',
            'src/MagicNet/lib/magicnet/primitives.sh',
            'src/MagicNet/lib/magicnet/common.sh',
            'src/MagicNet/lib/magicnet/subscribe_bootstrap.sh',
            'src/MagicNet/lib/magicnet/singbox_subscribe/bootstrap.sh',
            'src/MagicNet/lib/magicnet/network.sh',
            'src/MagicNet/lib/magicnet/core.sh',
            'src/MagicNet/lib/magicnet/transparent.sh',
            'src/MagicNet/lib/magicnet/singbox_subscribe/update.sh',
        )
        for name in inputs:
            self.write(name, 'original')
        subprocess.run(['git', 'add', '--', *inputs], cwd=self.root, check=True)
        command = ['cargo', 'test', '--workspace', '--locked']
        before = CACHE.fingerprint('rust', command)
        for name in inputs:
            with self.subTest(input=name):
                self.write(name, 'changed')
                try:
                    self.assertNotEqual(CACHE.fingerprint('rust', command), before,
                                        f'Rust success could be reused after changing {name}')
                finally:
                    self.write(name, 'original')

    def test_host_scope_ignores_rust_webui_and_docs_but_tracks_module(self):
        self.run_check(scope='host')
        self.write('crates/lib.rs', 'changed')
        self.run_check(scope='host')
        self.write('webui/src/app.js', 'changed')
        self.run_check(scope='host')
        self.write('docs/note.md', 'changed')
        self.run_check(scope='host')
        self.assertEqual(self.count(), 1)
        self.write('src/MagicNet/service.sh', 'changed')
        self.run_check(scope='host')
        self.assertEqual(self.count(), 2)

    def test_host_fingerprint_tracks_cli_lifecycle_contract_sources(self):
        # The host start/stop regression reads these production Rust command
        # contracts even though it does not compile or execute a Rust crate.
        inputs = ('crates/magicnet-cli/src/service.rs',
                  'crates/magicnet-cli/src/commands.rs')
        self.write('scripts/test-start-stop-rollback.py', 'fixture')
        for name in inputs:
            self.write(name, 'original')
        subprocess.run(['git', 'add', '--', *inputs], cwd=self.root, check=True)
        command = ['python3', 'scripts/test-start-stop-rollback.py', '--all-shells']
        before = CACHE.fingerprint('host', command)
        for name in inputs:
            with self.subTest(input=name):
                self.write(name, 'changed')
                try:
                    self.assertNotEqual(CACHE.fingerprint('host', command), before,
                                        f'Host success could be reused after changing {name}')
                finally:
                    self.write(name, 'original')

    def test_host_scope_tracks_rule_recipe_and_reviewed_pin(self):
        self.run_check(scope='host')
        self.write('rules-release.json', '{"tag":"rules-new"}')
        self.run_check(scope='host')
        self.assertEqual(self.count(), 2)
        self.write('rules/scripts/download_release.py', 'changed recipe')
        self.run_check(scope='host')
        self.assertEqual(self.count(), 3)

    def test_network_scope_ignores_ui_and_rust_but_tracks_network_inputs(self):
        self.run_check(scope='network')
        self.write('crates/lib.rs', 'changed')
        self.run_check(scope='network')
        self.write('webui/src/app.js', 'changed')
        self.run_check(scope='network')
        self.assertEqual(self.count(), 1)
        self.write('src/MagicNet/network-check.sh', 'changed')
        self.run_check(scope='network')
        self.assertEqual(self.count(), 2)

    def test_toolchain_environment_and_command_invalidate(self):
        self.run_check()
        with patch.object(CACHE, 'tool_fingerprint', return_value={'tool': 'v2'}):
            self.run_check()
        with patch.dict(os.environ, RUSTFLAGS='new-flags'):
            self.run_check()
        self.run_check(command=[*self.command, 'different-argument'])
        self.assertEqual(self.count(), 4)

    def test_failures_never_cache_or_hide_exit_status(self):
        command = [sys.executable, '-c', 'print("expected diagnostic"); raise SystemExit(27)']
        self.assertEqual(self.run_check(command=command), 27)
        self.assertEqual(self.run_check(command=command), 27)
        self.assertFalse(list(self.root.glob('.cache/**/*.json')))

    def test_timeout_is_not_success(self):
        result = self.run_check('--timeout', '1', command=[sys.executable, '-c', 'import time; time.sleep(20)'])
        self.assertEqual(result, 124)
        self.assertFalse(list(self.root.glob('.cache/**/*.json')))

    def test_interrupted_runner_reaps_child_and_never_caches_success(self):
        # Run outside the unittest process so a broken signal handler cannot
        # terminate the test runner. The child deliberately treats cancellation
        # as a clean exit; that must never make the enclosing check successful.
        child = ('import os, signal, sys, time; from pathlib import Path; '
                 'signal.signal(signal.SIGINT, lambda *_: sys.exit(0)); '
                 'signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); '
                 'Path("count.tmp").write_text(str(os.getpid())); '
                 'Path("count.tmp").rename("count"); time.sleep(30)')
        bootstrap = (
            'import importlib.util, sys; from pathlib import Path; '
            f'spec=importlib.util.spec_from_file_location("cache", {CACHE.__file__!r}); '
            'cache=importlib.util.module_from_spec(spec); spec.loader.exec_module(cache); '
            f'cache.ROOT=Path({str(self.root)!r}); '
            'cache.tool_fingerprint=lambda: {"tool":"fixture"}; '
            f'sys.argv=["ci-test-cache.py","repo","signal-test","--",sys.executable,"-c",{child!r}]; '
            'sys.exit(cache.main())'
        )
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                (self.root / 'count').unlink(missing_ok=True)
                child_pid = None
                process = subprocess.Popen([sys.executable, '-c', bootstrap],
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                try:
                    deadline = time.monotonic() + 5
                    while not (self.root / 'count').exists() and time.monotonic() < deadline:
                        if process.poll() is not None:
                            break
                        time.sleep(0.01)
                    self.assertTrue((self.root / 'count').exists(), 'check child did not start')
                    child_pid = int((self.root / 'count').read_text())
                    process.send_signal(signum)
                    output = process.communicate(timeout=5)[0]
                    self.assertEqual(process.returncode, 128 + signum, output)
                    self.assertIn('[ci-test] FAIL signal-test', output)
                    self.assertNotIn('[ci-test] PASS', output)
                    self.assertFalse(list(self.root.glob('.cache/**/*.json')))
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child_pid, 0)
                finally:
                    if child_pid is not None:
                        try:
                            os.killpg(child_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=5)

    def test_missing_or_modified_output_rebuilds(self):
        command = [sys.executable, '-c', self.command[2] +
                   '; Path("dist").mkdir(exist_ok=True); Path("dist/index.html").write_text("ok")']
        self.run_check('--output', 'dist', command=command)
        self.run_check('--output', 'dist', command=command)
        self.assertEqual(self.count(), 1)
        self.write('dist/index.html', 'corrupt')
        self.run_check('--output', 'dist', command=command)
        shutil.rmtree(self.root / 'dist')
        self.run_check('--output', 'dist', command=command)
        self.assertEqual(self.count(), 3)

    def test_force_and_disabled_cache_run_every_time(self):
        self.run_check()
        with patch.dict(os.environ, CI_TEST_FORCE='1'):
            self.run_check()
        with patch.dict(os.environ, CI_TEST_CACHE='0'):
            self.run_check()
        self.assertEqual(self.count(), 3)

    def test_failed_forced_recheck_revokes_earlier_pass(self):
        self.run_check()
        with patch.dict(os.environ, CI_TEST_FORCE='1'), patch.object(CACHE, 'run_check', return_value=27):
            self.assertEqual(self.run_check(), 27)
        self.assertFalse(list(self.root.glob('.cache/**/*.json')))
        self.run_check()
        self.assertEqual(self.count(), 2)

    def test_corrupt_record_is_a_miss(self):
        self.run_check()
        record = next(self.root.glob('.cache/**/*.json'))
        record.write_text('{broken')
        self.run_check()
        self.assertEqual(self.count(), 2)

    def test_input_mutation_during_test_is_not_cached(self):
        command = [sys.executable, '-c', 'from pathlib import Path; Path("source").write_text("changed")']
        self.assertEqual(self.run_check(command=command), 0)
        self.assertFalse(list(self.root.glob('.cache/**/*.json')))

    def test_symlink_target_bytes_invalidate(self):
        (self.root / 'link').symlink_to('source')
        self.run_check()
        self.write('source', 'changed')
        self.run_check()
        self.assertEqual(self.count(), 2)

    def test_recursive_submodule_revision_and_dirty_bytes_invalidate(self):
        sub = self.root / 'sub'
        subprocess.run(['git', 'init', '-q', str(sub)], check=True)
        self.write('sub/file', 'one')
        subprocess.run(['git', 'add', '.'], cwd=sub, check=True)
        def commit():
            subprocess.run(['git', '-c', 'user.name=test', '-c', 'user.email=test@example.invalid',
                            'commit', '-qm', 'fixture'], cwd=sub, check=True)
        commit()
        # A real submodule checkout has .git as either a file or directory.
        subprocess.run(['git', 'add', 'sub'], cwd=self.root, check=True, capture_output=True)
        self.run_check()
        self.write('sub/file', 'two')
        self.run_check()
        subprocess.run(['git', 'add', '.'], cwd=sub, check=True)
        commit()
        self.run_check()
        self.assertEqual(self.count(), 3)


if __name__ == '__main__':
    unittest.main()

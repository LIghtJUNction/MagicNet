#!/usr/bin/env python3
"""Regression tests for cache invalidation, failure propagation and outputs."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
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

    def test_rust_does_not_depend_on_docs_but_does_on_sources(self):
        self.run_check(scope='rust')
        self.write('docs/note.md', 'changed')
        self.run_check(scope='rust')
        self.assertEqual(self.count(), 1)
        self.write('crates/lib.rs', 'changed')
        self.run_check(scope='rust')
        self.assertEqual(self.count(), 2)

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

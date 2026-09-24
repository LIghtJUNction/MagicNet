#!/usr/bin/env python3
"""No-network tests for the production-pinned Android fixture helper build."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('proxylink_build', Path(__file__).with_name('build-android-proxylink.py'))
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)
PIN = 'a' * 40
HOOK = f'REPO_URL="https://github.com/example/Proxylink.git"\nPINNED_REV="{PIN}"\n'


class BuildTests(unittest.TestCase):
    def test_pin_matches_current_production_hook(self):
        repo, revision = MOD.production_pin(MOD.HOOK.read_text())
        self.assertEqual(repo, 'https://github.com/Fanju6/Proxylink.git')
        self.assertEqual(len(revision), 40)

    def test_missing_ambiguous_and_interpolated_pins_are_rejected(self):
        for text in ('', HOOK + HOOK, HOOK.replace(PIN, 'latest'),
                     HOOK.replace('https://github.com/example/Proxylink.git', '$(evil)')):
            with self.subTest(text=text), self.assertRaises(ValueError):
                MOD.production_pin(text)

    def exercise(self, mismatch=False, foreign=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hook = root / 'hook.sh'; hook.write_text(HOOK)
            destination = root / 'proxylink'; destination.write_bytes(b'previous')
            calls = []
            def run(argv, **kw):
                calls.append((argv, kw))
                if argv[:2] == ['git', 'init']:
                    (Path(argv[-1]) / 'Proxylink').mkdir(parents=True)
                if argv[:2] == ['go', 'build']:
                    for key, value in {'CGO_ENABLED':'0', 'GOOS':'linux', 'GOARCH':'amd64'}.items():
                        self.assertEqual(kw['env'][key], value)
                    self.assertIn('-mod=readonly', argv)
                    header = bytearray(64); header[:6] = b'\x7fELF\x02\x01'
                    header[18:20] = b'\xb7\x00' if foreign else b'\x3e\x00'
                    Path(argv[argv.index('-o') + 1]).write_bytes(header)
                return subprocess.CompletedProcess(argv, 0)
            with patch.object(MOD.subprocess, 'run', side_effect=run), \
                 patch.object(MOD.subprocess, 'check_output', return_value=('b'*40 if mismatch else PIN)+'\n'):
                if mismatch or foreign:
                    with self.assertRaises(ValueError): MOD.build(destination, hook)
                    self.assertEqual(destination.read_bytes(), b'previous')
                else:
                    MOD.build(destination, hook)
                    self.assertTrue(destination.read_bytes().startswith(b'\x7fELF'))
                    self.assertTrue(os.access(destination, os.X_OK))
                    self.assertTrue(any('fetch' in argv and argv[-1] == PIN for argv, _ in calls))
            self.assertFalse(list(root.glob('proxylink-avd-*')))

    def test_static_build_uses_exact_production_revision(self): self.exercise()
    def test_revision_mismatch_preserves_previous_output(self): self.exercise(mismatch=True)
    def test_wrong_architecture_preserves_previous_output(self): self.exercise(foreign=True)


if __name__ == '__main__':
    unittest.main()

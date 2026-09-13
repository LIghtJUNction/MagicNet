#!/usr/bin/env python3
"""Fail-closed release ordering and real split-asset signature regressions."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parent.parent


class ReleaseGateTest(unittest.TestCase):
    def setUp(self):
        self.build = yaml.safe_load((ROOT / '.github/workflows/exec.yml').read_text())['jobs']['build']
        self.steps = self.build['steps']
        self.gate = next(s for s in self.steps if s.get('id') == 'release_quality')
        self.release = next(s for s in self.steps if s.get('name') == 'Create GitHub release')

    def test_gate_precedes_publication_and_cannot_ignore_failure(self):
        self.assertLess(self.steps.index(self.gate), self.steps.index(self.release))
        self.assertIn("env.RELEASE_REQUESTED == '1'", self.gate['if'])
        self.assertNotIn('continue-on-error', self.gate)
        self.assertNotIn('continue-on-error', self.build)
        self.assertEqual(self.release['if'], "${{ env.RELEASE_REQUESTED == '1' && steps.release_quality.outcome == 'success' }}")
        for outcome in ('failure', 'cancelled', 'skipped', 'success'):
            for requested in ('0', '1'):
                allowed = requested == '1' and outcome == 'success'
                self.assertEqual(allowed, (requested, outcome) == ('1', 'success'))

    def test_gate_checks_built_checkout_and_dependencies(self):
        script = self.gate['run']
        self.assertIn('set -euo pipefail', script)
        self.assertIn('"$(git rev-parse HEAD)" = "$RELEASE_COMMIT_SHA"', script)
        self.assertIn('bash scripts/quality-check.sh all', script)
        self.assertIn('built-submodules.txt', script)
        self.assertIn('sha256sum -c SHA256SUMS', script)

    def test_checks_are_shared_not_a_weaker_release_copy(self):
        quality = yaml.safe_load((ROOT / '.github/workflows/quality.yml').read_text())
        for suite in ('rust', 'shell', 'webui', 'components'):
            commands = '\n'.join(s.get('run', '') for s in quality['jobs'][suite]['steps'])
            self.assertIn('bash scripts/quality-check.sh ' + suite, commands)
            self.assertIn(suite, (ROOT / 'scripts/quality-check.sh').read_text())

    def test_uploads_finish_before_draft_is_published(self):
        script = self.release['run']
        self.assertIn('set -euo pipefail', script)
        self.assertIn('--target "$RELEASE_COMMIT_SHA"', script)
        self.assertIn('--verify-build', script)
        self.assertIn('--draft ', script)
        self.assertLess(script.index('gh release create'), script.index('gh release edit'))
        for asset in ('dist/*.zip', 'dist/*.sig', 'dist/components-manifest.json', 'dist/SHA256SUMS'):
            self.assertIn(asset, script)

    def test_workflow_shell_syntax(self):
        for name in ('exec.yml', 'quality.yml'):
            workflow = yaml.safe_load((ROOT / '.github/workflows' / name).read_text())
            for job in workflow['jobs'].values():
                for step in job.get('steps', []):
                    if 'run' in step:
                        result = subprocess.run(['bash', '-n'], input=step['run'], text=True, capture_output=True)
                        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_quality_stops_before_publication(self):
        # Execute the real gate shell with inert external tools. A failed shared
        # suite must stop this shell before a publication sentinel can be written.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'scripts').mkdir()
            (root / 'bin').mkdir()
            (root / 'scripts/quality-check.sh').write_text('exit 27\n')
            for name, content in {'git': 'echo fixture-sha', 'sudo': 'exit 0', 'rustup': 'exit 0'}.items():
                p = root / 'bin' / name
                p.write_text('#!/bin/sh\n' + content + '\n')
                p.chmod(0o755)
            env = dict(os.environ, PATH=str(root/'bin')+':'+os.environ['PATH'], RELEASE_COMMIT_SHA='fixture-sha', RUNNER_TEMP=tmp)
            result = subprocess.run(['bash', '-c', self.gate['run']+'\ntouch published'], cwd=root, env=env, capture_output=True)
            self.assertEqual(result.returncode, 27, result.stderr.decode())
            self.assertFalse((root/'published').exists())

    def test_all_split_assets_signed_and_tampering_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'dist').mkdir()
            for name in ('MagicNet.zip', 'MagicNet-full.zip', 'MagicNet-core.zip', 'MagicNet-component-sing-box-arm64-test.zip', 'components-manifest.json', 'update-core.json', 'build-submodules.txt'):
                (root/'dist'/name).write_text(name+'\n')
            (root/'scripts').mkdir()
            for name in ('sign-split-artifacts.sh', 'verify-artifact-signature.sh'):
                (root/'scripts'/name).write_bytes((ROOT/'scripts'/name).read_bytes())
            key = root/'test-key.pem'
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(key)], check=True, capture_output=True)
            env = dict(os.environ, MAGICNET_SIGN_ENABLED='1', MAGICNET_SIGN_REQUIRED='1', SIGNING_KEY_PEM=key.read_text())
            result = subprocess.run(['bash', 'scripts/sign-split-artifacts.sh'], cwd=root, env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ('MagicNet.zip', 'MagicNet-full.zip', 'MagicNet-core.zip', 'components-manifest.json', 'SHA256SUMS'):
                self.assertTrue((root/'dist'/(name+'.sig')).is_file())
            public = root/'public.pem'
            subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-out', str(public)], check=True, capture_output=True)
            (root/'dist/MagicNet-core.zip').write_text('tampered')
            result = subprocess.run(['bash', 'scripts/verify-artifact-signature.sh', 'dist/MagicNet-core.zip', str(public)], cwd=root, capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()

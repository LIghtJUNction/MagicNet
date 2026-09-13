#!/usr/bin/env python3
"""Keep PR #203's release regressions on the shared gate introduced by #204."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class ReleaseGateTests(unittest.TestCase):
    def test_publication_requires_successful_local_quality_gate(self):
        build = yaml.safe_load((ROOT / '.github/workflows/exec.yml').read_text())['jobs']['build']
        steps = build['steps']
        gate = next(s for s in steps if s.get('id') == 'release_quality')
        publish = next(s for s in steps if s.get('name') == 'Create GitHub release')
        self.assertLess(steps.index(gate), steps.index(publish))
        self.assertEqual(gate['if'], "${{ env.RELEASE_REQUESTED == '1' }}")
        self.assertEqual(publish['if'], "${{ env.RELEASE_REQUESTED == '1' && steps.release_quality.outcome == 'success' }}")
        self.assertFalse(build.get('continue-on-error', False))
        self.assertFalse(gate.get('continue-on-error', False))
        self.assertGreater(gate['timeout-minutes'], 0)
        for command in ('set -euo pipefail', 'bash scripts/quality-gate.sh all',
                        'git submodule status --recursive', 'prepare-release.py --verify-build'):
            self.assertIn(command, gate['run'])
        self.assertIn('--target "$RELEASE_COMMIT_SHA"', publish['run'])
        self.assertIn('--draft', publish['run'])
        self.assertLess(publish['run'].index('gh release create'), publish['run'].index('gh release edit'))

    def test_smart_installer_is_built_and_verified_before_final_signing(self):
        build = yaml.safe_load((ROOT / '.github/workflows/exec.yml').read_text())['jobs']['build']
        steps = build['steps']
        package = next(i for i, s in enumerate(steps) if 'scripts/package-smart-installer.py' in s.get('run', ''))
        sign = next(i for i, s in enumerate(steps) if s.get('name') == 'Sign and verify final release assets')
        self.assertLess(package, sign)
        self.assertIn('scripts/test-downloader-installer.py dist/magicnet_installer.zip', steps[package]['run'])
        workflow = yaml.safe_load((ROOT / '.github/workflows/downloader-template.yml').read_text())
        steps = workflow['jobs']['publish']['steps']
        publish = next(i for i, s in enumerate(steps) if 'gh release create' in s.get('run', ''))
        tests = next(i for i, s in enumerate(steps) if 'scripts/test-downloader-installer.py' in s.get('run', ''))
        shared = next(i for i, s in enumerate(steps) if 'scripts/quality-gate.sh components' in s.get('run', ''))
        self.assertLess(tests, publish)
        self.assertLess(shared, publish)
        self.assertIn("github.event_name != 'pull_request'", steps[publish]['if'])

    def test_shared_suite_preserves_all_original_checks(self):
        script = (ROOT / 'scripts/quality-gate.sh').read_text()
        for command in ('cargo fmt', 'cargo clippy', 'cargo test',
                        'bash scripts/lint-shell.sh', 'bash scripts/test-host.sh',
                        'go vet', 'go test -race', 'npm run check', 'npm run test:ui'):
            self.assertIn(command, script)
        self.assertIn('for group in rust shell components webui-check webui-browser', script)
        quality = yaml.safe_load((ROOT / '.github/workflows/quality.yml').read_text())
        commands = '\n'.join(s.get('run', '') for job in quality['jobs'].values()
                             for s in job.get('steps', []))
        for group in ('rust', 'shell', 'components', 'webui-check', 'webui-browser'):
            self.assertIn('bash scripts/quality-gate.sh ' + group, commands)

    def test_each_failed_check_stops_before_publication(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            for name in ('scripts', 'bin', 'webui', 'installer/components'):
                (work / name).mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / 'scripts/quality-gate.sh', work / 'scripts/quality-gate.sh')
            # Exercise the actual shared shell; only external check commands are stubs.
            for name in ('cargo', 'go', 'npm', 'python3', 'gofmt'):
                stub = work / 'bin' / name
                stub.write_text('#!/bin/sh\n[ "${0##*/} $*" != "$FAIL_CHECK" ] || exit 27\nexit 0\n')
                stub.chmod(0o755)
            for name in ('lint-shell.sh', 'test-host.sh'):
                (work / 'scripts' / name).write_text('[ "${0##*/}" != "$FAIL_CHECK" ] || exit 27\n')
            checks = ('cargo fmt --all -- --check',
                      'cargo clippy --workspace --all-targets --all-features --locked -- -D warnings',
                      'cargo test --workspace --all-targets --all-features --locked',
                      'lint-shell.sh', 'test-host.sh',
                      'go vet ./installer/components', 'go test -race ./installer/components',
                      'python3 scripts/test-components.py', 'npm run check', 'npm run test:ui')
            for check in checks:
                with self.subTest(check=check):
                    sentinel = work / 'published'
                    sentinel.unlink(missing_ok=True)
                    env = dict(os.environ, PATH=str(work / 'bin') + ':' + os.environ['PATH'], FAIL_CHECK=check)
                    result = subprocess.run(['bash', '-e', '-c',
                                             'bash scripts/quality-gate.sh all\ntouch published'],
                                            cwd=work, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 27, result.stdout + result.stderr)
                    self.assertFalse(sentinel.exists())


if __name__ == '__main__':
    unittest.main()

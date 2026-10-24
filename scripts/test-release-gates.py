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
        self.assertEqual(publish['if'], "${{ env.RELEASE_REQUESTED == '1' && steps.release_quality.outcome == 'success' && steps.android_acceptance.outcome == 'success' }}")
        android = next(s for s in steps if s.get('id') == 'android_acceptance')
        self.assertLess(steps.index(gate), steps.index(android))
        self.assertLess(steps.index(android), steps.index(publish))
        self.assertIn('scripts/require-android-acceptance.py', android['run'])
        self.assertFalse(android.get('continue-on-error', False))
        self.assertFalse(build.get('continue-on-error', False))
        self.assertFalse(gate.get('continue-on-error', False))
        self.assertEqual(gate.get('env', {}).get('CI_TEST_FORCE'), '1')
        self.assertGreater(gate['timeout-minutes'], 0)
        for command in ('set -euo pipefail', 'bash scripts/quality-gate.sh all',
                        'git submodule status --recursive', 'prepare-release.py --verify-build'):
            self.assertIn(command, gate['run'])
        self.assertIn('--target "$RELEASE_COMMIT_SHA"', publish['run'])
        self.assertIn('--notes-file "$notes_file"', publish['run'])
        self.assertIn('cat "docs/releases/${RELEASE_VERSION}.md"', publish['run'])
        self.assertIn('--draft', publish['run'])
        self.assertLess(publish['run'].index('gh release create'), publish['run'].index('gh release edit'))

    def test_dispatched_release_uses_same_commit_acceptance_dependency(self):
        flow = yaml.safe_load((ROOT / '.github/workflows/exec.yml').read_text())
        android = yaml.safe_load((ROOT / '.github/workflows/android-kernelsu-acceptance.yml').read_text())
        call = flow['jobs']['release-android']
        self.assertEqual(call['uses'], './.github/workflows/android-kernelsu-acceptance.yml')
        self.assertEqual(call['permissions'], {'contents': 'read'})
        self.assertNotIn('secrets', call)
        self.assertNotIn('continue-on-error', call)
        self.assertIn('workflow_call', android.get('on', android.get(True)))
        for guard in ("github.event_name == 'workflow_dispatch'", "github.ref == 'refs/heads/main'",
                      "inputs.release == true", "inputs.bump == 'none'",
                      "inputs.expected_sha == github.sha"):
            self.assertIn(guard, call['if'])
        for job in ('harness', 'android-kernelsu'):
            checkout = android['jobs'][job]['steps'][0]
            self.assertEqual(checkout['with']['ref'], '${{ github.sha }}')
        gate = android['jobs']['simulation-gate']
        self.assertEqual(set(gate['needs']), {'harness', 'android-kernelsu'})
        command = gate['steps'][0]['run']
        for harness, device in (('success', 'success'), ('failure', 'success'),
                                ('success', 'skipped'), ('cancelled', 'success')):
            result = subprocess.run(['bash', '-e', '-c', command],
                                    env=dict(os.environ, HARNESS_RESULT=harness, ANDROID_RESULT=device))
            self.assertEqual(result.returncode == 0, harness == device == 'success')
        build = flow['jobs']['build']
        self.assertEqual(build['needs'], 'release-android')
        self.assertIn('!cancelled()', build['if'])
        self.assertIn("needs.release-android.result == 'success'", build['if'])
        # Even a skipped dependency must never grant release permission.
        verify = next(step for step in build['steps'] if step.get('id') == 'android_acceptance')
        self.assertEqual(verify['env']['ANDROID_RESULT'], '${{ needs.release-android.result }}')
        for status in ('success', 'skipped', 'failure', 'cancelled', ''):
            for ref in ('refs/heads/main', 'refs/heads/other'):
                result = subprocess.run(['bash', '-c', verify['run']], env=dict(
                    os.environ, GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REF=ref,
                    ANDROID_RESULT=status))
                self.assertEqual(result.returncode == 0,
                                 status == 'success' and ref == 'refs/heads/main')

    def test_bot_build_dispatch_binds_sha_and_rejects_moved_main(self):
        flow = yaml.safe_load((ROOT / '.github/workflows/exec.yml').read_text())
        steps = flow['jobs']['build']['steps']
        verify = next(step for step in steps if step.get('name') == 'Verify dispatched commit')
        validate = next(step for step in steps if step.get('name') == 'Validate release request')
        self.assertLess(steps.index(verify), steps.index(validate))
        self.assertEqual(verify['env']['EXPECTED_SHA'], '${{ inputs.expected_sha }}')
        for expected in ('', 'a' * 40, 'b' * 40):
            result = subprocess.run(['bash', '-c', verify['run']], capture_output=True,
                                    env=dict(os.environ, EXPECTED_SHA=expected, GITHUB_SHA='a' * 40))
            self.assertEqual(result.returncode == 0, expected != 'b' * 40)
        command = next(step['run'] for step in flow['jobs']['version-bump']['steps']
                       if step.get('name') == 'Open version pull request')
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            (work / 'gh').write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            for path in work.iterdir():
                path.chmod(0o755)
            result = subprocess.run(['bash', '-c', command], capture_output=True, text=True,
                                    env=dict(os.environ, PATH=tmp + ':' + os.environ['PATH'],
                                             VERSION='v1.2.4', GITHUB_RUN_ID='42',
                                             RUNNER_TEMP=tmp, RELEASE_INPUT='true',
                                             PRERELEASE_INPUT='false'))
            self.assertEqual(result.returncode, 0, result.stderr)
            output = result.stdout.splitlines()
            self.assertIn('pr', output)
            self.assertIn('create', output)
            self.assertIn('--base', output)
            self.assertIn('main', output)
            self.assertIn('--head', output)
            self.assertIn('release/version-1.2.4-42', output)
            self.assertIn('--title', output)
            self.assertIn('chore(release): prepare v1.2.4', output)

    def test_shared_suite_preserves_all_original_checks(self):
        script = (ROOT / 'scripts/quality-gate.sh').read_text()
        for command in ('cargo fmt', 'cargo clippy', 'cargo test',
                        'python3 scripts/test-lint-source.py', 'python3 scripts/lint-source.py',
                        'bash scripts/lint-shell.sh', 'bash scripts/test-host.sh',
                        'go vet', 'go test -race', 'npm run check', 'npm run test:ui'):
            self.assertIn(command, script)
        for lint in ('-D clippy::dbg_macro', '-D clippy::todo', '-D clippy::unimplemented'):
            self.assertIn(lint, script)
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
                      'cargo clippy --workspace --all-targets --all-features --locked -- -D warnings -D clippy::dbg_macro -D clippy::todo -D clippy::unimplemented',
                      'cargo test --workspace --all-targets --all-features --locked',
                      'python3 scripts/test-lint-source.py', 'python3 scripts/lint-source.py',
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

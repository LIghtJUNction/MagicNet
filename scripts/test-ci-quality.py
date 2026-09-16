#!/usr/bin/env python3
"""Exercise the real quality gate, including stale cache hits and failed jobs."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class UniqueLoader(yaml.BaseLoader):
    """Keep Actions' `on` key intact and reject silently overwritten YAML keys."""

    def construct_mapping(self, node, deep=False):
        mapping = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in mapping:
                raise ValueError(f"duplicate workflow key: {key}")
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


def workflow():
    return yaml.load((ROOT / '.github/workflows/quality.yml').read_text(), Loader=UniqueLoader)


class SanityExecutionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        for name in ('quality-gate.sh', 'lint-source.py'):
            shutil.copyfile(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        # Model an exact successful cache hit. Cheap repository checks must run
        # even if the cache says all previously checked inputs are unchanged.
        self.write('scripts/ci-test-cache.py', 'raise SystemExit(0)\n')
        for name in ('test-lint-source.py', 'test-ci-test-cache.py', 'test-ci-quality.py'):
            self.write('scripts/' + name,
                       'import os\nraise SystemExit(27 if os.environ.get("FAIL_CHECK") == '
                       + repr(name) + ' else 0)\n')
        self.write('scripts/lint-shell.sh', '[ "${FAIL_CHECK:-}" != lint-shell.sh ] || exit 27\n')
        self.write('scripts/test-host.sh', 'touch host-ran\n')
        for name in ('webui/src/app.vue', 'crates/lib.rs', 'docs/note.md'):
            self.write(name, 'fixture\n')
        self.write('webui/config.json', '{"valid": true}\n')
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', 'add', '.'], cwd=self.root, check=True)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def run_gate(self, group='shell', fail=''):
        return subprocess.run(
            ['bash', 'scripts/quality-gate.sh', group], cwd=self.root,
            env=dict(os.environ, CI_TEST_CACHE='1', FAIL_CHECK=fail),
            capture_output=True, text=True, timeout=20,
        )

    def test_unchanged_source_succeeds(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / 'host-ran').exists())

    def test_conflicts_outside_host_scope_cannot_hide_behind_cache_hits(self):
        self.assertEqual(self.run_gate().returncode, 0)
        for name in ('webui/src/app.vue', 'crates/lib.rs', 'docs/note.md'):
            with self.subTest(path=name):
                (self.root / 'host-ran').unlink(missing_ok=True)
                self.write(name, '<' * 7 + ' unresolved\n')
                result = self.run_gate()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(name, result.stderr)
                self.assertFalse((self.root / 'host-ran').exists())
                self.write(name, 'fixture\n')

    def test_duplicate_webui_json_keys_cannot_hide_behind_cache_hits(self):
        self.assertEqual(self.run_gate().returncode, 0)
        self.write('webui/config.json', '{"key": 1, "key": 2}\n')
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('duplicate JSON key', result.stderr)

    def test_each_cheap_check_failure_stops_host_tests(self):
        for name in ('test-lint-source.py', 'lint-source.py', 'lint-shell.sh'):
            with self.subTest(check=name):
                if name == 'lint-source.py':
                    self.write('scripts/lint-source.py', 'raise SystemExit(27)\n')
                result = self.run_gate(fail=name)
                self.assertEqual(result.returncode, 27, result.stdout + result.stderr)
                self.assertFalse((self.root / 'host-ran').exists())
                shutil.copyfile(ROOT / 'scripts/lint-source.py', self.root / 'scripts/lint-source.py')

    def test_cache_engine_cannot_reuse_its_own_success(self):
        result = self.run_gate('components', fail='test-ci-test-cache.py')
        self.assertEqual(result.returncode, 27, result.stdout + result.stderr)

    def test_ci_gate_regressions_cannot_reuse_their_own_success(self):
        result = self.run_gate('components', fail='test-ci-quality.py')
        self.assertEqual(result.returncode, 27, result.stdout + result.stderr)

    def test_unknown_group_fails(self):
        result = self.run_gate('not-a-group')
        self.assertEqual(result.returncode, 64)


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.config = workflow()
        self.jobs = self.config['jobs']

    def test_duplicate_yaml_keys_are_rejected(self):
        with self.assertRaises(ValueError):
            yaml.load('jobs:\n  rust: {}\n  rust: {}\n', Loader=UniqueLoader)

    def test_pr_and_merge_queue_are_not_path_filtered(self):
        events = self.config['on']
        for event in ('pull_request', 'merge_group'):
            self.assertIn(event, events)
            self.assertNotIn('paths', events[event] or {})
            self.assertNotIn('paths-ignore', events[event] or {})
        self.assertNotIn('pull_request_target', events)
        self.assertEqual(events['push']['branches'], ['main'])

    def test_aggregate_covers_every_other_job_and_always_runs(self):
        gate = self.jobs['quality-gate']
        self.assertEqual(gate['name'], 'CI Quality Gate')
        self.assertEqual(gate['if'], '${{ always() }}')
        self.assertEqual(set(gate['needs']), set(self.jobs) - {'quality-gate'})
        self.assertFalse(any('uses' in step for step in gate['steps']))
        self.assertEqual(gate['permissions'], {})

    def test_jobs_are_bounded_and_cannot_ignore_failures(self):
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                self.assertGreater(int(job['timeout-minutes']), 0)
                self.assertLessEqual(int(job['timeout-minutes']), 60)
                self.assertEqual(job.get('continue-on-error', 'false'), 'false')
                for step in job['steps']:
                    self.assertEqual(step.get('continue-on-error', 'false'), 'false')

    def test_existing_quality_jobs_wait_for_ci_self_tests(self):
        for name in ('rust', 'shell', 'components', 'webui'):
            self.assertEqual(self.jobs[name]['needs'], 'ci')
            self.assertNotIn('if', self.jobs[name])

    def test_ci_infrastructure_is_never_result_cached(self):
        steps = self.jobs['ci']['steps']
        self.assertFalse(any(step.get('uses') == './.github/actions/test-cache' for step in steps))
        commands = '\n'.join(step.get('run', '') for step in steps)
        for script in ('test-ci-test-cache.py', 'test-ci-quality.py'):
            self.assertIn('python3 scripts/' + script, commands)
        self.assertIn('actionlint@v1.7.12', commands)
        self.assertIn('.github/workflows/quality.yml', commands)

    def test_read_only_permissions_and_pinned_actions(self):
        self.assertEqual(self.config['permissions'], {'contents': 'read'})
        for job in self.jobs.values():
            for step in job['steps']:
                action = step.get('uses', '')
                if action and not action.startswith('./'):
                    self.assertRegex(action, r'^[^@]+@[0-9a-f]{40}$')
                if action.startswith('actions/checkout@'):
                    self.assertEqual(step['with']['persist-credentials'], 'false')

    def test_browser_failures_retain_diagnostics(self):
        steps = self.jobs['webui']['steps']
        upload = next(step for step in steps if step.get('uses', '').startswith('actions/upload-artifact@'))
        self.assertEqual(upload['if'], '${{ failure() }}')
        self.assertEqual(upload['with']['path'], 'webui/test-results/')
        self.assertEqual(upload['with']['retention-days'], '7')
        browser = next(step for step in steps if step.get('run') == 'bash scripts/quality-gate.sh webui-browser')
        self.assertLess(steps.index(browser), steps.index(upload))


class AggregateExecutionTests(unittest.TestCase):
    def setUp(self):
        gate = workflow()['jobs']['quality-gate']
        self.script = gate['steps'][0]['run']
        self.success = {name: {'result': 'success'} for name in gate['needs']}

    def run_aggregate(self, results, summary=None):
        env = dict(os.environ, NEEDS_JSON=json.dumps(results))
        env.pop('GITHUB_STEP_SUMMARY', None)
        if summary is not None:
            env['GITHUB_STEP_SUMMARY'] = str(summary)
        return subprocess.run([sys.executable, '-c', self.script], env=env,
                              capture_output=True, text=True, timeout=10)

    def test_all_success_passes(self):
        result = self.run_aggregate(self.success)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_each_failed_cancelled_or_skipped_job_blocks(self):
        for name in self.success:
            for state in ('failure', 'cancelled', 'skipped', 'neutral', 'unknown'):
                with self.subTest(job=name, state=state):
                    results = dict(self.success, **{name: {'result': state}})
                    result = self.run_aggregate(results)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name + '=' + state, result.stderr)

    def test_empty_or_malformed_results_fail_closed(self):
        for results in ({}, [], None, {'ci': {}}, {'ci': None}, {'ci': {'result': True}}):
            with self.subTest(results=results):
                self.assertNotEqual(self.run_aggregate(results).returncode, 0)

    def test_summary_preserves_existing_content_and_reports_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / 'summary.md'
            summary.write_text('Earlier summary\n')
            result = self.run_aggregate(dict(self.success, rust={'result': 'failure'}), summary)
            self.assertNotEqual(result.returncode, 0)
            text = summary.read_text()
            self.assertTrue(text.startswith('Earlier summary\n'))
            self.assertIn('| rust | failure |', text)


if __name__ == '__main__':
    unittest.main()

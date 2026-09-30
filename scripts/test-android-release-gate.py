#!/usr/bin/env python3
"""Publication must not reuse an old, PR-only, failed or incomplete Android run."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('android_release_gate',
                                            Path(__file__).with_name('require-android-acceptance.py'))
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
SHA = 'a' * 40
REPO = 'LIghtJUNction/MagicNet'
RUN = {'id': 10, 'head_sha': SHA, 'head_branch': 'main', 'event': 'push',
       'head_repository': {'full_name': REPO}, 'status': 'completed', 'conclusion': 'success'}
JOBS = [{'name': name, 'status': 'completed', 'conclusion': 'success'}
        for name in ('Simulation harness contracts', 'Android 15 / KernelSU / x86_64',
                     'Android Simulation Gate')]


class AndroidReleaseGateTests(unittest.TestCase):
    def test_success_requires_matching_run_and_all_jobs(self):
        requests = []
        def query(path):
            requests.append(path)
            return {'jobs': JOBS} if '/jobs?' in path else {'workflow_runs': [RUN]}
        self.assertEqual(GATE.require_acceptance(REPO, SHA, query=query), 10)
        self.assertIn(f'head_sha={SHA}&branch=main&event=push', requests[0])
        self.assertIn('/actions/runs/10/jobs?', requests[1])

    def test_other_commits_branches_events_and_repositories_are_not_evidence(self):
        for key, value in (('head_sha', 'b'*40), ('head_branch', 'work'),
                           ('event', 'pull_request'), ('head_repository', {'full_name': 'other/fork'})):
            self.assertIsNone(GATE.inspect_runs([RUN | {key: value}], SHA, REPO))

    def test_latest_failure_cannot_reuse_earlier_success(self):
        for conclusion in ('failure', 'cancelled', 'skipped', 'timed_out', None):
            with self.subTest(conclusion=conclusion), self.assertRaises(RuntimeError):
                GATE.inspect_runs([RUN, RUN | {'id': 11, 'conclusion': conclusion}], SHA, REPO)
        self.assertIsNone(GATE.inspect_runs([RUN, RUN | {'id': 11, 'status': 'in_progress'}], SHA, REPO))

    def test_missing_or_unsuccessful_gate_never_publishes(self):
        for jobs in (JOBS[:-1], JOBS[:-1] + [JOBS[-1] | {'conclusion': 'skipped'}],
                     JOBS[:-1] + [JOBS[-1] | {'status': 'in_progress'}]):
            with self.assertRaises(RuntimeError):
                GATE.verify_jobs(jobs)

    def test_pending_run_has_bounded_wait_then_fails(self):
        times = iter([0, 0, 5, 6])
        sleeps = []
        with self.assertRaisesRegex(RuntimeError, 'deadline'):
            GATE.require_acceptance(REPO, SHA, timeout=6,
                                    query=lambda _: {'workflow_runs': []},
                                    clock=lambda: next(times), sleep=sleeps.append)
        self.assertEqual(sleeps, [1])


if __name__ == '__main__':
    unittest.main()

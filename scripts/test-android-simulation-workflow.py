#!/usr/bin/env python3
"""Prevent accidental bypasses of automatic Android/KernelSU acceptance."""
from pathlib import Path
import os
import re
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / '.github/workflows'


def load(name):
    # BaseLoader deliberately keeps YAML 1.1's 'on' key a string.
    return yaml.load((WORKFLOWS / name).read_text(), Loader=yaml.BaseLoader)


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.flow = load('android-kernelsu-acceptance.yml')
        self.jobs = self.flow['jobs']
        self.steps = self.jobs['android-kernelsu']['steps']

    def step(self, name):
        return next(step for step in self.steps if step.get('name') == name)

    def test_every_change_can_trigger_acceptance_including_merge_queue(self):
        self.assertTrue({'pull_request', 'merge_group', 'push', 'workflow_dispatch'} <= self.flow['on'].keys())
        self.assertIn('main', self.flow['on']['push']['branches'])
        self.assertFalse(self.flow['on']['pull_request'])  # no path-filter bypass
        self.assertNotIn('pull_request_target', self.flow['on'])
        self.assertEqual(self.flow['permissions'], {'contents': 'read'})

    def test_harness_is_uncached_prerequisite(self):
        self.assertEqual(self.jobs['android-kernelsu']['needs'], 'harness')
        harness = self.jobs['harness']['steps']
        self.assertTrue(any('test-android-device-simulation.py' in s.get('run', '') for s in harness))
        self.assertFalse(any('cache' in s.get('uses', '') for s in harness))

    def test_simulation_is_not_optional_or_cached(self):
        simulation = self.step('Exercise offline Android KernelSU lifecycle')
        self.assertNotIn('if', simulation)
        self.assertNotIn('continue-on-error', simulation)
        self.assertEqual(simulation['run'], 'python3 scripts/android-device-simulation.py')
        self.assertEqual(simulation['env']['MAGICNET_DISPOSABLE_AVD'], '1')
        self.assertFalse(any('SUBSCRIPTION' in key or 'PROXY_REGION' in key for key in simulation['env']))
        self.assertNotIn('if', self.jobs['android-kernelsu'])
        self.assertNotIn('continue-on-error', self.jobs['android-kernelsu'])

    def test_public_proxy_is_explicit_opt_in_after_simulation(self):
        benchmark = self.step('Install and benchmark MagicNet in KernelSU AVD')
        self.assertIn("github.event_name == 'workflow_dispatch'", benchmark['if'])
        self.assertIn('inputs.public_benchmark == true', benchmark['if'])
        self.assertEqual(self.flow['on']['workflow_dispatch']['inputs']['public_benchmark']['default'], 'false')
        names = [s.get('name') for s in self.steps]
        self.assertLess(names.index('Exercise offline Android KernelSU lifecycle'),
                        names.index('Install and benchmark MagicNet in KernelSU AVD'))
        self.assertIn('android-public-benchmark', benchmark['env']['MAGICNET_ANDROID_REPORT_DIR'])

    def test_only_pristine_vm_is_saved_and_cached_kernel_is_reverified(self):
        names = [s.get('name') for s in self.steps]
        boot = names.index('Boot Android with KernelSU kernel')
        self.assertLess(names.index('Save pristine Android AVD'), boot)
        for step in self.steps[boot + 1:]:
            self.assertNotIn('actions/cache', step.get('uses', ''))
        verify = self.step('Verify cached KernelSU assets')['run']
        self.assertGreaterEqual(verify.count('sha256sum --check --strict'), 2)
        self.assertNotRegex(verify, r'(?m)^\s*(?:source|\.)\s+')
        self.assertNotIn('if', self.step('Verify cached KernelSU assets'))

    def test_exact_serial_kernel_and_enforcing_not_disabled(self):
        self.assertEqual(self.flow['env']['ANDROID_SERIAL'], 'emulator-5554')
        boot = self.step('Boot Android with KernelSU kernel')['run']
        self.assertIn('-port 5554', boot)
        self.assertIn('-kernel "$KSU_KERNEL"', boot)
        self.assertIn('-accel on', boot)
        self.assertIn('-no-snapshot-save', boot)
        self.assertNotIn('permissive', boot)
        self.assertNotIn('setenforce', boot)

    def test_unique_removed_init_checks_are_preserved(self):
        self.assertFalse((WORKFLOWS / 'init.yml').exists())
        validation = self.step('Validate repository')['run']
        for command in ('kam validate', 'kam check', 'python3 scripts/test-release-workflow.py',
                        'bash scripts/test-subscription-usage.sh', 'bash scripts/test-artifact-signature.sh'):
            self.assertIn(command, validation)

    def test_final_gate_fails_on_failure_cancellation_or_skipped_jobs(self):
        gate = self.jobs['simulation-gate']
        self.assertIn('always()', gate['if'])
        self.assertEqual(set(gate['needs']), {'harness', 'android-kernelsu'})
        self.assertEqual(gate['permissions'], {})
        command = gate['steps'][0]['run']
        for harness in ('success', 'failure', 'cancelled', 'skipped', ''):
            for android in ('success', 'failure', 'cancelled', 'skipped', ''):
                env = dict(os.environ, HARNESS_RESULT=harness, ANDROID_RESULT=android)
                result = subprocess.run(['bash', '-e', '-c', command], env=env, timeout=2)
                self.assertEqual(result.returncode == 0, harness == android == 'success')

    def test_automatic_webui_duplicate_is_removed_but_preview_remains(self):
        self.assertFalse((WORKFLOWS / 'webui.yml').exists())
        preview = load('webui-preview.yml')
        self.assertEqual(set(preview['on']), {'workflow_dispatch'})
        steps = preview['jobs']['preview']['steps']
        artifacts = {s.get('with', {}).get('name') for s in steps if 'upload-artifact' in s.get('uses', '')}
        self.assertEqual(artifacts, {'webui-source', 'webui-preview'})

    def test_real_dns_kernel_is_not_attested_by_cached_pass(self):
        network = load('network-regression.yml')
        dns = network['jobs']['dns-kernel']['steps']
        self.assertFalse(any('test-cache' in s.get('uses', '') for s in dns))
        self.assertTrue(any('test-dns-kernel.py --require' in s.get('run', '') for s in dns))
        self.assertEqual(network['jobs']['internet-observation']['if'], "github.event_name == 'workflow_dispatch'")

    def test_reports_and_cleanup_run_on_failure(self):
        for name in ('Stop emulator', 'Upload Android acceptance report'):
            self.assertIn('always()', self.step(name)['if'])

    def test_modified_workflow_shell_syntax(self):
        for name in ('android-kernelsu-acceptance.yml', 'network-regression.yml', 'webui-preview.yml'):
            for job in load(name)['jobs'].values():
                for step in job.get('steps', []):
                    if 'run' not in step:
                        continue
                    script = re.sub(r'\$\{\{.*?\}\}', 'placeholder', step['run'])
                    result = subprocess.run(['bash', '-n'], input=script, text=True, capture_output=True, timeout=2)
                    self.assertEqual(result.returncode, 0, (name, step.get('name'), result.stderr))


if __name__ == '__main__':
    unittest.main()

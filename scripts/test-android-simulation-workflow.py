#!/usr/bin/env python3
"""Prevent accidental bypasses of automatic Android/KernelSU acceptance."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import re
import stat
import struct
import subprocess
import tempfile
import unittest
import zipfile
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

    def test_only_pristine_vm_is_cached_and_official_ksud_is_verified_fresh(self):
        names = [s.get('name') for s in self.steps]
        boot = names.index('Boot pristine Android 15 AVD')
        self.assertLess(names.index('Save pristine Android AVD'), boot)
        for step in self.steps[boot + 1:]:
            self.assertNotIn('actions/cache', step.get('uses', ''))
        download = self.step('Download and verify official KernelSU userspace')['run']
        self.assertEqual(download.count('sha256sum --check --strict'), 1)
        self.assertIn('github.com/tiann/KernelSU/releases/download/$KSU_RELEASE/', download)
        self.assertIn('ksud-x86_64-linux-android', download)
        workflow_text = (WORKFLOWS / 'android-kernelsu-acceptance.yml').read_text()
        for retired in ('KSU_KERNEL', 'KSU_AVD_ARCHIVE', 'KSU_AVD_SHA256',
                        'leemikepop/avd-kernelsu-x86_64'):
            self.assertNotIn(retired, workflow_text)

    def test_exact_serial_stock_kernel_and_enforcing_not_disabled(self):
        self.assertEqual(self.flow['env']['ANDROID_SERIAL'], 'emulator-5554')
        boot = self.step('Boot pristine Android 15 AVD')['run']
        self.assertIn('-port 5554', boot)
        self.assertNotIn('-kernel', boot)
        self.assertNotIn('KSU_KERNEL', boot)
        self.assertIn('-accel on', boot)
        self.assertIn('-no-snapshot-save', boot)
        self.assertIn('-show-kernel', boot)
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

    def test_raw_kam_caches_do_not_block_fixture_or_hide_runtime_elf(self):
        # CI builds the raw KAM ZIP. Like the production component packager,
        # fixture preparation must omit build downloads, not execute them.
        spec = importlib.util.spec_from_file_location('simulation_cache', ROOT / 'scripts/android-device-simulation.py')
        simulation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(simulation)
        host = bytearray(64)
        host[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<HH', host, 16, 3, 62)
        foreign = bytearray(host)
        struct.pack_into('<H', foreign, 18, 183)
        caches = {'.local/state/tools/yq.asset': bytes(foreign),
                  '.local/state/tools/jq.asset': bytes(foreign),
                  '.local/state/zashboard.archive': b'cached dashboard'}
        for extra, kind in ((None, stat.S_IFREG), ('bin/hidden.asset', stat.S_IFREG),
                            ('.local/state/tools/runtime-helper', stat.S_IFREG),
                            ('.local/state/tools/link.asset', stat.S_IFLNK),
                            ('.local/state/../escape.asset', stat.S_IFREG)):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                source, output = root / 'raw.zip', root / 'fixture.zip'
                replacements = {}
                for name in simulation.PAYLOADS:
                    path = root / name.replace('/', '-')
                    path.write_bytes(host)
                    replacements[name] = path
                entries = {name: bytes(foreign) for name in simulation.PAYLOADS} | caches | {
                    'module.prop': b'id=MagicNet\n', 'customize.sh': b'export SKIPUNZIP=1\n',
                    '.local/state/tools/metadata.json': b'{"keep": true}'}
                if extra:
                    entries[extra] = bytes(foreign)
                with zipfile.ZipFile(source, 'w') as z:
                    for name, data in entries.items():
                        item = zipfile.ZipInfo(name)
                        item.external_attr = ((kind if name == extra else stat.S_IFREG) | 0o644) << 16
                        z.writestr(item, data)
                before = source.read_bytes()
                if extra:
                    with self.assertRaises(RuntimeError):
                        simulation.prepare_archive(source, output, replacements)
                    self.assertFalse(output.exists())
                else:
                    report = simulation.prepare_archive(source, output, replacements)
                    self.assertEqual(report['excluded_build_cache_sha256'], {
                        name: hashlib.sha256(data).hexdigest() for name, data in caches.items()})
                    with zipfile.ZipFile(output) as z:
                        self.assertEqual(set(z.namelist()), set(entries) - set(caches) | {simulation.PROVENANCE})
                        self.assertEqual(z.read('.local/state/tools/metadata.json'), entries['.local/state/tools/metadata.json'])
                        recorded = json.loads(z.read(simulation.PROVENANCE))
                        self.assertEqual(recorded['excluded_build_cache_sha256'], report['excluded_build_cache_sha256'])
                self.assertEqual(source.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()

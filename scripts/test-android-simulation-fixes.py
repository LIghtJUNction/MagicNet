#!/usr/bin/env python3
"""Host fault regressions for #344; these do not certify Android execution."""
from __future__ import annotations

import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SIM = load('android-device-simulation')
UP = load('android-simulation-upgrade')


def elf(machine, suffix=b''):
    data = bytearray(64)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<HH', data, 16, 3, machine)
    return bytes(data) + suffix


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'input.zip'
        self.output = self.root / 'output.zip'
        self.entries = {name: elf(183, name.encode()) for name in SIM.PAYLOADS}
        self.entries.update({'module.prop': b'id=MagicNet\n', 'customize.sh': b'original installer'})
        self.replacements = {}
        for name in SIM.PAYLOADS + SIM.OPTIONAL_PAYLOADS:
            file = self.root / name.replace('/', '-')
            file.write_bytes(elf(62, name.encode()))
            self.replacements[name] = file
        self.modes = {}

    def run_archive(self, optional=False):
        with zipfile.ZipFile(self.source, 'w') as z:
            # Binary before alias reproduces ZipInfo offset corruption as well.
            for name, data in sorted(self.entries.items()):
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = self.modes.get(name, stat.S_IFREG | 0o755) << 16
                z.writestr(info, data)
        replacements = self.replacements if optional else {
            name: self.replacements[name] for name in SIM.PAYLOADS}
        return SIM.prepare_archive(self.source, self.output, replacements)

    def test_dereferenced_cli_alias_is_replaced_and_attested(self):
        self.entries['cli'] = self.entries['bin/magicnet-cli']
        manifest = self.run_archive()
        with zipfile.ZipFile(self.output) as z:
            self.assertEqual(z.read('cli'), z.read('bin/magicnet-cli'))
            self.assertEqual(z.read('customize.sh'), self.entries['customize.sh'])
        self.assertEqual(manifest['alias_payload_sha256']['cli'], manifest['payload_sha256']['bin/magicnet-cli'])
        with zipfile.ZipFile(self.source) as z:
            self.assertEqual(z.read('cli'), self.entries['cli'])

    def test_alias_mismatch_is_not_silently_fixed(self):
        self.entries['cli'] = elf(183, b'unrelated code')
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            self.run_archive()
        self.assertFalse(self.output.exists())

    def test_canonical_symlink_is_preserved(self):
        self.entries['cli'] = b'bin/magicnet-cli'
        self.modes['cli'] = stat.S_IFLNK | 0o777
        manifest = self.run_archive()
        with zipfile.ZipFile(self.output) as z:
            self.assertEqual(z.read('cli'), b'bin/magicnet-cli')
            self.assertTrue(stat.S_ISLNK(z.getinfo('cli').external_attr >> 16))
        self.assertEqual(manifest['alias_payload_sha256'], {})

    def test_escaping_alias_and_special_file_are_rejected(self):
        for mode, data in ((stat.S_IFLNK | 0o777, b'../../outside'),
                           (stat.S_IFIFO | 0o600, self.entries['bin/magicnet-cli'])):
            with self.subTest(mode=mode):
                self.entries['cli'] = data
                self.modes['cli'] = mode
                with self.assertRaises(RuntimeError):
                    self.run_archive()

    def test_all_six_payloads_are_replaced_without_dropping_helpers(self):
        for name in SIM.OPTIONAL_PAYLOADS:
            self.entries[name] = elf(183, name.encode())
        self.entries['cli'] = self.entries['bin/magicnet-cli']
        manifest = self.run_archive(optional=True)
        self.assertEqual(set(manifest['payload_sha256']), set(SIM.PAYLOADS + SIM.OPTIONAL_PAYLOADS))
        with zipfile.ZipFile(self.output) as z:
            for name, file in self.replacements.items():
                self.assertEqual(z.read(name), file.read_bytes())

    def test_missing_optional_replacement_is_a_failure(self):
        self.entries['bin/ecapture'] = elf(183)
        with self.assertRaisesRegex(RuntimeError, 'optional tool'):
            self.run_archive()

    def test_unknown_foreign_runtime_still_fails(self):
        self.entries['bin/unknown'] = elf(183)
        with self.assertRaisesRegex(RuntimeError, 'unreplaced foreign ELF'):
            self.run_archive()

    def test_unknown_and_incomplete_replacement_sets_fail(self):
        self.run_archive()
        for replacements in ({}, self.replacements | {'bin/unknown': self.replacements[SIM.PAYLOADS[0]]}):
            with self.assertRaises(RuntimeError):
                SIM.prepare_archive(self.source, self.root / 'bad.zip', replacements)


class FakeDevice:
    """Stateful CLI/installer contract double, never a claim of device behavior."""
    def __init__(self, failure=None):
        self.verified = True
        self.active = SIM.fixture_config()
        self.staged = None
        self.marker = ''
        self.stage_marker = ''
        self.payloads = {}
        self.events = []
        self.failure = failure
        self.installed = False

    def kshell(self, command, **options):
        self.events.append(command)
        args = shlex.split(command)
        output = ''
        if 'webui payload create' in command:
            if self.installed:
                raise AssertionError('post-install configuration re-seeding is forbidden')
            self.payloads[args[-1]] = ''
            output = UP.MOD + '/.tmp/webui-payload/' + args[-1]
        elif 'webui payload append' in command:
            self.payloads[args[-2]] += args[-1]
        elif 'webui payload remove' in command:
            self.payloads.pop(args[-1], None)
        elif 'config-editor save-file' in command:
            if self.failure == 'save':
                raise RuntimeError('injected save failure')
            self.active = json.loads(base64.b64decode(self.payloads[Path(args[-1]).name]))
        elif 'config-editor get' in command:
            output = json.dumps(self.active)
        elif command.startswith('printf %s '):
            self.marker = args[2]
        elif 'module install' in command:
            if self.failure == 'install':
                raise RuntimeError('injected installer failure')
            self.installed = True
            self.staged = copy.deepcopy(self.active)
            self.stage_marker = self.marker
            if self.failure == 'staged-node':
                self.staged['outbounds'] = []
            elif self.failure == 'staged-setting':
                self.stage_marker = ''
        elif command == f'test -f {UP.STAGED}/module.prop':
            if self.failure == 'staging-missing':
                raise RuntimeError('missing staged module')
        elif command == f'cat {UP.STAGED}/.config/sing-box/config.json':
            output = json.dumps(self.staged)
        elif command == f'cat {UP.STAGED}/.config/magicnet/ci-upgrade-marker':
            output = self.stage_marker
        elif command == f'cat {UP.MOD}/.config/magicnet/ci-upgrade-marker':
            output = self.marker
        else:
            raise AssertionError('unexpected device command: ' + command)
        return subprocess.CompletedProcess(['adb'], 0, output, '')

    def ready(self):
        self.events.append('ready')
        if self.failure == 'readiness' and self.installed:
            raise RuntimeError('not ready')

    def reboot(self):
        self.events.append('reboot')
        self.active = copy.deepcopy(self.staged)
        if self.failure == 'activated-node':
            self.active['outbounds'] = []
        elif self.failure == 'activated-setting':
            self.marker = ''


class UpgradeTests(unittest.TestCase):
    def test_eligible_node_keeps_original_direct_policy_untouched(self):
        base = SIM.fixture_config()
        before = copy.deepcopy(base)
        candidate = UP.upgrade_config(base)
        self.assertEqual(base, before)
        for key in ('route', 'inbounds', 'dns'):
            self.assertEqual(candidate[key], base[key])
        UP.verify_node(candidate)
        self.assertEqual(candidate['route']['final'], 'direct')
        self.assertEqual(UP.NODE['server'], '127.0.0.1')

    def test_duplicate_seed_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'already exists'):
            UP.upgrade_config(UP.upgrade_config(SIM.fixture_config()))

    def test_node_fields_missing_or_changed_cannot_pass(self):
        for key in UP.NODE:
            candidate = UP.upgrade_config(SIM.fixture_config())
            del candidate['outbounds'][-1][key]
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                UP.verify_node(candidate)
        for port in (True, '19081', 19082):
            candidate = UP.upgrade_config(SIM.fixture_config())
            candidate['outbounds'][-1]['server_port'] = port
            with self.assertRaises(RuntimeError):
                UP.verify_node(candidate)

    def test_duplicates_and_credentials_cannot_pass(self):
        candidate = UP.upgrade_config(SIM.fixture_config())
        candidate['outbounds'].append(copy.deepcopy(UP.NODE))
        with self.assertRaises(RuntimeError):
            UP.verify_node(candidate)
        candidate['outbounds'].pop()
        candidate['outbounds'][-1]['password'] = 'not-a-real-credential'
        with self.assertRaises(RuntimeError):
            UP.verify_node(candidate)

    def test_installer_staging_reboot_and_readback_run_without_reseeding(self):
        device = FakeDevice()
        report = UP.verify_upgrade(device)
        self.assertEqual(report['status'], 'passed')
        self.assertIs(report['node_transport_tested'], False)
        install = next(i for i, x in enumerate(device.events) if 'module install' in x)
        reboot = device.events.index('reboot')
        self.assertLess(install, reboot)
        self.assertTrue(any('modules_update' in x for x in device.events[install:reboot]))
        self.assertFalse(any('save-file' in x or 'payload create' in x or x.startswith('printf')
                             for x in device.events[install + 1:]))
        self.assertEqual(device.payloads, {})

    def test_all_staged_and_activated_failures_propagate(self):
        for failure in ('save', 'install', 'staged-node', 'staged-setting', 'staging-missing',
                        'activated-node', 'activated-setting', 'readiness'):
            with self.subTest(failure=failure), self.assertRaises(RuntimeError):
                UP.verify_upgrade(FakeDevice(failure))

    def test_failed_payload_save_cleans_private_file(self):
        device = FakeDevice('save')
        with self.assertRaises(RuntimeError):
            UP.verify_upgrade(device)
        self.assertEqual(device.payloads, {})

    def test_unverified_device_is_rejected_without_commands(self):
        device = FakeDevice()
        device.verified = False
        with self.assertRaises(RuntimeError):
            UP.verify_upgrade(device)
        self.assertEqual(device.events, [])

    def test_memory_request_is_not_misrepresented_as_guest_ram(self):
        value = UP.memory_observation('MemTotal: 2490880 kB\nMemFree: 123 kB\n', '2048')
        self.assertEqual(value, {'requested_emulator_mib': 2048, 'observed_guest_memtotal_kib': 2490880})
        self.assertIsNone(UP.memory_observation('MemTotal: 12 kB\n', None)['requested_emulator_mib'])

    def test_missing_or_ambiguous_memory_is_not_guessed(self):
        for text in ('', 'MemTotal: 0 kB', 'MemTotal: 123 kB\nMemTotal: 123 kB\n'):
            with self.assertRaises(RuntimeError):
                UP.memory_observation(text, '2048')


class WiringTests(unittest.TestCase):
    def test_fix_tests_and_real_config_check_are_integrated(self):
        import yaml
        flow = yaml.load((ROOT / '.github/workflows/android-kernelsu-acceptance.yml').read_text(), Loader=yaml.BaseLoader)
        harness = flow['jobs']['harness']['steps']
        self.assertTrue(any('python3 scripts/test-android-simulation-fixes.py' in x.get('run', '') for x in harness))
        steps = flow['jobs']['android-kernelsu']['steps']
        names = [x.get('name') for x in steps]
        self.assertLess(names.index('Prepare additional Android x86_64 tools'), names.index('Boot Android with KernelSU kernel'))
        self.assertTrue(any('test-android-simulation-fixes.py --check-core' in x.get('run', '') for x in steps))
        for step in steps:
            if 'run' in step:
                command = re.sub(r'\$\{\{.*?\}\}', 'placeholder', step['run'])
                result = subprocess.run(['bash', '-n'], input=command, text=True, capture_output=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_tool_builder_syntax_and_pinned_inputs(self):
        script = ROOT / 'scripts/prepare-android-fixture-tools.sh'
        self.assertEqual(subprocess.run(['bash', '-n', str(script)], timeout=3).returncode, 0)
        content = script.read_text()
        self.assertIn('904f8335b70ea42fe00070b1af107b8a6fadfcdc4697d990b64b4740922cde54', content)
        self.assertIn('sha256sum --check --strict', content)
        self.assertIn('CGO_ENABLED=0 GOOS=linux GOARCH=amd64', content)
        self.assertIn('4910.update_proxylink.sh', content)
        self.assertIn('/system/bin/linker64', content)


def check_core(binary):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / 'upgrade.json'
        path.write_text(json.dumps(UP.upgrade_config(SIM.fixture_config())))
        subprocess.run([str(Path(binary).resolve()), 'check', '-c', str(path)], check=True, timeout=30)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--check-core':
        check_core(sys.argv[2])
    else:
        unittest.main()

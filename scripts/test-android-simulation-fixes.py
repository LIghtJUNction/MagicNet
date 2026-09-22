#!/usr/bin/env python3
"""Host regressions for #344. These results are NOT Android device acceptance.

--check-core PATH validates both initial and migration configs with a real core.
No SDK, root, network or third-party Python module is needed by the default suite.
"""
from __future__ import annotations

import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
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
SPEC = importlib.util.spec_from_file_location('simulation_fixes', ROOT / 'scripts/android-device-simulation.py')
SIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIM)


def elf(machine: int, suffix: bytes = b'') -> bytes:
    header = bytearray(64)
    header[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<HH', header, 16, 3, machine)
    return bytes(header) + suffix


def result(stdout: str = '', returncode: int = 0):
    return subprocess.CompletedProcess(['fixture'], returncode, stdout, '')


class ArchiveRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.zip'
        self.output = self.root / 'fixture.zip'
        self.entries = {name: (elf(183, name.encode()), stat.S_IFREG | 0o755) for name in SIM.PAYLOADS}
        self.entries.update({'customize.sh': (b'export SKIPUNZIP=1\n', stat.S_IFREG | 0o644),
                             'module.prop': (b'id=MagicNet\n', stat.S_IFREG | 0o644),
                             'untouched.txt': (b'do not change\n', stat.S_IFREG | 0o600)})
        self.replacements = {}
        for name in SIM.PAYLOADS:
            path = self.root / name.replace('/', '-')
            path.write_bytes(elf(62, name.encode() + b'-fixture'))
            self.replacements[name] = path

    def build(self, entries=None):
        with zipfile.ZipFile(self.source, 'w') as z:
            for name, (data, mode) in (self.entries if entries is None else entries).items():
                item = zipfile.ZipInfo(name, (2026, 1, 2, 3, 4, 6))
                item.create_system = 3
                item.compress_type = zipfile.ZIP_DEFLATED
                item.external_attr = mode << 16
                z.writestr(item, data)
        self.before = self.source.read_bytes()
        try:
            return SIM.prepare_archive(self.source, self.output, self.replacements)
        finally:
            self.assertEqual(self.source.read_bytes(), self.before)

    def test_raw_cli_copy_is_replaced_in_both_archive_orders(self):
        for first in (True, False):
            with self.subTest(alias_first=first):
                alias = {'cli': self.entries['bin/magicnet-cli']}
                entries = alias | self.entries if first else self.entries | alias
                report = self.build(entries)
                with zipfile.ZipFile(self.output) as z:
                    self.assertEqual(z.read('cli'), self.replacements['bin/magicnet-cli'].read_bytes())
                    self.assertEqual(z.read('cli'), z.read('bin/magicnet-cli'))
                    self.assertEqual(z.getinfo('cli').external_attr >> 16 & 0o777, 0o755)
                    provenance = json.loads(z.read(SIM.PROVENANCE))
                    self.assertEqual(provenance['compatibility_aliases'], report['compatibility_aliases'])
                self.assertEqual(report['compatibility_aliases']['cli']['representation'], 'executable-copy')
                self.assertEqual(report['compatibility_aliases']['cli']['target'], 'bin/magicnet-cli')

    def test_cli_symlink_remains_exact_and_busybox_compatible(self):
        report = self.build(self.entries | {'cli': (b'bin/magicnet-cli', stat.S_IFLNK | 0o777)})
        with zipfile.ZipFile(self.output) as z:
            self.assertEqual(z.read('cli'), b'bin/magicnet-cli')
            self.assertTrue(stat.S_ISLNK(z.getinfo('cli').external_attr >> 16))
            self.assertEqual(z.getinfo('cli').compress_type, zipfile.ZIP_STORED)
        self.assertEqual(report['compatibility_aliases']['cli']['representation'], 'symlink')

    def test_different_cli_binary_is_rejected_even_when_abi_matches(self):
        for machine in (183, 62):
            with self.subTest(machine=machine), self.assertRaisesRegex(RuntimeError, 'differs'):
                self.build(self.entries | {'cli': (elf(machine, b'unknown'), stat.S_IFREG | 0o755)})
            self.assertFalse(self.output.exists())

    def test_noncanonical_cli_script_is_not_silently_rewritten(self):
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            self.build(self.entries | {'cli': (b'#!/bin/sh\nexit 0\n', stat.S_IFREG | 0o755)})

    def test_unsafe_or_unexpected_cli_link_is_rejected(self):
        for target in (b'/system/bin/sh', b'../outside', b'bin/sing-box', b'bin/magicnet-cli\n'):
            with self.subTest(target=target), self.assertRaisesRegex(RuntimeError, 'symlink target'):
                self.build(self.entries | {'cli': (target, stat.S_IFLNK | 0o777)})

    def test_only_the_known_cli_path_can_be_a_foreign_copy(self):
        for name in ('bin/cli-copy', 'unknown-cli', 'bin/helper.asset'):
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, 'unreplaced foreign ELF'):
                self.build(self.entries | {name: self.entries['bin/magicnet-cli']})

    def test_runtime_target_symlink_still_fails(self):
        entries = self.entries | {'bin/magicnet-cli': (b'outside', stat.S_IFLNK | 0o777)}
        with self.assertRaisesRegex(RuntimeError, 'regular file'):
            self.build(entries)

    def test_cache_exclusions_and_source_metadata_still_hold(self):
        cache = '.local/state/tools/yq.asset'
        report = self.build(self.entries | {cache: self.entries['bin/yq']})
        self.assertIn(cache, report['excluded_build_cache_sha256'])
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(self.output) as fixture:
            self.assertNotIn(cache, fixture.namelist())
            for name in ('customize.sh', 'module.prop', 'untouched.txt'):
                self.assertEqual(source.read(name), fixture.read(name))
                self.assertEqual(source.getinfo(name).external_attr, fixture.getinfo(name).external_attr)
                self.assertEqual(source.getinfo(name).date_time, fixture.getinfo(name).date_time)

    def test_archive_without_optional_cli_alias_still_works(self):
        self.assertEqual(self.build()['compatibility_aliases'], {})

    def test_exact_arm64_optional_helpers_are_excluded_and_attested(self):
        entries = dict(self.entries)
        optional = {}
        for name in SIM.OPTIONAL_ARM64_HELPERS:
            data = elf(183, name.encode() + b'-arm64-only')
            entries[name] = (data, stat.S_IFREG | 0o755)
            optional[name] = data
        report = self.build(entries)
        self.assertEqual(report['excluded_optional_arm64_sha256'],
                         {name: __import__('hashlib').sha256(data).hexdigest()
                          for name, data in optional.items()})
        with zipfile.ZipFile(self.output) as z:
            for name in optional:
                self.assertNotIn(name, z.namelist())

    def test_x86_optional_helper_is_preserved_not_silently_removed(self):
        name = SIM.OPTIONAL_ARM64_HELPERS[0]
        data = elf(62, b'x86-helper')
        self.build(self.entries | {name: (data, stat.S_IFREG | 0o755)})
        with zipfile.ZipFile(self.output) as z:
            self.assertEqual(z.read(name), data)

    def test_unknown_or_wrong_arch_helper_still_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'unreplaced foreign ELF'):
            self.build(self.entries | {'bin/other-helper': (elf(183), stat.S_IFREG | 0o755)})
        with self.assertRaisesRegex(RuntimeError, 'unexpected ELF architecture'):
            self.build(self.entries | {SIM.OPTIONAL_ARM64_HELPERS[0]:
                                        (elf(40), stat.S_IFREG | 0o755)})

    def test_directory_cannot_masquerade_as_cli_executable(self):
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            self.build(self.entries | {'cli': (self.entries['bin/magicnet-cli'][0], stat.S_IFDIR | 0o755)})


class CandidateTests(unittest.TestCase):
    def test_candidate_preserves_baseline_and_routing(self):
        original = SIM.fixture_config()
        before = copy.deepcopy(original)
        candidate = SIM.upgrade_candidate(original)
        self.assertEqual(original, before)
        self.assertEqual(candidate['outbounds'][:-1], original['outbounds'])
        self.assertEqual(candidate['route'], original['route'])
        self.assertEqual(candidate['route']['final'], 'direct')
        self.assertEqual(candidate['outbounds'][-1], SIM.migration_node())
        SIM.verify_migrated_node(candidate)

    def test_canary_is_credential_free_loopback_socks_data(self):
        node = SIM.migration_node()
        self.assertEqual(node['server'], '127.0.0.1')
        self.assertEqual(node['type'], 'socks')
        self.assertEqual(node['version'], '5')
        self.assertIs(type(node['server_port']), int)
        self.assertTrue(1024 <= node['server_port'] <= 65535)
        self.assertEqual(set(node), {'type', 'tag', 'server', 'server_port', 'version'})

    def test_bad_shapes_and_duplicate_canary_fail(self):
        for config in (None, [], {}, {'outbounds': {}}, {'outbounds': [False]},
                       {'outbounds': [SIM.migration_node()]}):
            with self.subTest(config=config), self.assertRaises(RuntimeError):
                SIM.upgrade_candidate(config)

    def test_missing_and_duplicate_migrated_nodes_fail(self):
        for config in (None, {}, {'outbounds': []}, {'outbounds': [None]},
                       {'outbounds': [SIM.migration_node(), SIM.migration_node()]}):
            with self.subTest(config=config), self.assertRaises(RuntimeError):
                SIM.verify_migrated_node(config)

    def test_every_canary_field_is_verified_not_just_tag(self):
        for key, value in (('type', 'http'), ('tag', 'lost'), ('server', '192.0.2.1'),
                           ('server_port', 18080), ('server_port', '19080'),
                           ('server_port', True), ('version', '4'), ('username', 'added'),
                           ('password', ''), ('detour', 'proxy')):
            node = SIM.migration_node() | {key: value}
            with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                SIM.verify_migrated_node({'outbounds': [node]})


class MemoryTests(unittest.TestCase):
    def observe(self, sdk='35', memory='MemTotal:        2530000 kB\nMemFree: 512000 kB\n', requested='2048'):
        class ReadOnly:
            def shell(self, command):
                if command == 'getprop ro.build.version.sdk':
                    return result(sdk)
                if command == 'cat /proc/meminfo':
                    return result(memory)
                raise AssertionError(command)
        with patch.dict(os.environ, {} if requested is None else {'AVD_MEMORY': requested}, clear=True):
            return SIM.device_resources(ReadOnly())

    def test_requested_and_observed_memory_are_distinct(self):
        data = self.observe()
        self.assertEqual(data['requested_memory_mib'], 2048)
        self.assertEqual(data['observed_memtotal_kib'], 2530000)
        self.assertNotEqual(data['observed_memtotal_kib'], data['requested_memory_mib'] * 1024)

    def test_no_requested_memory_is_not_invented(self):
        self.assertIsNone(self.observe(requested=None)['requested_memory_mib'])

    def test_missing_zero_duplicate_or_malformed_memtotal_fails(self):
        for text in ('', 'MemFree: 2048 kB', 'MemTotal: 0 kB', 'MemTotal: -1 kB',
                     'MemTotal: 200 MB', 'MemTotal: 10 kB\nMemTotal: 10 kB\n'):
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                self.observe(memory=text)

    def test_wrong_sdk_or_request_fails(self):
        for sdk in ('34', '36', '', '35\n36'):
            with self.subTest(sdk=sdk), self.assertRaises(RuntimeError):
                self.observe(sdk=sdk)
        with self.assertRaises(RuntimeError):
            self.observe(requested='oops')


class MemoryDevice:
    """In-memory fault injection for orchestration, not an emulated Android kernel."""
    def __init__(self, fault=''):
        self.fault = fault
        self.config = SIM.fixture_config()
        self.calls = []
        self.buffers = {}
        self.marker = None
        self.installed = False
        self.rebooted = False

    def kshell(self, command, **kwargs):
        self.calls.append(command)
        args = shlex.split(command)
        prefix = SIM.MOD + '/cli'
        if args == [prefix, 'config-editor', 'get', 'sing-box']:
            return result(json.dumps(self.config))
        if args[:5] == [prefix, 'webui', 'payload', 'create', 'tmp']:
            if self.fault == 'deny-create':
                raise RuntimeError('injected creation failure')
            self.buffers[args[5]] = ''
            return result('/wrong/path' if self.fault == 'wrong-path'
                          else SIM.MOD + '/.tmp/webui-payload/' + args[5])
        if args[:5] == [prefix, 'webui', 'payload', 'append', 'tmp']:
            self.buffers[args[5]] += args[6]
            return result()
        if args[:5] == [prefix, 'webui', 'payload', 'remove', 'tmp']:
            self.buffers.pop(args[5])
            return result()
        if args[:4] == [prefix, 'config-editor', 'save-file', 'sing-box']:
            if self.fault == 'deny-save':
                raise RuntimeError('injected validation failure')
            candidate = json.loads(base64.b64decode(self.buffers[Path(args[4]).name]))
            self.config = candidate
            if self.fault == 'save-loses-node':
                self.config['outbounds'].pop()
            return result()
        if args == [prefix, 'service', 'restart', 'sing-box']:
            return result()
        if command == 'cat ' + SIM.MOD + '/.config/magicnet/network-policy.conf':
            return result('changed\n' if self.installed and self.fault == 'lose-policy'
                          else 'MAGICNET_NETWORK_IPV6_POLICY=ipv4_only\n')
        if command.startswith('printf %s '):
            self.marker = args[2]
            return result()
        if command.startswith('MAGICNET_NONINTERACTIVE=1 '):
            if self.fault == 'deny-install':
                raise RuntimeError('injected ksud failure')
            self.installed = True
            nodes = [node for node in self.config['outbounds'] if node.get('server')]
            # Model only the migration contract, not the production policy engine.
            self.config = {'outbounds': [{'type': 'direct', 'tag': 'direct'}] + nodes,
                           'route': {'final': 'proxy'}}
            if self.fault == 'drop-node':
                self.config['outbounds'].pop()
            if self.fault == 'change-node':
                self.config['outbounds'][-1]['server_port'] += 1
            if self.fault == 'duplicate-node':
                self.config['outbounds'].append(copy.deepcopy(nodes[0]))
            return result()
        if command == 'cat ' + SIM.MOD + '/.config/magicnet/ci-upgrade-marker':
            return result('lost' if self.fault == 'lose-marker' else self.marker)
        if command == 'test ! -e ' + SIM.MOD + '/.config/sing-box/standalone-config':
            if self.fault == 'keep-standalone':
                raise RuntimeError('injected standalone marker retained')
            return result()
        raise AssertionError(command)

    def ready(self):
        self.calls.append('READY')
        if self.installed and self.fault == 'not-ready':
            raise RuntimeError('injected readiness failure')

    def reboot(self):
        self.calls.append('REBOOT')
        if self.fault == 'reboot-failed':
            raise RuntimeError('injected reboot failure')
        self.rebooted = True


class UpgradeTransactionTests(unittest.TestCase):
    def test_positive_upgrade_controls_and_no_post_reboot_reseeding(self):
        device = MemoryDevice()
        report = SIM.upgrade_preservation(device)
        self.assertTrue(report['node_preserved'])
        self.assertTrue(report['user_policy_preserved'])
        self.assertTrue(report['standalone_marker_removed'])
        self.assertIs(report['proxy_connectivity_tested'], False)
        self.assertEqual(device.buffers, {})
        reboot = device.calls.index('REBOOT')
        before, after = device.calls[:reboot], device.calls[reboot + 1:]
        self.assertTrue(any('save-file' in command for command in before))
        self.assertTrue(any('module install' in command for command in before))
        self.assertFalse(any('save-file' in command or 'payload append' in command
                             or command.startswith(('printf', 'cp ', 'rm ')) for command in after))
        self.assertEqual(device.config['route']['final'], 'proxy', 'test overwrote migrated config')

    def test_endpoint_loss_or_change_fails(self):
        for fault in ('drop-node', 'change-node', 'duplicate-node'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                SIM.upgrade_preservation(MemoryDevice(fault))

    def test_user_setting_or_marker_loss_fails(self):
        for fault in ('lose-policy', 'lose-marker', 'keep-standalone'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                SIM.upgrade_preservation(MemoryDevice(fault))

    def test_ksud_boot_or_readiness_failure_propagates(self):
        for fault in ('deny-install', 'reboot-failed', 'not-ready'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                SIM.upgrade_preservation(MemoryDevice(fault))

    def test_failed_preparation_never_reaches_installer_and_cleans_payload(self):
        for fault in ('deny-create', 'wrong-path', 'deny-save', 'save-loses-node'):
            device = MemoryDevice(fault)
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                SIM.upgrade_preservation(device)
            self.assertFalse(device.installed)
            self.assertEqual(device.buffers, {})
            if fault == 'deny-create':
                self.assertFalse(any('payload remove' in c for c in device.calls))

    def test_initial_fixture_is_still_direct_only_until_upgrade_phase(self):
        self.assertEqual(SIM.fixture_config()['outbounds'], [{'type': 'direct', 'tag': 'direct'}])
        device = MemoryDevice()
        SIM.save_upgrade_candidate(device)
        self.assertFalse(device.installed)
        self.assertEqual(device.config['route']['final'], 'direct')
        self.assertEqual(device.buffers, {})

    def test_large_config_uses_bounded_payload_chunks(self):
        device = MemoryDevice()
        device.config['test-padding'] = 'x' * 70000
        SIM.save_upgrade_candidate(device)
        appends = [shlex.split(c)[-1] for c in device.calls if 'payload append' in c]
        self.assertGreater(len(appends), 1)
        self.assertTrue(all(len(part) <= 32768 for part in appends))
        self.assertEqual(device.config['test-padding'], 'x' * 70000)


class FailureGateTests(unittest.TestCase):
    def test_unexecuted_device_phases_still_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = SIM.Report(Path(tmp))
            report.write()
            self.assertEqual(json.loads((Path(tmp) / 'simulation.json').read_text())['status'], 'failed')
            self.assertFalse(report.complete())

    def test_physical_device_opt_in_is_not_weakened(self):
        with patch.dict(os.environ, {'ANDROID_SERIAL': 'usb-123', 'MAGICNET_DISPOSABLE_AVD': '1'}, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'emulator serial'):
                SIM.Device()


def check_core(binary):
    core = str(Path(binary).resolve())
    with tempfile.TemporaryDirectory() as tmp:
        for name, value in (('initial', SIM.fixture_config()),
                            ('upgrade', SIM.upgrade_candidate(SIM.fixture_config()))):
            config = Path(tmp) / (name + '.json')
            config.write_text(json.dumps(value))
            subprocess.run([core, 'check', '-c', str(config)], check=True, timeout=30, cwd=tmp)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--check-core':
        check_core(sys.argv[2])
    else:
        unittest.main()

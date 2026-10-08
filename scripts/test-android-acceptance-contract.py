#!/usr/bin/env python3
"""Exercise AVD build and prepared-runtime contracts without an SDK, network or VM."""
from pathlib import Path
import copy
import hashlib
import importlib.util
import stat
import struct
import shlex
import selectors
import signal
import zipfile
from unittest.mock import Mock, patch
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import unittest

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/android-kernelsu-acceptance.yml"


class AcceptanceContract(unittest.TestCase):
    def setUp(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        self.steps = workflow["jobs"]["android-kernelsu"]["steps"]

    def step(self, name):
        return next(step for step in self.steps if step.get("name") == name)

    def test_avd_build_references_real_workspace_packages(self):
        workspace = tomllib.loads((ROOT / "Cargo.toml").read_text())["workspace"]
        packages = []
        for member in workspace["members"]:
            for path in ROOT.glob(member):
                packages.append(tomllib.loads((path / "Cargo.toml").read_text())["package"]["name"])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "scripts").mkdir()
            cargo = root / "bin/cargo"
            cargo.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
assert args[:3] == ["ndk", "-t", "x86_64"], args
assert "build" in args and "--release" in args, args
requested = [args[i+1] for i, arg in enumerate(args[:-1]) if arg in ("-p", "--package")]
assert requested, args
for package in requested:
    if package not in json.loads(os.environ["WORKSPACE_PACKAGES"]):
        sys.exit("AVD requested missing workspace package: " + package)
    output = pathlib.Path("target/x86_64-linux-android/release") / package
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("#!/bin/sh\\nexit 0\\n")
    output.chmod(0o755)
''')
            cargo.chmod(0o755)
            core = root / "scripts/build-sing-box.sh"
            core.write_text('#!/bin/sh\nset -eu\n[ "$1" = android ] && [ "$2" = amd64 ]\nprintf "#!/bin/sh\\nexit 0\\n" > "$3"\nchmod 0755 "$3"\n')
            core.chmod(0o755)
            env = dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                       RUNNER_TEMP=str(root / "runner"), WORKSPACE_PACKAGES=json.dumps(packages))
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step("Build x86_64 AVD runtime payloads")["run"]],
                                    cwd=root, env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            payloads = root / "runner/magicnet-x86"
            self.assertEqual({p.name for p in payloads.iterdir()}, {"magicnet-cli", "sing-box"})
            self.assertTrue(all(os.access(p, os.X_OK) for p in payloads.iterdir()))

    def test_host_core_is_built_and_validated_before_packaging(self):
        name = "Build host core for package routing checks"
        names = [step.get("name") for step in self.steps]
        self.assertLess(names.index(name), names.index("Build current MagicNet module"))
        for failure in (0, 17):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "scripts").mkdir()
                builder = root / "scripts/build-sing-box.sh"
                builder.write_text('#!/bin/sh\nset -eu\n[ "$1" = linux ] && [ "$2" = amd64 ]\n'
                                   'test "$FAIL_BUILD" = 0 || exit "$FAIL_BUILD"\n'
                                   'printf "#!/bin/sh\\nexit 0\\n" > "$3"\nchmod 0755 "$3"\n')
                builder.chmod(0o755)
                validator = root / "scripts/test-android-tun-proof.py"
                validator.write_text('import os, pathlib, sys\n'
                                     'assert sys.argv[1] == "--check-core"\n'
                                     'assert pathlib.Path(sys.argv[2]).is_file()\n'
                                     'assert os.access(sys.argv[2], os.X_OK)\n'
                                     'pathlib.Path("validated").touch()\n')
                pathfile = root / "github-path"
                env = dict(os.environ, RUNNER_TEMP=str(root / "runner"),
                           GITHUB_PATH=str(pathfile), FAIL_BUILD=str(failure))
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step(name)["run"]],
                                        cwd=root, env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, failure, result.stdout + result.stderr)
                if failure:
                    self.assertFalse(pathfile.exists(), "failed core must not reach package checks")
                    self.assertFalse((root / "validated").exists())
                else:
                    self.assertEqual(pathfile.read_text().strip(), str(root / "runner/magicnet-host"))
                    self.assertTrue((root / "validated").exists())

    def test_acceptance_passes_only_the_current_runtime_payloads(self):
        env = self.step("Install and benchmark MagicNet in KernelSU AVD")["env"]
        self.assertIn("MAGICNET_X86_CLI", env)
        self.assertIn("MAGICNET_X86_SINGBOX", env)
        self.assertNotIn("MAGICNET_X86_MCP", env)


    def test_sdk_bootstrap_precedes_all_android_consumers(self):
        names = [step.get("name") for step in self.steps]
        for consumer in ("Build application-UID network probe", "Create pristine Android 15 AVD", "Boot pristine Android 15 AVD"):
            self.assertLess(names.index("Locate Android SDK tools"), names.index(consumer))

    def test_sdk_bootstrap_exports_all_tools_without_global_path_assumptions(self):
        for layout in ("latest", "versioned"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                sdk = root / "sdk with spaces"
                versions = ["latest"] if layout == "latest" else ["9.0", "16.0"]
                for version in versions:
                    toolbin = sdk / "cmdline-tools" / version / "bin"
                    toolbin.mkdir(parents=True)
                    for tool in ("sdkmanager", "avdmanager"):
                        file = toolbin / tool
                        file.write_text("#!/bin/sh\nexit 0\n")
                        file.chmod(0o755)
                pathfile = root / "github-path"
                env = dict(os.environ, ANDROID_SDK_ROOT=str(sdk), ANDROID_HOME="/not/the/sdk", GITHUB_PATH=str(pathfile))
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step("Locate Android SDK tools")["run"]],
                                        env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(pathfile.read_text().splitlines(), [str(sdk / "cmdline-tools" / versions[-1] / "bin"), str(sdk / "platform-tools"), str(sdk / "emulator")])

    def test_sdk_bootstrap_fails_without_publishing_partial_paths(self):
        for failure in ("missing-directory", "missing-manager", "missing-avdmanager", "not-executable", "newline"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                sdk = root / ("sdk\ninjected-path" if failure == "newline" else "sdk")
                tools = sdk / "cmdline-tools/latest/bin"
                if failure != "missing-directory":
                    tools.mkdir(parents=True)
                    for tool in ("sdkmanager", "avdmanager"):
                        if (failure == "missing-manager" and tool == "sdkmanager") or (failure == "missing-avdmanager" and tool == "avdmanager"):
                            continue
                        file = tools / tool
                        file.write_text("#!/bin/sh\nexit 0\n")
                        file.chmod(0o644 if failure == "not-executable" else 0o755)
                pathfile = root / "github-path"
                env = dict(os.environ, ANDROID_SDK_ROOT=str(sdk), GITHUB_PATH=str(pathfile))
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step("Locate Android SDK tools")["run"]],
                                        env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertFalse(pathfile.exists(), "invalid SDK must not publish paths")


    def test_failed_sdk_install_does_not_publish_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / "sdk"
            tools = sdk / "cmdline-tools/latest/bin"
            tools.mkdir(parents=True)
            for tool in ("sdkmanager", "avdmanager"):
                file = tools / tool
                file.write_text("#!/bin/sh\nexit 19\n")
                file.chmod(0o755)
            pathfile = root / "github-path"
            env = dict(os.environ, ANDROID_SDK_ROOT=str(sdk), GITHUB_PATH=str(pathfile))
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step("Locate Android SDK tools")["run"]],
                                    env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 19, result.stdout + result.stderr)
            self.assertFalse(pathfile.exists())


PUBLIC_RUNTIME = ROOT / "scripts/android-public-runtime.py"


def load_public_runtime():
    spec = importlib.util.spec_from_file_location("acceptance_public_runtime", PUBLIC_RUNTIME)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def fixture_elf(machine, suffix=b""):
    value = bytearray(64)
    value[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<HH", value, 16, 3, machine)
    return bytes(value) + suffix


class RuntimeDevice:
    """An explicit device model: any unknown command fails instead of succeeding."""

    def __init__(self, runtime, expected):
        self.runtime = runtime
        self.expected = expected
        self.verified = False
        self.installed = False
        self.staged = False
        self.disabled = False
        self.removed = False
        self.late_load_on_reboot = False
        self.allow_mutations = True
        self.calls = []
        self.overrides = {}
        self.pid = "42"
        self.start = "123"
        self.boot = "01234567-0123-0123-0123-0123456789ab"
        self.pid_sequence = []
        self.start_sequence = []
        self.boot_sequence = []
        self.live_hash = expected['payload_sha256']['bin/sing-box']
        self.apk_path = '/data/app/test-probe/base.apk'
        self.hashes = {runtime.SIM.MOD + '/' + path: value
                       for section in ('payload_sha256', 'static_files_sha256')
                       for path, value in expected[section].items()}
        self.hashes[runtime.SIM.MOD + '/' + runtime.SIM.PROVENANCE] = expected['marker_sha256']
        self.hashes[runtime.SIM.KSUD] = expected['ksud_sha256']
        self.hashes[self.apk_path] = expected['probe_apk_sha256']
        self.status = {'schema': 1, 'ok': True, 'command': 'service.status', 'data': {
            'core': {'selected': 'sing-box', 'sing_box': {'process_state': 'running'}},
            'api': {'ready': True}, 'readiness': {'dataplane': True, 'overall': True},
            'transparent': {'configured_mode': 'tun', 'effective_mode': 'tun',
                            'effective_type': 'tun', 'transition': 'idle'}}}

    def _reply(self, channel, command, check):
        self.calls.append((channel, command))
        sim = self.runtime.SIM
        installer = f'MAGICNET_NONINTERACTIVE=1 {sim.KSUD} module install {sim.REMOTE}/module.zip'
        seed_commands = {f'cp {sim.REMOTE}/config.json {target}/.config/sing-box/config.json && '
                         f'chmod 0600 {target}/.config/sing-box/config.json && '
                         f'printf "validated\\n" >{target}/.config/sing-box/standalone-config && '
                         f'{target}/bin/sing-box check -c {target}/.config/sing-box/config.json'
                         for target in (sim.MOD, sim.STAGED)}
        mutations = seed_commands | {installer, 'mkdir -p ' + sim.REMOTE,
                                     'rm -f ' + sim.REMOTE + '/module.zip ' + sim.REMOTE + '/config.json'}
        if not self.allow_mutations and command in mutations:
            raise RuntimeError('fake_device_forbids_mutation')
        if (channel, command) in self.overrides:
            cp = self.overrides[channel, command]
        elif command.startswith('/system/bin/sha256sum '):
            paths = shlex.split(command)[1:]
            hashes = dict(self.hashes)
            for path in paths:
                if path.startswith('/proc/') and path.endswith('/exe'):
                    hashes[path] = self.live_hash
                if path.startswith(sim.STAGED + '/'):
                    original = sim.MOD + path[len(sim.STAGED):]
                    if original in hashes:
                        hashes[path] = hashes[original]
            cp = self.cp(''.join(hashes[path] + '  ' + path + '\n' for path in paths)
                         if all(path in hashes for path in paths) else '',
                         0 if all(path in hashes for path in paths) else 1)
        elif command == sim.BB + ' pidof sing-box':
            if self.pid_sequence:
                self.pid = self.pid_sequence.pop(0)
            cp = self.cp(self.pid + '\n')
        elif command.startswith('cat /proc/') and command.endswith('/stat'):
            pid = command.split('/')[2]
            if self.start_sequence:
                self.start = self.start_sequence.pop(0)
            cp = self.cp(pid + ' (sing-box) S ' + '1 ' * 18 + self.start + '\n')
        elif command == 'cat /proc/sys/kernel/random/boot_id':
            if self.boot_sequence:
                self.boot = self.boot_sequence.pop(0)
            cp = self.cp(self.boot + '\n')
        elif command.startswith('readlink /proc/') and command.endswith('/exe'):
            cp = self.cp(sim.MOD + '/bin/sing-box\n')
        elif command.startswith('cat /proc/') and command.endswith('/attr/current'):
            cp = self.cp(sim.KSU_DOMAIN + '\n')
        elif command.startswith(sim.BB + ' test /proc/') and command.endswith(' -ef ' + sim.MOD + '/bin/sing-box'):
            cp = self.cp()
        elif command == sim.MOD + '/cli --json service status':
            cp = self.cp(json.dumps(self.status))
        elif command == f'test ! -e {sim.MOD} && test ! -e {sim.STAGED}':
            cp = self.cp(rc=int(self.installed or self.staged))
        elif command == f'test -d {sim.MOD} && test ! -e {sim.STAGED} && test ! -e {sim.MOD}/disable && test ! -e {sim.MOD}/remove':
            cp = self.cp(rc=int(not self.installed or self.staged or self.disabled or self.removed))
        elif command == installer:
            self.staged = True
            cp = self.cp()
        elif command == f'if [ -d {sim.STAGED} ]; then echo {sim.STAGED}; else echo {sim.MOD}; fi':
            cp = self.cp((sim.STAGED if self.staged else sim.MOD) + '\n')
        elif command in seed_commands:
            cp = self.cp()
        else:
            responses = {
                'getprop ro.kernel.qemu': '1\n', 'getprop ro.product.cpu.abi': 'x86_64\n',
                'getenforce': 'Enforcing\n', 'id -u': '0\n', 'id -Z': sim.KSU_DOMAIN + '\n',
                sim.KSUD + ' debug version': 'Kernel Version: 32389\n',
                'cat /proc/sys/kernel/random/boot_id': self.boot + '\n',
                'readlink ' + sim.MOD + '/cli': 'bin/magicnet-cli\n',
                'ip link show magicnet0': '12: magicnet0: <UP> mtu 1400\n',
                'pm path best.lmm.magicnet.probe': 'package:' + self.apk_path + '\n',
                'cmd package list packages -U best.lmm.magicnet.probe': 'package:best.lmm.magicnet.probe uid:10123\n',
                'mkdir -p ' + sim.REMOTE: '',
                'rm -f ' + sim.REMOTE + '/module.zip ' + sim.REMOTE + '/config.json': '',
            }
            cp = self.cp(responses[command]) if command in responses else self.cp(rc=127)
        if check and cp.returncode:
            raise RuntimeError('fake_device_command_failed')
        return cp

    @staticmethod
    def cp(text='', rc=0):
        return subprocess.CompletedProcess(['fake-adb'], rc, text, '')

    def wait_boot(self):
        self.calls.append(('lifecycle', 'wait_boot'))

    def shell(self, command, *, timeout=30, check=True):
        return self._reply('shell', command, check)

    def kshell(self, command, *, timeout=30, check=True):
        if not self.verified:
            raise RuntimeError('fake_device_unverified')
        return self._reply('kshell', command, check)

    def identify(self):
        self.calls.append(('lifecycle', 'identify'))
        if not self.allow_mutations:
            raise RuntimeError('fake_device_forbids_mutation')
        if self.installed or self.staged:
            raise RuntimeError('fake_device_not_pristine')
        self.verified = True

    def run(self, *args, timeout=30):
        self.calls.append(('run', args))
        if not self.allow_mutations or args[0] != 'push' or args[-1] not in (
                self.runtime.SIM.REMOTE + '/module.zip', self.runtime.SIM.REMOTE + '/config.json'):
            raise RuntimeError('fake_device_unexpected_mutation')
        return self.cp()

    def reboot(self):
        self.calls.append(('lifecycle', 'reboot'))
        if not self.allow_mutations:
            raise RuntimeError('fake_device_forbids_mutation')
        self.installed, self.staged = True, False

    def ready(self):
        self.calls.append(('lifecycle', 'ready'))


class PublicRuntimeContract(unittest.TestCase):
    """Use real fixture archives and device replies; unknown facts never pass."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "MagicNet.zip"
        self.output = self.root / "report"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.payloads = {}
        for name in ("magicnet-cli", "sing-box", "jq", "yq", "ecapture", "proxylink"):
            path = self.tools / name
            path.write_bytes(fixture_elf(62, name.encode() + b"-current"))
            path.chmod(0o755)
            self.payloads[name] = path
        self.ksud = self.root / "ksud"
        self.ksud.write_bytes(fixture_elf(62, b"kernelsu-userspace"))
        self.probe = self.root / "probe.apk"
        self.probe.write_bytes(b"test-only-application-probe")
        self.source_entries = {
            "module.prop": b"id=MagicNet\nname=MagicNet\nversion=v1.5.22\nversionCode=22\n",
            "customize.sh": b"#!/system/bin/sh\nexport SKIPUNZIP=1\n",
            "service.sh": b"#!/system/bin/sh\nexit 0\n",
            "action.sh": b"#!/system/bin/sh\nexit 0\n",
            "boot-completed.sh": b"#!/system/bin/sh\nexit 0\n",
            "lib/magicnet/runtime.sh": b"runtime_fixture() { :; }\n",
            ".config/sing-box/config.json": b'{"outbounds":[{"type":"direct","tag":"direct"}]}\n',
        }
        for name in self.payloads:
            self.source_entries["bin/" + name] = fixture_elf(183, name.encode() + b"-release")
        # KAM's raw archive may dereference cli. The real installer rebuilds
        # it as a symlink, so the consumer must attest the canonical target.
        self.source_entries["cli"] = self.source_entries["bin/magicnet-cli"]
        self.archive_links = set()
        self.write_archive()
        self.env = {
            "MAGICNET_DISPOSABLE_AVD": "1", "ANDROID_SERIAL": "emulator-5554",
            "GITHUB_SHA": "a" * 40, "MAGICNET_MODULE_ZIP": str(self.source),
            "MAGICNET_KSUD_HOST": str(self.ksud),
            "MAGICNET_X86_CLI": str(self.payloads["magicnet-cli"]),
            "MAGICNET_X86_SINGBOX": str(self.payloads["sing-box"]),
            "MAGICNET_X86_TOOLS": str(self.tools),
            "MAGICNET_NETWORK_PROBE_APK": str(self.probe),
        }
        self.environment = patch.dict(os.environ, self.env)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.runtime = load_public_runtime()
        self.no_real_processes = patch.object(
            self.runtime.SIM.subprocess, 'run',
            side_effect=AssertionError('unexpected real subprocess in public-runtime fixture'))
        self.no_real_processes.start()
        self.addCleanup(self.no_real_processes.stop)

    def write_archive(self):
        with zipfile.ZipFile(self.source, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, content in self.source_entries.items():
                entry = zipfile.ZipInfo(name, (2026, 1, 2, 3, 4, 6))
                entry.create_system = 3
                kind = stat.S_IFLNK if name in self.archive_links else stat.S_IFREG
                entry.external_attr = (kind | 0o755) << 16
                archive.writestr(entry, content)

    def cp(self, text="", rc=0):
        return subprocess.CompletedProcess(["fake-adb"], rc, text, "")

    def test_manifest_changes_when_the_current_build_changes(self):
        baseline = self.runtime.manifest_for_current()
        changes = (
            (self.payloads["sing-box"], fixture_elf(62, b"another-core")),
            (self.ksud, fixture_elf(62, b"another-kernelsu")),
            (self.probe, b"another-probe-apk"),
        )
        for path, replacement in changes:
            with self.subTest(artifact=path.name):
                before = path.read_bytes()
                try:
                    path.write_bytes(replacement)
                    self.assertNotEqual(self.runtime.manifest_for_current(), baseline)
                finally:
                    path.write_bytes(before)
        self.source_entries["service.sh"] = b"#!/system/bin/sh\nexit 17\n"
        self.write_archive()
        self.assertNotEqual(self.runtime.manifest_for_current(), baseline)

    def test_manifest_rejects_wrong_or_unknown_source_identity(self):
        for value in ("", "local", "a" * 39, "A" * 40, "a" * 40 + "\n"):
            with self.subTest(value=value), patch.dict(os.environ, {"GITHUB_SHA": value}):
                with self.assertRaises((RuntimeError, ValueError)):
                    self.runtime.manifest_for_current()

    def test_manifest_cannot_accept_missing_or_foreign_runtime_payload(self):
        core = self.payloads["sing-box"]
        before = core.read_bytes()
        for value in (b"", fixture_elf(183, b"arm64"), b"#!/bin/sh\nexit 0\n"):
            with self.subTest(value=value[:8]):
                try:
                    core.write_bytes(value)
                    with self.assertRaises((RuntimeError, ValueError)):
                        self.runtime.manifest_for_current()
                finally:
                    core.write_bytes(before)
        optional = self.payloads["proxylink"]
        optional.unlink()
        with self.assertRaises((RuntimeError, ValueError, FileNotFoundError)):
            self.runtime.manifest_for_current()

    def device(self, *, installed=True):
        device = RuntimeDevice(self.runtime, self.runtime.manifest_for_current())
        device.installed = installed
        device.verified = True
        device.allow_mutations = not installed
        return device

    def write_offline(self, expected):
        path = self.root / 'simulation.json'
        value = {'schema': 1, 'status': 'passed',
                 'cases': [{'name': name, 'status': 'passed'} for name in self.runtime.SIM.PHASES],
                 'provenance': expected | {'kernelsu': {'mode': 'pinned-kernel-userspace-late-load'}}}
        path.write_text(json.dumps(value))
        return path, value

    def test_environment_requires_real_disposable_root_and_native_kernelsu(self):
        valid = self.device()
        self.runtime.guard_environment(valid, installed=True)
        failures = (
            ('shell', 'getprop ro.kernel.qemu', '0\n', 0),
            ('shell', 'getprop ro.product.cpu.abi', 'arm64-v8a\n', 0),
            ('shell', 'getenforce', 'Permissive\n', 0),
            ('shell', 'id -u', '2000\n', 0),
            ('shell', self.runtime.SIM.KSUD + ' debug version', 'Kernel Version: 0\n', 0),
            ('shell', self.runtime.SIM.KSUD + ' debug version', 'Kernel Version: 32389\n', 1),
            ('kshell', 'id -Z', 'u:r:shell:s0\n', 0),
            ('kshell', 'getenforce', 'unknown\n', 0),
        )
        for channel, command, text, rc in failures:
            with self.subTest(command=command, text=text):
                device = self.device()
                device.overrides[channel, command] = self.cp(text, rc)
                with self.assertRaises(RuntimeError):
                    self.runtime.guard_environment(device, installed=True)
                self.assertFalse(any(channel == 'run' or (channel == 'lifecycle' and command != 'wait_boot')
                                     for channel, command in device.calls))
        device = self.device()
        device.hashes[self.runtime.SIM.KSUD] = 'b' * 64
        with self.assertRaises(RuntimeError):
            self.runtime.guard_environment(device, installed=True)
        for installed, staged in ((False, True), (True, False)):
            with self.subTest(pristine_installed=installed, staged=staged):
                device = self.device(installed=installed)
                device.staged = staged
                with self.assertRaises(RuntimeError):
                    self.runtime.guard_environment(device, installed=False)
        device = self.device()
        device.staged = True
        with self.assertRaises(RuntimeError):
            self.runtime.guard_environment(device, installed=True)
        for marker in ('disabled', 'removed'):
            with self.subTest(marker=marker):
                device = self.device()
                setattr(device, marker, True)
                with self.assertRaises(RuntimeError):
                    self.runtime.guard_environment(device, installed=True)

    def test_runtime_attests_installed_alias_and_running_inode_not_just_disk(self):
        device = self.device()
        observed = self.runtime.observe_runtime(device, device.expected)
        self.assertTrue(observed['ready'])
        self.assertTrue(observed['identity_verified'])
        self.assertRegex(observed['generation_sha256'], r'^[a-f0-9]{64}$')
        self.assertNotIn('pid', observed)
        self.assertNotIn(device.boot, json.dumps(observed))
        # The source CLI copy has different bytes from both its x86 target and
        # installed symlink, yet a faithful install must remain a positive case.
        raw = hashlib.sha256(self.source_entries['cli']).hexdigest()
        self.assertNotEqual(raw, device.expected['payload_sha256']['bin/magicnet-cli'])
        core = self.runtime.SIM.MOD + '/bin/sing-box'
        failures = (
            ('readlink ' + self.runtime.SIM.MOD + '/cli', '/system/bin/sh\n', 0),
            ('readlink ' + self.runtime.SIM.MOD + '/cli', '', 1),
            ('readlink /proc/42/exe', core + ' (deleted)\n', 0),
            ('readlink /proc/42/exe', '/another/module/bin/sing-box\n', 0),
            (self.runtime.SIM.BB + ' test /proc/42/exe -ef ' + core, '', 1),
        )
        for command, text, rc in failures:
            with self.subTest(command=command, text=text):
                device = self.device()
                device.overrides['kshell', command] = self.cp(text, rc)
                with self.assertRaises(RuntimeError):
                    self.runtime.observe_runtime(device, device.expected)
        device = self.device()
        device.live_hash = 'b' * 64
        with self.assertRaises(RuntimeError):
            self.runtime.observe_runtime(device, device.expected)
        for path in ('bin/sing-box', 'bin/proxylink', 'service.sh', self.runtime.SIM.PROVENANCE):
            with self.subTest(changed_disk_path=path):
                device = self.device()
                device.hashes[self.runtime.SIM.MOD + '/' + path] = 'b' * 64
                with self.assertRaises(RuntimeError):
                    self.runtime.observe_runtime(device, device.expected)

    def test_runtime_refuses_unknown_hashes_and_incomplete_machine_status(self):
        device = self.device()
        path = self.runtime.SIM.KSUD
        for text, rc in (('', 0), ('b' * 64 + '  /wrong/path\n', 0),
                         ('not-a-hash  ' + path + '\n', 0),
                         (device.hashes[path] + '  ' + path + '\n', 1),
                         ((device.hashes[path] + '  ' + path + '\n') * 2, 0)):
            with self.subTest(text=text, rc=rc):
                device.overrides['shell', '/system/bin/sha256sum ' + path] = self.cp(text, rc)
                with self.assertRaises(RuntimeError):
                    self.runtime.read_hashes(device, [path], privileged=False)
        for path, value in (
            (('core', 'sing_box', 'process_state'), 'unknown'),
            (('core', 'selected'), 'other'), (('api', 'ready'), False),
            (('readiness', 'dataplane'), False), (('readiness', 'overall'), False),
            (('transparent', 'configured_mode'), 'ebpf'),
            (('transparent', 'effective_mode'), 'unknown'),
            (('transparent', 'effective_type'), 'unknown'),
            (('transparent', 'transition'), 'pending'),
        ):
            with self.subTest(path=path, value=value):
                device = self.device()
                target = device.status['data']
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(RuntimeError):
                    self.runtime.observe_runtime(device, device.expected)
        device = self.device()
        device.overrides['kshell', 'ip link show magicnet0'] = self.cp('', 1)
        with self.assertRaises(RuntimeError):
            self.runtime.observe_runtime(device, device.expected)

    def test_runtime_requires_exact_core_domain_and_application_identity(self):
        for text in (self.runtime.SIM.KSU_DOMAIN, self.runtime.SIM.KSU_DOMAIN + '\n',
                     self.runtime.SIM.KSU_DOMAIN + '\x00', self.runtime.SIM.KSU_DOMAIN + '\x00\r\n'):
            with self.subTest(legal_domain=text):
                device = self.device()
                device.overrides['kshell', 'cat /proc/42/attr/current'] = self.cp(text)
                self.assertTrue(self.runtime.observe_runtime(device, device.expected)['ready'])
        for text in ('u:r:shell:s0\n', self.runtime.SIM.KSU_DOMAIN + '\x00\x00\n',
                     self.runtime.SIM.KSU_DOMAIN + '\x00garbage\n', 'u:r:\x00su:s0\n',
                     self.runtime.SIM.KSU_DOMAIN + ' \n', self.runtime.SIM.KSU_DOMAIN + '\x00\n\n'):
            with self.subTest(illegal_domain=text):
                device = self.device()
                device.overrides['kshell', 'cat /proc/42/attr/current'] = self.cp(text)
                with self.assertRaises(RuntimeError):
                    self.runtime.observe_runtime(device, device.expected)
        for uid in ('0', '9999', 'unknown'):
            with self.subTest(uid=uid):
                device = self.device()
                command = 'cmd package list packages -U best.lmm.magicnet.probe'
                device.overrides['shell', command] = self.cp('package:best.lmm.magicnet.probe uid:' + uid + '\n')
                with self.assertRaises(RuntimeError):
                    self.runtime.observe_runtime(device, device.expected)
        device = self.device()
        device.hashes[device.apk_path] = 'b' * 64
        with self.assertRaises(RuntimeError):
            self.runtime.observe_runtime(device, device.expected)

    def test_generation_changes_cannot_pass_during_observation_or_handoff(self):
        for field, values in (('pid_sequence', ['42', '43']), ('start_sequence', ['123', '124']),
                              ('boot_sequence', ['01234567-0123-0123-0123-0123456789ab',
                                                 '11234567-0123-0123-0123-0123456789ab'])):
            with self.subTest(field=field):
                device = self.device()
                setattr(device, field, values)
                with self.assertRaises(RuntimeError):
                    self.runtime.observe_runtime(device, device.expected)
        device = self.device()
        before = self.runtime.observe_runtime(device, device.expected)
        device.pid = '43'  # Same boot and clock tick can contain two distinct PIDs.
        after = self.runtime.observe_runtime(device, device.expected)
        self.assertNotEqual(before['generation_sha256'], after['generation_sha256'])
        self.output.mkdir()
        self.runtime.atomic_report(self.output / 'prepared-runtime.json',
                                   {'schema': 1, 'scope': self.runtime.SCOPE, 'status': 'READY',
                                    'expected': device.expected, 'observation': before})
        with patch.object(self.runtime.SIM, 'Device', return_value=device):
            self.assertEqual(self.runtime.main(['verify', '--output', str(self.output)]), 1)

    def test_source_cli_copy_and_symlink_both_attest_the_installed_alias(self):
        for representation in ('copy', 'symlink'):
            with self.subTest(representation=representation):
                if representation == 'symlink':
                    self.source_entries['cli'] = b'bin/magicnet-cli'
                    self.archive_links.add('cli')
                    self.write_archive()
                device = self.device()
                self.assertTrue(self.runtime.observe_runtime(device, device.expected)['identity_verified'])

    def test_live_verification_allows_explicit_config_restart_without_trusting_old_readiness(self):
        device = self.device()
        previous = self.runtime.observe_runtime(device, device.expected)
        self.output.mkdir()
        path = self.output / 'prepared-runtime.json'
        self.runtime.atomic_report(path, {'schema': 1, 'scope': self.runtime.SCOPE, 'status': 'READY',
                                         'expected': device.expected, 'observation': previous})
        original = path.read_bytes()
        device.pid = '43'
        device.allow_mutations = False
        with patch.object(self.runtime.SIM, 'Device', return_value=device):
            with self.assertRaisesRegex(RuntimeError, 'handoff_generation_changed'):
                self.runtime.verify_prepared(self.output)
            actual_device, expected, observed = self.runtime.verify_prepared(
                self.output, strict_generation=False)
            self.assertIs(actual_device, device)
            self.assertEqual(expected, device.expected)
            self.assertNotEqual(previous['generation_sha256'], observed['generation_sha256'])
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(self.runtime.main(['verify-live', '--output', str(self.output)]), 0)
            device.hashes[self.runtime.SIM.MOD + '/bin/sing-box'] = 'b' * 64
            with self.assertRaisesRegex(RuntimeError, 'module_identity_mismatch'):
                self.runtime.verify_prepared(self.output, strict_generation=False)
            self.assertEqual(path.read_bytes(), original)

    def test_prepared_benchmark_uses_real_handoff_guards_again_after_tun_restore(self):
        spec = importlib.util.spec_from_file_location(
            'prepared_benchmark_integration', ROOT / 'scripts/android-network-benchmark.py')
        bench = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bench)
        self.output.mkdir()
        corpus = self.root / 'targets.tsv'
        corpus.write_text('fixture|test|https://fixture.invalid/|204\n')
        identity = {'ok': True, 'complete': True, 'uid': 10000, 'reason': 'identity'}
        response = {'ok': True, 'complete': True, 'uid': 10000, 'reason': 'https_response',
                    'rc': 0, 'http': 204, 'redirects': 0, 'received_bytes': 0, 'elapsed_ms': 25}
        for fault in ('none', 'payload', 'domain'):
            with self.subTest(fault=fault):
                device = self.device()
                previous = self.runtime.observe_runtime(device, device.expected)
                self.runtime.atomic_report(self.output / 'prepared-runtime.json',
                                           {'schema': 1, 'scope': self.runtime.SCOPE, 'status': 'READY',
                                            'expected': device.expected, 'observation': previous})
                device.pid = '43'  # Public subscription activation replaced the prepared process.
                device.allow_mutations = False

                def proof(transport):
                    reply = transport('id -Z')
                    self.assertEqual(reply.stdout.strip(), self.runtime.SIM.KSU_DOMAIN)
                    device.pid = '44'  # Sentinel restoration legitimately starts another generation.
                    if fault == 'payload':
                        device.hashes[self.runtime.SIM.MOD + '/bin/sing-box'] = 'b' * 64
                    elif fault == 'domain':
                        device.overrides['kshell', 'cat /proc/44/attr/current'] = self.cp('u:r:wrong:s0')
                    return {'status': 'verified', 'positive': True, 'reject': True,
                            'positive_after': True, 'restored': True}

                output = self.root / ('benchmark-' + fault)
                argv = ['benchmark', '--targets', str(corpus), '--output', str(output),
                        '--rounds', '1', '--verify-tun', '--root-mode', 'ksud',
                        '--prepared-runtime-dir', str(self.output)]
                with patch.object(self.runtime.SIM, 'Device', return_value=device), \
                        patch.object(bench, 'load_prepared_runtime', return_value=self.runtime), \
                        patch.object(bench, 'instrument', return_value=identity) as instrumentation, \
                        patch.object(bench, 'verify_tun_path', side_effect=proof), \
                        patch.object(bench, 'fetch_probe', return_value=response) as fetch, \
                        patch.object(bench, 'collect_processes', return_value={'processes': {}}), \
                        patch.object(sys, 'argv', argv):
                    result = bench.main()
                report = json.loads((output / 'results.json').read_text())
                instrumentation.assert_called_once_with(bench.COMPONENT, 'identity', 5)
                if fault == 'none':
                    self.assertEqual(result, 0)
                    self.assertEqual(report['verdict'], 'PASS')
                    self.assertEqual(fetch.call_count, 1)
                    observed = report['prepared_runtime']
                    self.assertNotEqual(observed['preflight']['generation_sha256'],
                                        observed['after_tun_restore']['generation_sha256'])
                else:
                    self.assertNotEqual(result, 0)
                    self.assertEqual(report['verdict'], 'INCOMPLETE')
                    fetch.assert_not_called()
                    self.assertEqual(report['prepared_runtime']['error_code'],
                                     'module_identity_mismatch' if fault == 'payload' else 'core_domain_unknown')

    def test_offline_pass_requires_every_phase_and_current_source(self):
        expected = self.runtime.manifest_for_current()
        path, original = self.write_offline(expected)
        self.runtime.validate_offline(path, expected)
        failures = []
        value = copy.deepcopy(original)
        value['cases'].pop()
        failures.append(value)
        for phase_status in ('failed', 'not_run', 'skipped'):
            value = copy.deepcopy(original)
            value['cases'][-1]['status'] = phase_status
            failures.append(value)
        value = copy.deepcopy(original)
        value['cases'][-1]['name'] = value['cases'][0]['name']
        failures.append(value)
        for key, replacement in (('source_sha', 'b' * 40), ('production_zip_sha256', 'b' * 64),
                                  ('payload_sha256', {}), ('kernelsu', {'mode': 'stock-lkm'})):
            value = copy.deepcopy(original)
            value['provenance'][key] = replacement
            failures.append(value)
        value = copy.deepcopy(original)
        value['schema'] = True
        failures.append(value)
        for index, value in enumerate(failures):
            with self.subTest(invalid_report=index):
                path.write_text(json.dumps(value))
                with self.assertRaises(RuntimeError):
                    self.runtime.validate_offline(path, expected)
        path.write_text('{"schema":1,"schema":1,"status":"passed"}')
        with self.assertRaises(RuntimeError):
            self.runtime.validate_offline(path, expected)

    def test_successful_prepare_installs_once_and_verify_is_read_only(self):
        device = self.device(installed=False)
        device.verified = False
        offline, _ = self.write_offline(device.expected)
        with patch.object(self.runtime.SIM, 'Device', return_value=device):
            self.assertEqual(self.runtime.main(['prepare', '--output', str(self.output),
                                               '--simulation-report', str(offline)]), 0)
            report = json.loads((self.output / 'prepared-runtime.json').read_text())
            self.assertEqual(report['status'], 'READY')
            self.assertEqual(sum(channel == 'kshell' and ' module install ' in command
                                 for channel, command in device.calls), 1)
            self.assertEqual(device.calls.count(('lifecycle', 'reboot')), 1)
            pushed = [args for channel, args in device.calls if channel == 'run']
            self.assertEqual(len(pushed), 2)
            self.assertTrue(all(args[-1].startswith(self.runtime.SIM.REMOTE + '/') for args in pushed))
            device.calls.clear()
            device.allow_mutations = False
            self.assertEqual(self.runtime.main(['verify', '--output', str(self.output)]), 0)
            self.assertFalse(any(channel == 'run' or (channel == 'lifecycle' and command != 'wait_boot')
                                 for channel, command in device.calls))
            self.assertEqual(json.loads((self.output / 'prepared-runtime.json').read_text()), report)

    def test_device_model_refuses_unrecognized_targets_and_all_read_only_writes(self):
        device = self.device(installed=False)
        unknown = (
            'MAGICNET_NONINTERACTIVE=1 /not/ksud module install /untrusted.zip',
            'cp ' + self.runtime.SIM.REMOTE + '/config.json /wrong/target; unrelated-command',
            'entirely-unknown-command',
        )
        for command in unknown:
            with self.subTest(command=command):
                self.assertNotEqual(device.kshell(command, check=False).returncode, 0)
        device.allow_mutations = False
        known_mutations = (
            f'MAGICNET_NONINTERACTIVE=1 {self.runtime.SIM.KSUD} module install {self.runtime.SIM.REMOTE}/module.zip',
            'mkdir -p ' + self.runtime.SIM.REMOTE,
            'rm -f ' + self.runtime.SIM.REMOTE + '/module.zip ' + self.runtime.SIM.REMOTE + '/config.json',
        ) + tuple(f'cp {self.runtime.SIM.REMOTE}/config.json {target}/.config/sing-box/config.json && '
                  f'chmod 0600 {target}/.config/sing-box/config.json && '
                  f'printf "validated\\n" >{target}/.config/sing-box/standalone-config && '
                  f'{target}/bin/sing-box check -c {target}/.config/sing-box/config.json'
                  for target in (self.runtime.SIM.MOD, self.runtime.SIM.STAGED))
        for command in known_mutations:
            with self.subTest(command=command), self.assertRaises(RuntimeError):
                device.kshell(command)
        with self.assertRaises(RuntimeError):
            device.run('push', str(self.source), self.runtime.SIM.REMOTE + '/module.zip')
        with self.assertRaises(RuntimeError):
            device.reboot()
        with self.assertRaises(RuntimeError):
            device.identify()

    def test_verify_refuses_stale_handoff_before_device_work(self):
        expected = self.runtime.manifest_for_current()
        self.output.mkdir()
        path = self.output / 'prepared-runtime.json'
        device = self.device()
        observation = self.runtime.observe_runtime(device, expected)
        original = {'schema': 1, 'scope': self.runtime.SCOPE, 'status': 'READY',
                    'expected': expected, 'observation': observation}
        for section, replacement in (
            ('source_sha', 'b' * 40), ('production_zip_sha256', 'b' * 64),
            ('fixture_zip_sha256', 'b' * 64), ('payload_sha256', {}),
            ('static_files_sha256', {}), ('marker_sha256', 'b' * 64),
            ('ksud_sha256', 'b' * 64), ('probe_apk_sha256', 'b' * 64),
        ):
            with self.subTest(section=section):
                record = copy.deepcopy(original)
                record['expected'][section] = replacement
                self.runtime.atomic_report(path, record)
                fresh = self.device()
                fresh.calls.clear()
                with patch.object(self.runtime.SIM, 'Device', return_value=fresh):
                    self.assertEqual(self.runtime.main(['verify', '--output', str(self.output)]), 1)
                self.assertEqual(fresh.calls, [], 'stale handoff must fail before device commands')
        for damaged in ('{}', '{"schema":1,"schema":1}', 'not-json'):
            path.write_text(damaged)
            fresh = self.device()
            with patch.object(self.runtime.SIM, 'Device', return_value=fresh):
                self.assertEqual(self.runtime.main(['verify', '--output', str(self.output)]), 1)
            self.assertEqual(fresh.calls, [])

    def test_failed_or_interrupted_prepare_invalidates_previous_ready(self):
        expected = self.runtime.manifest_for_current()
        offline, _ = self.write_offline(expected)
        self.output.mkdir()
        path = self.output / 'prepared-runtime.json'
        old = {'schema': 1, 'scope': self.runtime.SCOPE, 'status': 'READY',
               'expected': expected, 'observation': {'ready': True}}
        for failure in ('missing_offline', 'unknown_source', 'device_failure', 'interrupted'):
            with self.subTest(failure=failure):
                self.runtime.atomic_report(path, old)
                args = ['prepare', '--output', str(self.output)]
                if failure != 'missing_offline':
                    args += ['--simulation-report', str(offline)]
                device = self.device(installed=False)
                device.verified = False
                if failure == 'device_failure':
                    device.overrides['shell', 'getprop ro.kernel.qemu'] = self.cp('0\n')
                if failure == 'interrupted':
                    device.identify = Mock(side_effect=KeyboardInterrupt)
                env = {'GITHUB_SHA': 'unknown'} if failure == 'unknown_source' else {}
                with patch.dict(os.environ, env), patch.object(self.runtime.SIM, 'Device', return_value=device):
                    self.assertEqual(self.runtime.main(args), 1)
                self.assertEqual(json.loads(path.read_text())['status'], 'FAIL')
                self.assertFalse(any(channel == 'run' or (channel == 'lifecycle' and command == 'reboot')
                                     for channel, command in device.calls))

    def test_atomic_publication_preserves_complete_bytes_on_replace_failure(self):
        self.output.mkdir()
        path = self.output / 'prepared-runtime.json'
        value = {'schema': 1, 'status': 'INCOMPLETE'}
        self.runtime.atomic_report(path, value)
        before = path.read_bytes()
        with patch.object(self.runtime.os, 'replace', side_effect=OSError('replace unavailable')):
            with self.assertRaises(OSError):
                self.runtime.atomic_report(path, {'schema': 1, 'status': 'READY'})
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.output.iterdir()), [path], 'failed publication must clean its partial file')
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_two_process_lock_blocks_reset_and_releases_after_owner_death(self):
        expected = self.runtime.manifest_for_current()
        offline, _ = self.write_offline(expected)
        self.output.mkdir()
        path = self.output / 'prepared-runtime.json'
        self.runtime.atomic_report(path, {'schema': 1, 'status': 'READY', 'old': True})
        # This process owns the real helper lock while paused immediately
        # before device identity work. It never creates a real Device or ADB.
        child = '''import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("runtime_contract_child", sys.argv[1])
test = importlib.util.module_from_spec(spec)
spec.loader.exec_module(test)
runtime = test.load_public_runtime()
expected = runtime.manifest_for_current()
class PausedDevice(test.RuntimeDevice):
    def identify(self):
        print("OWNER_READY", flush=True)
        sys.stdin.readline()
        super().identify()
runtime.SIM.Device = lambda: PausedDevice(runtime, expected)
raise SystemExit(runtime.main(["prepare", "--output", sys.argv[2], "--simulation-report", sys.argv[3]]))
'''
        owner = subprocess.Popen([sys.executable, '-c', child, str(Path(__file__).resolve()),
                                  str(self.output), str(offline)], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(owner.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(5), 'lock owner did not reach its bounded barrier')
            self.assertEqual(owner.stdout.readline().strip(), 'OWNER_READY')
            record = path.read_bytes()
            self.assertEqual(json.loads(record)['status'], 'INCOMPLETE')
            lock_path = self.output / '.prepared-runtime.lock'
            inode = lock_path.stat().st_ino
            for operation in ('prepare', 'verify'):
                with self.subTest(operation=operation), patch.object(self.runtime.SIM, 'Device') as constructor:
                    self.assertEqual(self.runtime.main([operation, '--output', str(self.output)]), 2)
                    constructor.assert_not_called()
                    self.assertEqual(path.read_bytes(), record)
            owner.kill()
            owner.communicate(timeout=5)
            self.assertEqual(owner.returncode, -signal.SIGKILL)
            self.assertEqual(path.read_bytes(), record, 'killed owner cannot publish READY')
            with patch.object(self.runtime.SIM, 'Device') as constructor:
                self.assertEqual(self.runtime.main(['prepare', '--output', str(self.output)]), 1)
            self.assertEqual(json.loads(path.read_text())['status'], 'FAIL')
            self.assertEqual(lock_path.stat().st_ino, inode, 'the lock inode must remain stable')
        finally:
            if owner.poll() is None:
                owner.kill()
            owner.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()

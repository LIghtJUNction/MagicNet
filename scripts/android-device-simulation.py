#!/usr/bin/env python3
"""Destructive, offline lifecycle acceptance for a disposable KernelSU x86_64 AVD.

This runs real Android/ksud/module code, not command stubs. The test ZIP replaces
four ABI-specific executables and removes the build-only download caches already
excluded by the production component packager. A provenance record covers both.
A local standalone config is seeded after installation, before the first module
boot. No public proxy feed or subscription credential is used.
"""
from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import struct
import subprocess
import tempfile
import time
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
MOD = '/data/adb/modules/MagicNet'
STAGED = '/data/adb/modules_update/MagicNet'
REMOTE = '/sdcard/Download/MagicNet/ci-simulation'
KSUD = '/data/adb/ksud'
BB = '/data/adb/ksu/bin/busybox'
PROVENANCE = '.ci-fixture.json'
PAYLOADS = ('bin/magicnet-cli', 'bin/sing-box', 'bin/jq', 'bin/yq')
PHASES = (
    'environment', 'kernelsu-bootstrap', 'install-before-first-boot',
    'cold-boot', 'app-uid-tun-controls', 'invalid-config-rollback',
    'stop-cleanup', 'restart-idempotence', 'upgrade-preservation',
    'disable-reboot', 'enable-reboot', 'uninstall-reboot',
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fixture_config() -> dict:
    # The hosts resolver never contacts an external DNS provider. Background
    # Android requests outside this corpus are not internet-acceptance evidence.
    return {
        'log': {'level': 'info', 'timestamp': True},
        'dns': {'servers': [{'type': 'hosts', 'tag': 'fixture-dns',
                            'predefined': {'magicnet.test': ['198.18.0.42']}}],
                'final': 'fixture-dns'},
        'inbounds': [
            {'type': 'tun', 'tag': 'tun-in', 'interface_name': 'magicnet0',
             'address': ['172.19.0.1/30'], 'auto_route': True,
             'iproute2_table_index': 2022, 'exclude_uid': [0], 'stack': 'system'},
            {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': 7892},
            {'type': 'direct', 'tag': 'magicnet-dns-in', 'listen': '127.0.0.1', 'listen_port': 1053},
        ],
        'outbounds': [{'type': 'direct', 'tag': 'direct'}],
        'route': {'auto_detect_interface': True, 'final': 'direct', 'rules': [
            {'inbound': ['magicnet-dns-in'], 'action': 'hijack-dns'},
            {'port': 53, 'action': 'hijack-dns'},
        ]},
        'experimental': {'clash_api': {'external_controller': '127.0.0.1:9090'}},
    }


def elf_x86_64(data: bytes) -> bool:
    return (len(data) >= 64 and data[:6] == b'\x7fELF\x02\x01'
            and struct.unpack_from('<H', data, 16)[0] in (2, 3)
            and struct.unpack_from('<H', data, 18)[0] == 62)


def prepare_archive(source: Path, destination: Path, replacements: dict[str, Path]) -> dict:
    require(source.resolve() != destination.resolve(), 'never overwrite the production ZIP')
    require(set(replacements) == set(PAYLOADS), 'exactly four ABI replacements are required')
    for name, path in replacements.items():
        with path.open('rb') as stream:
            require(elf_x86_64(stream.read(64)), f'invalid x86_64 ELF payload: {name}')
    manifest = {'schema': 1, 'scope': 'disposable-x86_64-avd-only',
                'production_zip_sha256': digest(source),
                'source_sha': os.environ.get('GITHUB_SHA', 'local'),
                'payload_sha256': {name: digest(path) for name, path in replacements.items()},
                'excluded_build_cache_sha256': {},
                'replaced_aliases': {}}
    # Write atomically; failed fixture preparation must not leave a usable ZIP.
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = destination.with_name(destination.name + '.partial')
    try:
        with zipfile.ZipFile(source) as original, zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as output:
            entries = original.infolist()
            names = [item.filename for item in entries]
            require(len(names) == len(set(names)), 'duplicate ZIP members')
            require(PROVENANCE not in names, 'refuse to repackage an existing fixture')
            require(set(PAYLOADS).issubset(names), 'production ZIP is missing runtime payloads')
            require('customize.sh' in names and 'module.prop' in names, 'not a module ZIP')
            require(sum(item.file_size for item in entries) <= 512 * 1024 * 1024, 'ZIP exceeds fixture budget')
            for source_item in entries:
                # writestr mutates ZipInfo offsets; never alter input metadata.
                item = copy.copy(source_item)
                parts = PurePosixPath(item.filename).parts
                require(parts and not item.filename.startswith('/') and '..' not in parts
                        and '\\' not in item.filename and '\x00' not in item.filename
                        and item.filename.rstrip('/') == str(PurePosixPath(item.filename))
                        and ':' not in parts[0],
                        'unsafe ZIP member')
                require(not item.flag_bits & 1, 'encrypted ZIP members are unsupported')
                mode = item.external_attr >> 16
                data = original.read(item)
                # Match package-components.py's production cleanup: these are
                # downloaded build caches, not installed runtime executables.
                # Validate path/CRC first and record every omitted member. Do
                # not weaken the foreign-ELF rejection for any runtime path.
                if item.filename.startswith('.local/state/') and item.filename.endswith(('.asset', '.archive')):
                    require(stat.S_IFMT(mode) in (0, stat.S_IFREG), 'build cache must be a regular file')
                    manifest['excluded_build_cache_sha256'][item.filename] = hashlib.sha256(data).hexdigest()
                    continue
                if item.filename == 'cli' and data.startswith(b'\x7fELF'):
                    # Some ZIP producers dereference cli -> bin/magicnet-cli.
                    # Only a byte-identical alias of the original CLI can be
                    # rebound; a different ELF is not an alias and must fail.
                    require(not stat.S_ISLNK(mode), 'CLI alias must not disguise an ELF as a link')
                    require(data == original.read('bin/magicnet-cli'),
                            'CLI alias differs from canonical payload')
                    manifest['replaced_aliases']['cli'] = {
                        'target': 'bin/magicnet-cli',
                        'original_sha256': hashlib.sha256(data).hexdigest(),
                        'replacement_sha256': manifest['payload_sha256']['bin/magicnet-cli'],
                    }
                    data = replacements['bin/magicnet-cli'].read_bytes()
                    item.create_system = 3
                    item.external_attr = (stat.S_IFREG | 0o755) << 16
                elif item.filename == 'cli' and stat.S_ISLNK(mode):
                    require(data == b'bin/magicnet-cli', 'CLI alias has an unexpected link target')
                elif item.filename in replacements:
                    require(not stat.S_ISLNK(mode), 'runtime payload must be a regular file')
                    data = replacements[item.filename].read_bytes()
                    item.create_system = 3
                    item.external_attr = (stat.S_IFREG | 0o755) << 16
                elif data.startswith(b'\x7fELF'):
                    require(elf_x86_64(data[:64]), f'unreplaced foreign ELF: {item.filename}')
                output.writestr(item, data)
            marker = zipfile.ZipInfo(PROVENANCE)
            marker.create_system = 3
            marker.external_attr = (stat.S_IFREG | 0o644) << 16
            output.writestr(marker, json.dumps(manifest, sort_keys=True) + '\n')
        tmp.replace(destination)
    finally:
        tmp.unlink(missing_ok=True)
    return manifest | {'fixture_zip_sha256': digest(destination)}


def unique_keys(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'duplicate JSON key')
        value[key] = item
    return value


def decode_status(text: str, command: str) -> dict:
    value = json.loads(text, object_pairs_hook=unique_keys)
    require(isinstance(value, dict) and type(value.get('schema')) is int and value['schema'] == 1
            and value.get('ok') is True and value.get('command') == command
            and isinstance(value.get('data'), dict), 'invalid machine status envelope')
    return value['data']


def is_ready(text: str) -> bool:
    try:
        data = decode_status(text, 'service.status')
        return (data.get('core', {}).get('sing_box', {}).get('process_state') == 'running'
                and data.get('api', {}).get('ready') is True
                and data.get('readiness', {}).get('dataplane') is True
                and data.get('readiness', {}).get('overall') is True)
    except (ValueError, TypeError, AttributeError, RuntimeError):
        return False


def has_owned_network(text: str) -> bool:
    return bool(re.search(r'magicnet|sing-box|(?:lookup|table)\s+2022\b', text, re.I))


class Device:
    def __init__(self):
        require(os.environ.get('MAGICNET_DISPOSABLE_AVD') == '1', 'explicit disposable AVD opt-in required')
        self.serial = os.environ.get('ANDROID_SERIAL', '')
        require(re.fullmatch(r'emulator-[0-9]+', self.serial) is not None, 'explicit emulator serial required')
        self.verified = False

    def run(self, *args: str, timeout: float = 30, check: bool = True,
            input_text: str | None = None) -> subprocess.CompletedProcess:
        require(0 < timeout <= 300, 'invalid ADB deadline')
        argv = ['adb', '-s', self.serial, *args]
        try:
            cp = subprocess.run(argv, input=input_text, text=True, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            cp = subprocess.CompletedProcess(argv, 124, '', 'ADB deadline exceeded')
        except OSError:
            cp = subprocess.CompletedProcess(argv, 127, '', 'ADB unavailable')
        if check:
            require(cp.returncode == 0, f'ADB operation failed (exit {cp.returncode})')
        return cp

    def shell(self, command: str, timeout: float = 30, check: bool = True):
        return self.run('shell', command, timeout=timeout, check=check)

    def kshell(self, command: str, timeout: float = 30, check: bool = True):
        require(self.verified, 'device identity not verified')
        # v3.2.0 debug su takes a script on stdin, not a nonexistent -c argument.
        # The shell first enters the real kernel-granted ksu domain, then executes
        # with the same BusyBox standalone semantics as module lifecycle hooks.
        script = 'export KSU=true ASH_STANDALONE=1\nexec ' + BB + ' sh -c ' + shlex.quote(command) + '\n'
        return self.run('shell', '-T', KSUD + ' debug su', timeout=timeout,
                        check=check, input_text=script)

    def wait_boot(self, previous: str | None = None, timeout: float = 300):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            cp = self.shell('getprop sys.boot_completed; cat /proc/sys/kernel/random/boot_id',
                            timeout=min(5, remaining), check=False)
            lines = cp.stdout.split()
            if (cp.returncode == 0 and len(lines) == 2 and lines[0] == '1'
                    and re.fullmatch(r'[0-9a-f-]{36}', lines[1]) and lines[1] != previous):
                return
            time.sleep(min(1, max(0, deadline - time.monotonic())))
        raise RuntimeError('Android boot deadline exceeded')

    def root(self):
        self.run('root')
        self.run('wait-for-device', timeout=30)
        require(self.shell('id -u').stdout.strip() == '0', 'debuggable/rootable Android image required')

    def identify(self):
        self.wait_boot()
        # These read-only identity checks precede root, push, reboot or deletion.
        require(self.shell('getprop ro.kernel.qemu').stdout.strip() == '1', 'physical device rejected')
        require(self.shell('getprop ro.product.cpu.abi').stdout.strip() == 'x86_64', 'x86_64 AVD required')
        require(self.shell('getenforce').stdout.strip() == 'Enforcing', 'SELinux must remain Enforcing')
        self.verified = True
        self.root()
        self.shell(f'test ! -e {MOD} && test ! -e {STAGED}')

    def reboot(self):
        require(self.verified, 'device identity not verified')
        old = self.shell('cat /proc/sys/kernel/random/boot_id').stdout.strip()
        require(re.fullmatch(r'[0-9a-f-]{36}', old) is not None, 'missing old boot identity')
        self.run('reboot')
        self.wait_boot(previous=old)
        self.root()
        require(self.shell('getenforce').stdout.strip() == 'Enforcing', 'SELinux changed across reboot')

    def ready(self, timeout: float = 90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            cp = self.kshell(MOD + '/cli --json service status',
                             timeout=min(10, remaining), check=False)
            if cp.returncode == 0 and is_ready(cp.stdout):
                return
            time.sleep(min(2, max(0, deadline - time.monotonic())))
        raise RuntimeError('core process/API/TUN did not become ready')

    def stopped(self):
        # Observe the kernel, not just the CLI return code or a stale state file.
        self.kshell(f'test ! -e /sys/class/net/magicnet0 && '
                    f'{{ p=$({BB} pidof sing-box 2>/dev/null); rc=$?; '
                    f'test "$rc" = 1 && test -z "$p"; }}')
        for command in ('ip -4 rule show', 'ip -6 rule show', 'ip -4 route show table all',
                        'ip -6 route show table all', 'iptables-save', 'ip6tables-save'):
            cp = self.kshell(command, timeout=10)
            require(not has_owned_network(cp.stdout), 'module-owned network state survived stop')


class Report:
    def __init__(self, out: Path):
        self.out = out
        out.mkdir(parents=True, exist_ok=True)
        self.cases = []
        self.provenance = {}

    @contextlib.contextmanager
    def phase(self, name: str):
        require(name in PHASES and name not in [c['name'] for c in self.cases], 'invalid simulation phase')
        case = {'name': name, 'status': 'failed'}
        start = time.monotonic()
        self.cases.append(case)
        print(f'[device-simulation] {name}', flush=True)
        try:
            yield
            case['status'] = 'passed'
        except BaseException as error:
            case['reason'] = type(error).__name__ + ': ' + str(error)[:256]
            raise
        finally:
            case['seconds'] = round(time.monotonic() - start, 3)
            self.write()

    def complete(self) -> bool:
        return ({case['name'] for case in self.cases} == set(PHASES)
                and all(case['status'] == 'passed' for case in self.cases))

    def write(self):
        cases = {case['name']: case for case in self.cases}
        rows = [cases.get(name, {'name': name, 'status': 'not_run', 'seconds': 0}) for name in PHASES]
        passed = all(row['status'] == 'passed' for row in rows)
        data = {'schema': 1, 'status': 'passed' if passed else 'failed',
                'scope': 'Android-15-KernelSU-x86_64-standalone-TUN-fixture',
                'not_tested': ['ARM64 execution', 'OEM kernels', 'Play/GMS login/download',
                               'public proxy quality', 'eBPF dataplane', 'IPv6 packet forwarding'],
                'provenance': self.provenance, 'cases': rows}
        (self.out / 'simulation.json').write_text(json.dumps(data, indent=2) + '\n')
        suite = ET.Element('testsuite', name='Android KernelSU lifecycle', tests=str(len(rows)),
                           failures=str(sum(row['status'] != 'passed' for row in rows)))
        for row in rows:
            element = ET.SubElement(suite, 'testcase', name=row['name'], time=str(row['seconds']))
            if row['status'] != 'passed':
                ET.SubElement(element, 'failure', message=row.get('reason', 'phase was not executed'))
        ET.ElementTree(suite).write(self.out / 'simulation-junit.xml', encoding='utf-8', xml_declaration=True)
        lines = ['## Android / KernelSU simulation', '', f"Result: **{data['status']}**", '',
                 '| Phase | Result | Seconds |', '| --- | --- | --- |']
        lines += [f"| {r['name']} | {r['status']} | {r['seconds']} |" for r in rows]
        lines += ['', 'Required environment: real KernelSU + SELinux Enforcing. See phase results above.',
                  'Not evidence of ARM64/OEM/Play Store or IPv6 packet acceptance.', '']
        (self.out / 'simulation-summary.md').write_text('\n'.join(lines))


def load_script(name: str):
    path = ROOT / 'scripts' / (name + '.py')
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), path)
    require(spec is not None and spec.loader is not None, 'missing simulation dependency')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tun_controls(device: Device, out: Path, phase: str):
    proof = load_script('android-tun-proof')
    benchmark = load_script('android-network-benchmark')
    result = proof.verify(device.kshell, benchmark.instrument, benchmark.COMPONENT)
    (out / ('tun-controls-' + phase + '.json')).write_text(json.dumps(result, indent=2) + '\n')
    require(result.get('status') == 'verified' and all(result.get(k) is True for k in
            ('positive', 'reject', 'positive_after', 'restored')), 'app-UID TUN controls failed')


def invalid_config_rollback(device: Device):
    bad = MOD + '/.tmp/webui-payload/ci-invalid.json'
    save = f'{MOD}/cli config-editor save-file sing-box {bad}'
    try:
        # Positive control on the exact same path and command. A permission or
        # path-validation failure must not masquerade as malformed-JSON rejection.
        device.kshell(f'mkdir -p {MOD}/.tmp/webui-payload && '
                      f'cp {MOD}/.config/sing-box/config.json {bad} && chmod 0600 {bad}')
        device.kshell(save, timeout=90)
        device.ready()
        before = json.loads(device.kshell(MOD + '/cli config-editor get sing-box').stdout)
        device.kshell(f'printf "{{" >{bad}')
        result = device.kshell(save, timeout=90, check=False)
        require(result.returncode not in (0, 124, 127),
                'invalid configuration was accepted or validation unavailable')
        after = json.loads(device.kshell(MOD + '/cli config-editor get sing-box').stdout)
        require(before == after, 'invalid config changed the active configuration')
        device.ready()
    finally:
        device.kshell('rm -f ' + bad)


def diagnostics(device: Device, out: Path):
    if not device.verified:
        return
    # Diagnostics must not turn a failing test green or exhaust the job timeout.
    deadline = time.monotonic() + 25
    commands = {'logcat.txt': 'logcat -d -t 600', 'dmesg.txt': 'dmesg | tail -n 400',
                'service-status.json': MOD + '/cli --json service status',
                'service.log': f'tail -n 300 {MOD}/.log/service.log',
                'sing-box.log': f'tail -n 300 {MOD}/.log/sing-box.log'}
    for name, command in commands.items():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        cp = device.shell(command, timeout=min(5, remaining), check=False)
        (out / name).write_text((cp.stdout + cp.stderr)[-256000:])


def main() -> int:
    out = Path(os.environ.get('MAGICNET_ANDROID_REPORT_DIR', str(ROOT / 'artifacts/android-kernelsu')))
    report = Report(out)
    device = None
    try:
        with tempfile.TemporaryDirectory(prefix='magicnet-device-fixture-') as tmp:
            work = Path(tmp)
            with report.phase('environment'):
                device = Device()
                source = Path(os.environ.get('MAGICNET_MODULE_ZIP', str(ROOT / 'dist/MagicNet.zip')))
                keys = {'bin/magicnet-cli': 'MAGICNET_X86_CLI', 'bin/sing-box': 'MAGICNET_X86_SINGBOX'}
                replacements = {name: Path(os.environ[key]) for name, key in keys.items()}
                tools = Path(os.environ['MAGICNET_X86_TOOLS'])
                replacements.update({f'bin/{name}': tools / name for name in ('jq', 'yq')})
                archive = work / 'MagicNet-ci-x86_64.zip'
                report.provenance = prepare_archive(source, archive, replacements)
                device.identify()
            with report.phase('kernelsu-bootstrap'):
                device.shell(f'mkdir -p {REMOTE} /data/adb')
                device.run('push', os.environ['MAGICNET_KSUD_HOST'], REMOTE + '/ksud')
                device.shell(f'cp {REMOTE}/ksud {KSUD} && chmod 0755 {KSUD} && {KSUD} debug version')
                device.shell(KSUD + ' install', timeout=90)
                device.reboot()
                device.shell(f'test -x {BB}')
                require(device.kshell('id -Z').stdout.strip() == 'u:r:ksu:s0', 'real KernelSU SELinux domain required')
                require(device.kshell('getenforce').stdout.strip() == 'Enforcing', 'permissive KernelSU fixture rejected')
                version = device.kshell(KSUD + ' debug version').stdout.strip()
                require(re.fullmatch(r'Kernel Version: [1-9][0-9]*', version) is not None,
                        'KernelSU kernel interface did not report a positive version')
                report.provenance['kernelsu_version'] = version
                device.run('install', '-t', '-r', os.environ['MAGICNET_NETWORK_PROBE_APK'], timeout=90)
            with report.phase('install-before-first-boot'):
                device.run('push', str(archive), REMOTE + '/module.zip', timeout=120)
                device.kshell(f'MAGICNET_NONINTERACTIVE=1 {KSUD} module install {REMOTE}/module.zip', timeout=180)
                # Never manually move modules_update or run service.sh: ksud owns activation.
                target = device.kshell(f'if [ -d {STAGED} ]; then echo {STAGED}; else echo {MOD}; fi').stdout.strip()
                require(target in (STAGED, MOD), 'unexpected install destination')
                device.kshell(f'test -f {target}/module.prop && test -f {target}/{PROVENANCE}')
                for name, expected in report.provenance['payload_sha256'].items():
                    value = device.kshell(f'{BB} sha256sum {target}/{name}').stdout.split()
                    require(bool(value) and value[0] == expected, 'installer changed a fixture binary')
                config = work / 'config.json'
                config.write_text(json.dumps(fixture_config()) + '\n')
                device.run('push', str(config), REMOTE + '/config.json')
                device.kshell(f'cp {REMOTE}/config.json {target}/.config/sing-box/config.json && '
                              f'chmod 0600 {target}/.config/sing-box/config.json && '
                              f'printf "validated\\n" >{target}/.config/sing-box/standalone-config && '
                              f'{target}/bin/sing-box check -c {target}/.config/sing-box/config.json')
            with report.phase('cold-boot'):
                device.reboot()
                device.ready()
                device.kshell(f'p=$({BB} pidof sing-box) && test -n "$p" && '
                              'for n in $p; do test "$(cat /proc/$n/attr/current)" = u:r:ksu:s0 || exit 1; done')
            with report.phase('app-uid-tun-controls'):
                tun_controls(device, out, 'app-uid-tun-controls')
            with report.phase('invalid-config-rollback'):
                invalid_config_rollback(device)
            with report.phase('stop-cleanup'):
                device.kshell(MOD + '/cli service stop sing-box', timeout=90)
                device.stopped()
            with report.phase('restart-idempotence'):
                device.kshell(MOD + '/cli service start sing-box', timeout=90)
                device.ready()
                for _ in range(2):
                    device.kshell(MOD + '/cli service restart sing-box', timeout=90)
                    device.ready()
                    pids = device.kshell(BB + ' pidof sing-box').stdout.split()
                    require(len(pids) == 1, 'restart left duplicate core processes')
                tun_controls(device, out, 'restart-idempotence')
            with report.phase('upgrade-preservation'):
                marker = hashlib.sha256(os.urandom(32)).hexdigest()
                device.kshell(f'printf %s {marker} >{MOD}/.config/magicnet/ci-upgrade-marker')
                device.kshell(f'MAGICNET_NONINTERACTIVE=1 {KSUD} module install {REMOTE}/module.zip', timeout=180)
                # Do NOT re-seed the config/marker after upgrade; that would mask data loss.
                device.reboot()
                require(device.kshell(f'cat {MOD}/.config/magicnet/ci-upgrade-marker').stdout == marker, 'upgrade lost user config')
                device.ready()
                tun_controls(device, out, 'upgrade-preservation')
            with report.phase('disable-reboot'):
                device.kshell(KSUD + ' module disable MagicNet')
                device.reboot()
                device.stopped()
            with report.phase('enable-reboot'):
                device.kshell(KSUD + ' module enable MagicNet')
                device.reboot()
                device.ready()
                tun_controls(device, out, 'enable-reboot')
            with report.phase('uninstall-reboot'):
                device.kshell(KSUD + ' module uninstall MagicNet')
                device.reboot()
                device.kshell(f'test ! -e {MOD} && test ! -e {STAGED}')
                device.stopped()
                device.kshell('rm -rf ' + REMOTE)
        require(report.complete(), 'simulation phases incomplete')
        return 0
    except (Exception, KeyboardInterrupt) as error:
        print('[device-simulation] FAILED: ' + type(error).__name__ + ': ' + str(error)[:256], flush=True)
        return 1
    finally:
        report.write()
        if device is not None:
            try:
                diagnostics(device, out)
            except (OSError, RuntimeError):
                print('[device-simulation] diagnostics incomplete', flush=True)
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with open(summary, 'a') as stream:
                stream.write((out / 'simulation-summary.md').read_text())


if __name__ == '__main__':
    raise SystemExit(main())

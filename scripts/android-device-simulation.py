#!/usr/bin/env python3
"""Destructive, offline lifecycle acceptance for a disposable KernelSU x86_64 AVD.

This runs real Android/ksud/module code, not command stubs. The test ZIP replaces
all bundled ABI-specific executables and removes the build-only download caches already
excluded by the production component packager. A provenance record covers both.
A local standalone config is seeded after installation, before the first module
boot. No public proxy feed or subscription credential is used.
"""
from __future__ import annotations

import base64
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
# Upstream late-load always copies current_exe onto KSUD. Running that path
# returns ETXTBSY, so lifecycle activation must start from a different file.
KSUD_LAUNCH = '/data/adb/ksu/ci-ksud'
# Pinned KernelSU v3.2.0 sets KERNEL_SU_DOMAIN to "su", so granted tasks
# run as u:r:su:s0. The older u:r:ksu:s0 type is not created by this kernel.
KSU_DOMAIN = 'u:r:su:s0'
BB = '/data/adb/ksu/bin/busybox'
PROVENANCE = '.ci-fixture.json'
PAYLOADS = ('bin/magicnet-cli', 'bin/sing-box', 'bin/jq', 'bin/yq')
# Optional components must be replaced when present, never silently omitted.
OPTIONAL_PAYLOADS = ('bin/ecapture', 'bin/proxylink')
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
    require(set(PAYLOADS) <= set(replacements) <= set(PAYLOADS + OPTIONAL_PAYLOADS),
            'required ABI replacements missing or unknown replacement supplied')
    for name, path in replacements.items():
        with path.open('rb') as stream:
            require(elf_x86_64(stream.read(64)), f'invalid x86_64 ELF payload: {name}')
    manifest = {'schema': 1, 'scope': 'disposable-x86_64-avd-only',
                'production_zip_sha256': digest(source),
                'source_sha': os.environ.get('GITHUB_SHA', 'local'),
                'payload_sha256': {name: digest(path) for name, path in replacements.items()},
                'excluded_build_cache_sha256': {},
                'compatibility_aliases': {}}
    # Write atomically; failed fixture preparation must not leave a usable ZIP.
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = destination.with_name(destination.name + '.partial')
    try:
        with zipfile.ZipFile(source) as original, zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as output:
            entries = original.infolist()
            names = [item.filename for item in entries]
            require(len(names) == len(set(names)), 'duplicate ZIP members')
            require(PROVENANCE not in names, 'refuse to repackage an existing fixture')
            require(set(replacements).issubset(names), 'production ZIP is missing runtime payloads')
            require(set(names).intersection(OPTIONAL_PAYLOADS) <= set(replacements),
                    'bundled optional tool has no ABI replacement')
            require('customize.sh' in names and 'module.prop' in names, 'not a module ZIP')
            require(sum(item.file_size for item in entries) <= 512 * 1024 * 1024, 'ZIP exceeds fixture budget')
            for source_item in entries:
                # ZipFile.writestr mutates its ZipInfo; keep input metadata usable
                # when the compatibility alias is checked after its target.
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
                if item.filename == 'cli':
                    # KAM can dereference the tracked cli -> bin/magicnet-cli
                    # symlink in its raw ZIP. Accept only that exact alias,
                    # never arbitrary same-architecture/unknown executables.
                    target = 'bin/magicnet-cli'
                    if stat.S_ISLNK(mode):
                        require(data == target.encode(), 'unexpected CLI symlink target')
                        # BusyBox unzip requires symlink payloads to be stored.
                        item.compress_type = zipfile.ZIP_STORED
                        representation = 'symlink'
                    else:
                        require(stat.S_IFMT(mode) in (0, stat.S_IFREG)
                                and data.startswith(b'\x7fELF')
                                and data == original.read(target),
                                'CLI alias differs from the canonical executable')
                        data = replacements[target].read_bytes()
                        item.create_system = 3
                        item.external_attr = (stat.S_IFREG | 0o755) << 16
                        representation = 'executable-copy'
                    manifest['compatibility_aliases']['cli'] = {
                        'target': target, 'representation': representation,
                        'source_sha256': hashlib.sha256(original.read(item.filename)).hexdigest(),
                        'fixture_sha256': hashlib.sha256(data).hexdigest(),
                    }
                    output.writestr(item, data)
                    continue
                if item.filename in replacements:
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


# Exercise the same regex operations as startup using public, synthetic input.
# A crash is a broken runtime, never a legitimate "no nodes" result.
NODE_PATTERN = r'"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks|wireguard|tuic|anytls|socks)"'
CONFIG_PATTERNS = {'nodes': NODE_PATTERN, 'inbounds': r'"inbounds"[[:space:]]*:',
                   'outbounds': r'"outbounds"[[:space:]]*:'}


def busybox_regex_cases():
    sample = '{"inbounds": [], "outbounds": [{"type": "socks", "tag": "测试"}]}\n'
    cases = [(name, ['grep', '-Eq', pattern], sample, 0, '')
             for name, pattern in CONFIG_PATTERNS.items()]
    cases.extend([
        ('nodes_absent', ['grep', '-Eq', NODE_PATTERN], '{"type":"direct"}\n', 1, ''),
        ('awk_trimmed_lines', ['awk',
         '{ line=$0; ws=" \\t\\r\\n\\v\\f"; '
         'while (length(line) && index(ws, substr(line, 1, 1))) line=substr(line, 2); '
         'while (length(line) && index(ws, substr(line, length(line), 1))) line=substr(line, 1, length(line)-1); '
         'if (line == "" || substr(line, 1, 1) == "#") next; '
         'if (!seen[line]++) print line }'],
         ' \n# comment\n  # comment\n 测试 \n测试\n', 0, '测试\n'),
        ('awk_preserved_lines', ['awk',
         '{ trimmed=$0; ws=" \\t\\r\\n\\v\\f"; '
         'while (length(trimmed) && index(ws, substr(trimmed, 1, 1))) trimmed=substr(trimmed, 2); '
         'while (length(trimmed) && index(ws, substr(trimmed, length(trimmed), 1))) trimmed=substr(trimmed, 1, length(trimmed)-1); '
         'if (trimmed == "" || substr(trimmed, 1, 1) == "#") next; '
         'if (!seen[$0]++) print }'],
         ' \n# comment\n  # comment\n 测试 \n测试\n 测试 \n', 0, ' 测试 \n测试\n'),
        ('awk_user_ids', ['awk',
         'index($0, "UserInfo{") { value=substr($0, index($0, "UserInfo{")+9); '
         'colon=index(value, ":"); if (colon) { value=substr(value, 1, colon-1); '
         'if (value ~ /^[0-9]+$/) print value } }'],
         'Users:\n UserInfo{0:测试:13}\n UserInfo{10:工作:30}\n', 0, '0\n10\n'),
    ])
    return cases


def system_sed_cases():
    # Only ASCII module metadata uses sed in this pre-install check. UTF-8
    # lists/user names use the actual awk operations above; JSON uses jq and
    # is checked on the installed module, not with a regex tag extractor.
    return [
        ('sed_lines', ['/^[[:space:]]*$/d; /^[[:space:]]*#/d'],
         ' \n# comment\n  # comment\nversion=v1.5.18\n', 0, 'version=v1.5.18\n'),
        ('sed_capture', ['-n', 's/^version=//p'],
         'id=MagicNet\nversion=v1.5.18\n', 0, 'v1.5.18\n'),
    ]


def bounded_exit_code(value):
    # subprocess uses negative signal numbers; Android shells commonly use 128+signal.
    return value if type(value) is int and -255 <= value <= 255 else None


def adb_result_kind(result: subprocess.CompletedProcess) -> str:
    # Keep only normalized diagnostics. ADB can include a serial or an argv in
    # its raw output; neither belongs in the public acceptance report.
    output = (result.stdout + '\n' + result.stderr).lower()
    if ('cannot run as root' in output or 'root access is disabled' in output
            or 'permission denied' in output or 'operation not permitted' in output):
        return 'root_denied'
    if 'unauthorized' in output or 'access denied' in output:
        return 'authorization_denied'
    if result.returncode == 0:
        return 'success'
    if result.returncode == 124:
        return 'timeout'
    if result.returncode == 127:
        return 'unavailable'
    if result.returncode != 1:
        return 'command_failed'
    patterns = (
        (r'device offline(?: \((?:no transport|transport offline)\))?', 'transport_offline'),
        (r"device(?: '[^'\r\n]{1,80}')? not found|no devices(?:/emulators)? found",
         'transport_missing'),
        (r'device disconnected|connection reset by peer|connection closed|transport is closing|closed',
         'transport_disconnected'),
        (r"(?:unexpected )?eof|protocol fault \((?:couldn't read status(?: length| message)?|no status)\)"
         r'(?:: (?:success|eof|closed|connection reset by peer))?', 'transport_eof'),
    )
    kinds = []
    for line in output.splitlines():
        line = line.strip()
        if not line or line in ('restarting adbd as root', 'adbd is already running as root',
                                '* daemon started successfully'):
            continue
        if re.fullmatch(r'\* daemon not running; starting now at tcp:[0-9]+', line):
            continue
        for pattern, kind in patterns:
            if re.fullmatch(r'(?:adb: )?(?:error: )?(?:unable to connect for root: )?(?:'
                            + pattern + ')', line):
                kinds.append(kind)
                break
        else:
            # A known transport line must not swallow an accompanying unknown
            # error. Keep the failed request failed until its cause is understood.
            return 'command_failed'
    return kinds[0] if kinds else 'command_failed'


class Device:
    def __init__(self):
        require(os.environ.get('MAGICNET_DISPOSABLE_AVD') == '1', 'explicit disposable AVD opt-in required')
        self.serial = os.environ.get('ANDROID_SERIAL', '')
        require(re.fullmatch(r'emulator-[0-9]+', self.serial) is not None, 'explicit emulator serial required')
        self.verified = False
        self.late_load_on_reboot = False
        self.busybox_checks = []
        self.root_checks = []
        self.stop_checks = []
        self.boot_log = ROOT / 'artifacts/android-kernelsu/emulator.log'

    def boot_failure(self, offset: int = 0) -> str | None:
        # Read bounded host-side evidence even when early init cannot expose ADB.
        try:
            with self.boot_log.open('rb') as stream:
                size = stream.seek(0, 2)
                stream.seek(max(offset if offset <= size else 0, size - 262144))
                log = stream.read(262144)
        except OSError:
            return None
        if (b'disagrees about version of symbol module_layout' in log
                and b'Failed to insmod' in log):
            return 'kernel_module_abi_mismatch'
        if log.count(b'init: InitFatalReboot:') >= 2:
            return 'early_init_reboot_loop'
        return None

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
            operation = args[0] if args and args[0] in ('shell', 'root', 'reboot', 'wait-for-device', 'push', 'install') else 'operation'
            require(cp.returncode == 0, f'ADB {operation} failed (exit {cp.returncode})')
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
        # Earlier lifecycle boots must not poison the observation of this reboot.
        try:
            offset = self.boot_log.stat().st_size if previous is not None else 0
        except OSError:
            offset = 0
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            failure = self.boot_failure(offset)
            if failure:
                raise RuntimeError(f'Android boot failed: {failure}')
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
        # The first request can race adbd's boot-time restart too. Bound the
        # entire operation, and retry only an explicitly observed transport loss.
        deadline = time.monotonic() + 30
        evidence = {'status': 'failed', 'root_requests': [], 'wait_attempts': 0,
                    'identity_attempts': 0}
        require(len(self.root_checks) < 16, 'ADB root history budget exceeded')
        self.root_checks.append(evidence)
        request_needed = True
        request_accepted = False
        # wait-for-device can observe the old transport before adb root exits
        # and restarts adbd. Verify the new connection with a read-only probe;
        # lifecycle mutations must never be replayed to conceal this race.
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if request_needed:
                requested = self.run('root', timeout=min(5, remaining), check=False)
                kind = adb_result_kind(requested)
                evidence['root_requests'].append({'exit_code': bounded_exit_code(requested.returncode),
                                                 'diagnostic': kind,
                                                 'stderr_present': bool(requested.stderr)})
                require(kind != 'root_denied',
                        f'ADB root refused (exit {requested.returncode}; diagnostic root_denied)')
                require(kind == 'success' or kind.startswith('transport_'),
                        f'ADB root failed (exit {requested.returncode}; diagnostic {kind})')
                request_accepted = kind == 'success'
                request_needed = False
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            evidence['wait_attempts'] += 1
            connected = self.run('wait-for-device', timeout=min(5, remaining), check=False)
            kind = adb_result_kind(connected)
            require(kind == 'success' or kind == 'timeout' or kind.startswith('transport_'),
                    f'ADB reconnect failed (exit {connected.returncode}; diagnostic {kind})')
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if connected.returncode == 0:
                evidence['identity_attempts'] += 1
                identity = self.shell('id -u', timeout=min(5, remaining), check=False)
                kind = adb_result_kind(identity)
                require(kind == 'success' or kind == 'timeout' or kind.startswith('transport_'),
                        f'ADB root identity failed (exit {identity.returncode}; diagnostic {kind})')
                if identity.returncode == 0:
                    uid = identity.stdout.strip()
                    require(re.fullmatch(r'[0-9]+', uid) is not None, 'ADB root identity is invalid')
                    if uid == '0':
                        require(time.monotonic() < deadline, 'ADB root identity arrived after deadline')
                        evidence['status'] = 'passed'
                        return
                    # A lost reply may still have applied root. Only reissue
                    # after a real non-root observation, never after acceptance.
                    request_needed = not request_accepted
            time.sleep(min(0.25, max(0, deadline - time.monotonic())))
        raise RuntimeError('debuggable/rootable Android image did not reconnect before deadline')

    def identify(self):
        self.wait_boot()
        # These read-only identity checks precede root, push, reboot or deletion.
        require(self.shell('getprop ro.kernel.qemu').stdout.strip() == '1', 'physical device rejected')
        require(self.shell('getprop ro.product.cpu.abi').stdout.strip() == 'x86_64', 'x86_64 AVD required')
        require(self.shell('getenforce').stdout.strip() == 'Enforcing', 'SELinux must remain Enforcing')
        self.verified = True
        self.root()
        self.shell(f'test ! -e {MOD} && test ! -e {STAGED}')

    def check_busybox(self, stage: str, *, activated: bool):
        require(self.verified, 'device identity not verified')
        require(stage in ('extracted', 'activated'), 'invalid BusyBox probe stage')
        require(len(self.busybox_checks) < 16, 'BusyBox probe history budget exceeded')
        evidence = {'stage': stage, 'status': 'failed', 'sha256': None,
                    'version': None, 'checks': {}}
        self.busybox_checks.append(evidence)  # Keep partial evidence on failure.
        deadline = time.monotonic() + 20

        def run(command, *, runtime=False):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return subprocess.CompletedProcess([], 124, '', '')
            if runtime and activated:
                return self.kshell(command, timeout=min(3, remaining), check=False)
            if runtime:
                command = 'ASH_STANDALONE=1 ' + BB + ' sh -c ' + shlex.quote(command)
            return self.shell(command, timeout=min(3, remaining), check=False)

        hashed = run('/system/bin/sha256sum ' + BB)
        evidence['hash_exit_code'] = bounded_exit_code(hashed.returncode)
        fields = hashed.stdout.split()
        if hashed.returncode == 0 and len(fields) == 2 and fields[1] == BB and re.fullmatch(r'[0-9a-f]{64}', fields[0]):
            evidence['sha256'] = fields[0]
        version = run(BB + ' --help', runtime=True)
        evidence['version_exit_code'] = bounded_exit_code(version.returncode)
        match = re.match(r'BusyBox v([0-9]+(?:\.[0-9]+){2,3})(?:\s|[-(])', (version.stdout[:128] + version.stderr[:128]))
        if version.returncode == 0 and match:
            evidence['version'] = match[1]
        for name, args, sample, expected_exit, expected_output in busybox_regex_cases():
            command = ('printf %s ' + shlex.quote(sample) + ' | ' + BB + ' '
                       + ' '.join(shlex.quote(arg) for arg in args))
            result = run(command, runtime=True)
            evidence['checks'][name] = {
                'exit_code': bounded_exit_code(result.returncode),
                'expected_exit_code': expected_exit,
                'output_matches': result.stdout == expected_output,
                'provider': 'kernelsu_busybox',
            }
        evidence['sed_provider'] = '/system/bin/sed'
        for name, args, sample, expected_exit, expected_output in system_sed_cases():
            command = ('test -x /system/bin/sed && printf %s ' + shlex.quote(sample)
                       + ' | /system/bin/sed ' + ' '.join(shlex.quote(arg) for arg in args))
            result = run(command, runtime=True)
            evidence['checks'][name] = {
                'exit_code': bounded_exit_code(result.returncode),
                'expected_exit_code': expected_exit,
                'output_matches': result.stdout == expected_output,
                'provider': 'android_system_sed',
            }
        valid = (evidence['sha256'] is not None and evidence['version'] is not None
                 and all(item['exit_code'] == item['expected_exit_code'] and item['output_matches']
                         for item in evidence['checks'].values()))
        if valid:
            evidence['status'] = 'passed'
        require(valid, 'Module shell tool preflight failed; see busybox_checks evidence')

    def late_load_kernelsu(self) -> dict:
        require(self.verified, 'device identity not verified')
        require(self.shell('getenforce').stdout.strip() == 'Enforcing',
                'SELinux must be Enforcing before KernelSU userspace activation')
        # The CI AVD boots a pinned API35 x86_64 kernel with KernelSU already
        # integrated. Do not attempt to inject an LKM into an arbitrary stock
        # emulator kernel: current x86_64 KernelSU requires kernel-side syscall
        # hardening compatibility patches. late-load is still useful here to
        # install userspace and execute KernelSU lifecycle stages after each boot.
        before = self.shell(KSUD + ' debug version', timeout=30, check=False).stdout.strip()
        require(re.fullmatch(r'Kernel Version: [1-9][0-9]*', before) is not None,
                'pinned KernelSU kernel is not active before userspace late-load')
        self.shell('mkdir -p /data/adb/ksu/bin')
        self.shell(KSUD + ' debug extract-binary busybox ' + BB, timeout=30)
        self.shell(f'chmod 0755 {BB} && {BB} --install -s /data/adb/ksu/bin')
        self.check_busybox('extracted', activated=False)
        command = 'PATH=/data/adb/ksu/bin:/system/bin:/system/xbin ' + KSUD
        current = self.shell(command + ' boot-info current-kmi', timeout=30).stdout.strip()
        require(bool(current), 'KernelSU could not determine the pinned AVD kernel KMI')
        self.shell(f'cp {KSUD} {KSUD_LAUNCH} && chmod 0755 {KSUD_LAUNCH}')
        launch = 'PATH=/data/adb/ksu/bin:/system/bin:/system/xbin ' + KSUD_LAUNCH
        self.shell(launch + ' late-load', timeout=120)
        version = self.shell(KSUD + ' debug version', timeout=30).stdout.strip()
        require(re.fullmatch(r'Kernel Version: [1-9][0-9]*', version) is not None,
                'KernelSU userspace late-load lost the kernel interface')
        self.shell(f'test -x {BB}')
        require(self.kshell('id -Z').stdout.strip() == KSU_DOMAIN,
                'real KernelSU SELinux domain required after userspace late-load')
        require(self.kshell('getenforce').stdout.strip() == 'Enforcing',
                'KernelSU userspace late-load changed SELinux enforcement')
        self.check_busybox('activated', activated=True)
        self.late_load_on_reboot = True
        return {'mode': 'pinned-kernel-userspace-late-load', 'kmi': current,
                'kernel_version': version}

    def reboot(self):
        require(self.verified, 'device identity not verified')
        old = self.shell('cat /proc/sys/kernel/random/boot_id').stdout.strip()
        require(re.fullmatch(r'[0-9a-f-]{36}', old) is not None, 'missing old boot identity')
        self.run('reboot')
        self.wait_boot(previous=old)
        self.root()
        require(self.shell('getenforce').stdout.strip() == 'Enforcing', 'SELinux changed across reboot')
        if self.late_load_on_reboot:
            self.late_load_kernelsu()

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

    def stop_service(self):
        # Never replay a lifecycle mutation to hide a failure. Keep only a
        # bounded exit code; command output can contain private configuration.
        result = self.kshell(MOD + '/cli service stop sing-box', timeout=90, check=False)
        error_kinds = {
            'prepare network for core stop:': 'network_prepare',
            'finalize stopped network:': 'network_finalize',
            'read sing-box candidate ': 'core_identity',
            'managed sing-box process set changed': 'core_generation',
            'managed sing-box did not stop': 'core_timeout',
            'cannot signal managed process ': 'core_signal',
            'managed supervisor ': 'supervisor_stop',
            'supervisor PID file changed': 'supervisor_marker',
            'unable to inspect live supervisor': 'supervisor_identity',
        }
        kinds = sorted({kind for prefix, kind in error_kinds.items()
                        if any(line.startswith('[error] ' + prefix)
                               for line in result.stderr.splitlines())})
        self.stop_checks.append({'operation': 'service_stop',
                                 'exit_code': bounded_exit_code(result.returncode),
                                 'error_kinds': kinds})
        require(result.returncode == 0,
                f'service stop command failed (exit {result.returncode}; kinds {kinds})')

    def stopped(self, timeout: float = 10):
        # Observe the kernel, not just the CLI return code or a stale state file.
        # CLI ownership checks exclude zombies. BusyBox pidof can still see
        # them until their parent reaps them; wait only on this read-only proof.
        deadline = time.monotonic() + timeout
        evidence = {'operation': 'kernel_stop', 'exit_codes': []}
        self.stop_checks.append(evidence)
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            result = self.kshell(f'test ! -e /sys/class/net/magicnet0 && '
                                 f'{{ p=$({BB} pidof sing-box 2>/dev/null); rc=$?; '
                                 f'test "$rc" = 1 && test -z "$p"; }}',
                                 timeout=min(3, remaining), check=False)
            evidence['exit_codes'].append(bounded_exit_code(result.returncode))
            if result.returncode == 0:
                break
            time.sleep(min(0.5, max(0, deadline - time.monotonic())))
        else:
            raise RuntimeError('core process/TUN survived stop observation deadline')
        require(bool(evidence['exit_codes']) and evidence['exit_codes'][-1] == 0,
                'core process/TUN survived stop observation deadline')
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
                'scope': 'Android-15-KernelSU-v3.2.0-pinned-kernel-x86_64-standalone-TUN-fixture',
                'not_tested': ['stock-kernel KernelSU LKM injection', 'ARM64 execution', 'OEM kernels',
                               'Play/GMS login/download', 'public proxy quality', 'eBPF dataplane',
                               'IPv6 packet forwarding', 'eCapture execution',
                               'proxylink subscription parsing'],
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
    # The proof owns failure accounting and restoration. Return failed commands
    # to it instead of raising before it can record the operation and exit code.
    def probe_command(command, timeout=30):
        return device.kshell(command, timeout=timeout, check=False)
    result = proof.verify(probe_command, benchmark.instrument, benchmark.COMPONENT)
    (out / ('tun-controls-' + phase + '.json')).write_text(json.dumps(result, indent=2) + '\n')
    require(result.get('status') == 'verified' and all(result.get(k) is True for k in
            ('positive', 'reject', 'positive_after', 'restored')), 'app-UID TUN controls failed')


def invalid_config_rollback(device: Device) -> dict:
    bad = MOD + '/.tmp/webui-payload/ci-invalid.json'
    save = f'{MOD}/cli config-editor save-file sing-box {bad}'
    validator = f'{MOD}/bin/sing-box check -c {bad} -D {MOD}/.config/sing-box'
    try:
        # Positive control on the exact same path and command. A permission or
        # path-validation failure must not masquerade as malformed-JSON rejection.
        device.kshell(f'mkdir -p {MOD}/.tmp/webui-payload && '
                      f'cp {MOD}/.config/sing-box/config.json {bad} && chmod 0600 {bad}')
        device.kshell(save, timeout=90)
        device.ready()
        device.kshell(validator, timeout=30)
        before = json.loads(device.kshell(MOD + '/cli config-editor get sing-box').stdout)
        device.kshell(f'printf "{{" >{bad}')
        # The CLI normalizes every child-validator failure to exit 1, including
        # crashes. Independently require the exact core's normal rejection on
        # the same payload/path; signals, panics and unavailable tools are failures.
        rejected = device.kshell(validator, timeout=30, check=False)
        require(rejected.returncode == 1, 'core validator did not reject malformed JSON normally')
        result = device.kshell(save, timeout=90, check=False)
        require(result.returncode == 1, 'config save did not reject malformed JSON normally')
        after = json.loads(device.kshell(MOD + '/cli config-editor get sing-box').stdout)
        require(before == after, 'invalid config changed the active configuration')
        device.ready()
        return {'core_rejection_exit_code': rejected.returncode,
                'save_rejection_exit_code': result.returncode, 'active_config_preserved': True}
    finally:
        device.kshell('rm -f ' + bad)


def migration_node() -> dict:
    # Data-only migration canary, not an operational/public proxy. The initial
    # fixture still routes direct; after migration only sentinel controls count
    # as connectivity evidence. No password or real subscription is involved.
    return {'type': 'socks', 'tag': 'ci-upgrade-canary', 'server': '127.0.0.1',
            'server_port': 19080, 'version': '5'}


def upgrade_candidate(original: dict) -> dict:
    require(isinstance(original, dict), 'upgrade config is not an object')
    outbounds = original.get('outbounds')
    require(isinstance(outbounds, list) and all(isinstance(v, dict) for v in outbounds),
            'upgrade config has invalid outbounds')
    node = migration_node()
    require(not any(v.get('tag') == node['tag'] for v in outbounds), 'duplicate migration canary')
    # Do not mutate the baseline used by the earlier TUN/rollback controls.
    return original | {'outbounds': outbounds + [node]}


def verify_migrated_node(config: dict) -> None:
    require(isinstance(config, dict), 'migrated config is not an object')
    outbounds = config.get('outbounds')
    require(isinstance(outbounds, list) and all(isinstance(v, dict) for v in outbounds),
            'migrated config has invalid outbounds')
    expected = migration_node()
    nodes = [v for v in outbounds if v.get('tag') == expected['tag']]
    require(len(nodes) == 1, 'migration canary missing or duplicated')
    require(all(type(nodes[0].get(k)) is type(v) and nodes[0].get(k) == v
                for k, v in expected.items())
            and not any(k in nodes[0] for k in ('username', 'password', 'detour')),
            'migration changed canary endpoint or protocol')


def save_upgrade_candidate(device: Device) -> None:
    before = json.loads(device.kshell(MOD + '/cli config-editor get sing-box').stdout,
                        object_pairs_hook=unique_keys)
    candidate = upgrade_candidate(before)
    name = 'ci-upgrade-' + os.urandom(8).hex() + '.json'
    path = MOD + '/.tmp/webui-payload/' + name
    encoded = base64.b64encode(json.dumps(candidate).encode()).decode('ascii')
    require(len(encoded) <= 6 * 1024 * 1024, 'upgrade fixture exceeds payload budget')
    created = False
    try:
        actual = device.kshell(MOD + '/cli webui payload create tmp ' + name).stdout.strip()
        created = True
        require(actual == path, 'unexpected upgrade payload path')
        for offset in range(0, len(encoded), 32768):
            device.kshell(MOD + '/cli webui payload append tmp ' + name + ' '
                          + shlex.quote(encoded[offset:offset + 32768]))
        device.kshell(MOD + '/cli config-editor save-file sing-box ' + path, timeout=90)
        verify_migrated_node(json.loads(device.kshell(MOD + '/cli config-editor get sing-box').stdout,
                                       object_pairs_hook=unique_keys))
        device.kshell(MOD + '/cli service restart sing-box', timeout=90)
        device.ready()
    finally:
        if created:
            device.kshell(MOD + '/cli webui payload remove tmp ' + name)


def upgrade_preservation(device: Device) -> dict:
    # The production upgrade regenerates managed policy and imports server
    # nodes; a direct-only standalone config is intentionally not migratable.
    # Prepare a real, valid node BEFORE ksud installs. Never seed after reboot.
    save_upgrade_candidate(device)
    marker = hashlib.sha256(os.urandom(32)).hexdigest()
    setting = MOD + '/.config/magicnet/network-policy.conf'
    before_policy = device.kshell('cat ' + setting).stdout
    require(bool(before_policy.strip()), 'network policy snapshot is empty')
    device.kshell(f'printf %s {marker} >{MOD}/.config/magicnet/ci-upgrade-marker')
    device.kshell(f'MAGICNET_NONINTERACTIVE=1 {KSUD} module install {REMOTE}/module.zip', timeout=180)
    # Read the installer's actual staged result before activation. No reseeding.
    device.kshell(f'test -f {STAGED}/module.prop')
    verify_migrated_node(json.loads(device.kshell(f'cat {STAGED}/.config/sing-box/config.json').stdout,
                                   object_pairs_hook=unique_keys))
    require(device.kshell(f'cat {STAGED}/.config/magicnet/ci-upgrade-marker').stdout == marker,
            'staged upgrade lost user config')
    require(device.kshell(f'cat {STAGED}/.config/magicnet/network-policy.conf').stdout == before_policy,
            'staged upgrade changed network policy')
    device.reboot()
    require(device.kshell(f'cat {MOD}/.config/magicnet/ci-upgrade-marker').stdout == marker,
            'upgrade lost user config')
    require(device.kshell('cat ' + setting).stdout == before_policy, 'upgrade changed network policy')
    current = json.loads(device.kshell(MOD + '/cli config-editor get sing-box').stdout,
                         object_pairs_hook=unique_keys)
    verify_migrated_node(current)
    # The installer must have regenerated the managed template, not left the
    # old standalone marker/config and accidentally passed the canary check.
    device.kshell(f'test ! -e {MOD}/.config/sing-box/standalone-config')
    device.ready()
    return {'node_preserved': True, 'staged_node_preserved': True,
            'staged_policy_preserved': True, 'user_policy_preserved': True,
            'standalone_marker_removed': True, 'proxy_connectivity_tested': False}


def device_resources(device: Device) -> dict:
    sdk = device.shell('getprop ro.build.version.sdk').stdout.strip()
    require(sdk == '35', 'Android API 35 is required by this fixture')
    memory = device.shell('cat /proc/meminfo').stdout
    matches = re.findall(r'^MemTotal:\s+([1-9][0-9]*) kB\s*$', memory, re.M)
    require(len(matches) == 1, 'device memory observation unavailable')
    requested = os.environ.get('AVD_MEMORY')
    require(requested is None or requested in ('2048', '4096'), 'invalid requested AVD memory')
    return {'sdk': int(sdk), 'requested_memory_mib': int(requested) if requested else None,
            'observed_memtotal_kib': int(matches[0]), 'memory_source': '/proc/meminfo'}


def diagnostics(device: Device, out: Path):
    if not device.verified:
        return
    # Diagnostics must not turn a failing test green or exhaust the job timeout.
    deadline = time.monotonic() + 25
    # Only statuses leave the device; no configuration or command output is retained.
    predicates = {}
    for name, pattern in CONFIG_PATTERNS.items():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        result = device.kshell(BB + ' grep -Eq ' + shlex.quote(pattern) + ' '
                               + MOD + '/.config/sing-box/config.json >/dev/null 2>&1',
                               timeout=min(3, remaining), check=False)
        predicates[name] = bounded_exit_code(result.returncode)
    (out / 'config-regex-exit-codes.json').write_text(json.dumps(predicates, indent=2) + '\n')
    commands = {'kam.log': 'tail -n 300 /data/adb/cache/MagicNet/kam.log',
                'api-probe.txt': f'{MOD}/cli mode; '
                                 f'ls -l {MOD}/bin/curl {MOD}/system/bin/curl '
                                 '/system/bin/curl /system/xbin/curl /vendor/bin/curl 2>/dev/null',
                'config-check.txt': f'{MOD}/bin/sing-box check -c '
                                    f'{MOD}/.config/sing-box/config.json -D {MOD}/.config/sing-box',
                'startup-state.txt': f'ls -l {MOD}/.state/machines; '
                                     f'cat {MOD}/.state/machines/*.state',
                'logcat.txt': 'logcat -d -t 1200', 'dmesg.txt': 'dmesg | tail -n 400',
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
                with zipfile.ZipFile(source) as production:
                    replacements.update({name: tools / Path(name).name for name in OPTIONAL_PAYLOADS
                                         if name in production.namelist()})
                archive = work / 'MagicNet-ci-x86_64.zip'
                report.provenance = prepare_archive(source, archive, replacements)
                device.identify()
                report.provenance['device'] = device_resources(device)
                report.provenance['system_curl_available'] = device.shell(
                    'test -f /system/bin/curl || test -f /system/xbin/curl || '
                    'test -f /vendor/bin/curl', check=False).returncode == 0
            with report.phase('kernelsu-bootstrap'):
                device.shell(f'mkdir -p {REMOTE} /data/adb')
                device.run('push', os.environ['MAGICNET_KSUD_HOST'], REMOTE + '/ksud')
                device.shell(f'cp {REMOTE}/ksud {KSUD} && chmod 0755 {KSUD}')
                report.provenance['kernelsu'] = device.late_load_kernelsu()
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
                              f'for n in $p; do test "$(cat /proc/$n/attr/current)" = {KSU_DOMAIN} || exit 1; done')
            with report.phase('app-uid-tun-controls'):
                tun_controls(device, out, 'app-uid-tun-controls')
            with report.phase('invalid-config-rollback'):
                report.provenance['invalid_config_rollback'] = invalid_config_rollback(device)
            with report.phase('stop-cleanup'):
                device.stop_service()
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
                report.provenance['upgrade'] = upgrade_preservation(device)
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
        if device is not None:
            report.provenance['busybox_checks'] = device.busybox_checks
            report.provenance['root_checks'] = device.root_checks
            report.provenance['stop_checks'] = device.stop_checks
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

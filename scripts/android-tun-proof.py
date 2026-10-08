#!/usr/bin/env python3
"""Prove one app UID reaches the installed TUN using a reversible emulator fixture.

No public service or proxy node is needed for the sentinel. A fresh random marker
is served only on the host loopback and adb-reversed to device loopback. The app
requests a benchmarking IP, which can reach this marker only through a matching
TUN + destination + app-UID route override. A reject control must refuse the
connection, then restoration must make the positive case work again.

Never run on a user's physical device. The caller discards the disposable AVD
if interrupted or if restoration cannot be verified; it never caches a mutated VM.
"""
from __future__ import annotations

import base64
import copy
import json
import re
import secrets
import shlex
import socketserver
import subprocess
import threading

MODDIR = '/data/adb/modules/MagicNet'
CLI = MODDIR + '/cli'
MARKER = MODDIR + '/.config/sing-box/standalone-config'
SENTINEL = '198.18.0.42'
MAX_OUTPUT_BYTES = 1024 * 1024
MAX_SERVICE_STATUS_BYTES = 64 * 1024
SERVICE_OBSERVATION_TIMEOUT = 5
STARTUP_STAGES = frozenset({
    'subscription', 'chain', 'transparent', 'hotspot', 'dns', 'tailscale', 'apps',
    'warp', 'overrides', 'auth', 'config-check', 'route-baseline', 'core-launch',
    'route-capture', 'network-ready',
})


def sanitized_failure(output: str, *, operation: str) -> dict:
    """Keep fixed diagnostic tokens only, even when CLI errors contain config text."""
    diagnostic = {'kind': 'command_failed'}
    messages = (
        ('config validation failed', 'config_validation'),
        ('config apply is still busy', 'config_apply_busy'),
    )
    if operation == 'core_restart':
        messages += (
            ('Timed out waiting for config lock:', 'config_lock_timeout'),
            ('create config apply lock directory:', 'config_apply_lock_error'),
            ('open config apply lock:', 'config_apply_lock_error'),
            ('lock config apply:', 'config_apply_lock_error'),
            ('managed sing-box process set changed during stop', 'core_generation_changed'),
            ('managed sing-box did not stop after SIGKILL:', 'core_stop_timeout'),
            ('cannot signal managed process', 'core_signal_failed'),
            ('cannot bind sing-box ownership to ', 'core_identity_unknown'),
            ('read sing-box candidate ', 'core_identity_unknown'),
            ('cannot verify executable identity for live sing-box candidate ', 'core_identity_unknown'),
            ('trusted Android pidof is unavailable', 'core_identity_unknown'),
            ('pid lookup deadline exceeded for sing-box', 'core_identity_unknown'),
            ('pid lookup timed out for sing-box', 'core_identity_unknown'),
            ('pid lookup output was truncated for sing-box', 'core_identity_unknown'),
            ('pid lookup failed for sing-box', 'core_identity_unknown'),
            ('pid lookup was terminated for sing-box', 'core_identity_unknown'),
            ('pid lookup returned non-UTF-8 output for sing-box', 'core_identity_unknown'),
            ('pid lookup returned malformed output for sing-box', 'core_identity_unknown'),
            ('pid lookup returned an empty success for sing-box', 'core_identity_unknown'),
            ('unable to read supervisor PID file', 'supervisor_identity_unknown'),
            ('unable to inspect supervisor PID file', 'supervisor_identity_unknown'),
            ('invalid supervisor PID file', 'supervisor_identity_unknown'),
            ('unable to inspect live supervisor ownership', 'supervisor_identity_unknown'),
            ('unable to remove stopped supervisor PID file', 'supervisor_identity_unknown'),
            ('managed supervisor survived stop verification', 'supervisor_stop_failed'),
            ('cannot signal managed supervisor:', 'supervisor_signal_failed'),
            ('managed supervisor did not stop after SIGTERM', 'supervisor_stop_timeout'),
            ('managed supervisor did not stop after SIGKILL', 'supervisor_stop_timeout'),
            ('managed supervisor force-stop is unavailable', 'supervisor_force_unavailable'),
            ('managed supervisor process generation changed during inspection', 'supervisor_generation_changed'),
            ('managed supervisor process generation changed during stop', 'supervisor_generation_changed'),
            ('managed supervisor ownership changed during stop', 'supervisor_ownership_changed'),
            ('supervisor PID file changed during stop', 'supervisor_pid_changed'),
            ('supervisor PID file changed during read', 'supervisor_pid_changed'),
            ('prepare network for core stop:', 'network_stop_failed'),
            ('finalize stopped network:', 'network_finalize_failed'),
        )
    messages += (
        ('No sing-box nodes were found', 'nodes_unavailable'),
        ('No sing-box nodes found', 'nodes_unavailable'),
        ('No subscription source is configured', 'source_unavailable'),
        ('ADB deadline exceeded', 'adb_deadline'),
    )
    for message, kind in messages:
        if message in output:
            diagnostic['kind'] = kind
            break
    # Validation errors can embed arbitrary config strings. Such strings
    # cannot establish a service failure category or a startup stage.
    if operation != 'core_restart' or diagnostic['kind'] == 'config_validation':
        return diagnostic
    for match in re.finditer(
            r'Startup step failed: stage=([a-z-]{1,32}) exit=([0-9]{1,3})(?=\s|$)', output):
        stage, exit_code = match.groups()
        if stage in STARTUP_STAGES and 1 <= int(exit_code) <= 255:
            diagnostic.update(stage=stage, stage_exit_code=int(exit_code))
            if diagnostic['kind'] == 'command_failed':
                diagnostic['kind'] = 'startup_step_failed'
            break
    return diagnostic


def output_counts(stdout, stderr) -> dict:
    """Record bounded UTF-8 byte counts without retaining command output."""
    result = {}
    for label, output in (('stdout', stdout), ('stderr', stderr)):
        text = output if isinstance(output, str) else ''
        encoded = text[:MAX_OUTPUT_BYTES].encode('utf-8', errors='replace')
        result[label + '_present'] = bool(text)
        result[label + '_bytes'] = min(len(encoded), MAX_OUTPUT_BYTES)
        result[label + '_bytes_capped'] = len(text) > MAX_OUTPUT_BYTES or len(encoded) > MAX_OUTPUT_BYTES
    return result


def service_observation(adb) -> dict:
    """One best-effort machine observation before failure cleanup, never a retry.

    This observes service state after the failed command, not the command's
    internal stage or the later restoration outcome. Unknown fields stay unknown.
    """
    observation = {'status': 'unknown', 'capture_phase': 'before_failure_cleanup'}
    try:
        cp = adb(CLI + ' --json service status', timeout=SERVICE_OBSERVATION_TIMEOUT)
        observation.update(output_counts(cp.stdout, cp.stderr))
        observation['exit_code'] = (cp.returncode if type(cp.returncode) is int
                                    and -255 <= cp.returncode <= 255 else None)
        if type(cp.returncode) is not int or cp.returncode != 0:
            return observation
        if (not isinstance(cp.stdout, str) or len(cp.stdout) > MAX_SERVICE_STATUS_BYTES
                or len(cp.stdout.encode('utf-8')) > MAX_SERVICE_STATUS_BYTES):
            return observation
        envelope = json.loads(cp.stdout)
        if (not isinstance(envelope, dict) or type(envelope.get('schema')) is not int
                or envelope.get('schema') != 1 or envelope.get('ok') is not True
                or envelope.get('command') != 'service.status'
                or not isinstance(envelope.get('data'), dict)):
            return observation

        def obj(value):
            return value if isinstance(value, dict) else {}

        def token(value, allowed):
            return value if isinstance(value, str) and value in allowed else 'unknown'

        def boolean(value):
            return value if type(value) is bool else None

        data = envelope['data']
        core = obj(data.get('core'))
        singbox = obj(core.get('sing_box'))
        api = obj(data.get('api'))
        readiness = obj(data.get('readiness'))
        transparent = obj(data.get('transparent'))
        count = transparent.get('shared_interface_count')
        observation['service'] = {
            'lifecycle': token(data.get('lifecycle'), {
                'stopped', 'unknown', 'reconfiguring', 'ready', 'not_ready', 'running_unknown'}),
            'core': {
                'selected': token(core.get('selected'), {'sing-box'}),
                'running': boolean(singbox.get('running')),
                'process_state': token(singbox.get('process_state'), {'running', 'stopped', 'unknown'}),
            },
            'api_ready': boolean(api.get('ready')),
            'readiness': {'dataplane': boolean(readiness.get('dataplane')),
                          'overall': boolean(readiness.get('overall'))},
            'transparent': {
                'configured_mode': token(transparent.get('configured_mode'), {'tun', 'ebpf'}),
                'effective_type': token(transparent.get('effective_type'), {'tun', 'ebpf'}),
                'effective_mode': token(transparent.get('effective_mode'), {'tun', 'local', 'shared', 'hybrid'}),
                'capability': token(transparent.get('capability'), {'not_required', 'ok', 'failed', 'unknown'}),
                'local_cgroup': token(transparent.get('local_cgroup'), {
                    'inactive', 'configured', 'unknown', 'attached', 'missing'}),
                'shared_tc': token(transparent.get('shared_tc'), {
                    'inactive', 'pending', 'configured', 'unknown', 'attached', 'missing'}),
                'shared_interface_count': count if type(count) is int and 0 <= count <= 4096 else None,
                'dataplane_ready': boolean(transparent.get('dataplane_ready')),
                'transition': token(transparent.get('transition'), {
                    'idle', 'prepared', 'target-written', 'preflight', 'candidate-prepared',
                    'stopping-old', 'old-stopped', 'candidate-starting', 'verified',
                    'rolling-back', 'old-restored'}),
                'has_recent_error': boolean(transparent.get('has_recent_error')),
            },
        }
        observation['status'] = 'observed'
    except Exception:
        # Observation must never replace the primary failure or prevent restore.
        # Exception strings can contain argv/config text and are not report data.
        pass
    return observation


def fixture_config(original: dict, uid: int, port: int, *, blocked: bool) -> dict:
    if type(uid) is not int or uid < 10000 or type(port) is not int or not 1024 <= port <= 65535:
        raise ValueError('invalid fixture identity')
    candidate = copy.deepcopy(original)
    inbounds = [item for item in candidate.get('inbounds', []) if item.get('type') == 'tun']
    if len(inbounds) != 1 or inbounds[0].get('interface_name') != 'magicnet0':
        raise ValueError('fixture requires the installed TUN mode')
    inbound = inbounds[0]
    if not isinstance(inbound.get('tag'), str) or not inbound['tag']:
        raise ValueError('missing TUN tag')
    if 0 not in inbound.get('exclude_uid', []) or uid in inbound.get('exclude_uid', []):
        raise ValueError('root must remain excluded and probe UID must be included')
    if inbound.get('include_uid') and uid not in inbound['include_uid']:
        raise ValueError('probe UID is outside the configured app policy')
    if not any(item.get('type') == 'direct' and item.get('tag') == 'direct'
               for item in candidate.get('outbounds', [])):
        raise ValueError('missing direct fixture outbound')
    rule = dict(inbound=[inbound['tag']], ip_cidr=[SENTINEL + '/32'], port=port,
                user_id=[uid], network='tcp')
    if blocked:
        rule.update(action='reject', method='default', no_drop=True)
    else:
        rule.update(action='route', outbound='direct', override_address='127.0.0.1', override_port=port)
    route = candidate.setdefault('route', {})
    if not isinstance(route.get('rules', []), list):
        raise ValueError('invalid existing route rules')
    route['rules'] = [rule] + route.get('rules', [])
    return candidate


def verify(adb, instrument, component) -> dict:
    report = {'status': 'not_verified', 'scope': 'emulator_test_uid_tcp',
              'positive': False, 'reject': False, 'positive_after': False, 'restored': False}
    # A user could run the benchmark locally; refuse mutation on physical phones.
    qemu = adb('getprop ro.kernel.qemu', timeout=5)
    abi = adb('getprop ro.product.cpu.abi', timeout=5)
    if qemu.returncode or qemu.stdout.strip() != '1' or abi.returncode or abi.stdout.strip() != 'x86_64':
        return report | {'reason': 'disposable_x86_emulator_required'}
    identity = instrument(component, 'identity', 5)
    if not identity['ok']:
        return report | {'reason': 'probe_app_unavailable'}
    uid = identity['uid']
    package = adb('cmd package list packages -U best.lmm.magicnet.probe', timeout=5)
    if package.returncode or package.stdout.strip() != f'package:best.lmm.magicnet.probe uid:{uid}':
        return report | {'reason': 'app_uid_not_confirmed'}
    current = adb(CLI + ' config-editor get sing-box', timeout=15)
    marker = adb('if [ -f ' + MARKER + ' ]; then cat ' + MARKER + '; else echo absent; fi', timeout=5)
    if current.returncode or marker.returncode or marker.stdout.strip() not in ('absent', 'validated'):
        return report | {'reason': 'config_snapshot_unavailable'}
    try:
        if len(current.stdout) > 4 * 1024 * 1024:
            raise ValueError('config budget')
        original = json.loads(current.stdout)
        if not isinstance(original, dict):
            raise ValueError('config must be an object')
    except (ValueError, TypeError):
        return report | {'reason': 'invalid_config_snapshot'}

    control = 'prepare'

    def command(text, timeout=30, *, operation='device_operation'):
        cp = adb(text, timeout=timeout)
        if cp.returncode:
            # Keep the first failure even if restoration also fails. Never
            # retain argv, payloads or raw output from a user configuration.
            failure = {'operation': operation, 'exit_code': cp.returncode,
                       **sanitized_failure(cp.stdout + '\n' + (cp.stderr or ''), operation=operation),
                       **output_counts(cp.stdout, cp.stderr)}
            if 'failure_control' not in report:
                report['failure_control'] = control
                report.update({'failure_' + key: value for key, value in failure.items()})
                # Direct read with its own short deadline, before payload cleanup
                # and restoration can erase the failed activation's observations.
                report['failure_service_observation'] = service_observation(adb)
            # A secondary restore failure must not overwrite the original
            # cause, or lend its startup stage to the original failure record.
            if control == 'restore' and 'restore_failure_operation' not in report:
                report.update({'restore_failure_' + key: value for key, value in failure.items()})
            raise RuntimeError('device_operation_failed')
        return cp.stdout

    def install_config(value):
        # Use the existing private CLI payload API rather than exposing configs
        # through world-readable storage, argv-sized blobs or an ad hoc writer.
        name = 'network-probe-' + secrets.token_hex(8) + '.json'
        path = MODDIR + '/.tmp/webui-payload/' + name
        encoded = base64.b64encode(json.dumps(value, ensure_ascii=False).encode()).decode()
        created = False
        try:
            actual = command(CLI + ' webui payload create tmp ' + name,
                             operation='payload_create').strip()
            created = True
            if actual != path:
                raise RuntimeError('unexpected_payload_path')
            for offset in range(0, len(encoded), 32768):
                command(CLI + ' webui payload append tmp ' + name + ' ' + shlex.quote(encoded[offset:offset + 32768]),
                        operation='payload_append')
            command(CLI + ' config-editor save-file sing-box ' + path,
                    operation='config_save')
            command(CLI + ' service restart sing-box', timeout=90,
                    operation='core_restart')
        finally:
            if created:
                command(CLI + ' webui payload remove tmp ' + name,
                        operation='payload_remove')

    marker_bytes = secrets.token_hex(16)
    counts = {'accepted': 0}
    lock = threading.Lock()

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(2)
            with lock:
                counts['accepted'] += 1
            self.request.sendall((marker_bytes + '\n').encode('ascii'))

    server = socketserver.TCPServer(('127.0.0.1', 0), Handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    reverse = False
    changed = False
    try:
        positive = fixture_config(original, uid, port, blocked=False)
        blocked = fixture_config(original, uid, port, blocked=True)
        subprocess.run(['adb', 'reverse', '--no-rebind', f'tcp:{port}', f'tcp:{port}'],
                       check=True, capture_output=True, timeout=10)
        reverse = True
        for key, candidate in (('positive', positive), ('reject', blocked), ('positive_after', positive)):
            control = key
            changed = True  # A failed save/restart may already have changed the active file.
            install_config(candidate)
            with lock:
                before = counts['accepted']
            result = instrument(component, 'sentinel', 5, port=port, marker=marker_bytes)
            with lock:
                count = counts['accepted'] - before
            if key == 'reject':
                report[key] = (result['complete'] and not result['ok'] and result['uid'] == uid
                               and result['reason'] == 'connect' and count == 0)
            else:
                report[key] = (result['ok'] and result['uid'] == uid
                               and result['reason'] == 'sentinel' and count == 1)
            if not report[key]:
                raise RuntimeError('sentinel_control_failed')
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, subprocess.SubprocessError):
        report['reason'] = 'sentinel_not_proven'
    finally:
        if changed:
            control = 'restore'
            try:
                install_config(original)
                if marker.stdout.strip() == 'absent':
                    command('rm -f ' + MARKER)
                restored = json.loads(command(CLI + ' config-editor get sing-box', timeout=15))
                report['restored'] = restored == original
                if not report['restored']:
                    report['reason'] = 'config_restore_mismatch_discard_avd'
            except (OSError, ValueError, RuntimeError):
                report['reason'] = 'config_restore_failed_discard_avd'
        if reverse:
            try:
                subprocess.run(['adb', 'reverse', '--remove', f'tcp:{port}'], check=True,
                               capture_output=True, timeout=10)
            except (OSError, subprocess.SubprocessError):
                report['restored'] = False
                report['reason'] = 'reverse_cleanup_failed_discard_avd'
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    if all(report[key] for key in ('positive', 'reject', 'positive_after', 'restored')):
        report['status'] = 'verified'
        report.pop('reason', None)
    return report

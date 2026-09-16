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
import secrets
import shlex
import socketserver
import subprocess
import threading

MODDIR = '/data/adb/modules/MagicNet'
CLI = MODDIR + '/cli'
MARKER = MODDIR + '/.config/sing-box/standalone-config'
SENTINEL = '198.18.0.42'


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

    def command(text, timeout=30):
        cp = adb(text, timeout=timeout)
        if cp.returncode:
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
            actual = command(CLI + ' webui payload create tmp ' + name).strip()
            created = True
            if actual != path:
                raise RuntimeError('unexpected_payload_path')
            for offset in range(0, len(encoded), 32768):
                command(CLI + ' webui payload append tmp ' + name + ' ' + shlex.quote(encoded[offset:offset + 32768]))
            command(CLI + ' config-editor save-file sing-box ' + path)
            command(CLI + ' service restart sing-box', timeout=90)
        finally:
            if created:
                command(CLI + ' webui payload remove tmp ' + name)

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

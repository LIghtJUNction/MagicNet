#!/usr/bin/env python3
"""Upgrade metadata assertions for the disposable Android acceptance driver.

A loopback SOCKS node makes the fixture eligible for the *production* node
migration path. No server is started and no proxy connectivity is claimed.
The normal direct route and separate app-UID TUN controls are kept independent.
"""
from __future__ import annotations

import base64
import copy
import json
import re
import secrets
import shlex

MOD = '/data/adb/modules/MagicNet'
STAGED = '/data/adb/modules_update/MagicNet'
REMOTE_ZIP = '/sdcard/Download/MagicNet/ci-simulation/module.zip'
KSUD = '/data/adb/ksud'
NODE = {'type': 'socks', 'tag': 'ci-upgrade-loopback', 'server': '127.0.0.1',
        'server_port': 19081, 'version': '5'}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def upgrade_config(original):
    require(isinstance(original, dict) and isinstance(original.get('outbounds'), list),
            'invalid pre-upgrade configuration')
    candidate = copy.deepcopy(original)
    require(not any(isinstance(x, dict) and x.get('tag') == NODE['tag']
                    for x in candidate['outbounds']), 'upgrade fixture node already exists')
    candidate['outbounds'].append(copy.deepcopy(NODE))
    return candidate


def verify_node(config):
    require(isinstance(config, dict) and isinstance(config.get('outbounds'), list),
            'missing upgraded outbounds')
    nodes = [x for x in config['outbounds'] if isinstance(x, dict) and x.get('tag') == NODE['tag']]
    require(len(nodes) == 1, 'upgraded node is missing or duplicated')
    require(all(type(nodes[0].get(k)) is type(v) and nodes[0][k] == v for k, v in NODE.items()),
            'upgraded node fields changed')
    require(not any(k in nodes[0] for k in ('username', 'password')),
            'credential-free fixture unexpectedly acquired credentials')


def save_config(device, config):
    name = 'ci-upgrade-' + secrets.token_hex(8) + '.json'
    path = MOD + '/.tmp/webui-payload/' + name
    encoded = base64.b64encode(json.dumps(config, ensure_ascii=False).encode()).decode('ascii')
    require(len(encoded) <= 6 * 1024 * 1024, 'upgrade fixture exceeds payload budget')
    created = False
    try:
        actual = device.kshell(f'{MOD}/cli webui payload create tmp {name}').stdout.strip()
        created = True
        require(actual == path, 'unexpected private payload path')
        for offset in range(0, len(encoded), 32768):
            device.kshell(f'{MOD}/cli webui payload append tmp {name} '
                          + shlex.quote(encoded[offset:offset + 32768]))
        device.kshell(f'{MOD}/cli config-editor save-file sing-box {path}', timeout=90)
    finally:
        if created:
            device.kshell(f'{MOD}/cli webui payload remove tmp {name}')


def verify_upgrade(device):
    require(device.verified, 'disposable device identity not verified')
    original = json.loads(device.kshell(MOD + '/cli config-editor get sing-box').stdout)
    candidate = upgrade_config(original)
    save_config(device, candidate)
    device.ready()
    # Positive control proves the installer receives the expected node; otherwise
    # an ignored write could be mistaken for later migration/data loss.
    verify_node(json.loads(device.kshell(MOD + '/cli config-editor get sing-box').stdout))
    marker = secrets.token_hex(32)
    marker_path = MOD + '/.config/magicnet/ci-upgrade-marker'
    device.kshell(f'printf %s {marker} >{marker_path}')
    device.kshell(f'MAGICNET_NONINTERACTIVE=1 {KSUD} module install {REMOTE_ZIP}', timeout=180)
    # Inspect the actual staged result, never move it or repair it ourselves.
    device.kshell(f'test -f {STAGED}/module.prop')
    verify_node(json.loads(device.kshell(f'cat {STAGED}/.config/sing-box/config.json').stdout))
    require(device.kshell(f'cat {STAGED}/.config/magicnet/ci-upgrade-marker').stdout == marker,
            'staged upgrade lost the user setting')
    device.reboot()
    require(device.kshell('cat ' + marker_path).stdout == marker, 'upgrade lost the user setting')
    verify_node(json.loads(device.kshell(MOD + '/cli config-editor get sing-box').stdout))
    device.ready()
    return {'schema': 1, 'status': 'passed', 'scope': 'node-and-user-setting-migration',
            'staged_node_preserved': True, 'activated_node_preserved': True,
            'user_setting_preserved': True, 'node_transport_tested': False}


def memory_observation(text, requested):
    matches = re.findall(r'^MemTotal:\s+([1-9][0-9]*)\s+kB\s*$', text, re.M)
    require(len(matches) == 1, 'Android MemTotal is missing or ambiguous')
    require(requested is None or re.fullmatch(r'[1-9][0-9]{0,5}', requested),
            'invalid requested emulator RAM')
    # MemTotal is available guest RAM, not the emulator's configured allocation.
    return {'requested_emulator_mib': int(requested) if requested is not None else None,
            'observed_guest_memtotal_kib': int(matches[0])}

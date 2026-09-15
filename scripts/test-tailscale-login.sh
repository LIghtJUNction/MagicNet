#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as temp:
    module = Path(temp)
    (module/'bin').mkdir()
    (module/'bin/jq').symlink_to(shutil.which('jq'))
    config_path = module/'.config/sing-box/config.json'
    config_path.parent.mkdir(parents=True)
    tailnets = ['100.64.0.0/10', 'fd7a:115c:a1e0::/48']
    lan_rule = {'ip_cidr': tailnets + ['192.168.0.0/16'], 'outbound':'lan'}
    config = {
        'endpoints':[{'type':'tailscale','tag':'tailnet','system_interface':False}],
        'dns': {'servers':[{'type':'local','tag':'tailnet-dns'}], 'rules':[]},
        'inbounds':[{'type':'tun','tag':'tun-in','route_exclude_address':tailnets + ['192.168.0.0/16']}],
        'route':{'rules':[
            {'clash_mode':'Direct','outbound':'direct'},
            {'ip_cidr':tailnets,'outbound':'stale-tailnet'},
            lan_rule,
            {'domain_suffix':['ts.net'],'outbound':'lan'},
        ]}
    }
    config_path.write_text(json.dumps(config))
    command = ['sh','-c','. "$1"; magicnet_tailscale_apply_unlocked','test',str(root/'src/MagicNet/lib/magicnet/runtime_config.sh')]
    env = dict(os.environ,MODDIR=temp)
    subprocess.run(command, env=env, check=True)
    output = json.loads(config_path.read_text())
    assert output['dns']['servers'][0] == {'type':'local','tag':'tailnet-dns'}
    server = output['dns']['servers'][1]
    assert server == {'type':'tailscale','tag':'tailnet-dns-1','endpoint':'tailnet'}
    assert output['dns']['rules'][0] == {'domain_suffix':['ts.net'],'server':'tailnet-dns-1'}
    assert output['inbounds'][0]['route_exclude_address'] == ['192.168.0.0/16']
    assert output['route']['rules'][0] == config['route']['rules'][0]
    assert output['route']['rules'][1] == {
        'ip_cidr':tailnets,
        'preferred_by':['tailscale'],
        'outbound':'tailnet',
    }
    assert output['route']['rules'][2] == {'domain_suffix':['ts.net'],'outbound':'tailnet'}
    # Capturing the CGNAT range in magicnet0 is required for userspace Tailscale,
    # but non-peer CGNAT destinations must still fall through to the normal LAN
    # path instead of being hijacked into the Tailnet endpoint.
    assert output['route']['rules'][3] == lan_rule
    assert not any(rule.get('outbound') == 'stale-tailnet' for rule in output['route']['rules'])
    subprocess.run(command, env=env, check=True)
    assert json.loads(config_path.read_text()) == output
print('Tailscale browser-login runtime configuration passed')
PY

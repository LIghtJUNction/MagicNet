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
    config = {
        'endpoints':[{'type':'tailscale','tag':'tailnet','system_interface':False}],
        'dns': {'servers':[{'type':'local','tag':'tailnet-dns'}], 'rules':[]},
        'inbounds':[{'type':'tun','tag':'tun-in','route_exclude_address':['100.64.0.0/10','fd7a:115c:a1e0::/48','192.168.0.0/16']}],
        'route':{'rules':[{'clash_mode':'Direct','outbound':'direct'},{'domain_suffix':['ts.net'],'outbound':'lan'}]}
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
    assert output['route']['rules'][1] == {'ip_cidr':['100.64.0.0/10','fd7a:115c:a1e0::/48'],'outbound':'tailnet'}
    assert output['route']['rules'][2] == {'domain_suffix':['ts.net'],'outbound':'tailnet'}
    subprocess.run(command, env=env, check=True)
    assert json.loads(config_path.read_text()) == output
print('Tailscale browser-login runtime configuration passed')
PY

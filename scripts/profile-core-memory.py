#!/usr/bin/env python3
"""Controlled Linux RSS A/B using the pinned core and local rule sets only.

No TUN, external request, proxy credentials, user accounts or Tailscale session.
This attributes idle host memory to loaded rules; it is NOT an Android heap profile.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import statistics
import subprocess
import tempfile
import time
import urllib.request

FIELDS = ('VmRSS', 'RssAnon', 'RssFile', 'RssShmem', 'VmHWM', 'VmSwap', 'Threads')

def rules_from(config: Path) -> list[dict]:
    root = config.resolve().parent
    raw = json.loads(config.read_text())
    rules = []
    for rule in raw.get('route', {}).get('rule_set', []):
        if rule.get('type') != 'local':
            raise ValueError('Only local, offline rule sets may enter this profile')
        path = (root / rule['path']).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise ValueError('Missing or out-of-tree rule file')
        rules.append(dict(type='local', tag=rule['tag'], format=rule.get('format','binary'), path=str(path)))
    if not rules or len({rule['tag'] for rule in rules}) != len(rules):
        raise ValueError('Missing or duplicate rule-set inventory')
    return rules

def measure(binary: Path, rules: list[dict], limit: str) -> dict:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
    credential=secrets.token_hex(32)
    config={'log':{'level':'error'},'inbounds':[], 'outbounds':[{'type':'direct','tag':'direct'}],
            'route':{'final':'direct','rule_set':rules,'rules':([{'rule_set':[r['tag'] for r in rules],'outbound':'direct'}] if rules else [])},
            'experimental':{'clash_api':{'external_controller':f'127.0.0.1:{port}','secret':credential}}}
    with tempfile.TemporaryDirectory(prefix='magicnet-memory-') as directory:
        root=Path(directory); path=root/'config.json'; path.write_text(json.dumps(config)); path.chmod(0o600)
        subprocess.run([str(binary),'check','-c',str(path)],check=True,capture_output=True,timeout=15)
        env={k:v for k,v in os.environ.items() if k not in ('GOGC','GOMEMLIMIT','GODEBUG')}
        env.update(GOMEMLIMIT=limit,GOGC='100')
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        def query():
            req=urllib.request.Request(f'http://127.0.0.1:{port}/connections',headers={'Authorization':'Bearer '+credential})
            with opener.open(req,timeout=1) as response:
                data=response.read(65537)
                if len(data)>65536: raise ValueError('Oversized local API response')
                return json.loads(data)
        started=time.monotonic()
        with (root/'core.log').open('wb') as log:
            proc=subprocess.Popen([str(binary),'run','-c',str(path)],env=env,stdout=log,stderr=log)
            try:
                deadline=started+20
                while time.monotonic()<deadline:
                    if proc.poll() is not None: raise RuntimeError('Profile core exited before readiness')
                    try:
                        query(); break
                    except (OSError,ValueError): time.sleep(.1)
                else: raise RuntimeError('Profile core did not become ready')
                startup_ms=round((time.monotonic()-started)*1000)
                samples=[]
                for _ in range(8):
                    time.sleep(.5)
                    if proc.poll() is not None: raise RuntimeError('Profile core exited during measurement')
                    status={}
                    for line in Path(f'/proc/{proc.pid}/status').read_text().splitlines():
                        key,_,value=line.partition(':')
                        if key in FIELDS: status[key]=int(value.split()[0])
                    memory=query().get('memory')
                    if not status.get('VmRSS'): raise RuntimeError('No RSS evidence available')
                    status['core_api_memory_bytes']=memory if type(memory) is int and memory>=0 else None
                    samples.append(status)
                return {'rule_set_count':len(rules),'GOMEMLIMIT':limit,'GOGC':'100','startup_ms':startup_ms,'samples':samples,
                        'median_rss_kib':statistics.median(s['VmRSS'] for s in samples[-4:]),
                        'median_anon_kib':(statistics.median(s['RssAnon'] for s in samples[-4:]) if all('RssAnon' in s for s in samples[-4:]) else None)}
            finally:
                proc.terminate()
                try: proc.wait(timeout=5)
                except subprocess.TimeoutExpired: proc.kill();proc.wait(timeout=5)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core',type=Path,required=True);parser.add_argument('--config',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();rules=rules_from(args.config)
    groups={'minimal':[], 'ads_only':[r for r in rules if any(word in r['tag'] for word in ('ads','hagezi'))],
            'cn_only':[r for r in rules if r['tag'].endswith('-cn') or 'china-' in r['tag']], 'all_local_rules':rules}
    results={}
    for name, selected in groups.items():
        results[name]=[measure(args.core.resolve(),selected,'off') for _ in range(2)]
        print(name, 'median RSS KiB:', [r['median_rss_kib'] for r in results[name]])
    results['all_rules_soft64MiB']=[measure(args.core.resolve(),rules,'64MiB') for _ in range(2)]
    report={'schema':1,'scope':'Linux_idle_local_rules_AB_not_Android','source_commit':os.getenv('GITHUB_SHA'),
            'binary_sha256':hashlib.sha256(args.core.read_bytes()).hexdigest(),
            'rule_inventory':[{'tag':r['tag'],'bytes':Path(r['path']).stat().st_size,'sha256':hashlib.sha256(Path(r['path']).read_bytes()).hexdigest()} for r in rules],
            'results':results,'not_measured':['Android','TUN','active_connections','Tailscale','throughput','battery','Go_heap_allocation_profile'],
            'notes':'The soft-limit experiment is not a recommendation or RSS cap. Anonymous RSS is not synonymous with live Go heap.'}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__': main()

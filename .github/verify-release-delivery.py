"""One-shot public delivery verification; no credentials enter evidence."""
from __future__ import annotations
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

REPO = 'LIghtJUNction/MagicNet'
VERSION = 'v1.5.6'
CODE = '1789322930997'
EXPECTED_TREE = os.environ['EXPECTED_RELEASE_TREE']
SHA = os.environ['EXPECTED_RELEASE_SHA']
RUN = os.environ['RELEASE_RUN_ID']
OUT = Path(os.environ['RUNNER_TEMP']) / 'verified-delivery'
OUT.mkdir(parents=True, exist_ok=True)
assert re.fullmatch('[a-f0-9]{40}', SHA)
assert re.fullmatch('[a-f0-9]{40}', EXPECTED_TREE)
assert RUN.isdecimal()

def get(path: str):
    cp = subprocess.run(['gh', 'api', f'repos/{REPO}{path}'], text=True,
                        check=True, capture_output=True, timeout=30)
    return json.loads(cp.stdout)

def sha256(path: Path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

run = get('/actions/runs/' + RUN)
assert run['head_sha'] == SHA and run['conclusion'] == 'success'
assert run['status'] == 'completed' and run['path'] == '.github/workflows/exec.yml'
commit = get('/git/commits/' + SHA)
assert commit['tree']['sha'] == EXPECTED_TREE, 'release tree differs from checked candidate'
release = get('/releases/tags/' + VERSION)
latest = get('/releases/latest')
assert not release['draft'] and not release['prerelease']
assert release['id'] == latest['id'] and latest['tag_name'] == VERSION
assert release['target_commitish'] == SHA
ref = get('/git/ref/tags/' + VERSION)['object']
assert ref['type'] == 'commit' and ref['sha'] == SHA
assets = release['assets']
names = {a['name'] for a in assets}
assert len(names) == len(assets) and 1 <= len(assets) <= 250
assert {'magicnet_installer.zip','MagicNet-core.zip','MagicNet-full.zip',
        'components.json','SHA256SUMS','build-submodules.txt'} <= names
assert sum(a['size'] for a in assets) <= 512 * 1024 * 1024
prefix = f'https://github.com/{REPO}/releases/download/{VERSION}/'

def download(asset):
    name = asset['name']
    assert re.fullmatch(r'[A-Za-z0-9_.!@-]+', name) and name not in ('.','..')
    assert asset['browser_download_url'] == prefix + name
    assert asset['state'] == 'uploaded' and 0 < asset['size'] < 256 * 1024 * 1024
    path = OUT / name
    public_env = {k:v for k,v in os.environ.items() if k not in ('GH_TOKEN','GITHUB_TOKEN')}
    subprocess.run(['curl','--fail','--silent','--show-error','--location','--proto','=https',
                    '--proto-redir','=https','--retry','2','--max-time','120',
                    '--max-filesize',str(asset['size']),'--output',str(path),
                    asset['browser_download_url']], check=True, timeout=380, env=public_env)
    assert path.stat().st_size == asset['size'], name
    value = sha256(path)
    assert asset['digest'] == 'sha256:' + value, name
    return {'name':name,'bytes':asset['size'],'sha256':value}

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    downloads = list(pool.map(download, assets))
sums = {}
for line in (OUT / 'SHA256SUMS').read_text().splitlines():
    match = re.fullmatch(r'([a-f0-9]{64})  ([A-Za-z0-9_.!@-]+)', line)
    assert match, 'malformed checksum row'
    value, name = match.groups()
    assert name in names and name not in sums and sha256(OUT / name) == value, name
    sums[name] = value
payloads = names - {n for n in names if n.endswith('.sig')} - {'SHA256SUMS'}
assert set(sums) == payloads
assert {n+'.sig' for n in payloads | {'SHA256SUMS'}} <= names
manifest = json.loads((OUT/'components.json').read_text())
assert manifest['schema'] == 1 and manifest['version'] == VERSION
rules_pin = json.loads(Path('rules-release.json').read_text())
assert rules_pin['tag'] == 'rules-20260916-c802d68ca104e3ce'
assert rules_pin['recipe_commit'] in (OUT/'build-submodules.txt').read_text()
critical = ['lib/magicnet/network.sh', 'lib/magicnet/lifecycle.sh', 'lib/magicnet/routes.sh',
            'lib/magicnet/core.sh','uninstall.sh','lib/magicnet/uninstall.sh']
srs_count = 0
with zipfile.ZipFile(OUT/'MagicNet-full.zip') as full:
    assert sum(i.file_size for i in full.infolist()) <= 512*1024*1024
    assert full.testzip() is None
    props = dict(line.split('=',1) for line in full.read('module.prop').decode().splitlines()
                 if '=' in line and not line.startswith('#'))
    assert props['id'] == 'MagicNet' and props['version'] == VERSION and props['versionCode'] == CODE
    for name in critical:
        assert full.read(name) == (Path('src/MagicNet')/name).read_bytes(), name
    for component in manifest['components']:
        name = component['asset']
        assert name in names
        part_path = OUT/name
        assert part_path.stat().st_size == component['size'] and sha256(part_path) == component['sha256']
        with zipfile.ZipFile(part_path) as part:
            assert sum(i.file_size for i in part.infolist()) <= 512*1024*1024
            assert part.testzip() is None
            for entry in component['files']:
                raw = part.read(entry['path'])
                assert len(raw) == entry['size'] and hashlib.sha256(raw).hexdigest() == entry['sha256']
                assert raw == full.read(entry['path']), entry['path']
                if entry['path'].endswith('.srs'):
                    assert raw[:3] == b'SRS', entry['path']
                    srs_count += 1
    with zipfile.ZipFile(OUT/'magicnet_installer.zip') as installer:
        assert installer.read('module.prop') == full.read('module.prop')
        assert json.loads(installer.read('components.json')) == manifest
assert srs_count == 53
subprocess.run(['python3','scripts/test-downloader-installer.py',str(OUT/'magicnet_installer.zip'),
                '--core',str(OUT/'MagicNet-core.zip')],check=True,timeout=30)
result = {'status':'PASS','version':VERSION,'versionCode':int(CODE),'source_commit':SHA,
          'source_tree':EXPECTED_TREE,'release_run_id':int(RUN),'release_id':release['id'],
          'published_at':release['published_at'],'assets':downloads,'rules_pin':rules_pin,
          'verified_srs':srs_count,'verified_runtime_sources':critical,
          'scope':'public_download_integrity_package_source_consistency',
          'not_tested':['physical_device_Play_GMS','Android_RSS_reduction','network_handover']}
(OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
(OUT/'release.json').write_text(json.dumps(release,indent=2)+'\n')
print(f'PASS: {VERSION}, {len(assets)} public assets, {srs_count} SRS files, six exact runtime source files')

#!/usr/bin/env python3
"""Split a built MagicNet ZIP without changing its runtime feature set.

Run before KAM's signing hook. All component versions are content-addressed;
release versions locate assets, but do not decide whether bytes need downloading.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile

STAMP = (1980, 1, 1, 0, 0, 0)
BOOTSTRAP = '''
# Resolve this release's locked components before any module-specific imports.
for _component_path in "$MODPATH" "$MODPATH/bin" "$MODPATH/bin/magicnet-components" "$MODPATH/.components" "$MODPATH/.components/manifest.json"; do
  [ ! -L "$_component_path" ] || abort "! unsafe component bootstrap path"
done
unset _component_path
unzip -o "$ZIPFILE" 'bin/magicnet-components' '.components/manifest.json' -d "$MODPATH" >&2 || abort "! component bootstrap missing"
chmod 0755 "$MODPATH/bin/magicnet-components" || abort "! component bootstrap is not executable"
"$MODPATH/bin/magicnet-components" --manifest "$MODPATH/.components/manifest.json" \
  --module "$MODPATH" --previous "${MAGICNET_PREV_DIR:-/data/adb/modules/MagicNet}" \
  --bundle "$ZIPFILE" || abort "! component verification/install failed; release not installed"
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_name(name: str) -> bool:
    return (bool(name) and not name.startswith('/') and '\\' not in name
            and all(ord(c) >= 32 for c in name)
            and all(p not in ('', '.', '..') for p in name.split('/')))


def component_for(name: str) -> str | None:
    # Bootstrap and first-party Rust entry points stay in the small core.
    if name.startswith('bin/') and name.count('/') == 1:
        binary = name[4:]
        if binary not in ('magicnet-cli', 'magicnet-mcp-server', 'magicnet-components'):
            return binary if re.fullmatch(r'[a-z0-9][a-z0-9-]*', binary) else None
    if name.startswith('webroot/'):
        return 'webui'
    if name.startswith('.config/sing-box/zashboard/'):
        return 'dashboard'
    if name.endswith('.srs') and name.startswith('.config/sing-box/'):
        return 'rules'
    return None


def build_only(name: str) -> bool:
    parts = PurePosixPath(name).parts
    # Downloaded upstream archives are build inputs, never runtime dependencies.
    return ('.git' in parts or name.startswith('.local/state/')
            or name == '.local/subscriptions.env'
            or name.startswith('.components/'))


def write_zip(path: Path, entries: dict[str, tuple[bytes, int]]) -> None:
    temp = path.with_name(path.name + '.tmp')
    try:
        with zipfile.ZipFile(temp, 'w', compression=zipfile.ZIP_DEFLATED,
                             compresslevel=9) as archive:
            for name, (data, mode) in sorted(entries.items()):
                info = zipfile.ZipInfo(name, STAMP)
                info.create_system = 3
                info.external_attr = mode << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, data, compresslevel=9)
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def package(path: Path, repository: str) -> dict:
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('invalid release repository')
    entries: dict[str, tuple[bytes, int]] = {}
    with zipfile.ZipFile(path) as archive:
        seen = set()
        for info in archive.infolist():
            name = info.filename.rstrip('/') if info.is_dir() else info.filename
            if not safe_name(name) or name in seen:
                raise ValueError(f'unsafe or duplicate ZIP entry: {info.filename!r}')
            seen.add(name)
            if info.is_dir() or build_only(name):
                continue
            mode = info.external_attr >> 16
            if not stat.S_IFMT(mode):
                mode |= stat.S_IFREG
            if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
                raise ValueError(f'unsupported ZIP entry type: {name}')
            entries[name] = (archive.read(info), mode)
    for required in ('module.prop', 'customize.sh', 'bin/magicnet-components', 'bin/sing-box'):
        if required not in entries:
            raise ValueError(f'missing required module file: {required}')
    props = dict(line.split('=', 1) for line in entries['module.prop'][0].decode().splitlines()
                 if '=' in line and not line.startswith('#'))
    version = props['version']
    version_code = int(props['versionCode'])
    if version_code < 1:
        raise ValueError('invalid module versionCode')
    if props.get('id') != 'MagicNet' or not re.fullmatch(r'v?[0-9][A-Za-z0-9._-]*', version):
        raise ValueError('invalid module ID/version')
    customize = entries['customize.sh'][0].decode()
    if customize.count('\nimport this\n') != 1 or 'locked components before' in customize:
        raise ValueError('customize bootstrap anchor changed or package already split')
    entries['customize.sh'] = (customize.replace('\nimport this\n', BOOTSTRAP + '\nimport this\n'),
                               entries['customize.sh'][1])
    entries['customize.sh'] = (entries['customize.sh'][0].encode(), entries['customize.sh'][1])
    groups: dict[str, dict[str, tuple[bytes, int]]] = {}
    core = {}
    for name, value in entries.items():
        component = component_for(name)
        if component:
            if not stat.S_ISREG(value[1]):
                raise ValueError(f'component contains symlink: {name}')
            groups.setdefault(component, {})[name] = value
        else:
            core[name] = value
    if 'sing-box' not in groups:
        raise ValueError('sing-box component is required')
    manifest = {'schema': 1, 'module': 'MagicNet', 'version': version, 'arch': 'arm64',
                'base_url': f'https://github.com/{repository}/releases/download/{version}/',
                'mirrors': ['https://ghfast.top/', 'https://ghproxy.net/', 'https://gh-proxy.com/'],
                'components': []}
    for name, payload in sorted(groups.items()):
        files = [{'path': p, 'sha256': digest(data), 'size': len(data),
                  'mode': 0o755 if (mode & 0o111) or p.startswith('bin/') else 0o644}
                 for p, (data, mode) in sorted(payload.items())]
        identity = digest(json.dumps(files, sort_keys=True, separators=(',', ':')).encode())
        asset = f'MagicNet-component-{name}-arm64-{identity[:16]}.zip'
        # Normalize permission metadata too, so identical contents reproduce archives.
        normalized = {f['path']: (payload[f['path']][0], stat.S_IFREG | f['mode']) for f in files}
        target = path.parent / asset
        write_zip(target, normalized)
        manifest['components'].append({'id': name, 'version': identity, 'asset': asset,
                                       'sha256': digest(target.read_bytes()),
                                       'size': target.stat().st_size, 'files': files})
    encoded = (json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()
    for payload in (entries, core):
        payload['.components/manifest.json'] = (encoded, stat.S_IFREG | 0o644)
    # Core installations must stay on the core channel on the next manager
    # update instead of silently downloading the old full ZIP again.
    update_url = f'https://github.com/{repository}/releases/latest/download/update-core.json'
    core_prop = entries['module.prop'][0].decode().splitlines()
    core_prop = [line for line in core_prop if not line.startswith('updateJson=')]
    core_prop.append('updateJson=' + update_url)
    core['module.prop'] = (('\n'.join(core_prop) + '\n').encode(), entries['module.prop'][1])
    core_update = {'version': version, 'versionCode': version_code,
                   'zipUrl': manifest['base_url'] + 'MagicNet-core.zip',
                   'changelog': f'https://github.com/{repository}/releases/tag/{version}'}
    (path.parent / 'update-core.json').write_text(json.dumps(core_update, indent=2) + '\n')
    # Keep MagicNet.zip as the backwards-compatible full/offline entry point.
    write_zip(path, entries)
    write_zip(path.parent / 'MagicNet-core.zip', core)
    write_zip(path.parent / 'MagicNet-full.zip', entries)
    (path.parent / 'components-manifest.json').write_bytes(encoded)
    sizes = {p.name: p.stat().st_size for p in sorted(path.parent.glob('*.zip'))}
    print(json.dumps({'packages_bytes': sizes}, indent=2))
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--repository', default='LIghtJUNction/MagicNet')
    args = parser.parse_args()
    package(args.archive, args.repository)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Ship the same component engine in the branded installer and module core."""
import argparse
import json
from pathlib import Path
import re
import stat
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def package(helper: Path, output: Path) -> None:
    version = json.loads((ROOT / 'installer/smart/version.json').read_text())
    if not re.fullmatch(r'\d+\.\d+\.\d+', version['version']) or type(version['versionCode']) is not int or version['versionCode'] < 4:
        raise ValueError('invalid smart installer version')
    binary = helper.read_bytes()
    if len(binary) < 20 or binary[:4] != b'\x7fELF' or struct.unpack_from('<H', binary, 18)[0] != 183:
        raise ValueError('smart installer requires the verified Android arm64 helper')
    source = ROOT / 'tmpl/downloader_template/src/{{prop.id}}'
    entries = {
        'module.prop': (f"id=magicnet_installer\nname=MagicNet Installer\nversion={version['version']}\nversionCode={version['versionCode']}\nauthor=LIghtJUNction\ndescription=Smart component-aware MagicNet installer: reuse, resume, verify, install.\n".encode(), 0o644),
        'download.json': (json.dumps({'repository': 'LIghtJUNction/MagicNet', 'module_id': 'MagicNet', 'asset': 'MagicNet-core.zip'}).encode(), 0o644),
        'customize.sh': ((ROOT / 'installer/smart/customize.sh').read_bytes(), 0o755),
        'bin/module-downloader': (binary, 0o755),
    }
    for name in ('META-INF/com/google/android/update-binary', 'META-INF/com/google/android/updater-script'):
        entries[name] = ((source / name).read_bytes(), 0o755 if name.endswith('update-binary') else 0o644)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix('.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, (data, mode) in sorted(entries.items()):
                info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | mode) << 16
                archive.writestr(info, data, compresslevel=9)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError('installer ZIP CRC validation failed')
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    package(args.helper, args.output)

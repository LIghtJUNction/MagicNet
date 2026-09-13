#!/usr/bin/env python3
"""Package the standalone installer from the shared, tested template and bootstrap."""
import argparse
import json
from pathlib import Path
import stat
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def package(helper: Path, output: Path) -> None:
    template = ROOT / 'tmpl/downloader_template'
    prop = tomllib.loads((template / 'kam.toml').read_text())['prop']
    variables = {'target_repository': 'LIghtJUNction/MagicNet',
                 'target_asset': 'MagicNet.zip', 'target_module': 'MagicNet'}
    files = {}
    for path in (template / 'src/{{prop.id}}').rglob('*'):
        if not path.is_file():
            continue
        text = path.read_text()
        for name, value in variables.items():
            text = text.replace('{{' + name + '}}', value)
        files[path.relative_to(template / 'src/{{prop.id}}').as_posix()] = text.encode()
    files['module.prop'] = (
        'id=magicnet_installer\nname=MagicNet Smart Installer\n'
        f'version={prop["version"]}\nversionCode={prop["versionCode"]}\n'
        'author=LIghtJUNction\n'
        'description=Smart verified install with per-component reuse and minimum download planning\n'
    ).encode()
    binary = helper.read_bytes()
    if binary[:4] != b'\x7fELF' or int.from_bytes(binary[18:20], 'little') != 183:
        raise ValueError('installer requires the Android arm64 component bootstrap')
    files['bin/module-downloader'] = binary
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = output.with_suffix('.tmp')
    try:
        with zipfile.ZipFile(temp, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, content in sorted(files.items()):
                info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                executable = name.startswith('bin/') or name.endswith(('.sh', 'update-binary'))
                info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
                info.create_system = 3
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, content, compresslevel=9)
        with zipfile.ZipFile(temp) as archive:
            if archive.testzip() is not None:
                raise ValueError('installer ZIP failed CRC verification')
            json.loads(archive.read('download.json'))
        temp.replace(output)
    finally:
        temp.unlink(missing_ok=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    package(args.helper, args.output)

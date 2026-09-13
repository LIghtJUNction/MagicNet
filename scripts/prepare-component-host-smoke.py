#!/usr/bin/env python3
"""Copy a release archive, replacing only its Android bootstrap for host tests."""
import copy
from pathlib import Path
import sys
import zipfile


def prepare(source: Path, work: Path) -> None:
    binary = (work / 'magicnet-components').read_bytes()
    target = work / 'host-smoke.zip'
    with zipfile.ZipFile(source) as src, zipfile.ZipFile(target, 'w') as out:
        for info in src.infolist():
            data = binary if info.filename == 'bin/magicnet-components' else src.read(info)
            # writestr changes header_offset and other metadata. Never hand it
            # an object still owned by the source archive's central directory.
            out.writestr(copy.copy(info), data)
        manifest = src.read('.components/manifest.json')
    with zipfile.ZipFile(target) as archive:
        bad = archive.testzip()
        if bad is not None:
            raise ValueError(f'corrupt host smoke entry: {bad}')
        if archive.read('.components/manifest.json') != manifest:
            raise ValueError('host smoke manifest differs from release')
    (work / 'manifest.json').write_bytes(manifest)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: prepare-component-host-smoke.py MODULE_ZIP WORK_DIR')
    prepare(Path(sys.argv[1]), Path(sys.argv[2]))

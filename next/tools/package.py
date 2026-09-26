"""Build a deterministic, ABI-checked *candidate* module from explicit inputs.
No downloads, latest-version lookups, secrets, private checkout state, or
production cutover are implicit. Checksums establish integrity, not authorship.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ABIS = {'aarch64-linux-android': 183, 'x86_64-linux-android': 62}
BINARIES = ('magicnet-cli', 'sing-box', 'curl', 'yq')
HOOKS = ('customize.sh', 'service.sh', 'boot-completed.sh', 'action.sh', 'uninstall.sh')
MAX_FILE = 256 * 1024 * 1024
MAX_PACKAGE = 512 * 1024 * 1024


def elf(data: bytes, abi: str) -> None:
    if len(data) < 64 or data[:7] != b'\x7fELF\x02\x01\x01':
        raise ValueError('Expected a 64-bit little-endian ELF binary')
    kind, machine = struct.unpack_from('<HH', data, 16)
    if kind not in (2, 3) or machine != ABIS[abi]:
        raise ValueError('ELF ABI does not match the selected Android target')
    offset = struct.unpack_from('<Q', data, 32)[0]
    entry_size, count = struct.unpack_from('<HH', data, 54)
    if count > 1024 or (count and entry_size != 56) or offset + count * entry_size > len(data):
        raise ValueError('ELF program headers are invalid or truncated')
    for index in range(count):
        header = offset + index * entry_size
        if struct.unpack_from('<I', data, header)[0] != 3:
            continue
        start, size = struct.unpack_from('<Q', data, header + 8)[0], struct.unpack_from('<Q', data, header + 32)[0]
        if size > 256 or start + size > len(data) or data[start:start + size] != b'/system/bin/linker64\0':
            raise ValueError('Host dynamic loader is not an Android runtime dependency')


def read(path: Path, maximum: int = MAX_FILE) -> bytes:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
        raise ValueError('A package input is not a bounded regular file')
    # A replaced symlink cannot be followed between lstat and open.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        opened = os.fstat(stream.fileno())
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
            raise ValueError('A package input changed during inspection')
        result = stream.read(maximum + 1)
    if len(result) > maximum:
        raise ValueError('A package input grew beyond its size limit')
    return result


def inputs(runtime: Path, webui: Path, abi: str, version: str, revision: str) -> dict[str, tuple[bytes, int]]:
    if abi not in ABIS or not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('An explicit supported ABI and 40-character source revision are required')
    if not re.fullmatch(r'[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}', version):
        raise ValueError('The package version must be a bounded metadata token')
    for directory in (runtime, webui):
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError('Inputs must be real directories, not links')
    result: dict[str, tuple[bytes, int]] = {}
    for name in BINARIES:
        data = read(runtime / name)
        elf(data, abi)
        result[f'bin/{name}'] = data, 0o755
    for name in HOOKS:
        data = read(ROOT / 'module' / name, 32 * 1024)
        if b'\r' in data or not data.startswith(b'#!/system/bin/sh\n'):
            raise ValueError('Module hooks must use Android sh with LF line endings')
        result[name] = data, 0o755
    for directory, dirs, files in os.walk(webui, followlinks=False):
        for name in dirs:
            if (Path(directory) / name).is_symlink():
                raise ValueError('The WebUI contains a linked directory')
        for name in files:
            source = Path(directory) / name
            relative = source.relative_to(webui)
            if any(part.startswith('.') for part in relative.parts) or source.suffix not in {'.html','.js','.css','.svg','.png','.webp','.ico','.json'}:
                raise ValueError('The WebUI includes a private or unsupported asset')
            result[f'webroot/{relative.as_posix()}'] = read(source, 8 * 1024 * 1024), 0o644
    if 'webroot/index.html' not in result:
        raise ValueError('The built WebUI is missing index.html')
    result['module.prop'] = (f'id=MagicNetNext\nname=MagicNet Next (candidate)\nversion={version}\nversionCode=2000000\nauthor=LIghtJUNction\ndescription=Isolated rewrite candidate; does not replace MagicNet v1\n'.encode(), 0o644)
    result['abi'] = (abi + '\n').encode(), 0o644
    result['module-id'] = b'MagicNetNext\n', 0o644
    result['skip_mount'] = b'', 0o644
    result['.magicnet-candidate.json'] = b'{"schema":1,"kind":"isolated-candidate","version":2}\n', 0o600
    if len(result) > 1024 or sum(len(data) for data, _ in result.values()) > MAX_PACKAGE:
        raise ValueError('The complete package exceeds its entry or size bound')
    manifest = {'schema':1,'kind':'isolated-candidate','production':False,'module_id':'MagicNetNext',
                'version':version,'revision':revision,'abi':abi,
                'files':[{'path':name,'sha256':hashlib.sha256(data).hexdigest(),'size':len(data),'mode':mode}
                         for name,(data,mode) in sorted(result.items())]}
    result['manifest.json'] = (json.dumps(manifest,ensure_ascii=False,sort_keys=True,indent=2)+'\n').encode(), 0o644
    return result


def build(runtime: Path, webui: Path, output: Path, abi: str, version: str, revision: str) -> str:
    contents = inputs(runtime, webui, abi, version, revision)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.magicnet-package-', dir=output.parent)
    try:
        with os.fdopen(fd,'w+b') as stream:
            with zipfile.ZipFile(stream,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
                for path,(data,mode) in sorted(contents.items()):
                    item=zipfile.ZipInfo(path,date_time=(1980,1,1,0,0,0))
                    item.create_system=3
                    item.external_attr=(stat.S_IFREG|mode)<<16
                    item.compress_type=zipfile.ZIP_DEFLATED
                    archive.writestr(item,data)
            stream.flush(); os.fsync(stream.fileno())
        os.replace(name,output)
        directory=os.open(output.parent,os.O_RDONLY|os.O_DIRECTORY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        try: os.unlink(name)
        except FileNotFoundError: pass
    with output.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime',type=Path,required=True)
    parser.add_argument('--webui',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--abi',choices=ABIS,required=True)
    parser.add_argument('--version',default='2.0.0-alpha.1')
    parser.add_argument('--revision',required=True)
    args=parser.parse_args()
    try:
        digest=build(args.runtime,args.webui,args.output,args.abi,args.version,args.revision)
        print(json.dumps({'schema':1,'sha256':digest,'production':False,'output':str(args.output)}))
    except (OSError,ValueError) as error:
        parser.exit(1,f'Package validation failed: {error}\n')

#!/usr/bin/env python3
"""Build the production-pinned Proxylink revision for the disposable x86_64 AVD."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / 'hooks/pre-build/4910.update_proxylink.sh'


def production_pin(text):
    values = {}
    for name, pattern in (('REPO_URL', r'https://github\.com/[\w.-]+/[\w.-]+\.git'),
                          ('PINNED_REV', r'[0-9a-f]{40}')):
        matches = re.findall(r'^' + name + r'="(' + pattern + r')"$', text, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError('missing or ambiguous production Proxylink pin: ' + name)
        values[name] = matches[0]
    return values['REPO_URL'], values['PINNED_REV']


def build(destination, hook=HOOK):
    repo, revision = production_pin(hook.read_text())
    destination = Path(destination).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='proxylink-avd-', dir=destination.parent) as directory:
        root = Path(directory)
        source = root / 'source'
        subprocess.run(['git', 'init', '-q', str(source)], check=True, timeout=15)
        subprocess.run(['git', '-C', str(source), 'remote', 'add', 'origin', repo], check=True, timeout=15)
        subprocess.run(['git', '-C', str(source), 'fetch', '-q', '--depth', '1', 'origin', revision],
                       check=True, timeout=120)
        subprocess.run(['git', '-C', str(source), 'checkout', '-q', '--detach', revision],
                       check=True, timeout=15)
        actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'],
                                         text=True, timeout=15).strip()
        if actual != revision:
            raise ValueError('Proxylink source revision mismatch')
        output = root / 'proxylink'
        environment = dict(os.environ, CGO_ENABLED='0', GOOS='linux', GOARCH='amd64')
        subprocess.run(['go', 'build', '-mod=readonly', '-trimpath', '-ldflags=-s -w',
                        '-o', str(output), '.'], cwd=source / 'Proxylink',
                       env=environment, check=True, timeout=180)
        with output.open('rb') as stream:
            header = stream.read(64)
        if len(header) != 64 or header[:6] != b'\x7fELF\x02\x01' or header[18:20] != b'\x3e\x00':
            raise ValueError('Proxylink build is not an x86_64 ELF')
        output.chmod(0o755)
        os.replace(output, destination)
    print('Proxylink AVD build uses production revision ' + revision)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: build-android-proxylink.py OUTPUT')
    try:
        build(Path(sys.argv[1]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from error

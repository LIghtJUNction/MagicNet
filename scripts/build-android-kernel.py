#!/usr/bin/env python3
"""Build the pinned API35 emulator kernel, or verify its cached build output."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import urllib.request

import yaml

BUILD_ID = '12525588'
COMMON = '8adecb593e9b745427da9d61c3cc8bc4857de209'
KSU = '5f9cada650f1171807c0d702b6cfbf510a2ec175'
RECIPE_SHA256 = '3a06394d29fc87cf9204137bb4634d5dc91030251df962d82ae084b3e1c870a8'
RECIPE_URL = ('https://raw.githubusercontent.com/leemikepop/avd-kernelsu-x86_64/'
              'b3d3fe7d29fed146aaf7b23b5e3b49a63d647822/.github/workflows/_build-gki-core.yml')
MANIFEST_SHA256 = '3828669e61c1cba6a312e1946b702625ed7cff4586ef047fb21f4efbd372dd91'
IDENTITY = {'schema': 1, 'build_id': BUILD_ID, 'common': COMMON, 'kernelsu': KSU,
            'recipe_sha256': RECIPE_SHA256, 'source_manifest_sha256': MANIFEST_SHA256,
            'target': '//common-modules/virtual-device:virtual_device_x86_64_dist'}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            value.update(chunk)
    return value.hexdigest()


def verify(output: Path) -> dict:
    value = json.loads((output / 'provenance.json').read_text())
    if any(value.get(key) != expected for key, expected in IDENTITY.items()):
        raise ValueError('kernel provenance does not match reviewed source pins')
    for name in ('bzImage', 'build-info.txt'):
        path = output / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError('missing or unsafe kernel output: ' + name)
        if value.get('sha256', {}).get(name) != digest(path):
            raise ValueError('kernel output checksum mismatch: ' + name)
    return value


def build(output: Path, work: Path) -> None:
    work.mkdir(parents=True, exist_ok=False)
    with urllib.request.urlopen(RECIPE_URL, timeout=120) as response:
        recipe = response.read(131073)
    if len(recipe) > 131072 or hashlib.sha256(recipe).hexdigest() != RECIPE_SHA256:
        raise ValueError('kernel build recipe changed')
    (work / 'recipe.yml').write_bytes(recipe)
    flow = yaml.safe_load(recipe)
    names = ['Sync Kernel Source', 'Fix Less Than 6.6.50 Builds', 'Integrate KernelSU',
             'Apply x86_64 Syscall Hardening Patches', 'Build GKI Kernel']
    steps = {step['name']: step['run'] for step in flow['jobs']['build']['steps']
             if step.get('name') in names}
    if set(steps) != set(names):
        raise ValueError('unexpected kernel build recipe shape')
    env = dict(os.environ, BUILD_ID=BUILD_ID, TARGET_ID='a15-api35-6.6', TARGET_ARCH='x86_64',
               TARGET_ANDROID_VERSION='android15', KSU_REF='v3.2.0', DIST_NAME='magicnet-dist',
               GITHUB_ENV=str(work / 'stage.env'))
    Path(env['GITHUB_ENV']).touch()
    replacements = {'inputs.ksu_variant': 'KernelSU', 'inputs.ksu_ref': 'v3.2.0',
                    'steps.metadata.outputs.kernel_version': '6.6',
                    'steps.metadata.outputs.sublevel': '50'}
    for name in names:
        script = steps[name]
        for key, value in replacements.items():
            script = script.replace('${{ ' + key + ' }}', value)
        if '${{' in script:
            raise ValueError('unresolved kernel recipe expression')
        if name == 'Sync Kernel Source':
            marker = "python3 - <<'PY'"
            if script.count(marker) != 1:
                raise ValueError('unexpected manifest download step')
            check = ('printf "%s  %s\\n" ' + MANIFEST_SHA256 +
                     ' ".repo/manifests/manifest_${BUILD_ID}.xml" | sha256sum --check --strict\n')
            script = script.replace(marker, check + marker)
        if name == 'Build GKI Kernel':
            script = script.replace('//common:kernel_x86_64_dist', IDENTITY['target'])
        print('::group::' + name, flush=True)
        subprocess.run(['bash', '-euo', 'pipefail', '-c', script], cwd=work,
                       env=env, check=True, timeout=5400)
        print('::endgroup::', flush=True)
        for line in Path(env['GITHUB_ENV']).read_text().splitlines():
            key, sep, value = line.partition('=')
            if sep and re.fullmatch(r'KSU_[A-Z0-9_]+', key):
                env[key] = value
        if name in ('Sync Kernel Source', 'Integrate KernelSU'):
            repo, expected = ('common', COMMON) if name == 'Sync Kernel Source' else ('KernelSU', KSU)
            actual = subprocess.check_output(['git', '-C', str(work / 'kernel' / repo),
                                              'rev-parse', 'HEAD'], text=True).strip()
            if actual != expected:
                raise ValueError('kernel source revision changed: ' + repo)
    if env.get('KSU_X86_SYSCALL_CHECK_BYPASSED') != 'false':
        raise ValueError('KernelSU capability check must remain enabled')
    output.mkdir(parents=True, exist_ok=False)
    shutil.copy2(work / 'kernel/magicnet-dist/bzImage', output / 'bzImage')
    (output / 'build-info.txt').write_text(
        'Target ID: a15-api35-6.6\nBuild ID: ' + BUILD_ID + '\nArchitecture: x86_64\n'
        'Kernel Version: 6.6\nKSU Variant: KernelSU\nKSU Requested Ref: v3.2.0\n'
        'x86_64 Syscall Hardening Patch Applied: true\n'
        'x86_64 Syscall Hardening Default Off: true\nRequired Emulator Boot Arg: none\n')
    for key in ('KSU_X86_SYSCALL_HARDENING_PATCHED', 'KSU_X86_SYSCALL_HARDENING_DEFAULT_OFF'):
        if env.get(key) != 'true':
            raise ValueError('required x86 compatibility patch missing')
    value = dict(IDENTITY, sha256={name: digest(output / name)
                                 for name in ('bzImage', 'build-info.txt')})
    (output / 'provenance.json').write_text(json.dumps(value, indent=2) + '\n')
    verify(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work', type=Path)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.verify:
        verify(args.output.resolve())
    else:
        if args.work is None:
            parser.error('--work is required for a build')
        build(args.output.resolve(), args.work.resolve())


if __name__ == '__main__':
    main()

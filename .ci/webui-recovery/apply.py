"""Restore one hash-pinned UTF-8 source delta; no main/tag/branch mutations."""
import hashlib
import json
import lzma
import os
from pathlib import Path, PurePosixPath
import subprocess

BASE = '8f432d81986676304e1e252de4c6aea7f124b383'
TREE = 'b91f6fe7e0fb2e78e41a404e2dd18935cbd2ddcc'
DELTA_SHA = '8b75e533d7e4ce9739e1d83bea36b476db6ec8f93ac87fbf04b75b2187ac3f93'
raw = lzma.decompress(b''.join(Path(f'.ci/webui-recovery/part{i}.bin').read_bytes() for i in range(4)))
assert hashlib.sha256(raw).hexdigest() == DELTA_SHA
files = json.loads(raw)
assert len(files) == 37
out = Path(os.environ['RUNNER_TEMP']) / 'webui-recovery-evidence'
out.mkdir(exist_ok=True)
(out / 'delta.json').write_bytes(raw)
subprocess.run(['git', 'reset', '--hard', BASE], check=True)
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == BASE
for name, item in files.items():
    path = PurePosixPath(name)
    assert not path.is_absolute() and '..' not in path.parts
    assert path.parts[0] in ('docs', 'installer', 'scripts', 'src', 'webui')
    assert name not in ('src/MagicNet/module.prop', 'webui/package-lock.json')
    target = Path(name)
    old = target.read_bytes() if target.is_file() else b''
    if item['before'] is None:
        assert not target.exists()
    else:
        assert hashlib.sha256(old).hexdigest() == item['before'], name
    if item['after'] is None:
        target.unlink()
        continue
    lines = old.decode().splitlines(keepends=True)
    text = ''.join(op if isinstance(op, str) else ''.join(lines[op[0]:op[1]]) for op in item['ops'])
    data = text.encode()
    assert hashlib.sha256(data).hexdigest() == item['after'], name
    assert item['mode'] in ('100644', '100755')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    target.chmod(int(item['mode'][-3:], 8))
subprocess.run(['git', 'add', '--', *files], check=True)
subprocess.run(['git', 'diff', '--cached', '--check'], check=True)
actual = subprocess.check_output(['git', 'write-tree'], text=True).strip()
assert actual == TREE, (actual, TREE)
receipt = {'base': BASE, 'tree': TREE, 'delta_sha256': DELTA_SHA,
           'files': {name: {'sha256': item['after'], 'mode': item['mode']} for name, item in files.items()}}
(out / 'source-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))

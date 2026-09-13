#!/usr/bin/env python3
"""Check ZIP local headers, CRC and nested manager installation without Android."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zipfile

archive = Path(sys.argv[1]).resolve()
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    assert len(z.namelist()) == len(set(z.namelist()))
    raw = archive.read_bytes()
    for info in z.infolist():
        assert raw[info.header_offset:info.header_offset + 4] == b'PK\x03\x04'
        name_len = struct.unpack_from('<H', raw, info.header_offset + 26)[0]
        assert raw[info.header_offset + 30:info.header_offset + 30 + name_len].decode() == info.filename
    assert b'id=magicnet_installer\n' in z.read('module.prop')
    config = json.loads(z.read('download.json'))
    assert config['module_id'] == 'MagicNet'
    binary = z.read('bin/module-downloader')
    assert binary[:4] == b'\x7fELF' and struct.unpack_from('<H', binary, 18)[0] == 183
    script = z.read('customize.sh')
for failure in (False, True):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        module = root / 'installer'
        module.mkdir()
        customize = root / 'customize.sh'
        customize.write_bytes(script)
        # Mock only the downloader and manager; execute the real customize script.
        harness = r'''
set -eu
ui_print() { printf '%s\n' "$*"; }
abort() { printf '%s\n' "$*" >&2; exit 1; }
unzip() {
 mkdir -p "$MODPATH/bin"
 cat > "$MODPATH/bin/module-downloader" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
 if [ "$1" = -out ]; then shift; printf verified > "$1"; exit 0; fi
 shift
done
exit 1
SH
}
install_module() {
 [ "$ZIPFILE" != "$ORIGINAL_ZIP" ]
 [ "$(cat "$ZIPFILE")" = verified ]
 [ "$TMPDIR" != "$ORIGINAL_TMP" ]
 printf invoked > "$TEST_ROOT/called"
 [ "$FAIL_INSTALL" = 0 ]
}
. "$TEST_ROOT/customize.sh"
[ "$ZIPFILE" = "$ORIGINAL_ZIP" ]
[ "$TMPDIR" = "$ORIGINAL_TMP" ]
'''
        env = dict(os.environ, TEST_ROOT=tmp, MODPATH=str(module), BOOTMODE='true', ARCH='arm64', ZIPFILE='/original.zip', ORIGINAL_ZIP='/original.zip', TMPDIR='/original-tmp', ORIGINAL_TMP='/original-tmp', FAIL_INSTALL=str(int(failure)))
        r = subprocess.run(['sh', '-c', harness], env=env, capture_output=True, text=True)
        assert (r.returncode != 0) == failure, (r.stdout, r.stderr)
        assert (root / 'called').exists()
        assert not list(root.glob('installer.download.*'))
print('ZIP/ELF verification, manager isolation, failure propagation and cleanup passed')

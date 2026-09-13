#!/usr/bin/env bash
# Exercise real release payloads. Only the bootstrap executable is host-built;
# Android payload bytes and component manifests are not rewritten for the test.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$(realpath "${1:?full module ZIP required}")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(
  cd "$ROOT/tools/components"
  go build -trimpath -o "$work/magicnet-components" .
)
python3 - "$archive" "$work" <<'PY'
from pathlib import Path
import sys
import zipfile
source, work = Path(sys.argv[1]), Path(sys.argv[2])
with zipfile.ZipFile(source) as src, zipfile.ZipFile(work/'host-smoke.zip', 'w') as out:
    for info in src.infolist():
        data = (work/'magicnet-components').read_bytes() if info.filename == 'bin/magicnet-components' else src.read(info)
        out.writestr(info, data)
    (work/'manifest.json').write_bytes(src.read('.components/manifest.json'))
PY
# These are the existing full installer/configuration/runtime regressions, not
# a replacement that only checks whether archive entries exist.
bash "$ROOT/scripts/package-install-smoke.sh" "$work/host-smoke.zip"
bash "$ROOT/scripts/fake-magisk-smoke.sh" "$work/host-smoke.zip"
# Verify core -> previous-full reuse against the actual release payloads.
"$work/magicnet-components" --manifest "$work/manifest.json" --module "$work/previous" \
  --previous "$work/nonexistent" --bundle "$archive" --cache "$work/cache"
"$work/magicnet-components" --manifest "$work/manifest.json" --module "$work/upgraded" \
  --previous "$work/previous" --bundle "$(dirname "$archive")/MagicNet-core.zip" --cache "$work/cache"
test ! -e "$work/cache"

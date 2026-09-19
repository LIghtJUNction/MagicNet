#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
output=${1:-"$project_root/src/MagicNet/libexec/network-policy-bridge.jar"}
d8=${MAGICNET_D8:-}
if [[ -z "$d8" ]] && command -v d8 >/dev/null 2>&1; then
    d8=$(command -v d8)
fi
if [[ -z "$d8" ]]; then
    for sdk_root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" /opt/android-sdk; do
        [[ -n "$sdk_root" ]] || continue
        for version in 36.0.0 35.0.0; do
            if [[ -x "$sdk_root/build-tools/$version/d8" ]]; then
                d8="$sdk_root/build-tools/$version/d8"
                break 2
            fi
        done
    done
fi
if [[ -z "$d8" || ! -x "$d8" ]] || ! command -v javac >/dev/null 2>&1; then
    echo 'Network policy bridge requires javac and Android d8; set MAGICNET_D8 to its executable.' >&2
    exit 1
fi
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
mkdir -p "$build_dir/classes" "$build_dir/dex" "$(dirname "$output")"
javac --release 8 -Xlint:-options -d "$build_dir/classes" \
    "$project_root/crates/magicnet-cli/android/NetworkPolicyBridge.java"
mapfile -d '' classes < <(find "$build_dir/classes" -name '*.class' -type f -print0)
"$d8" --min-api 26 --output "$build_dir/dex" "${classes[@]}"
python3 - "$build_dir/dex/classes.dex" "$output" <<'PY'
import os
import sys
import tempfile
import zipfile
from pathlib import Path
source, output = map(Path, sys.argv[1:])
fd, temporary = tempfile.mkstemp(prefix='.network-policy-', dir=output.parent)
os.close(fd)
try:
    with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        info = zipfile.ZipInfo('classes.dex', date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, source.read_bytes())
    os.chmod(temporary, 0o644)
    os.replace(temporary, output)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY

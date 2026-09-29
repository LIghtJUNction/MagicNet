#!/usr/bin/env bash
# ABI-correct versions of the additional tools shipped by the production module.
# Does not execute captures or start a proxy; these are installation payloads.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?usage: prepare-android-fixture-tools.sh OUTPUT_DIRECTORY}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Keep the Android flavor and release aligned with the shipped ARM64 component.
# A version change requires reviewing the matching x86_64 digest, not guessing it.
# shellcheck source=hooks/lib/release_locks.sh
. "$ROOT/hooks/lib/release_locks.sh"
release_lock_lookup ecapture
[[ "$RELEASE_LOCK_REPO" == gojue/ecapture && "$RELEASE_LOCK_TAG" == v2.5.2 &&
   "$RELEASE_LOCK_ASSET" == ecapture-v2.5.2-android-arm64.tar.gz ]] || {
    echo 'eCapture fixture pin must be reviewed alongside the production pin' >&2
    exit 1
}
curl --fail --location --retry 3 --max-time 180 \
    "https://github.com/$RELEASE_LOCK_REPO/releases/download/$RELEASE_LOCK_TAG/ecapture-v2.5.2-android-amd64.tar.gz" \
    -o "$WORK/ecapture.tar.gz"
printf '%s  %s\n' 904f8335b70ea42fe00070b1af107b8a6fadfcdc4697d990b64b4740922cde54 \
    "$WORK/ecapture.tar.gz" | sha256sum --check --strict
# Extract only one bounded regular file, without following archive paths/links.
python3 - "$WORK" <<'PY'
from pathlib import Path, PurePosixPath
import sys
import tarfile
root = Path(sys.argv[1])
with tarfile.open(root / 'ecapture.tar.gz', 'r:gz') as archive:
    matches = [m for m in archive.getmembers() if PurePosixPath(m.name).name == 'ecapture']
    if len(matches) != 1 or not matches[0].isfile() or not 0 < matches[0].size <= 96 * 1024 * 1024:
        raise SystemExit('expected one bounded regular eCapture executable')
    with archive.extractfile(matches[0]) as source, (root / 'ecapture').open('wb') as target:
        target.write(source.read(matches[0].size))
PY

# Read only the reviewed literal pin; never source a build hook to discover it.
revision="$(sed -n 's/^PINNED_REV="\([0-9a-f]*\)"$/\1/p' "$ROOT/hooks/pre-build/4910.update_proxylink.sh")"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid Proxylink pin' >&2; exit 1; }
git init -q "$WORK/proxylink-src"
git -C "$WORK/proxylink-src" remote add origin https://github.com/Fanju6/Proxylink.git
timeout 180 git -C "$WORK/proxylink-src" fetch -q --depth 1 origin "$revision"
git -C "$WORK/proxylink-src" checkout -q --detach "$revision"
[[ "$(git -C "$WORK/proxylink-src" rev-parse HEAD)" == "$revision" ]]
(
    cd "$WORK/proxylink-src/Proxylink"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
        timeout 300 go build -mod=readonly -trimpath -ldflags='-s -w' -o "$WORK/proxylink" .
)
for tool in ecapture proxylink; do
    readelf -h "$WORK/$tool" >"$WORK/header"
    grep -Eq 'Machine:.*X86-64' "$WORK/header"
    readelf -l "$WORK/$tool" >"$WORK/segments"
    if grep -q INTERP "$WORK/segments"; then
        grep -Fq '[Requesting program interpreter: /system/bin/linker64]' "$WORK/segments"
    fi
    install -m 0755 "$WORK/$tool" "$OUT/$tool"
done

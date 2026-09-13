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
python3 "$ROOT/scripts/prepare-component-host-smoke.py" "$archive" "$work"
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

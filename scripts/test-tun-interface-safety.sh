#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
TRANSPARENT="$ROOT/src/MagicNet/lib/magicnet/transparent.sh"

# The standalone loader has no interface ownership evidence. A familiar name
# cannot authorize deleting a TUN; the owned core performs its own teardown.
if grep -Eq 'ip[[:space:]]+link[[:space:]]+delete[[:space:]]+(tun0|magicnet0)([[:space:]]|$)' "$CONFIG"; then
    printf '%s\n' 'subscription restart deletes a TUN without ownership evidence' >&2
    exit 1
fi
grep -Eq '"interface_name"[[:space:]]*:[[:space:]]*"magicnet0"' "$TRANSPARENT"

printf '%s\n' 'TUN interface safety test passed'

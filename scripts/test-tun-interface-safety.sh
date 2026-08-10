#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
TRANSPARENT="$ROOT/src/MagicNet/lib/magicnet/transparent.sh"

# MagicNet owns only magicnet0.  A subscription restart must never tear down
# tun0 (or any other legacy/third-party VPN interface) as a side effect.
if grep -Eq 'ip[[:space:]]+link[[:space:]]+delete[[:space:]]+tun0([[:space:]]|$)' "$CONFIG"; then
    printf '%s\n' 'subscription restart still deletes third-party tun0' >&2
    exit 1
fi
grep -Eq 'ip[[:space:]]+link[[:space:]]+delete[[:space:]]+magicnet0([[:space:]]|$)' "$CONFIG"
grep -Fq '"interface_name": "magicnet0"' "$TRANSPARENT"

printf '%s\n' 'TUN interface safety test passed'

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export MODDIR="$fixture/module"
mkdir -p "$MODDIR/.state/config.lock"
printf 'protected owner\n' >"$MODDIR/.state/config.lock/pid"
for key in MAGICNET_CONFIG_LOCK_TIMEOUT MAGICNET_CONFIG_LOCK_NO_PID_TIMEOUT; do
    for value in invalid -1 1.5 901 999999999999999999999999; do
        rc=0
        timeout 2 env "$key=$value" bash -s -- "$ROOT" <<'CHILD' || rc=$?
import() { :; }
. "$1/src/MagicNet/lib/magicnet/common.sh"
magicnet_warn() { :; }
magicnet_config_lock_owner_matches() { return 2; }
magicnet_config_lock_acquire
CHILD
        test "$rc" -eq 1 || { printf 'invalid budget %s=%s escaped validation (rc=%s)\n' "$key" "$value" "$rc" >&2; exit 1; }
        test "$(cat "$MODDIR/.state/config.lock/pid")" = 'protected owner'
    done
done
printf 'config lock budget tests passed\n'

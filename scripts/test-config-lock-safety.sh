#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-config-lock.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

export MODDIR="$fixture/module"
mkdir -p "$MODDIR/.state/config.lock"
import() { :; }
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"

# A stale signal trap from another PID must not remove the current owner.
printf '%s\n' '999999:1' >"$MODDIR/.state/config.lock/pid"
magicnet_config_lock_release
test -d "$MODDIR/.state/config.lock"

# The current owner can release its own marker, and the directory is removed
# only after the marker is gone (never with recursive deletion).
start="$(awk '{print $22}' /proc/$$/stat)"
printf '%s:%s\n' "$$" "$start" >"$MODDIR/.state/config.lock/pid"
magicnet_config_lock_release
test ! -e "$MODDIR/.state/config.lock"

# Stale and marker-less owners are reclaimed without recursive deletion.
mkdir -p "$MODDIR/.state/config.lock"
printf '%s\n' '999999:1' >"$MODDIR/.state/config.lock/pid"
magicnet_config_lock_acquire
test "$(cut -d: -f1 "$MODDIR/.state/config.lock/pid")" = "$$"
magicnet_config_lock_release

mkdir -p "$MODDIR/.state/config.lock"
MAGICNET_CONFIG_LOCK_NO_PID_TIMEOUT=1 magicnet_config_lock_acquire
test "$(cut -d: -f1 "$MODDIR/.state/config.lock/pid")" = "$$"
magicnet_config_lock_release

# A marker write failure must not leave an empty directory that blocks every
# later config update until the timeout-based reclamation path runs.
printf() {
    case "${2:-}" in
        "$$"|"$$:"*) return 1 ;;
    esac
    command printf "$@"
}
set +e
magicnet_config_lock_acquire
acquire_rc=$?
set -e
unset -f printf
[ "$acquire_rc" -ne 0 ] || {
    printf '%s\n' 'config lock acquisition succeeded after marker write failure' >&2
    exit 1
}
[ ! -e "$MODDIR/.state/config.lock" ] || {
    printf '%s\n' 'failed config lock acquisition leaked its directory' >&2
    exit 1
}

printf '%s\n' 'config lock safety test passed'

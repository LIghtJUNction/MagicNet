#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export MODDIR="$WORKDIR/module"
UPDATE_LOCK="$MODDIR/.state/sing-box/subscription-update.lock"
mkdir -p "$UPDATE_LOCK"

info() { :; }
warn() { :; }
error() { :; }
success() { :; }
import() { :; }

# Keep the injected owner-marker failure hook defined before any printf call so
# The static checker must not mistake the intentional builtin override for a late
# declaration.  It is dormant until the second half of the fixture.
printf() {
    if [ "${MAGICNET_TEST_FAIL_OWNER_WRITE:-0}" = "1" ]; then
        case "${2:-}" in
            *:*:*) return 1 ;;
        esac
    fi
    command printf "$@"
}

# shellcheck disable=SC1090
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"

# The PID is live, but its recorded start time is intentionally stale.
printf '%s\n' "$$:0:stale" >"$UPDATE_LOCK/owner"
recursive_reclaim=0
TEST_UPDATE_LOCK="$UPDATE_LOCK"
rm() {
    if [ "${1:-}" = -rf ] && [ "${2:-}" = "$TEST_UPDATE_LOCK" ]; then
        # Model a new owner winning the lock after the stale-owner check and
        # before a recursive removal.  A safe implementation must never use
        # that recursive removal against the lock directory.
        recursive_reclaim=1
        printf '%s\n' 'new-owner' >"$TEST_UPDATE_LOCK/owner"
    fi
    command rm "$@"
}

set +e
magicnet_singbox_update_lock_active
lock_rc=$?
set -e
unset -f rm

[ "$lock_rc" -ne 0 ] || {
    printf '%s\n' 'stale subscription update lock was reported active' >&2
    exit 1
}
[ "$recursive_reclaim" -eq 0 ] || {
    printf '%s\n' 'stale subscription lock reclamation still uses a recursive delete' >&2
    exit 1
}

printf '%s\n' 'subscription update lock safety test passed'

# The owner marker is published immediately after mkdir.  A concurrent status
# read must not mistake that short markerless window for a stale lock and
# remove the directory before the updater can publish its token.
rm -rf "$UPDATE_LOCK"
mkdir -p "$UPDATE_LOCK"
set +e
magicnet_singbox_update_lock_active
markerless_rc=$?
set -e
[ "$markerless_rc" -eq 0 ] || {
    printf '%s\n' 'markerless subscription lock was reclaimed during publication' >&2
    exit 1
}
[ -d "$UPDATE_LOCK" ] || {
    printf '%s\n' 'markerless subscription lock directory disappeared during publication' >&2
    exit 1
}
rm -rf "$UPDATE_LOCK"
printf '%s\n' 'subscription update lock publication-window safety test passed'

# Status recovery mutates the same persisted files as an update.  Verify the
# public status path executes both reconciliation hooks under the config lock.
(
    status_lock_held=0
    status_cache="$MODDIR/.state/sing-box/subscription-cache"
    mkdir -p "$MODDIR/.config/sing-box" "$status_cache"
    magicnet_singbox_subscription_status_file() {
        printf '%s\n' "$MODDIR/.state/sing-box/subscription-status"
    }
    magicnet_singbox_subscription_cache_dir() {
        printf '%s\n' "$status_cache"
    }
    magicnet_singbox_subscription_fingerprint() {
        printf '%064d\n' 0
    }
    magicnet_with_config_lock() {
        status_lock_held=1
        "$@"
        local status_rc=$?
        status_lock_held=0
        return "$status_rc"
    }
    magicnet_singbox_transaction_reconcile() {
        [ "$status_lock_held" -eq 1 ]
    }
    magicnet_singbox_status_reconcile() {
        [ "$status_lock_held" -eq 1 ]
    }
    magicnet_singbox_status >/dev/null
)
printf '%s\n' 'subscription status reconciliation lock-safety test passed'

# An owner marker write failure must not leave an empty directory that blocks
# every later subscription update until a timeout-based reclamation.
rm -rf "$UPDATE_LOCK"
MAGICNET_TEST_FAIL_OWNER_WRITE=1
export MAGICNET_TEST_FAIL_OWNER_WRITE
set +e
magicnet_singbox_update_lock_acquire
acquire_rc=$?
set -e
unset MAGICNET_TEST_FAIL_OWNER_WRITE
[ "$acquire_rc" -ne 0 ] || {
    printf '%s\n' 'subscription update lock acquisition succeeded after owner marker write failure' >&2
    exit 1
}
[ ! -e "$UPDATE_LOCK" ] || {
    printf '%s\n' 'failed subscription update lock acquisition leaked its directory' >&2
    exit 1
}

printf '%s\n' 'subscription update lock write-failure safety test passed'

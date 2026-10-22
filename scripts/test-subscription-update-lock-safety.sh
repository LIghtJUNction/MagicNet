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

# Public status is diagnostic-only.  An interrupted transaction may require a
# disruptive rollback/restart, so status must report it without taking the
# config lock or invoking either reconciliation hook.
(
    status_cache="$MODDIR/.state/sing-box/subscription-cache"
    status_transaction="$MODDIR/.state/sing-box/subscription-transaction"
    status_mutation_marker="$MODDIR/.state/sing-box/status-mutated"
    mkdir -p "$MODDIR/.config/sing-box" "$status_cache" "$status_transaction"
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
        : >"$status_mutation_marker"
        return 99
    }
    magicnet_singbox_transaction_reconcile() {
        : >"$status_mutation_marker"
        return 99
    }
    magicnet_singbox_status_reconcile() {
        : >"$status_mutation_marker"
        return 99
    }
    status_output="$(magicnet_singbox_status)"
    [ ! -e "$status_mutation_marker" ]
    [ -d "$status_transaction" ]
    grep -q '^recovery_result=pending$' <<<"$status_output"
)
printf '%s\n' 'subscription status read-only safety test passed'

# A signal can arrive after restart_owned stopped fswatch but before the update
# wrapper reached its normal deferred restore. The interrupt path must release
# the config lock first, then restore fswatch before dropping the update lock.
interrupt_trace="$MODDIR/.state/sing-box/interrupt-trace"
set +e
(
    export MAGICNET_CONFIG_LOCK_HELD=1
    export MAGICNET_SUB_DEFER_FSWATCH_RESTORE=1
    export MAGICNET_SUB_FSWATCH_RESTORE_PENDING=0
    export MAGICNET_SUB_FSWATCH_WAS_ACTIVE=1
    magicnet_singbox_transaction_reconcile() { :; }
    magicnet_singbox_update_cleanup_stage() { :; }
    magicnet_singbox_status_mark_interrupted() { :; }
    magicnet_config_lock_release() { printf '%s\n' config-release >>"$interrupt_trace"; }
    magicnet_singbox_supervisor_restore() {
        [ "$1" -eq 1 ]
        [ -z "${MAGICNET_SUB_DEFER_FSWATCH_RESTORE+x}" ]
        printf '%s\n' fswatch-restore >>"$interrupt_trace"
    }
    magicnet_singbox_update_lock_release() { printf '%s\n' update-release >>"$interrupt_trace"; }
    magicnet_singbox_update_interrupt 143
)
interrupt_rc=$?
set -e
[ "$interrupt_rc" -eq 143 ]
[ "$(<"$interrupt_trace")" = $'config-release\nfswatch-restore\nupdate-release' ]

printf '%s\n' 'subscription interrupt fswatch restoration test passed'

# A signal while config-lock acquisition is still waiting must not reconcile
# another operation's files without owning that lock. Leave the journal for a
# later status/startup recovery and release only the update lock.
prelock_interrupt_trace="$MODDIR/.state/sing-box/prelock-interrupt-trace"
set +e
(
    unset MAGICNET_CONFIG_LOCK_HELD MAGICNET_SUB_FSWATCH_RESTORE_PENDING
    unset MAGICNET_SUB_FSWATCH_WAS_ACTIVE MAGICNET_SUB_DEFER_FSWATCH_RESTORE
    magicnet_singbox_transaction_reconcile() { printf '%s\n' reconcile >>"$prelock_interrupt_trace"; }
    magicnet_singbox_update_cleanup_stage() { :; }
    magicnet_singbox_status_mark_interrupted() { :; }
    magicnet_config_lock_release() { printf '%s\n' config-release >>"$prelock_interrupt_trace"; }
    magicnet_singbox_update_lock_release() { printf '%s\n' update-release >>"$prelock_interrupt_trace"; }
    magicnet_singbox_update_interrupt 143
)
prelock_interrupt_rc=$?
set -e
[ "$prelock_interrupt_rc" -eq 143 ]
[ "$(<"$prelock_interrupt_trace")" = update-release ]

printf '%s\n' 'subscription pre-lock interrupt serialization test passed'

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

# Pause a stale reclaimer after its last owner comparison, then let another
# contender run. Both must serialize metadata: the old reclaimer must not
# remove a new live owner between the comparison and unlink.
mkdir -p "$UPDATE_LOCK"
printf '%s\n' '999999:1:stale' >"$UPDATE_LOCK/owner"
(
    rm() {
        if [ "${2:-}" = "$UPDATE_LOCK/owner" ]; then
            : >"$WORKDIR/reclaimer-paused"
            while [ ! -f "$WORKDIR/reclaimer-resume" ]; do sleep 0.01; done
        fi
        command rm "$@"
    }
    magicnet_singbox_update_lock_active || true
) &
reclaimer_pid=$!
for _ in {1..300}; do
    [ ! -f "$WORKDIR/reclaimer-paused" ] || break
    sleep 0.01
done
test -f "$WORKDIR/reclaimer-paused"
contender_acquired=0
magicnet_singbox_update_lock_acquire && contender_acquired=1
: >"$WORKDIR/reclaimer-resume"
wait "$reclaimer_pid"
if [ "$contender_acquired" -eq 1 ]; then
    printf '%s\n' 'subscription contender published an owner inside a stale reclaim' >&2
    exit 1
fi
magicnet_singbox_update_lock_acquire
# The sourced acquisition helper publishes the token in the caller's shell.
# shellcheck disable=SC2154
test "$(cat "$UPDATE_LOCK/owner")" = "$_update_token"
magicnet_singbox_update_lock_release
test ! -e "$UPDATE_LOCK"
printf '%s\n' 'subscription update lock ABA safety test passed'

# Incomplete/corrupt evidence must fail closed without blocking on a FIFO or
# following a symlink. Diagnostics retain unknown instead of inventing death.
mkdir -p "$UPDATE_LOCK"
for bad_owner in broken '+4242:777:nonce' '04242:777:nonce' '0:777:nonce' \
    '4242:not-a-time:nonce' '4242:777:' '4242:777:nonce:extra'; do
    printf '%s\n' "$bad_owner" >"$UPDATE_LOCK/owner"
    if magicnet_singbox_update_lock_live; then exit 1; else test "$?" -eq 2; fi
    magicnet_singbox_update_lock_active
    if magicnet_singbox_update_lock_acquire; then exit 1; fi
    test "$(cat "$UPDATE_LOCK/owner")" = "$bad_owner"
done
(
    magicnet_singbox_subscription_status_file() { printf '%s\n' "$WORKDIR/status"; }
    magicnet_singbox_subscription_cache_dir() { printf '%s\n' "$WORKDIR/cache"; }
    magicnet_singbox_subscription_fingerprint() { printf '%064d\n' 0; }
    mkdir -p "$WORKDIR/cache"
    printf '%s\n' 'result=running' >"$WORKDIR/status"
    status_output=$(magicnet_singbox_status)
    for expected in update_running=0 update_lock_owner=unknown recovery_result=unknown last_result=running; do
        grep -qx "$expected" <<<"$status_output"
    done
    test "$(cat "$WORKDIR/status")" = result=running
)
rm -f "$UPDATE_LOCK/owner"
mkfifo "$UPDATE_LOCK/owner"
magicnet_singbox_update_lock_active
if magicnet_singbox_update_lock_acquire; then exit 1; fi
test -p "$UPDATE_LOCK/owner"
rm -f "$UPDATE_LOCK/owner"
printf '%s\n' '999999:1:stale' >"$WORKDIR/outside-owner"
ln -s "$WORKDIR/outside-owner" "$UPDATE_LOCK/owner"
magicnet_singbox_update_lock_active
if magicnet_singbox_update_lock_acquire; then exit 1; fi
test -L "$UPDATE_LOCK/owner"
test "$(cat "$WORKDIR/outside-owner")" = '999999:1:stale'
rm -f "$UPDATE_LOCK/owner"
rmdir "$UPDATE_LOCK"
printf '%s\n' 'subscription unknown owner and diagnostic safety test passed'

# Release must compare the token under the same guard and report a failed
# unlink, so a successful updater cannot silently report successful cleanup.
magicnet_singbox_update_lock_acquire
(
    rm() {
        if [ "${2:-}" = "$UPDATE_LOCK/owner" ]; then return 1; fi
        command rm "$@"
    }
    if magicnet_singbox_update_lock_release; then exit 1; fi
    test -f "$UPDATE_LOCK/owner"
)
printf '%s\n' '999999:1:replacement' >"$UPDATE_LOCK/owner"
magicnet_singbox_update_lock_release
test "$(cat "$UPDATE_LOCK/owner")" = '999999:1:replacement'
magicnet_singbox_update_lock_acquire
magicnet_singbox_update_lock_release
(
    magicnet_singbox_update_lock_acquire() { :; }
    magicnet_with_config_lock() { "$@"; }
    magicnet_singbox_transaction_reconcile() { :; }
    magicnet_singbox_cleanup_stale_candidates() { :; }
    magicnet_singbox_update_subscription_unlocked() { :; }
    magicnet_singbox_update_lock_release() { return 1; }
    if magicnet_singbox_update_subscription; then exit 1; fi
)
printf '%s\n' 'subscription update lock release failure safety test passed'

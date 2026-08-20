#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export MODDIR="$WORKDIR/module"
mkdir -p \
  "$MODDIR/.config/sing-box" \
  "$MODDIR/.state/sing-box/subscription-work" \
  "$MODDIR/.state/sing-box/subscription-transaction/old-work"

info() { :; }
warn() { :; }
error() { :; }
success() { :; }
import() { :; }

# shellcheck disable=SC1090
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"

ACTIVE_WORK="$MODDIR/.state/sing-box/subscription-work"
TRANSACTION="$MODDIR/.state/sing-box/subscription-transaction"
printf '%s\n' current >"$ACTIVE_WORK/marker"
printf '%s\n' old >"$TRANSACTION/old-work/marker"
printf '%s\n' new-config >"$MODDIR/.config/sing-box/config.json"
printf '%s\n' old-config >"$TRANSACTION/old-config"
touch "$TRANSACTION/had-config"
printf '%s\n' new-url >"$MODDIR/.config/sing-box/subscription.url"
printf '%s\n' old-url >"$TRANSACTION/old-url"
touch "$TRANSACTION/had-url" "$TRANSACTION/had-work"

# Fail only on the first move into the active work path.  The production
# recovery must be able to restore the current directory after that failure;
# the old implementation deleted it before attempting the move.
failed_work_move=0
TEST_ACTIVE_WORK="$ACTIVE_WORK"
mv() {
    if [ "$2" = "$TEST_ACTIVE_WORK" ] && [ "$failed_work_move" -eq 0 ]; then
        failed_work_move=1
        return 1
    fi
    command mv "$@"
}

set +e
magicnet_singbox_transaction_reconcile
reconcile_rc=$?
set -e
unset -f mv

[ "$reconcile_rc" -ne 0 ] || {
    printf '%s\n' 'transaction recovery unexpectedly succeeded after work-directory move failure' >&2
    exit 1
}
[ "$(<"$ACTIVE_WORK/marker")" = current ] || {
    printf '%s\n' 'transaction recovery lost the current work directory on failure' >&2
    exit 1
}
[ -d "$TRANSACTION" ] || {
    printf '%s\n' 'failed transaction journal was removed before recovery completed' >&2
    exit 1
}

printf '%s\n' 'subscription transaction atomicity test passed'

# If an idempotent activation was interrupted after publishing the same config
# and the old core is still healthy, recovery should restore journaled metadata
# without an unnecessary stop/start cycle. This keeps status recovery bounded.
rm -rf "$TRANSACTION" "$ACTIVE_WORK"
mkdir -p "$TRANSACTION"
printf '%s\n' stable-config >"$MODDIR/.config/sing-box/config.json"
printf '%s\n' stable-config >"$TRANSACTION/old-config"
touch "$TRANSACTION/had-config" "$TRANSACTION/was-running"
restart_count=0
policy_count=0
magicnet_singbox_owned_ready() { return 0; }
magicnet_singbox_restart_owned() { restart_count=$((restart_count + 1)); }
magicnet_after_kernel_start_unlocked() { policy_count=$((policy_count + 1)); }
magicnet_singbox_transaction_reconcile

[ "$restart_count" -eq 0 ] || {
    printf '%s\n' 'idempotent recovery restarted an already healthy core' >&2
    exit 1
}
[ "$policy_count" -eq 1 ] || {
    printf '%s\n' 'idempotent recovery did not reapply runtime network policy' >&2
    exit 1
}
[ ! -e "$TRANSACTION" ] || {
    printf '%s\n' 'idempotent recovery left its transaction journal behind' >&2
    exit 1
}
[ "$(<"$MODDIR/.config/sing-box/config.json")" = stable-config ]

printf '%s\n' 'subscription idempotent recovery test passed'

# A merely spawned core is not enough to suppress rollback restart. If its
# listener/API readiness probe fails, recovery must take the restart path.
mkdir -p "$TRANSACTION"
printf '%s\n' stable-config >"$TRANSACTION/old-config"
touch "$TRANSACTION/had-config" "$TRANSACTION/was-running"
magicnet_singbox_owned_ready() { return 1; }
magicnet_singbox_restart_owned() { restart_count=$((restart_count + 1)); }
magicnet_singbox_transaction_reconcile
[ "$restart_count" -eq 1 ]
[ ! -e "$TRANSACTION" ]

printf '%s\n' 'subscription unready-core recovery test passed'

# A failed runtime-policy repair must retain the durable journal so startup or
# a later bounded status call can retry instead of accepting a half-ready core.
mkdir -p "$TRANSACTION"
printf '%s\n' stable-config >"$TRANSACTION/old-config"
touch "$TRANSACTION/had-config" "$TRANSACTION/was-running"
magicnet_singbox_owned_ready() { return 0; }
magicnet_after_kernel_start_unlocked() { return 1; }
set +e
magicnet_singbox_transaction_reconcile
policy_recovery_rc=$?
set -e
[ "$policy_recovery_rc" -ne 0 ]
[ -d "$TRANSACTION" ]

printf '%s\n' 'subscription runtime-policy recovery failure test passed'

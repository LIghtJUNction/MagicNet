#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export MODDIR="$fixture/module"
mkdir -p "$MODDIR"
events="$fixture/events"
: >"$events"

magicnet_json_escape() { printf '%s' "$1"; }
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"

# A subscription-owned restart records the prior fswatch state without
# restoring it while the caller still owns the config transaction.
magicnet_supervisors_stop() { :; }
magicnet_singbox_owned_pids() { :; }
magicnet_singbox_ensure_start_owned() { :; }
ss() { :; }
ip() { :; }
magicnet_fswatch_start() { printf 'restore-lock=%s\n' "$CONFIG_LOCK_HELD" >>"$events"; }
magicnet_fswatch_status() { return 0; }

export MAGICNET_SUB_FSWATCH_WAS_ACTIVE=1
MAGICNET_SUB_DEFER_FSWATCH_RESTORE=1
MAGICNET_SUB_FSWATCH_RESTORE_PENDING=0
magicnet_singbox_restart_owned "$MODDIR/config.json"
test "$MAGICNET_SUB_FSWATCH_RESTORE_PENDING" -eq 1
test ! -s "$events"
unset MAGICNET_SUB_FSWATCH_WAS_ACTIVE MAGICNET_SUB_DEFER_FSWATCH_RESTORE

# The update wrapper restores fswatch after magicnet_with_config_lock returns.
CONFIG_LOCK_HELD=0
magicnet_singbox_update_lock_acquire() { :; }
magicnet_singbox_update_lock_release() { :; }
magicnet_singbox_transaction_reconcile() { :; }
magicnet_singbox_cleanup_stale_candidates() { :; }
magicnet_singbox_update_cleanup_stage() { :; }
magicnet_singbox_update_status() { :; }
error() { :; }
magicnet_with_config_lock() {
  CONFIG_LOCK_HELD=1
  "$@"
  local rc=$?
  CONFIG_LOCK_HELD=0
  return "$rc"
}
magicnet_singbox_update_subscription_unlocked() {
  test "$MAGICNET_SUB_DEFER_FSWATCH_RESTORE" -eq 1
  printf 'transaction-lock=%s\n' "$CONFIG_LOCK_HELD" >>"$events"
  MAGICNET_SUB_FSWATCH_RESTORE_PENDING=1
}

MAGICNET_SUB_FSWATCH_RESTORE_PENDING=0
magicnet_singbox_update_subscription
test "$(tr '\n' ' ' <"$events")" = 'transaction-lock=1 restore-lock=0 '
test -z "${MAGICNET_SUB_DEFER_FSWATCH_RESTORE+x}"
test -z "${MAGICNET_SUB_FSWATCH_RESTORE_PENDING+x}"

printf 'subscription activation order test passed\n'

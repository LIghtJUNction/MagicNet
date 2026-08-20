#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export MODDIR="$fixture/module"
mkdir -p "$MODDIR/.config/sing-box"
events="$fixture/events"
: >"$events"

cat >"$MODDIR/.config/sing-box/config.json" <<'JSON'
{"experimental":{"cache_file":{"enabled":true,"path":"cache.db"}}}
JSON
for cache_name in cache.db cache.db-wal cache.db-shm cache.db-journal; do
  printf 'bootstrap-selector\n' >"$MODDIR/.config/sing-box/$cache_name"
done

magicnet_json_escape() { printf '%s' "$1"; }
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"

# A subscription-owned restart records the prior fswatch state without
# restoring it while the caller still owns the config transaction.
magicnet_supervisors_stop() { printf 'supervisors-stop\n' >>"$events"; }
magicnet_disable_dns_capture() { printf 'dns-capture-disable\n' >>"$events"; }
magicnet_disable_dns_leak_guard() { printf 'dns-leak-guard-disable\n' >>"$events"; }
magicnet_after_kernel_start_unlocked() { printf 'post-start\n' >>"$events"; }
magicnet_singbox_owned_pids() { :; }
magicnet_singbox_ensure_start_owned() { :; }
ss() { :; }
ip() { :; }
magicnet_fswatch_start() { printf 'restore-lock=%s\n' "$CONFIG_LOCK_HELD" >>"$events"; }
magicnet_fswatch_status() { return 0; }
warn() { :; }

export MAGICNET_SUB_FSWATCH_WAS_ACTIVE=1
export MAGICNET_SUB_RESET_BOOTSTRAP_CACHE=1
MAGICNET_SUB_DEFER_FSWATCH_RESTORE=1
MAGICNET_SUB_FSWATCH_RESTORE_PENDING=0
magicnet_singbox_restart_owned "$MODDIR/.config/sing-box/config.json"
test "$MAGICNET_SUB_FSWATCH_RESTORE_PENDING" -eq 1
test "$(tr '\n' ' ' <"$events")" = 'dns-capture-disable dns-leak-guard-disable supervisors-stop post-start '
for cache_name in cache.db cache.db-wal cache.db-shm cache.db-journal; do
  test ! -e "$MODDIR/.config/sing-box/$cache_name"
done
: >"$events"
unset MAGICNET_SUB_FSWATCH_WAS_ACTIVE MAGICNET_SUB_RESET_BOOTSTRAP_CACHE \
  MAGICNET_SUB_DEFER_FSWATCH_RESTORE

# A custom cache path is outside MagicNet's ownership and must never be
# removed by the first-activation recovery.
printf 'outside-cache\n' >"$fixture/outside.db"
cat >"$MODDIR/.config/sing-box/custom.json" <<'JSON'
{"experimental":{"cache_file":{"enabled":true,"path":"../../../outside.db"}}}
JSON
magicnet_singbox_reset_bootstrap_cache "$MODDIR/.config/sing-box/custom.json"
test -f "$fixture/outside.db"

# A failed post-start phase must tear down the newly started generation. The
# old generation is already gone at this point; leaving PID 222 alive would
# expose a core without its TUN/DNS policy and make the next request flaky.
failure_state="$fixture/failure-state"
printf 'stopped\n' >"$failure_state"
failure_owned_pids=
magicnet_singbox_owned_pids() {
  test -n "$failure_owned_pids" && printf '%s\n' "$failure_owned_pids"
}
magicnet_singbox_ensure_start_owned() {
  printf 'running\n' >"$failure_state"
  failure_owned_pids=222
}
magicnet_after_kernel_start_unlocked() { return 1; }
kill() {
  case "$*" in
    *222*)
      failure_owned_pids=
      printf 'stopped\n' >"$failure_state"
      ;;
  esac
  return 0
}
export MAGICNET_SUB_STOP_TIMEOUT=0 MAGICNET_SUB_KILL_TIMEOUT=0
CONFIG_LOCK_HELD=0
set +e
magicnet_singbox_restart_owned "$MODDIR/.config/sing-box/config.json"
failure_restart_rc=$?
set -e
test "$failure_restart_rc" -ne 0
test "$(cat "$failure_state")" = stopped
test -z "$failure_owned_pids"
unset failure_state failure_owned_pids failure_restart_rc
unset MAGICNET_SUB_STOP_TIMEOUT MAGICNET_SUB_KILL_TIMEOUT CONFIG_LOCK_HELD
: >"$events"

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

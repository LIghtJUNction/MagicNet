#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export MODDIR="$fixture/module"
export MAGICNET_PROC_QUERY_DIR="$MODDIR/.state/sing-box"
mkdir -p "$MODDIR/.state/sing-box" "$MODDIR/.config/sing-box" "$MODDIR/bin" "$fixture/runtime"
chmod 700 "$MODDIR/.state/sing-box"
printf '{}\n' >"$MODDIR/.config/sing-box/config.json"
printf '4242\n' >"$fixture/runtime/core.pid"
printf 'present\n' >"$fixture/runtime/magicnet0"
printf 'present\n' >"$fixture/runtime/dns-rules"
printf '5101\n5102\n' >"$fixture/runtime/supervisor.pids"
: >"$fixture/mutations.log"

. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"

warn() { :; }
error() { :; }
magicnet_fswatch_status() { printf '%s\n' 5101; }
record_mutation() { printf '%s\n' "$1" >>"$fixture/mutations.log"; }
magicnet_supervisors_stop() { record_mutation supervisors-stop; }
magicnet_disable_dns_capture() { record_mutation dns-capture-disable; }
magicnet_disable_dns_leak_guard() { record_mutation dns-guard-disable; }
magicnet_singbox_reset_bootstrap_cache() { record_mutation cache-reset; }
magicnet_singbox_ensure_start_owned() { record_mutation core-start; }
magicnet_singbox_supervisor_restore() { record_mutation supervisors-restore; }
magicnet_reapply_post_start_policy() { record_mutation policy-reapply; }
magicnet_singbox_record_runtime_fingerprint() { record_mutation fingerprint; }
ip() { record_mutation "ip:$*"; }
ss() { return 1; }
kill() { record_mutation "kill:$*"; }

assert_runtime_unchanged() {
  test "$(cat "$fixture/runtime/core.pid")" = 4242
  test -f "$fixture/runtime/magicnet0"
  test -f "$fixture/runtime/dns-rules"
  test "$(cat "$fixture/runtime/supervisor.pids")" = $'5101\n5102'
  test ! -s "$fixture/mutations.log"
}

for fault in timeout exit2 truncated; do
  PROC_LOOKUP_FAULT="$fault"
  export PROC_LOOKUP_FAULT
  magicnet_proc_named_pids_test_hook() {
    case "$PROC_LOOKUP_FAULT" in
    timeout) return 124 ;;
    exit2) return 2 ;;
    truncated) printf '%s\n' MAGICNET_PROC_PIDS_V1 4242 ;;
    esac
  }
  : >"$fixture/mutations.log"
  set +e
  MAGICNET_SINGBOX_PROC_ROOT=/proc \
    magicnet_singbox_restart_owned "$MODDIR/.config/sing-box/config.json"
  restart_rc=$?
  set -e
  test "$restart_rc" -eq 2
  assert_runtime_unchanged
  unset -f magicnet_proc_named_pids_test_hook
done

# A stop-wait lookup failure must not be accepted as successful shutdown and
# must not proceed to supervisor, DNS, TUN, or core-start mutation.
(
  query_count=0
  magicnet_singbox_owned_pids_to_file() {
    query_count=$((query_count + 1))
    : >"$2"
    if [ "$query_count" -eq 1 ]; then
      printf '%s\n' 4242 >"$2"
      return 0
    fi
    return 2
  }
  : >"$fixture/mutations.log"
  set +e
  magicnet_singbox_restart_owned "$MODDIR/.config/sing-box/config.json"
  restart_rc=$?
  set -e
  test "$restart_rc" -eq 2
  grep -q '^kill:4242$' "$fixture/mutations.log"
  ! grep -Eq 'supervisors|dns|ip:|core-start|policy-reapply' "$fixture/mutations.log"
)

printf 'sing-box tri-state safety test passed\n'

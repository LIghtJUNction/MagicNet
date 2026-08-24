#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export MODDIR="$fixture/module"
mkdir -p "$MODDIR" "$fixture/bin" "$fixture/sed-bin" "$fixture/proc/101" "$fixture/proc/202" "$fixture/proc/303"
for tool in sed mkdir chmod mktemp rm stat; do
  ln -s "$(command -v "$tool")" "$fixture/sed-bin/$tool"
done

. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"
. "$ROOT/scripts/test-lib/proc-reader-hook.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"

pidof_log="$fixture/pidof.log"
cat >"$fixture/bin/pidof" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$PIDOF_LOG"
printf '%s\n' "${PIDOF_RESULT:-202 101 invalid}"
exit "${PIDOF_RC:-0}"
EOF
chmod +x "$fixture/bin/pidof"
write_proc_stat() {
  local pid="$1" state="$2" start="$3"
  printf '%s (sing-box) %s 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 %s 0\n' \
    "$pid" "$state" "$start" >"$fixture/proc/$pid/stat"
}
write_proc_stat 101 S 10101
write_proc_stat 202 S 20202

pid_output="$(
  PIDOF_LOG="$pidof_log" PIDOF_RESULT='202 101' \
    MAGICNET_SINGBOX_PROC_ROOT="$fixture/proc" \
    PATH="$fixture/bin:$PATH" magicnet_singbox_pids
)"
test "$pid_output" = $'202\n101'
test "$(cat "$pidof_log")" = sing-box

# Production discovery must stay O(1) in total proc entries: one bounded name
# lookup followed by identity checks for only the returned candidates.
for fake_pid in $(seq 1000 1999); do
  mkdir -p "$fixture/proc/$fake_pid"
  printf 'unrelated\n' >"$fixture/proc/$fake_pid/comm"
done
reader_count="$fixture/proc-reader.count"
printf '0\n' >"$reader_count"
pid_output="$(
  PIDOF_LOG="$pidof_log" PIDOF_RESULT='101' \
    PROC_READER_COUNT_FILE="$reader_count" \
    MAGICNET_SINGBOX_PROC_ROOT="$fixture/proc" \
    PATH="$fixture/bin:$PATH" magicnet_singbox_pids
)"
test "$pid_output" = 101
test "$(cat "$reader_count")" -le 2

# An installed pidof is authoritative even when no process exists. Falling
# through to /proc here would reintroduce a full scan in every stop-wait poll.
printf 'sing-box\n' >"$fixture/proc/303/comm"
write_proc_stat 303 S 30303
: >"$pidof_log"
set +e
pid_output="$(
  PIDOF_LOG="$pidof_log" PIDOF_RESULT='' PIDOF_RC=1 \
    MAGICNET_SINGBOX_PROC_ROOT="$fixture/proc" \
    PATH="$fixture/bin:$PATH" magicnet_singbox_pids
)"
pid_rc=$?
set -e
test "$pid_rc" -eq 1
test -z "$pid_output"
test "$(cat "$pidof_log")" = sing-box

# The fallback must use the shell read builtin. A cat override makes any
# per-process external cat regression fail deterministically.
printf 'sing-box\n' >"$fixture/proc/101/comm"
write_proc_stat 101 S 10101
printf 'sh\n' >"$fixture/proc/202/comm"
pid_output="$(
  cat() {
    printf 'cat must not be used for proc comm discovery\n' >&2
    return 99
  }
  PATH="$fixture/sed-bin" MAGICNET_SINGBOX_PROC_ROOT="$fixture/proc" magicnet_singbox_pids
)"
test "$pid_output" = $'101\n303'

# Malformed, failed, and count-framed truncated results are indeterminate, not
# authoritative empty process sets.
for fault in malformed exit2 truncated; do
  magicnet_proc_named_pids_test_hook() {
    case "$fault" in
    malformed) printf '%s\n' MAGICNET_PROC_PIDS_V1 invalid 'MAGICNET_PROC_PIDS_END 1' ;;
    exit2) return 2 ;;
    truncated) printf '%s\n' MAGICNET_PROC_PIDS_V1 101 ;;
    esac
  }
  fault_output=$(magicnet_proc_query_temp_create)
  set +e
  MAGICNET_SINGBOX_PROC_ROOT=/proc magicnet_singbox_pids_to_file "$fault_output"
  fault_rc=$?
  set -e
  test "$fault_rc" -eq 2
  test ! -s "$fault_output"
  rm -f "$fault_output"
  unset -f magicnet_proc_named_pids_test_hook
done

printf 'sing-box pid discovery test passed\n'

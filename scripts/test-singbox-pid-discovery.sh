#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export MODDIR="$fixture/module"
mkdir -p "$MODDIR" "$fixture/bin" "$fixture/sed-bin" "$fixture/proc/101" "$fixture/proc/202" "$fixture/proc/303"
ln -s "$(command -v sed)" "$fixture/sed-bin/sed"

magicnet_json_escape() { printf '%s' "$1"; }
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"

pidof_log="$fixture/pidof.log"
cat >"$fixture/bin/pidof" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$PIDOF_LOG"
printf '%s\n' "${PIDOF_RESULT:-202 101 invalid}"
exit "${PIDOF_RC:-0}"
EOF
chmod +x "$fixture/bin/pidof"

pid_output="$(
  PIDOF_LOG="$pidof_log" PIDOF_RESULT='202 101 invalid' \
    PATH="$fixture/bin:$PATH" magicnet_singbox_pids
)"
test "$pid_output" = $'202\n101'
test "$(cat "$pidof_log")" = sing-box

# An installed pidof is authoritative even when no process exists. Falling
# through to /proc here would reintroduce a full scan in every stop-wait poll.
printf 'sing-box\n' >"$fixture/proc/303/comm"
printf '303 (sing-box) S 1 2 3 4 5 6\n' >"$fixture/proc/303/stat"
: >"$pidof_log"
pid_output="$(
  PIDOF_LOG="$pidof_log" PIDOF_RESULT='' PIDOF_RC=1 \
    MAGICNET_SINGBOX_PROC_ROOT="$fixture/proc" \
    PATH="$fixture/bin:$PATH" magicnet_singbox_pids
)"
test -z "$pid_output"
test "$(cat "$pidof_log")" = sing-box

# The fallback must use the shell read builtin. A cat override makes any
# per-process external cat regression fail deterministically.
printf 'sing-box\n' >"$fixture/proc/101/comm"
printf '101 (sing-box) S 1 2 3 4 5 6\n' >"$fixture/proc/101/stat"
printf 'sh\n' >"$fixture/proc/202/comm"
pid_output="$(
  cat() {
    printf 'cat must not be used for proc comm discovery\n' >&2
    return 99
  }
  PATH="$fixture/sed-bin" MAGICNET_SINGBOX_PROC_ROOT="$fixture/proc" magicnet_singbox_pids
)"
test "$pid_output" = $'101\n303'

# The early-boot kamfw helper has its own /proc fallback.  Keep its proc root
# extraction covered too: a custom fixture root must not be parsed as though it
# were literally /proc (which would yield an empty PID and hide sing-box).
mkdir -p "$fixture/kamproc/515"
printf 'sing-box\n' >"$fixture/kamproc/515/comm"
printf '515 (sing-box) S 1 2 3 4 5 6\n' >"$fixture/kamproc/515/stat"
import() { :; }
set_i18n() { :; }
. "$ROOT/src/MagicNet/lib/kamfw/__singbox__.sh"
pidof() { return 1; }
pid_output="$(MAGICNET_SINGBOX_PROC_ROOT="$fixture/kamproc" singbox_pids)"
test "$pid_output" = 515

printf 'sing-box pid discovery test passed\n'

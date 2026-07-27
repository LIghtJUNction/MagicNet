#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export MODDIR="$ROOT/src/MagicNet"
export MAGICNET_FETCH_TEST_LOG="$tmp/log"
. "$MODDIR/lib/magicnet/singbox_subscribe/fetch.sh"

magicnet_singbox_subscription_url_file() {
  printf '%s\n' "$tmp/subscription.url"
}

magicnet_singbox_subscription_user_agent_file() {
  printf '%s\n' "$tmp/subscription.user-agent"
}

error() {
  printf 'error %s\n' "$*" >>"$MAGICNET_FETCH_TEST_LOG"
}

warn() {
  printf 'warn %s\n' "$*" >>"$MAGICNET_FETCH_TEST_LOG"
}

mkdir "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/bin/sh
printf 'env=%s/%s/%s/%s\n' "${http_proxy-}" "${HTTP_PROXY-}" "${all_proxy-}" "${ALL_PROXY-}" >>"$MAGICNET_FETCH_TEST_LOG"
printf 'curl %s\n' "$*" >>"$MAGICNET_FETCH_TEST_LOG"
case "$*" in *127.0.0.1:9090/version*) printf '{"version":"test"}\n'; exit 0;; esac
[ "${MAGICNET_FETCH_FAIL:-0}" = 1 ] && exit 1
for last do :; done
case " $* " in *' -o '*) while [ "$#" -gt 1 ]; do [ "$1" = -o ] && { printf ok >"$2"; break; }; shift; done;; esac
SH
cat >"$tmp/bin/wget" <<'SH'
#!/bin/sh
printf 'wget %s\n' "$*" >>"$MAGICNET_FETCH_TEST_LOG"
exit 1
SH
cat >"$tmp/bin/sing-box" <<'SH'
#!/bin/sh
printf 'sing-box %s\n' "$*" >>"$MAGICNET_FETCH_TEST_LOG"
[ "${MAGICNET_FETCH_FAIL:-0}" = 1 ] && exit 1
printf ok
SH
cat >"$tmp/bin/timeout" <<'SH'
#!/bin/sh
printf 'timeout %s\n' "$1" >>"$MAGICNET_FETCH_TEST_LOG"
shift
exec "$@"
SH
chmod +x "$tmp/bin/"*
http_proxy=http://bad HTTP_PROXY=http://bad all_proxy=http://bad ALL_PROXY=http://bad \
  PATH="$tmp/bin:$PATH" magicnet_singbox_try_fetch_subscription curl https://example.invalid/sub "$tmp/direct" 2 7
grep -q '^env=///$' "$tmp/log"
grep -q 'curl .*--noproxy \*' "$tmp/log"
if grep -q -- '--proxy' "$tmp/log"; then
  exit 1
fi
: >"$tmp/log"
MAGICNET_SUB_PROXY=http://127.0.0.1:7892 PATH="$tmp/bin:$PATH" \
  magicnet_singbox_try_fetch_subscription curl https://example.invalid/sub "$tmp/proxy" 2 9
grep -q 'curl .*--proxy http://127.0.0.1:7892' "$tmp/log"
: >"$tmp/log"
PATH="$tmp/bin:$PATH" magicnet_singbox_try_fetch_subscription sing-box https://example.invalid/sub "$tmp/sing" 2 11
grep -q '^timeout 11$' "$tmp/log"
grep -q '^sing-box tools fetch ' "$tmp/log"
: >"$tmp/log"
MAGICNET_SUB_USER_AGENT='sing-box/1.12.0 (Android)' PATH="$tmp/bin:$PATH" \
  magicnet_singbox_try_fetch_subscription wget https://example.invalid/sub "$tmp/wget-ua" 2 11 || true
grep -q 'wget .*--user-agent sing-box/1.12.0 (Android).*https://example.invalid/sub' "$tmp/log"
: >"$tmp/log"
if MAGICNET_SUB_USER_AGENT=sing-box PATH="$tmp/bin:$PATH" \
  magicnet_singbox_try_fetch_subscription sing-box https://example.invalid/sub "$tmp/sing-ua" 2 11; then
  exit 1
fi
if grep -q '^sing-box ' "$tmp/log"; then
  exit 1
fi
: >"$tmp/log"
printf '%s\n' 'mihomo/1.19.0' >"$tmp/subscription.user-agent"
PATH="$tmp/bin:$PATH" \
  magicnet_singbox_fetch_one_subscription \
    https://example.invalid/sub "$tmp/custom-ua" "" "" "" '#1'
grep -q 'curl .*--user-agent mihomo/1.19.0.*https://example.invalid/sub' "$tmp/log"
test "$(cat "$tmp/custom-ua")" = ok
rm -f "$tmp/subscription.user-agent"
: >"$tmp/log"
MAGICNET_FETCH_FAIL=1 MAGICNET_SUB_PROXY=http://127.0.0.1:7892 PATH="$tmp/bin:$PATH" \
  magicnet_singbox_fetch_one_subscription \
    https://example.invalid/sub "$tmp/missing" "" "" "" '#1' 2>/dev/null && exit 1 || true
grep -q '^curl ' "$tmp/log"
if grep -Eq '^(wget|sing-box) ' "$tmp/log"; then
  exit 1
fi
: >"$tmp/log"
MAGICNET_FETCH_FAIL=1 PATH="$tmp/bin:$PATH" \
  magicnet_singbox_fetch_one_subscription \
    https://example.invalid/sub "$tmp/local-proxy" "" "" "" '#1' 2>/dev/null && exit 1 || true
grep -q 'curl .*127.0.0.1:9090/version' "$tmp/log"
grep -q 'curl .*--proxy http://127.0.0.1:7892.*https://example.invalid/sub' "$tmp/log"
if grep -q 'wget .*--proxy' "$tmp/log" || grep -q 'sing-box .*--proxy' "$tmp/log"; then
  exit 1
fi
MODDIR="$tmp/module"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"
magicnet_singbox_update_lock_acquire
if (magicnet_singbox_update_lock_acquire) 2>/dev/null; then
  exit 1
fi
magicnet_singbox_update_lock_release
mkdir -p "$MODDIR/.state/sing-box/subscription-update.lock"
printf '999999:0:stale\n' >"$MODDIR/.state/sing-box/subscription-update.lock/owner"
magicnet_singbox_update_lock_acquire
magicnet_singbox_update_lock_release
mkdir -p "$MODDIR/.state/sing-box/subscription-update.lock"
start=$(awk '{print $22}' "/proc/$$/stat")
printf '%s:%s:0\n' "$$" "$start" >"$MODDIR/.state/sing-box/subscription-update.lock/owner"
if (magicnet_singbox_update_lock_acquire) 2>/dev/null; then
  exit 1
fi
rm -rf "$MODDIR/.state/sing-box/subscription-update.lock"
magicnet_singbox_update_lock_acquire
old_token=$_update_token
printf 'replacement-owner\n' >"$MODDIR/.state/sing-box/subscription-update.lock/owner"
_update_token=$old_token
magicnet_singbox_update_lock_release
test -d "$MODDIR/.state/sing-box/subscription-update.lock"
rm -rf "$MODDIR/.state/sing-box/subscription-update.lock"
order_log="$tmp/order.log"
magicnet_singbox_update_subscription_unlocked() { printf 'update-body\n' >>"$order_log"; }
# Invoked indirectly by the update wrapper.
# shellcheck disable=SC2329
magicnet_with_config_lock() {
  test -d "$MODDIR/.state/sing-box/subscription-update.lock"
  printf 'global-lock\n' >>"$order_log"
  "$@"
}
magicnet_singbox_update_subscription
test "$(tr '\n' ' ' <"$order_log")" = 'global-lock global-lock update-body '
test ! -d "$MODDIR/.state/sing-box/subscription-update.lock"
: >"$order_log"
global_lock="$tmp/global.lock"
mkdir "$global_lock"
# Invoked indirectly by the update wrapper.
# shellcheck disable=SC2329
magicnet_with_config_lock() {
  while [ -d "$global_lock" ]; do sleep 0.02; done
  printf 'global-after-apply\n' >>"$order_log"
  "$@"
}
(
  sleep 0.1
  test -d "$MODDIR/.state/sing-box/subscription-update.lock"
  printf 'update-waited\n' >>"$order_log"
  rmdir "$global_lock"
) &
waiter=$!
magicnet_singbox_update_subscription
wait "$waiter"
test "$(tr '\n' ' ' <"$order_log")" = 'update-waited global-after-apply global-after-apply update-body '
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
mkdir -p "$MODDIR/bin" "$tmp/foreign"
cat >"$tmp/sing-box.c" <<'C'
#include <unistd.h>

int main(void) {
    sleep(30);
    return 0;
}
C
cc -o "$MODDIR/bin/sing-box" "$tmp/sing-box.c"
cc -o "$tmp/foreign/sing-box" "$tmp/sing-box.c"
"$MODDIR/bin/sing-box" run -c "$tmp/config.json" -D "$tmp" &
old_core=$!
magicnet_singbox_pids() { kill -0 "$old_core" 2>/dev/null && printf '%s\n' "$old_core"; }
magicnet_singbox_is_running() { kill -0 "$old_core" 2>/dev/null; }
magicnet_supervisors_stop() { printf 'stop\n' >>"$order_log"; }
magicnet_fswatch_start() { printf 'start\n' >>"$order_log"; }
magicnet_fswatch_status() { return 0; }
magicnet_singbox_listener_owned() { kill -0 "$1" 2>/dev/null; }
magicnet_singbox_subscription_config_file() { printf '%s\n' "$tmp/config.json"; }
: >"$tmp/config.json"
# Android Toybox/BusyBox awk treats the NUL-delimited cmdline as one record.
# Ownership parsing must use the shell's NUL-safe read loop instead of awk.
awk() { return 99; }
magicnet_singbox_pid_owned "$old_core" "$tmp/config.json"
unset -f awk
cc -o "$tmp/replacement-sing-box" "$tmp/sing-box.c"
mv "$tmp/replacement-sing-box" "$MODDIR/bin/sing-box"
magicnet_singbox_pid_owned "$old_core" "$tmp/config.json"
kill "$old_core"
wait "$old_core" 2>/dev/null || true
"$MODDIR/bin/sing-box" run -c "$tmp/config.json" -D "$tmp" &
old_core=$!
magicnet_singbox_pid_owned "$old_core" "$tmp/config.json"
"$tmp/foreign/sing-box" run -c "$tmp/config.json" -D "$tmp" &
foreign_exe=$!
magicnet_singbox_pid_owned "$foreign_exe" "$tmp/config.json" && exit 1 || true
cc -o "$tmp/foreign-replacement" "$tmp/sing-box.c"
mv "$tmp/foreign-replacement" "$tmp/foreign/sing-box"
magicnet_singbox_pid_owned "$foreign_exe" "$tmp/config.json" && exit 1 || true
kill "$foreign_exe"
wait "$foreign_exe" 2>/dev/null || true
"$MODDIR/bin/sing-box" run -c "$tmp/other.json" -D "$tmp" &
wrong_config=$!
magicnet_singbox_pid_owned "$wrong_config" "$tmp/config.json" && exit 1 || true
kill "$wrong_config"
wait "$wrong_config" 2>/dev/null || true
"$MODDIR/bin/sing-box" run -c "$tmp/config.json" -D "$tmp/other-work" &
wrong_work=$!
magicnet_singbox_pid_owned "$wrong_work" "$tmp/config.json" && exit 1 || true
kill "$wrong_work"
wait "$wrong_work" 2>/dev/null || true
newline_config=$(printf '%s\n%s' '-c' "$tmp/config.json")
"$MODDIR/bin/sing-box" run "$newline_config" -D "$tmp" &
newline_arg=$!
magicnet_singbox_pid_owned "$newline_arg" "$tmp/config.json" && exit 1 || true
kill "$newline_arg"
wait "$newline_arg" 2>/dev/null || true
"$MODDIR/bin/sing-box" run -c "$tmp/config.json" -c "$tmp/config.json" -D "$tmp" &
duplicate_config=$!
magicnet_singbox_pid_owned "$duplicate_config" "$tmp/config.json" && exit 1 || true
kill "$duplicate_config"
wait "$duplicate_config" 2>/dev/null || true
"$MODDIR/bin/sing-box" run -c "$tmp/config.json" -D "$tmp" -D "$tmp" &
duplicate_work=$!
magicnet_singbox_pid_owned "$duplicate_work" "$tmp/config.json" && exit 1 || true
kill "$duplicate_work"
wait "$duplicate_work" 2>/dev/null || true
: >"$order_log"
PATH="$tmp/bin:$PATH" magicnet_singbox_restart_if_running
wait "$old_core" 2>/dev/null || true
# Set by magicnet_singbox_restart_if_running.
# shellcheck disable=SC2154
kill "$_new_pid" 2>/dev/null || true
test "$(tr '\n' ' ' <"$order_log")" = 'stop start '
(
  "$tmp/foreign/sing-box" run -c "$tmp/foreign.json" -D "$tmp/foreign" & foreign=$!
  magicnet_singbox_pids() { printf '%s\n' "$foreign"; }
  magicnet_supervisors_stop() { :; }
  magicnet_fswatch_status() { return 0; }
  magicnet_fswatch_start() { :; }
  ss() { printf 'LISTEN 0 4096 127.0.0.1:9090 0.0.0.0:* users:(("foreign",pid=%s,fd=1))\n' "$foreign"; }
  magicnet_singbox_restart_owned "$tmp/config.json" && exit 1 || true
  kill -0 "$foreign"
  kill "$foreign"
)
(
  magicnet_singbox_owned_pids() { printf '999999\n'; }
  magicnet_supervisors_stop() { :; }
  magicnet_fswatch_status() { return 1; }
  kill() { :; }
  MAGICNET_SUB_STOP_TIMEOUT=0 MAGICNET_SUB_KILL_TIMEOUT=0 \
    magicnet_singbox_restart_owned "$tmp/config.json" && exit 1 || true
)
(
  magicnet_singbox_owned_pids() { :; }
  magicnet_supervisors_stop() { :; }
  magicnet_fswatch_status() { return 0; }
  magicnet_fswatch_start() { return 1; }
  ss() { :; }
  magicnet_singbox_ensure_start_owned() { return 0; }
  magicnet_singbox_restart_owned "$tmp/config.json" && exit 1 || true
)
printf 'subscription fetch policy test passed\n'

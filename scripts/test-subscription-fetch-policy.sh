#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export MODDIR="$tmp/module"
export MAGICNET_FETCH_TEST_LOG="$tmp/log"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/fetch.sh"

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
mkdir -p "$MODDIR"
cat >"$tmp/bin/curl" <<'SH'
#!/bin/sh
printf 'env=%s/%s/%s/%s\n' "${http_proxy-}" "${HTTP_PROXY-}" "${all_proxy-}" "${ALL_PROXY-}" >>"$MAGICNET_FETCH_TEST_LOG"
printf 'curl %s\n' "$*" >>"$MAGICNET_FETCH_TEST_LOG"
case " $* " in
  *' http://127.0.0.1:9090/version '*)
    printf '%s\n' '{"version":"test"}'
    exit 0
    ;;
esac
[ "${MAGICNET_FETCH_FAIL:-0}" = 1 ] && exit 1
if [ "${MAGICNET_FETCH_OVERFLOW:-0}" = 1 ]; then
  dd if=/dev/zero bs=8388610 count=1 2>/dev/null
elif [ "${MAGICNET_FETCH_LARGE:-0}" = 1 ]; then
  dd if=/dev/zero bs=131072 count=1 2>/dev/null
else
  printf ok
fi
SH
cat >"$MODDIR/cli" <<'SH'
#!/bin/sh
printf 'resolver %s\n' "$*" >>"$MAGICNET_FETCH_TEST_LOG"
[ "$1" = sub ] && [ "$2" = resolve-host ] || exit 2
case "${MAGICNET_RESOLVE_RESULT:-public}" in
  public) printf '%s\n' "1.1.1.1" "2606:4700:4700::1111" ;;
  private) printf '%s\n' "127.0.0.1" ;;
  empty) ;;
  fail) exit 1 ;;
esac
SH
cat >"$tmp/bin/timeout" <<'SH'
#!/bin/sh
printf 'timeout %s\n' "$1" >>"$MAGICNET_FETCH_TEST_LOG"
shift
exec "$@"
SH
chmod +x "$tmp/bin/"* "$MODDIR/cli"
for special_address in \
  192.0.0.1 \
  192.0.2.1 \
  192.31.196.1 \
  192.52.193.1 \
  192.88.99.1 \
  192.168.1.1 \
  192.175.48.1 \
  198.18.0.1 \
  198.51.100.1 \
  203.0.113.1; do
  if magicnet_singbox_public_address "$special_address"; then
    printf 'special-use address was accepted: %s\n' "$special_address" >&2
    exit 1
  fi
done
for special_ipv6 in \
  '::' \
  '::1' \
  'fc00::1' \
  'fe80::1' \
  '100::1' \
  '64:ff9b::1' \
  '2001:0::1' \
  '2001:2::1' \
  '2001:10::1' \
  '2001:20::1' \
  '2001:db8::1' \
  'ff02::1' \
  '::ffff:127.0.0.1' \
  '::ffff:192.0.2.1'; do
  if magicnet_singbox_public_address "$special_ipv6"; then
    printf 'special-use IPv6 address was accepted: %s\n' "$special_ipv6" >&2
    exit 1
  fi
done
for malformed_ipv6 in \
  '2001:db8' \
  '2001:db8:::1' \
  '2001:0:0:0:0:0:0:0:1' \
  '2001:db8:1:2:3:4:5:6:7' \
  '::2'; do
  if magicnet_singbox_public_address "$malformed_ipv6"; then
    printf 'malformed or non-public IPv6 address was accepted: %s\n' "$malformed_ipv6" >&2
    exit 1
  fi
done
magicnet_singbox_public_address '2001:4860:4860::8888'
magicnet_singbox_public_address 1.1.1.1
http_proxy=http://bad HTTP_PROXY=http://bad all_proxy=http://bad ALL_PROXY=http://bad \
  PATH="$tmp/bin:$PATH" magicnet_singbox_try_fetch_subscription https://example.invalid/sub "$tmp/direct" 2 7
grep -q '^env=///$' "$tmp/log"
grep -q 'curl .*--noproxy \*' "$tmp/log"
grep -q 'curl .*--resolve example.invalid:443:1.1.1.1' "$tmp/log"
grep -Fq -- '--resolve example.invalid:443:[2606:4700:4700::1111]' "$tmp/log"
grep -q 'curl .* -o - ' "$tmp/log"
if grep -q -- '--proxy' "$tmp/log"; then
  exit 1
fi
test "$(cat "$tmp/direct")" = ok
: >"$tmp/log"
PATH="$tmp/bin:$PATH" \
  magicnet_singbox_try_fetch_subscription HTTPS://example.invalid/sub "$tmp/uppercase" 2 7
grep -q 'resolver sub resolve-host example.invalid 443' "$tmp/log"
test "$(cat "$tmp/uppercase")" = ok
: >"$tmp/log"
PATH="$tmp/bin:$PATH" \
  magicnet_singbox_try_fetch_subscription https://1.1.1.1:8443/sub "$tmp/public-ip" 2 7
grep -q '^resolver sub resolve-host 1.1.1.1 8443$' "$tmp/log"
grep -q 'curl .*--resolve 1.1.1.1:8443:1.1.1.1' "$tmp/log"
test "$(cat "$tmp/public-ip")" = ok
: >"$tmp/log"
if MAGICNET_RESOLVE_RESULT=private PATH="$tmp/bin:$PATH" \
  magicnet_singbox_try_fetch_subscription https://example.invalid/sub "$tmp/private" 2 7; then
  exit 1
fi
test ! -e "$tmp/private"
: >"$tmp/log"
if MAGICNET_RESOLVE_RESULT=empty PATH="$tmp/bin:$PATH" \
  magicnet_singbox_try_fetch_subscription https://example.invalid/sub "$tmp/unresolved" 2 7; then
  exit 1
fi
test ! -e "$tmp/unresolved"
: >"$tmp/log"
MAGICNET_FETCH_LARGE=1 PATH="$tmp/bin:$PATH" \
  magicnet_singbox_try_fetch_subscription https://example.invalid/sub "$tmp/large" 2 11
test "$(wc -c <"$tmp/large")" -eq 131072
: >"$tmp/log"
if MAGICNET_FETCH_OVERFLOW=1 PATH="$tmp/bin:$PATH" \
  magicnet_singbox_try_fetch_subscription https://example.invalid/sub "$tmp/overflow" 2 11; then
  exit 1
fi
test ! -e "$tmp/overflow"
: >"$tmp/log"
printf '%s\n' 'mihomo/1.19.0' >"$tmp/subscription.user-agent"
PATH="$tmp/bin:$PATH" \
  magicnet_singbox_fetch_one_subscription \
    https://example.invalid/sub "$tmp/custom-ua" "" "" "" '#1'
grep -q 'curl .*--user-agent mihomo/1.19.0.*https://example.invalid/sub' "$tmp/log"
test "$(cat "$tmp/custom-ua")" = ok
rm -f "$tmp/subscription.user-agent"
: >"$tmp/log"

# A failed publish must not fall through to normalizing the previous source
# and report a fresh subscription as successful.
stale_source="$tmp/stale-source.yaml"
printf '%s\n' 'old-source' >"$stale_source"
if (
  mv() {
    if [ "${MAGICNET_FETCH_FAIL_PUBLISH:-0}" = 1 ] &&
      [ "${3:-}" = "$stale_source" ]; then
      unset MAGICNET_FETCH_FAIL_PUBLISH
      return 1
    fi
    command mv "$@"
  }
  MAGICNET_FETCH_FAIL_PUBLISH=1 PATH="$tmp/bin:$PATH" \
    magicnet_singbox_fetch_one_subscription \
      https://example.invalid/sub "$stale_source" "" "" "" '#publish-failure'
); then
  printf '%s\n' 'subscription publish failure must not be reported as success' >&2
  exit 1
fi
test "$(cat "$stale_source")" = old-source
test ! -e "${stale_source}.download"
: >"$tmp/log"

cache_file="$tmp/cache.yaml"
cache_identity="$tmp/cache.yaml.identity"
cache_stage="$tmp/cache-stage.yaml"
printf '%s\n' 'cached-source' >"$cache_file"
printf '%s\n' 'cache-identity' >"$cache_identity"
if (
  cp() { return 1; }
  magicnet_singbox_use_cached_subscription \
    "$cache_stage" "$cache_file" "$cache_identity" cache-identity
); then
  printf '%s\n' 'cache fallback must fail when staging the cache fails' >&2
  exit 1
fi
test ! -e "$cache_stage"
unset cache_file cache_identity cache_stage
MAGICNET_FETCH_FAIL=1 MAGICNET_SUB_PROXY=http://127.0.0.1:7892 PATH="$tmp/bin:$PATH" \
  magicnet_singbox_fetch_one_subscription \
    https://example.invalid/sub "$tmp/missing" "" "" "" '#1' 2>/dev/null && exit 1 || true
grep -qx 'error Explicit subscription proxy is unsupported because it bypasses destination verification' "$tmp/log"
if grep -q '^curl ' "$tmp/log"; then
  exit 1
fi
: >"$tmp/log"
MAGICNET_FETCH_FAIL=1 PATH="$tmp/bin:$PATH" \
  magicnet_singbox_fetch_one_subscription \
    https://example.invalid/sub "$tmp/local-proxy" "" "" "" '#1' 2>/dev/null && exit 1 || true
grep -q '^curl ' "$tmp/log"
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
magicnet_after_kernel_start_unlocked() { :; }
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
mkdir -p "$tmp/proc/12345"
printf 'sing-box\n' >"$tmp/proc/12345/comm"
printf '12345 (sing-box) S 1 2 3 4 5 6\n' >"$tmp/proc/12345/stat"
printf 'sing-box\0sing-box\0run\0-c\0%s\0-D\0%s\0' "$tmp/config.json" "$tmp" >"$tmp/proc/12345/cmdline"
MAGICNET_SINGBOX_PROC_ROOT="$tmp/proc" magicnet_singbox_pid_owned 12345 "$tmp/config.json"
mkdir -p "$tmp/proc/505"
printf 'sing-box\n' >"$tmp/proc/505/comm"
if MAGICNET_SINGBOX_PROC_ROOT="$tmp/proc" magicnet_singbox_pid_live 505; then
  printf 'magicnet_singbox_pid_live accepted a PID with unreadable proc stat\n' >&2
  exit 1
fi
MAGICNET_SINGBOX_PROC_ROOT="$tmp/proc" magicnet_singbox_pid_owned 12345 "$tmp/other.json" && exit 1 || true
rm -rf "$tmp/proc"
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

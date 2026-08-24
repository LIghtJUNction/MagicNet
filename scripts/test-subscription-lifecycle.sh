#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
cleanup() {
  test -z "${stale_pid:-}" || kill "$stale_pid" 2>/dev/null || true
  test -z "${mismatch_pid:-}" || kill "$mismatch_pid" 2>/dev/null || true
  test -z "${owned_pid:-}" || kill "$owned_pid" 2>/dev/null || true
  test -z "${orphan_pid:-}" || kill "$orphan_pid" 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT

export MODDIR="$fixture/module"
mkdir -p \
  "$MODDIR/.config/sing-box" \
  "$MODDIR/.state/sing-box/subscription-work" \
  "$MODDIR/.log"

info() { :; }
warn() { :; }
error() { :; }
success() { :; }
set_i18n() { :; }
import() { :; }
magicnet_json_escape() { printf '%s' "$1"; }

. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/fetch.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"
. "$ROOT/src/MagicNet/lib/magicnet/supervisors.sh"
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"

magicnet_proc_reader_test_hook() {
  local kind="$1" proc_root="$2" pid="$3" argument count stat rest
  local -a argv=() fields=()
  if test "$kind" = stat; then
    test -r "$proc_root/$pid/stat" || return 1
    stat=$(<"$proc_root/$pid/stat")
    rest=${stat##*) }
    read -r -a fields <<<"$rest"
    test "${#fields[@]}" -ge 20 || return 1
    printf '%s %s\n' "${fields[0]}" "${fields[19]}"
    return 0
  fi
  test "$kind" = cmdline || return 1
  if test -n "${TR_COUNT_FILE:-}"; then
    count=$(cat "$TR_COUNT_FILE" 2>/dev/null || printf '0\n')
    printf '%s\n' "$((count + 1))" >"$TR_COUNT_FILE"
  fi
  if test -n "${EXACT_READ_COUNT_FILE:-}"; then
    count=$(cat "$EXACT_READ_COUNT_FILE" 2>/dev/null || printf '0\n')
    count=$((count + 1))
    printf '%s\n' "$count" >"$EXACT_READ_COUNT_FILE"
    if test "${EXACT_READ_MODE:-}" = persistent || test "$count" -eq 1; then
      return 2
    fi
  fi
  mapfile -d '' -t argv <"$proc_root/$pid/cmdline" || true
  test "${#argv[@]}" -gt 0 || return 1
  for argument in "${argv[@]}"; do
    test -n "$argument" || return 1
    case "$argument" in *$'\n'* | *$'\r'*) return 1 ;; esac
    printf '%s\n' "$argument"
  done
}

# Test-only scan hook. Production uses the bounded Rust scanner.
magicnet_proc_script_pids_test_hook() {
  local proc_root="$1" expected="$2" pid="$3" first count
  if test -n "${SCAN_GREP_COUNT_FILE:-}"; then
    first=$(printf '%s\n' "$proc_root"/[0-9]* | sed -n '1p')
    first=${first##*/}
    if test "$pid" = "$first"; then
      count=$(cat "$SCAN_GREP_COUNT_FILE" 2>/dev/null || printf '0\n')
      count=$((count + 1))
      printf '%s\n' "$count" >"$SCAN_GREP_COUNT_FILE"
      case "${SCAN_GREP_MODE:-}" in
        persistent) return 2 ;;
        transient) test "$count" -ne 1 || return 2 ;;
        two-transient) test "$count" -gt 2 || return 2 ;;
      esac
    fi
  fi
  # Empty cmdlines belong to kernel threads and are definite non-matches for
  # this script scan, not ownership read failures.
  test -s "$proc_root/$pid/cmdline" || return 1
  MAGICNET_SUB_REFRESH_PROC_ROOT="$proc_root" \
    magicnet_subscription_refresh_proc_command_matches "$pid"
}

printf '#!/system/bin/sh\n' >"$MODDIR/cli"
chmod +x "$MODDIR/cli"

assert_file() {
  local path="$1" expected="$2"
  local actual
  actual="$(cat "$path")"
  test "$actual" = "$expected" || {
    printf 'expected %s to contain <%s>, got <%s>\n' "$path" "$expected" "$actual" >&2
    exit 1
  }
}

assert_issue_93_local_startup_sources() {
  local issue_moddir="$fixture/issue-93-module"
  mkdir -p "$issue_moddir/.config/sing-box"

  printf 'proxies:\n  - local-fixture\n' >"$issue_moddir/.config/sing-box/subscription.local"
  MODDIR="$issue_moddir" magicnet_require_subscription_or_stop

  rm -f "$issue_moddir/.config/sing-box/subscription.local"
  printf '%s\n' '{"inbounds":[],"outbounds":[]}' >"$issue_moddir/.config/sing-box/config.json"
  printf '%s\n' validated >"$issue_moddir/.config/sing-box/standalone-config"
  MODDIR="$issue_moddir" magicnet_require_subscription_or_stop
}

assert_issue_93_local_startup_sources

# Config-lock ownership records include the process start time so a reused PID
# cannot hold a stale lock forever or be mistaken for the current owner.
magicnet_config_lock_acquire
lock_owner="$(cat "$MODDIR/.state/config.lock/pid")"
case "$lock_owner" in
"$$:"*) ;;
*)
  printf 'config lock owner is not start-time bound: %s\n' "$lock_owner" >&2
  exit 1
  ;;
esac
magicnet_config_lock_release
sleep 60 &
stale_pid=$!
stale_start="$(awk '{print $22}' "/proc/$stale_pid/stat")"
mkdir -p "$MODDIR/.state/config.lock"
printf '%s:%s\n' "$stale_pid" "$((stale_start + 1))" >"$MODDIR/.state/config.lock/pid"
magicnet_config_lock_acquire
test "$(cut -d: -f1 "$MODDIR/.state/config.lock/pid")" = "$$"
magicnet_config_lock_release
kill "$stale_pid" 2>/dev/null || true
wait "$stale_pid" 2>/dev/null || true
stale_pid=

with_no_refresh_loop_candidates() (
  trap - EXIT
  # shellcheck disable=SC2329 # Called indirectly by the production owner-state function.
  magicnet_subscription_refresh_loop_pids() { return 0; }
  "$@"
)

active_url="$MODDIR/.config/sing-box/subscription.url"
active_config="$MODDIR/.config/sing-box/config.json"
work_marker="$MODDIR/.state/sing-box/subscription-work/marker"
candidate_dir="$MODDIR/.state/sing-box/subscription-candidates"
candidate_url="$candidate_dir/fixture.url"
candidate_local="$candidate_dir/fixture.local"
restart_log="$fixture/restarts.log"
core_state="$fixture/core-state"
proxylink_calls="$fixture/proxylink-calls"
mkdir -p "$candidate_dir"
: >"$restart_log"
: >"$proxylink_calls"
printf 'active-candidate\n' >"$active_url"
printf 'active-config\n' >"$active_config"
printf 'last-good-work\n' >"$work_marker"

# The production fetcher stages local content without a network request and
# enforces the same fixed size budget as remote subscription responses.
local_fetch_input="$fixture/local-fetch-input.yaml"
local_fetch_sources="$fixture/local-fetch-generation/sources.txt"
printf 'proxies:\n  - local-fetch-fixture\n' >"$local_fetch_input"
# The production implementation is sourced above; a later same-name test double
# intentionally replaces it for transaction-failure cases.
# shellcheck disable=SC2218
MAGICNET_SUB_SOURCE_FILE="$local_fetch_input" magicnet_singbox_fetch_subscription "$local_fetch_sources"
assert_file "$local_fetch_sources" "$fixture/local-fetch-generation/sources/local-source.txt"
assert_file "$fixture/local-fetch-generation/sources/local-source.txt" $'proxies:\n  - local-fetch-fixture'

write_candidate() {
  mkdir -p "$candidate_dir"
  printf 'new-candidate\n' >"$candidate_url"
  chmod 600 "$candidate_url"
}

write_local_candidate() {
  mkdir -p "$candidate_dir"
  printf 'proxies:\n  - local-fixture\n' >"$candidate_local"
  chmod 600 "$candidate_local"
}

magicnet_with_config_lock() {
  if test "${MAGICNET_CONFIG_LOCK_HELD:-0}" -eq 1; then
    "$@"
    return $?
  fi
  MAGICNET_CONFIG_LOCK_HELD=1
  "$@"
  local lock_rc=$?
  unset MAGICNET_CONFIG_LOCK_HELD
  return "$lock_rc"
}
magicnet_fswatch_status() { return 1; }
RUNNING=0
NATIVE_NODE_COUNT=1
PROXYLINK_AVAILABLE=0
magicnet_singbox_is_running() { test "$RUNNING" -eq 1; }
magicnet_singbox_extract_clash_nodes() { printf '%s\n' "$NATIVE_NODE_COUNT"; }
magicnet_singbox_extract_share_links() { printf '%s\n' "$NATIVE_NODE_COUNT"; }
magicnet_singbox_build_outbounds_with_proxylink() {
  test "$PROXYLINK_AVAILABLE" -eq 1 || return 1
  # shellcheck disable=SC2034 # consumed by the production status writer
  MAGICNET_SUB_CONVERTER_FORMAT=singbox
  printf 'called\n' >>"$proxylink_calls"
  printf '  "outbounds": [{"type":"vless","tag":"redacted-node"}]\n' >"$2"
  printf '1 0\n'
}
magicnet_singbox_proxylink_bin() {
  test "$PROXYLINK_AVAILABLE" -eq 1 || return 1
  printf '%s\n' fixture-proxylink
}
magicnet_singbox_build_outbounds_file() {
  printf '  "outbounds": [{"type":"vless","tag":"redacted-node"}]\n' >"$2"
  printf '1 0\n'
}
magicnet_singbox_update_config_with_nodes() {
  printf 'candidate-config\n' >"$(magicnet_singbox_subscription_config_file)"
}
magicnet_singbox_verify_subscription_ready() { return "${VERIFY_RC:-0}"; }
magicnet_singbox_restart_owned() {
  printf 'restart\n' >>"$restart_log"
  {
    sed -n '1p' "$active_config" 2>/dev/null || true
    sed -n '1p' "$active_url" 2>/dev/null || true
    sed -n '1p' "$work_marker" 2>/dev/null || true
  } >"$core_state"
}

FETCH_RC=1
test_fingerprint=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
magicnet_singbox_fetch_subscription() {
  test "$FETCH_RC" -eq 0 || return "$FETCH_RC"
  local generation="${1%/*}"
  local source="$generation/sources/${test_fingerprint}.yaml"
  local cache="$MODDIR/.state/sing-box/subscription-cache/${test_fingerprint}.yaml"
  local identity="${cache}.identity"
  mkdir -p "${source%/*}" "${cache%/*}"
  printf 'proxies:\n' >"$source"
  printf '%s\n' "$source" >"$1"
  printf '%s|%s|%s|%s\n' "${test_fingerprint}.yaml" "$cache" "$identity" "$test_fingerprint" \
    >"$generation/cache-map.txt"
  MAGICNET_SUB_CONFIGURED_COUNT=1
  MAGICNET_SUB_SOURCE_COUNT=1
  export MAGICNET_SUB_CONFIGURED_COUNT MAGICNET_SUB_SOURCE_COUNT
}

# Native parsing may produce no nodes for a format delegated to Proxylink.
# The converter must still be attempted before the update is rejected.
FETCH_RC=0
NATIVE_NODE_COUNT=0
PROXYLINK_AVAILABLE=1
write_candidate
MAGICNET_SUB_CANDIDATE_URL_FILE="$candidate_url" magicnet_singbox_update_subscription
assert_file "$active_config" candidate-config
assert_file "$proxylink_calls" called
regression_status="$(magicnet_singbox_status)"
grep -q '^last_native_parser=clash$' <<<"$regression_status"
grep -q '^last_native_node_count=0$' <<<"$regression_status"
grep -q '^last_converter_attempted=1$' <<<"$regression_status"
grep -q '^last_converter_format=singbox$' <<<"$regression_status"
grep -q '^last_converter_result=success$' <<<"$regression_status"
NATIVE_NODE_COUNT=1
PROXYLINK_AVAILABLE=0
FETCH_RC=1
printf 'active-candidate\n' >"$active_url"
printf 'active-config\n' >"$active_config"
printf 'last-good-work\n' >"$work_marker"

write_candidate
if MAGICNET_SUB_CANDIDATE_URL_FILE="$candidate_url" magicnet_singbox_update_subscription; then
  echo 'candidate failure unexpectedly succeeded' >&2
  exit 1
fi
assert_file "$active_url" active-candidate
assert_file "$active_config" active-config
assert_file "$work_marker" last-good-work

FETCH_RC=0
printf 'stale-candidate\n' >"$candidate_dir/stale.url"
printf 'stale-config-candidate\n' >"$MODDIR/.config/sing-box/config.json.candidate-orphan"
write_candidate
MAGICNET_SUB_CANDIDATE_URL_FILE="$candidate_url" magicnet_singbox_update_subscription
assert_file "$active_url" new-candidate
assert_file "$active_config" candidate-config
test -s "$MODDIR/.state/sing-box/subscription-work/outbounds.json"
assert_file "$MODDIR/.state/sing-box/subscription-cache/${test_fingerprint}.yaml.identity" "$test_fingerprint"
assert_file "$MODDIR/.state/sing-box/subscription-cache/${test_fingerprint}.yaml" proxies:
test ! -e "$candidate_dir/stale.url"
test ! -e "$MODDIR/.config/sing-box/config.json.candidate-orphan"

# Local content is a first-class persisted source. Switching modes removes the
# inactive source only after validation and activation have succeeded.
write_local_candidate
MAGICNET_SUB_CANDIDATE_SOURCE_FILE="$candidate_local" magicnet_singbox_update_subscription
assert_file "$MODDIR/.config/sing-box/subscription.local" $'proxies:\n  - local-fixture'
test ! -e "$active_url"
local_status="$(magicnet_singbox_status)"
grep -q '^source_mode=local$' <<<"$local_status"
write_candidate
MAGICNET_SUB_CANDIDATE_URL_FILE="$candidate_url" magicnet_singbox_update_subscription
assert_file "$active_url" new-candidate
test ! -e "$MODDIR/.config/sing-box/subscription.local"
url_status="$(magicnet_singbox_status)"
grep -q '^source_mode=url$' <<<"$url_status"

assert_subscription_recovery_pending() {
  local status
  status="$(magicnet_singbox_status)"
  grep -q '^update_running=0$' <<<"$status"
  grep -q '^recovery_result=pending$' <<<"$status"
  test -d "$MODDIR/.state/sing-box/subscription-transaction"
}

# Every active-state commit boundary must survive an unhandled process exit.
# Status remains read-only and reports pending recovery; an explicit lifecycle
# recovery then restores the journaled state.
run_fault_recovery_case() {
  local boundary="$1"
  local running="${2:-0}"
  local restart_before restart_after crash_rc
  rm -rf "$MODDIR/.state/sing-box/subscription-work"
  mkdir -p "$MODDIR/.state/sing-box/subscription-work"
  printf 'old-url\n' >"$active_url"
  printf 'old-config\n' >"$active_config"
  printf 'old-work\n' >"$work_marker"
  write_candidate
  RUNNING="$running"
  restart_before="$(wc -l <"$restart_log" 2>/dev/null || printf '0\n')"
  set +e
  (
    MAGICNET_SUB_CANDIDATE_URL_FILE="$candidate_url" \
      MAGICNET_SUB_FAULT="$boundary" MAGICNET_SUB_FAULT_EXIT137=1 \
      magicnet_singbox_update_subscription
  )
  crash_rc=$?
  set -e
  if test "$crash_rc" -ne 137; then
    printf 'fault boundary %s unexpectedly committed\n' "$boundary" >&2
    exit 1
  fi
  test -d "$MODDIR/.state/sing-box/subscription-transaction"
  test -f "$MODDIR/.state/sing-box/subscription-transaction/input-source"
  test "$(stat -c '%a' "$MODDIR/.state/sing-box/subscription-transaction/input-source")" = 600
  test ! -e "$candidate_url"
  assert_subscription_recovery_pending
  restart_after="$(wc -l <"$restart_log" 2>/dev/null || printf '0\n')"
  test "$restart_after" -eq "$restart_before"

  magicnet_recover_interrupted_subscription
  assert_file "$active_url" old-url
  assert_file "$active_config" old-config
  assert_file "$work_marker" old-work
  test ! -e "$MODDIR/.state/sing-box/subscription-transaction"
  test -z "$(find "$MODDIR/.config/sing-box" -maxdepth 1 -name 'config.json.candidate-*' -print -quit)"
  restart_after="$(wc -l <"$restart_log" 2>/dev/null || printf '0\n')"
  if test "$running" -eq 1; then
    test "$restart_after" -eq "$((restart_before + 1))"
    assert_file "$core_state" $'old-config\nold-url\nold-work'
  else
    test "$restart_after" -eq "$restart_before"
  fi
  RUNNING=0
}

run_fault_recovery_case after-active-config-rename
run_fault_recovery_case after-core-verification 1
run_fault_recovery_case after-work-switch
run_fault_recovery_case after-url-commit

# Service startup checks the durable subscription journal before accepting an
# already-running core, so a reboot/startup also repairs an interrupted update.
(
  startup_recovery="$MODDIR/.state/sing-box/subscription-transaction"
  mkdir -p "$startup_recovery"
  magicnet_singbox_update_lock_active() { return 1; }
  magicnet_singbox_recover_interrupted_locked() {
    rm -rf "$startup_recovery"
    printf '%s\n' recovered >"$fixture/startup-recovery"
  }
  magicnet_recover_interrupted_subscription
  test ! -e "$startup_recovery"
  assert_file "$fixture/startup-recovery" recovered
)

# `service start/ensure` must preserve a live connection when recovery would
# be disruptive. Explicit repair opts in and is still allowed to reconcile.
(
  # shellcheck disable=SC1090
  . "$ROOT/src/MagicNet/lib/magicnet/core.sh"
  live_recovery_count=0
  mkdir -p "$MODDIR/.state/sing-box/subscription-transaction"
  magicnet_module_disabled() { return 1; }
  magicnet_kernel_running() { return 0; }
  magicnet_recover_interrupted_subscription() {
    live_recovery_count=$((live_recovery_count + 1))
    rm -rf "$MODDIR/.state/sing-box/subscription-transaction"
  }
  magicnet_ensure_kernel
  magicnet_start_kernel
  test "$live_recovery_count" -eq 0
  MAGICNET_ALLOW_DISRUPTIVE_RECOVERY=1 magicnet_ensure_kernel
  test "$live_recovery_count" -eq 1
)

# A crash after changing source modes restores both source files exactly.
printf 'old-url-before-local\n' >"$active_url"
rm -f "$MODDIR/.config/sing-box/subscription.local"
write_local_candidate
set +e
(
  MAGICNET_SUB_CANDIDATE_SOURCE_FILE="$candidate_local" MAGICNET_SUB_FAULT=after-source-commit \
    MAGICNET_SUB_FAULT_EXIT137=1 magicnet_singbox_update_subscription
)
local_switch_rc=$?
set -e
test "$local_switch_rc" -eq 137
assert_subscription_recovery_pending
magicnet_recover_interrupted_subscription
assert_file "$active_url" old-url-before-local
test ! -e "$MODDIR/.config/sing-box/subscription.local"

rm -f "$active_url"
printf 'old-local-before-url\n' >"$MODDIR/.config/sing-box/subscription.local"
write_candidate
set +e
(
  MAGICNET_SUB_CANDIDATE_URL_FILE="$candidate_url" MAGICNET_SUB_FAULT=after-source-commit \
    MAGICNET_SUB_FAULT_EXIT137=1 magicnet_singbox_update_subscription
)
url_switch_rc=$?
set -e
test "$url_switch_rc" -eq 137
assert_subscription_recovery_pending
magicnet_recover_interrupted_subscription
assert_file "$MODDIR/.config/sing-box/subscription.local" old-local-before-url
test ! -e "$active_url"

# Restore URL mode for the first-configuration absence checks below.
rm -f "$MODDIR/.config/sing-box/subscription.local"
printf 'active-candidate\n' >"$active_url"

# Absence is part of a first-configuration rollback state.
rm -f "$active_url"
rm -rf "$MODDIR/.state/sing-box/subscription-work"
printf 'old-config-without-url-or-work\n' >"$active_config"
write_candidate
set +e
(
  MAGICNET_SUB_CANDIDATE_URL_FILE="$candidate_url" MAGICNET_SUB_FAULT=after-url-commit \
    MAGICNET_SUB_FAULT_EXIT137=1 magicnet_singbox_update_subscription
)
absent_rc=$?
set -e
if test "$absent_rc" -ne 137; then
  echo 'absent-state crash did not exit 137' >&2
  exit 1
fi
test -d "$MODDIR/.state/sing-box/subscription-transaction"
assert_subscription_recovery_pending
magicnet_recover_interrupted_subscription
assert_file "$active_config" old-config-without-url-or-work
test ! -e "$active_url"
test ! -e "$MODDIR/.state/sing-box/subscription-work"
test ! -e "$MODDIR/.state/sing-box/subscription-transaction"

# TERM uses the installed signal handler and performs the same full recovery.
mkdir -p "$MODDIR/.state/sing-box/subscription-work"
printf 'term-old-url\n' >"$active_url"
printf 'term-old-config\n' >"$active_config"
printf 'term-old-work\n' >"$work_marker"
write_candidate
set +e
(
  MAGICNET_SUB_CANDIDATE_URL_FILE="$candidate_url" MAGICNET_SUB_FAULT=after-work-switch \
    MAGICNET_SUB_FAULT_TERM=1 magicnet_singbox_update_subscription
)
term_rc=$?
set -e
test "$term_rc" -eq 143
assert_file "$active_url" term-old-url
assert_file "$active_config" term-old-config
assert_file "$work_marker" term-old-work
test ! -e "$MODDIR/.state/sing-box/subscription-transaction"

# Restore the normal fixture for status and cache checks.
mkdir -p "$MODDIR/.state/sing-box/subscription-work"
printf 'active-candidate\n' >"$active_url"
printf 'last-good-work\n' >"$work_marker"

# Cache identity must follow the source identity, not its list position.
identity_log="$fixture/cache-identities"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/fetch.sh"
magicnet_singbox_fetch_one_subscription() {
  printf '%s|%s\n' "$1" "$3" >>"$identity_log"
  mkdir -p "${2%/*}"
  printf 'fixture\n' >"$2"
}
first_urls="$fixture/first.urls"
second_urls="$fixture/second.urls"
printf 'candidate-a\ncandidate-b\n' >"$first_urls"
printf 'candidate-b\ncandidate-a\n' >"$second_urls"
MAGICNET_SUB_URL_FILE="$first_urls" magicnet_singbox_fetch_subscription "$fixture/first/sources.txt"
MAGICNET_SUB_URL_FILE="$second_urls" magicnet_singbox_fetch_subscription "$fixture/second/sources.txt"
candidate_a_cache="$(magicnet_singbox_subscription_fingerprint candidate-a).yaml"
first_a="$(awk -F'|' -v name="$candidate_a_cache" '$1 == name { print $2 }' "$fixture/first/cache-map.txt")"
second_a="$(awk -F'|' -v name="$candidate_a_cache" '$1 == name { print $2 }' "$fixture/second/cache-map.txt")"
test -n "$first_a"
test "$first_a" = "$second_a"

# A stale running record is reconciled without exposing candidate contents.
status_file="$(magicnet_singbox_subscription_status_file)"
mkdir -p "${status_file%/*}"
cat >"$status_file" <<'EOF'
phase=activate
result=running
attempt_epoch=100
success_epoch=90
configured_count=1
source_count=1
imported_count=2
skipped_count=0
generation_id=fixture-generation
reason=none
EOF
mkdir -p "$MODDIR/.state/sing-box/subscription-update.lock"
printf '999999:0:stale\n' >"$MODDIR/.state/sing-box/subscription-update.lock/owner"
status_output="$(magicnet_singbox_status)"
grep -q '^last_result=interrupted$' <<<"$status_output"
grep -q '^cache_source=url_sha256_identity$' <<<"$status_output"
if grep -q 'new-candidate\|active-candidate' <<<"$status_output"; then
  echo 'subscription status leaked candidate data' >&2
  exit 1
fi

# Schedule values are closed-set and live state is reported without URLs.
if magicnet_subscription_schedule_set 6; then
  echo 'invalid schedule unexpectedly accepted' >&2
  exit 1
fi

# Proc discovery prefilters by the fixed loop path before exact argv matching.
# Hundreds of unrelated processes must not each spawn the exact matcher, a
# substring decoy must fail closed, and the exact argv1 remains discoverable.
fake_proc="$fixture/proc"
command_wrappers="$fixture/command-wrappers"
tr_count_file="$fixture/tr-count"
real_tr="$(command -v tr)"
mkdir -p "$fake_proc" "$command_wrappers"
cat >"$command_wrappers/tr" <<'EOF'
#!/bin/sh
count=$(cat "$TR_COUNT_FILE" 2>/dev/null || printf '0\n')
printf '%s\n' "$((count + 1))" >"$TR_COUNT_FILE"
exec "$TR_REAL" "$@"
EOF
chmod +x "$command_wrappers/tr"

write_fake_cmdline() {
  local pid="$1"
  shift
  mkdir -p "$fake_proc/$pid"
  printf '%s\0' "$@" >"$fake_proc/$pid/cmdline"
}

for fake_pid in $(seq 920000 920119); do
  write_fake_cmdline "$fake_pid" /system/bin/sh /unrelated/worker.sh
done
expected_refresh_loop="$(magicnet_subscription_refresh_loop_file)"
write_fake_cmdline 920120 /system/bin/sh -c "echo $expected_refresh_loop"
write_fake_cmdline 920121 /system/bin/sh "$expected_refresh_loop"
printf '0\n' >"$tr_count_file"
prefiltered_pids="$({
  PATH="$command_wrappers:$PATH" \
    TR_COUNT_FILE="$tr_count_file" TR_REAL="$real_tr" \
    MAGICNET_SUB_REFRESH_PROC_ROOT="$fake_proc" \
    magicnet_subscription_refresh_loop_pids
})"
test "$prefiltered_pids" = 920121
assert_file "$tr_count_file" 123
if MAGICNET_SUB_REFRESH_PROC_ROOT="$fake_proc" \
  magicnet_subscription_refresh_proc_command_matches 920120; then
  echo 'trustworthy argv mismatch unexpectedly matched' >&2
  exit 1
else
  test "$?" -eq 1
fi
unset fake_pid prefiltered_pids

# A transient proc race gets fresh readable-file snapshots and bounded batched
# grep retries. Persistent grep errors remain fail-closed after the retries.
scan_grep_bin="$fixture/scan-grep-bin"
scan_grep_count_file="$fixture/scan-grep-count"
real_grep="$(command -v grep)"
mkdir -p "$scan_grep_bin"
cat >"$scan_grep_bin/grep" <<'EOF'
#!/bin/sh
count=$(cat "$SCAN_GREP_COUNT_FILE" 2>/dev/null || printf '0\n')
count=$((count + 1))
printf '%s\n' "$count" >"$SCAN_GREP_COUNT_FILE"
case "$SCAN_GREP_MODE" in
  persistent) exit 2 ;;
  transient) [ "$count" -eq 1 ] && exit 2 ;;
  two-transient) [ "$count" -le 2 ] && exit 2 ;;
esac
exec "$SCAN_GREP_REAL" "$@"
EOF
chmod +x "$scan_grep_bin/grep"
printf '0\n' >"$scan_grep_count_file"
printf '0\n' >"$tr_count_file"
transient_scan_pids="$({
  PATH="$scan_grep_bin:$command_wrappers:$PATH" \
    SCAN_GREP_COUNT_FILE="$scan_grep_count_file" \
    SCAN_GREP_MODE=transient SCAN_GREP_REAL="$real_grep" \
    TR_COUNT_FILE="$tr_count_file" TR_REAL="$real_tr" \
    MAGICNET_SUB_REFRESH_PROC_ROOT="$fake_proc" \
    magicnet_subscription_refresh_loop_pids
})"
test "$transient_scan_pids" = 920121
assert_file "$scan_grep_count_file" 2
assert_file "$tr_count_file" 123
printf '0\n' >"$scan_grep_count_file"
printf '0\n' >"$tr_count_file"
two_transient_scan_pids="$({
  PATH="$scan_grep_bin:$command_wrappers:$PATH" \
    SCAN_GREP_COUNT_FILE="$scan_grep_count_file" \
    SCAN_GREP_MODE=two-transient SCAN_GREP_REAL="$real_grep" \
    TR_COUNT_FILE="$tr_count_file" TR_REAL="$real_tr" \
    MAGICNET_SUB_REFRESH_PROC_ROOT="$fake_proc" \
    magicnet_subscription_refresh_loop_pids
})"
test "$two_transient_scan_pids" = 920121
assert_file "$scan_grep_count_file" 3
assert_file "$tr_count_file" 123
printf '0\n' >"$scan_grep_count_file"
if PATH="$scan_grep_bin:$PATH" \
  SCAN_GREP_COUNT_FILE="$scan_grep_count_file" \
  SCAN_GREP_MODE=persistent SCAN_GREP_REAL="$real_grep" \
  MAGICNET_SUB_REFRESH_PROC_ROOT="$fake_proc" \
  magicnet_subscription_refresh_loop_pids; then
  echo 'persistent proc scan error unexpectedly succeeded' >&2
  exit 1
else
  test "$?" -eq 2
fi
assert_file "$scan_grep_count_file" 3
unset scan_grep_bin scan_grep_count_file real_grep transient_scan_pids two_transient_scan_pids

# A real prefilter scan error is not equivalent to finding no process. With no
# trustworthy owner state, status is stale and an enabled schedule must refuse
# to generate or launch a replacement loop.
scan_error_root="$fixture/missing-proc-root"
rm -rf "$scan_error_root"
rm -f \
  "$(magicnet_subscription_refresh_owner_file)" \
  "$(magicnet_subscription_refresh_pid_file)" \
  "$(magicnet_subscription_refresh_loop_file)"
scan_error_state="$(
  MAGICNET_SUB_REFRESH_PROC_ROOT="$scan_error_root" \
    magicnet_subscription_refresh_owner_state 2>/dev/null || true
)"
test "$scan_error_state" = indeterminate
mkdir -p "$(magicnet_subscription_schedule_file | sed 's@/[^/]*$@@')"
printf '24\n' >"$(magicnet_subscription_schedule_file)"
if MAGICNET_SUB_REFRESH_PROC_ROOT="$scan_error_root" magicnet_subscription_refresh_start; then
  echo 'proc prefilter failure unexpectedly allowed refresh start' >&2
  exit 1
fi
test ! -e "$(magicnet_subscription_refresh_owner_file)"
test ! -e "$(magicnet_subscription_refresh_pid_file)"
test ! -e "$(magicnet_subscription_refresh_loop_file)"
printf 'off\n' >"$(magicnet_subscription_schedule_file)"
unset scan_error_root scan_error_state

# grep rc=1 is the normal no-candidate result. The off/status report keeps its
# established fields and does not invoke exact matching for unrelated entries.
no_candidate_proc="$fixture/no-candidate-proc"
mkdir -p "$no_candidate_proc/930000"
printf '%s\0' /system/bin/sh /unrelated/status-worker.sh \
  >"$no_candidate_proc/930000/cmdline"
printf '0\n' >"$tr_count_file"
printf 'off\n' >"$(magicnet_subscription_schedule_file)"
off_schedule_output="$({
  PATH="$command_wrappers:$PATH" \
    TR_COUNT_FILE="$tr_count_file" TR_REAL="$real_tr" \
    MAGICNET_SUB_REFRESH_PROC_ROOT="$no_candidate_proc" \
    magicnet_subscription_schedule_report
})"
grep -q '^schedule_interval_hours=off$' <<<"$off_schedule_output"
grep -q '^schedule_enabled=0$' <<<"$off_schedule_output"
grep -q '^schedule_running=0$' <<<"$off_schedule_output"
grep -q '^schedule_owner=none$' <<<"$off_schedule_output"
assert_file "$tr_count_file" 1
disappearing_grep_bin="$fixture/disappearing-grep-bin"
mkdir -p "$disappearing_grep_bin"
cat >"$disappearing_grep_bin/grep" <<'EOF'
#!/bin/sh
printf '%s\n' "$DISAPPEARED_CMDLINE"
EOF
chmod +x "$disappearing_grep_bin/grep"
if disappeared_output="$({
  PATH="$disappearing_grep_bin:$PATH" \
    DISAPPEARED_CMDLINE="$no_candidate_proc/930001/cmdline" \
    MAGICNET_SUB_REFRESH_PROC_ROOT="$no_candidate_proc" \
    magicnet_subscription_refresh_loop_pids
})"; then
  echo 'no-candidate scan unexpectedly reported a result' >&2
  exit 1
else
  test "$?" -eq 1
fi
test -z "$disappeared_output"
if MAGICNET_SUB_REFRESH_PROC_ROOT="$no_candidate_proc" \
  magicnet_subscription_refresh_proc_command_matches 999999 2>/dev/null; then
  echo 'disappeared proc candidate unexpectedly passed exact matching' >&2
  exit 1
else
  test "$?" -eq 1
fi
exact_read_error_proc="$fixture/exact-read-error-proc"
exact_read_error_bin="$fixture/exact-read-error-bin"
exact_read_count_file="$fixture/exact-read-count"
mkdir -p "$exact_read_error_proc/930002" "$exact_read_error_bin"
printf '%s\0' /system/bin/sh "$expected_refresh_loop" \
  >"$exact_read_error_proc/930002/cmdline"
cat >"$exact_read_error_bin/tr" <<'EOF'
#!/bin/sh
count=$(cat "$EXACT_READ_COUNT_FILE" 2>/dev/null || printf '0\n')
count=$((count + 1))
printf '%s\n' "$count" >"$EXACT_READ_COUNT_FILE"
if [ "$EXACT_READ_MODE" = persistent ] || [ "$count" -eq 1 ]; then
  exit 2
fi
exec "$EXACT_READ_REAL" "$@"
EOF
chmod +x "$exact_read_error_bin/tr"
printf '0\n' >"$exact_read_count_file"
transient_exact_pids="$({
  PATH="$exact_read_error_bin:$PATH" \
    EXACT_READ_COUNT_FILE="$exact_read_count_file" \
    EXACT_READ_MODE=transient EXACT_READ_REAL="$real_tr" \
    MAGICNET_SUB_REFRESH_PROC_ROOT="$exact_read_error_proc" \
    magicnet_subscription_refresh_loop_pids
})"
test "$transient_exact_pids" = 930002
assert_file "$exact_read_count_file" 3
printf '0\n' >"$exact_read_count_file"
if PATH="$exact_read_error_bin:$PATH" \
  EXACT_READ_COUNT_FILE="$exact_read_count_file" \
  EXACT_READ_MODE=persistent EXACT_READ_REAL="$real_tr" \
  MAGICNET_SUB_REFRESH_PROC_ROOT="$exact_read_error_proc" \
  magicnet_subscription_refresh_loop_pids; then
  echo 'persistent exact-read error unexpectedly passed' >&2
  exit 1
else
  test "$?" -eq 2
fi
assert_file "$exact_read_count_file" 3
unset no_candidate_proc off_schedule_output disappearing_grep_bin disappeared_output
unset exact_read_error_proc exact_read_error_bin exact_read_count_file transient_exact_pids

missing_cmdline_proc="$fixture/missing-cmdline-proc"
mkdir -p "$missing_cmdline_proc/940000"
if MAGICNET_SUB_REFRESH_PROC_ROOT="$missing_cmdline_proc" \
  magicnet_subscription_refresh_loop_pids; then
  echo 'live pid directory without cmdline unexpectedly passed proc scan' >&2
  exit 1
else
  test "$?" -eq 2
fi
unset missing_cmdline_proc

# The child can exist before its /proc identity is readable. A single
# immediately-failing identity probe must not reject a valid refresh loop.
(
  race_pid=
  cleanup_race_loop() {
    if [ -n "${race_pid:-}" ]; then
      kill "$race_pid" 2>/dev/null || true
      wait "$race_pid" 2>/dev/null || true
    fi
  }
  trap cleanup_race_loop EXIT
  race_proc_start_count_file="$fixture/race-proc-start-count"
  printf '0\n' >"$race_proc_start_count_file"
  # shellcheck disable=SC2329 # Called by the production start path.
  magicnet_subscription_refresh_proc_start() {
    race_proc_start_calls=$(cat "$race_proc_start_count_file")
    race_proc_start_calls=$((race_proc_start_calls + 1))
    printf '%s\n' "$race_proc_start_calls" >"$race_proc_start_count_file"
    if [ "$race_proc_start_calls" -eq 1 ]; then
      return 1
    fi
    printf '4242\n'
  }
  # shellcheck disable=SC2329 # Called by the production start path.
  magicnet_subscription_refresh_proc_command_matches() { return 0; }
  rm -f \
    "$(magicnet_subscription_refresh_owner_file)" \
    "$(magicnet_subscription_refresh_pid_file)" \
    "$(magicnet_subscription_refresh_loop_file)"
  printf '24\n' >"$(magicnet_subscription_schedule_file)"
  with_no_refresh_loop_candidates magicnet_subscription_refresh_start
  test "$(cat "$race_proc_start_count_file")" -ge 2
  race_pid="$(sed -n '1p' "$(magicnet_subscription_refresh_pid_file)")"
  test -n "$race_pid"
  printf 'off\n' >"$(magicnet_subscription_schedule_file)"
  rm -f \
    "$(magicnet_subscription_refresh_owner_file)" \
    "$(magicnet_subscription_refresh_pid_file)" \
    "$(magicnet_subscription_refresh_loop_file)"
)

if magicnet_subscription_refresh_wait_for_identity invalid-pid; then
  echo 'invalid refresh identity PID unexpectedly succeeded' >&2
  exit 1
fi
test -z "${_refresh_wait_pid:-}"
test -z "${_refresh_wait_attempts:-}"
test -z "${_refresh_wait_delay:-}"

if magicnet_subscription_refresh_proc_start invalid-pid; then
  echo 'invalid refresh proc PID unexpectedly succeeded' >&2
  exit 1
fi
test -z "${_refresh_proc_pid:-}"
test -z "${_refresh_proc_root:-}"
if MAGICNET_SUB_REFRESH_PROC_ROOT=relative-proc-root magicnet_subscription_refresh_proc_start 1; then
  echo 'relative refresh proc root unexpectedly succeeded' >&2
  exit 1
fi
test -z "${_refresh_proc_pid:-}"
test -z "${_refresh_proc_root:-}"

# Owner persistence failure must tear down the just-spawned, strictly matched
# loop and leave no state that could cause duplicate refreshers.
mkdir -p "$(magicnet_subscription_schedule_file | sed 's@/[^/]*$@@')"
printf '24\n' >"$(magicnet_subscription_schedule_file)"
for failure_attempt in 1 2; do
  if MAGICNET_SUB_REFRESH_OWNER_WRITE_FAIL=1 \
    with_no_refresh_loop_candidates magicnet_subscription_refresh_start; then
    echo "injected refresh owner write failure attempt ${failure_attempt} unexpectedly succeeded" >&2
    exit 1
  fi
  test -z "$(magicnet_subscription_refresh_loop_pids)"
  test ! -e "$(magicnet_subscription_refresh_owner_file)"
  test ! -e "$(magicnet_subscription_refresh_pid_file)"
done
printf 'off\n' >"$(magicnet_subscription_schedule_file)"

# An exact loop without its owner record is an orphan. Never start a duplicate
# and never terminate or silently adopt the unowned process.
orphan_loop="$(magicnet_subscription_refresh_loop_file)"
cat >"$orphan_loop" <<'EOF'
#!/bin/sh
while :; do sleep 30; done
EOF
chmod +x "$orphan_loop"
sh "$orphan_loop" &
orphan_pid=$!
sleep 0.1
orphan_proc="$fixture/orphan-proc"
write_fake_cmdline "$orphan_pid" /system/bin/sh "$orphan_loop"
mv "$fake_proc/$orphan_pid" "$orphan_proc"
mkdir -p "$orphan_proc/$orphan_pid"
mv "$orphan_proc/cmdline" "$orphan_proc/$orphan_pid/cmdline"
rm -f "$(magicnet_subscription_refresh_owner_file)" "$(magicnet_subscription_refresh_pid_file)"
printf '24\n' >"$(magicnet_subscription_schedule_file)"
test "$(MAGICNET_SUB_REFRESH_PROC_ROOT="$orphan_proc" magicnet_subscription_refresh_owner_state 2>/dev/null || true)" = orphan
if MAGICNET_SUB_REFRESH_PROC_ROOT="$orphan_proc" magicnet_subscription_refresh_start; then
  echo 'orphan refresh loop unexpectedly allowed a duplicate' >&2
  exit 1
fi
kill -0 "$orphan_pid"
test "$(MAGICNET_SUB_REFRESH_PROC_ROOT="$orphan_proc" magicnet_subscription_refresh_loop_pids)" = "$orphan_pid"
test ! -e "$(magicnet_subscription_refresh_owner_file)"
kill "$orphan_pid"
wait "$orphan_pid" 2>/dev/null || true
orphan_pid=
rm -f "$orphan_loop"
printf 'off\n' >"$(magicnet_subscription_schedule_file)"

# Stopping is idempotent only after a trustworthy empty scan. Malformed owner
# state is indeterminate and must be retained.
empty_stop_proc="$fixture/empty-stop-proc"
mkdir -p "$empty_stop_proc"
rm -f "$(magicnet_subscription_refresh_owner_file)"
MAGICNET_SUB_REFRESH_PROC_ROOT="$empty_stop_proc" magicnet_subscription_refresh_stop
printf 'malformed-owner\n' >"$(magicnet_subscription_refresh_owner_file)"
if MAGICNET_SUB_REFRESH_PROC_ROOT="$empty_stop_proc" magicnet_subscription_refresh_stop; then
  echo 'malformed owner unexpectedly reported stopped' >&2
  exit 1
else
  test "$?" -eq 2
fi
assert_file "$(magicnet_subscription_refresh_owner_file)" malformed-owner
rm -f "$(magicnet_subscription_refresh_owner_file)"

with_no_refresh_loop_candidates magicnet_subscription_schedule_set 24
assert_file "$(magicnet_subscription_schedule_file)" 24
refresh_status_output="$(magicnet_subscription_refresh_status)"
test -n "$refresh_status_output"
schedule_output="$(magicnet_subscription_schedule_report)"
grep -q '^schedule_interval_hours=24$' <<<"$schedule_output"
grep -q '^schedule_enabled=1$' <<<"$schedule_output"
grep -q '^schedule_running=1$' <<<"$schedule_output"
grep -q '^schedule_owner=active$' <<<"$schedule_output"
magicnet_subscription_schedule_set off
assert_file "$(magicnet_subscription_schedule_file)" off
test ! -e "$(magicnet_subscription_refresh_owner_file)"

# Stale and command-mismatched owners must never terminate arbitrary PIDs.
sleep 30 &
stale_pid=$!
stale_start="$(magicnet_subscription_refresh_proc_start "$stale_pid")"
mkdir -p "$(magicnet_subscription_refresh_state_dir)"
printf '%s:%s:%s\n' "$stale_pid" "$((stale_start + 1))" subscription-refresh-v1 \
  >"$(magicnet_subscription_refresh_owner_file)"
printf '%s\n' "$stale_pid" >"$(magicnet_subscription_refresh_pid_file)"
stale_record="${stale_pid}:$((stale_start + 1)):subscription-refresh-v1"
if magicnet_subscription_refresh_stop; then
  echo 'stale refresh owner unexpectedly reported stopped' >&2
  exit 1
else
  test "$?" -eq 1
fi
kill -0 "$stale_pid"
assert_file "$(magicnet_subscription_refresh_owner_file)" "$stale_record"
assert_file "$(magicnet_subscription_refresh_pid_file)" "$stale_pid"
printf '24\n' >"$(magicnet_subscription_schedule_file)"
if magicnet_subscription_refresh_start; then
  echo 'stale refresh owner unexpectedly allowed a second loop' >&2
  exit 1
fi
kill -0 "$stale_pid"
test -z "$(magicnet_subscription_refresh_loop_pids)"
assert_file "$(magicnet_subscription_refresh_owner_file)" "$stale_record"
printf 'off\n' >"$(magicnet_subscription_schedule_file)"
kill "$stale_pid"
wait "$stale_pid" 2>/dev/null || true
stale_pid=

sleep 30 &
mismatch_pid=$!
mismatch_start="$(magicnet_subscription_refresh_proc_start "$mismatch_pid")"
printf '%s:%s:%s\n' "$mismatch_pid" "$mismatch_start" subscription-refresh-v1 \
  >"$(magicnet_subscription_refresh_owner_file)"
printf '%s\n' "$mismatch_pid" >"$(magicnet_subscription_refresh_pid_file)"
mismatch_record="${mismatch_pid}:${mismatch_start}:subscription-refresh-v1"
if magicnet_subscription_refresh_stop; then
  echo 'mismatched refresh owner unexpectedly reported stopped' >&2
  exit 1
else
  test "$?" -eq 1
fi
kill -0 "$mismatch_pid"
assert_file "$(magicnet_subscription_refresh_owner_file)" "$mismatch_record"
assert_file "$(magicnet_subscription_refresh_pid_file)" "$mismatch_pid"
kill "$mismatch_pid"
wait "$mismatch_pid" 2>/dev/null || true
mismatch_pid=

# A matching PID, start time, identity, and exact loop command is owned.
owned_loop="$(magicnet_subscription_refresh_loop_file)"
cat >"$owned_loop" <<'EOF'
#!/bin/sh
while :; do sleep 30; done
EOF
chmod +x "$owned_loop"
sh "$owned_loop" &
owned_pid=$!
owned_start="$(magicnet_subscription_refresh_proc_start "$owned_pid")"
printf '%s:%s:%s\n' "$owned_pid" "$owned_start" subscription-refresh-v1 \
  >"$(magicnet_subscription_refresh_owner_file)"
printf '%s\n' "$owned_pid" >"$(magicnet_subscription_refresh_pid_file)"
MAGICNET_SUB_REFRESH_STOP_TIMEOUT=1 magicnet_subscription_refresh_stop
if kill -0 "$owned_pid" 2>/dev/null; then
  echo 'owned refresh loop was not stopped' >&2
  exit 1
fi
test ! -e "$(magicnet_subscription_refresh_owner_file)"
test ! -e "$(magicnet_subscription_refresh_pid_file)"
test ! -e "$(magicnet_subscription_refresh_loop_file)"
owned_pid=

echo 'subscription lifecycle tests passed'

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
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"
. "$ROOT/src/MagicNet/lib/magicnet/supervisors.sh"

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
restart_log="$fixture/restarts.log"
core_state="$fixture/core-state"
mkdir -p "$candidate_dir"
: >"$restart_log"
printf 'active-candidate\n' >"$active_url"
printf 'active-config\n' >"$active_config"
printf 'last-good-work\n' >"$work_marker"

write_candidate() {
  mkdir -p "$candidate_dir"
  printf 'new-candidate\n' >"$candidate_url"
  chmod 600 "$candidate_url"
}

magicnet_with_config_lock() { "$@"; }
magicnet_fswatch_status() { return 1; }
RUNNING=0
magicnet_singbox_is_running() { test "$RUNNING" -eq 1; }
magicnet_singbox_extract_clash_nodes() { printf '1\n'; }
magicnet_singbox_extract_share_links() { printf '1\n'; }
magicnet_singbox_build_outbounds_with_proxylink() { return 1; }
magicnet_singbox_proxylink_bin() { return 1; }
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

# Every active-state commit boundary must survive an unhandled process exit.
# The next status read performs the real recovery; the wrapper cannot pre-clean
# the journal because exit 137 terminates it first.
run_fault_recovery_case() {
  local boundary="$1"
  local running="${2:-0}"
  local restart_before restart_after crash_rc status_after
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
  test -f "$MODDIR/.state/sing-box/subscription-transaction/input-url"
  test "$(stat -c '%a' "$MODDIR/.state/sing-box/subscription-transaction/input-url")" = 600
  test ! -e "$candidate_url"
  status_after="$(magicnet_singbox_status)"
  grep -q '^update_running=0$' <<<"$status_after"
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
magicnet_singbox_status >/dev/null
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
assert_file "$tr_count_file" 2
if MAGICNET_SUB_REFRESH_PROC_ROOT="$fake_proc" \
  magicnet_subscription_refresh_proc_command_matches 920120; then
  echo 'trustworthy argv mismatch unexpectedly matched' >&2
  exit 1
else
  test "$?" -eq 1
fi
unset fake_pid prefiltered_pids

# A transient proc race gets one fresh readable-file snapshot and one more
# batched grep. Persistent grep errors remain fail-closed after that retry.
scan_grep_bin="$fixture/scan-grep-bin"
scan_grep_count_file="$fixture/scan-grep-count"
real_grep="$(command -v grep)"
mkdir -p "$scan_grep_bin"
cat >"$scan_grep_bin/grep" <<'EOF'
#!/bin/sh
count=$(cat "$SCAN_GREP_COUNT_FILE" 2>/dev/null || printf '0\n')
count=$((count + 1))
printf '%s\n' "$count" >"$SCAN_GREP_COUNT_FILE"
if [ "$SCAN_GREP_MODE" = persistent ] || [ "$count" -eq 1 ]; then
  exit 2
fi
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
assert_file "$tr_count_file" 2
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
assert_file "$scan_grep_count_file" 2
unset scan_grep_bin scan_grep_count_file real_grep transient_scan_pids

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
test "$scan_error_state" = stale
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
assert_file "$tr_count_file" 0
disappearing_grep_bin="$fixture/disappearing-grep-bin"
mkdir -p "$disappearing_grep_bin"
cat >"$disappearing_grep_bin/grep" <<'EOF'
#!/bin/sh
printf '%s\n' "$DISAPPEARED_CMDLINE"
EOF
chmod +x "$disappearing_grep_bin/grep"
disappeared_output="$({
  PATH="$disappearing_grep_bin:$PATH" \
    DISAPPEARED_CMDLINE="$no_candidate_proc/930001/cmdline" \
    MAGICNET_SUB_REFRESH_PROC_ROOT="$no_candidate_proc" \
    magicnet_subscription_refresh_loop_pids
})"
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
assert_file "$exact_read_count_file" 2
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
assert_file "$exact_read_count_file" 2
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
rm -f "$(magicnet_subscription_refresh_owner_file)" "$(magicnet_subscription_refresh_pid_file)"
printf '24\n' >"$(magicnet_subscription_schedule_file)"
test "$(magicnet_subscription_refresh_owner_state 2>/dev/null || true)" = orphan
if magicnet_subscription_refresh_start; then
  echo 'orphan refresh loop unexpectedly allowed a duplicate' >&2
  exit 1
fi
kill -0 "$orphan_pid"
test "$(magicnet_subscription_refresh_loop_pids)" = "$orphan_pid"
test ! -e "$(magicnet_subscription_refresh_owner_file)"
kill "$orphan_pid"
wait "$orphan_pid" 2>/dev/null || true
orphan_pid=
rm -f "$orphan_loop"
printf 'off\n' >"$(magicnet_subscription_schedule_file)"

# Stopping is a safe, idempotent no-op without a valid owned record.
rm -f "$(magicnet_subscription_refresh_owner_file)"
magicnet_subscription_refresh_stop
printf 'malformed-owner\n' >"$(magicnet_subscription_refresh_owner_file)"
magicnet_subscription_refresh_stop
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
magicnet_subscription_refresh_stop
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
magicnet_subscription_refresh_stop
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

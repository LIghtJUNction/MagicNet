#!/usr/bin/env python3
"""Exercise standalone subscription shutdown through the shipped loader.

Only process discovery, signals, time and runtime side effects are fixtures.
This does not verify Android networking. Set MAGICNET_TEST_SUBSCRIPTION_CONFIG_PATH
to an old config.sh copy for a negative control without changing module source.
"""
from __future__ import annotations

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "src/MagicNet/lib"
CONFIG_SOURCE = Path(os.environ.get(
    "MAGICNET_TEST_SUBSCRIPTION_CONFIG_PATH",
    str(LIB / "magicnet/singbox_subscribe/config.sh"),
)).resolve(strict=True)
SHELLS = [["sh"], ["bash"]]
if shutil.which("busybox"):
    SHELLS.append(["busybox", "sh"])


class SubscriptionSignalSafety(unittest.TestCase):
    def run_case(self, scenario: str, operation: str, assertions: str, *, mode: str = "tun"):
        for shell in SHELLS:
            with self.subTest(shell=shell, scenario=scenario, operation=operation, mode=mode):
                with tempfile.TemporaryDirectory(prefix="magicnet-sub-signal-") as work:
                    mod = Path(work) / "module with spaces"
                    lib = mod / "lib/magicnet"
                    lib.mkdir(parents=True)
                    for source in (LIB / "magicnet").iterdir():
                        if source.name != "singbox_subscribe":
                            (lib / source.name).symlink_to(source, target_is_directory=source.is_dir())
                    pipeline = lib / "singbox_subscribe"
                    pipeline.mkdir()
                    for source in (LIB / "magicnet/singbox_subscribe").iterdir():
                        target = CONFIG_SOURCE if source.name == "config.sh" else source
                        (pipeline / source.name).symlink_to(target, target_is_directory=target.is_dir())
                    (mod / "lib/magicnet_singbox_subscribe.sh").symlink_to(
                        LIB / "magicnet_singbox_subscribe.sh")
                    (mod / "tmp").mkdir()
                    (mod / "foreign-magicnet0").touch()
                    config = mod / ".config/sing-box/config.json"
                    config.parent.mkdir(parents=True)
                    config.write_text("{}\n", encoding="utf-8")
                    (mod / "bin").mkdir()
                    core = mod / "bin/sing-box"
                    core.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                    core.chmod(0o700)
                    script = r'''
set -eu
MODDIR=__MODDIR__
scenario=__SCENARIO__
readiness=__READINESS__
mode=__MODE__
config="$MODDIR/.config/sing-box/config.json"
export MODDIR
MAGICNET_LIB_DIR="$MODDIR/lib/magicnet"
export MAGICNET_LIB_DIR
# Load exactly the standalone shim used by the subscription updater. No kamfw
# helper or test replacement for the shutdown implementation is sourced.
. "$MODDIR/lib/magicnet_singbox_subscribe.sh"
event() { printf '%s\n' "$*" >>"$MODDIR/events"; }
magicnet_transparent_mode() { printf '%s\n' "$mode"; }
warn() { event "warn:$*"; }
error() { event "error:$*"; }
magicnet_proc_query_temp_create() { mktemp "$MODDIR/tmp/private.XXXXXX"; }
printf '0\n' >"$MODDIR/clock"
printf '0\n' >"$MODDIR/queries"
: >"$MODDIR/events"
date() { [ "$*" = +%s ] || return 97; cat "$MODDIR/clock"; }
sleep() {
    [ "$1" = 1 ] || return 97
    now=$(cat "$MODDIR/clock")
    printf '%s\n' "$((now + 1))" >"$MODDIR/clock"
}
kill() {
    now=$(cat "$MODDIR/clock")
    case "$1" in
        -0) return 0 ;;
        -9) signal=KILL; target="$2" ;;
        -15) signal=TERM; target="$2" ;;
        *) signal=TERM; target="$1" ;;
    esac
    event "$signal:$target:$now"
    case "$signal:$scenario" in
        TERM:term_denied | TERM:term_denied_unknown)
            : >"$MODDIR/refused"
            return 1
            ;;
        KILL:kill_denied | KILL:kill_denied_unknown)
            : >"$MODDIR/refused"
            return 1
            ;;
        TERM:term_exit_race | KILL:kill_exit_race)
            : >"$MODDIR/exited"
            return 1
            ;;
        TERM:immediate | TERM:supervisor_denied)
            : >"$MODDIR/exited"
            ;;
        KILL:*) : >"$MODDIR/exited" ;;
    esac
    [ "$signal" != TERM ] || : >"$MODDIR/termed"
}
magicnet_singbox_owned_pids_to_file() {
    [ "$1" = "$config" ] || return 98
    query=$(cat "$MODDIR/queries")
    query=$((query + 1))
    printf '%s\n' "$query" >"$MODDIR/queries"
    : >"$2"
    # Readiness starts with no old core, then discovers the failed launch.
    [ "$readiness:$query" != 1:1 ] || return 1
    case "$scenario" in
        unknown_initial) return 2 ;;
        unknown_poll) [ "$query" -le 1 ] || return 2 ;;
        term_denied_unknown | kill_denied_unknown)
            [ ! -e "$MODDIR/refused" ] || return 2
            ;;
        stopped) return 1 ;;
    esac
    [ ! -e "$MODDIR/exited" ] || return 1
    if [ "$scenario" = slow ] && [ -e "$MODDIR/termed" ] &&
        [ "$(cat "$MODDIR/clock")" -ge 3 ]; then
        : >"$MODDIR/exited"
        return 1
    fi
    if [ "$scenario" = replacement ] && [ "$query" -gt 1 ]; then
        printf '456\n' >"$2"
    else
        printf '123\n' >"$2"
    fi
}
magicnet_fswatch_status() { return 1; }
magicnet_singbox_api_listener_exists() { return 1; }
magicnet_supervisors_stop() {
    event supervisors-stop
    [ "$scenario" != supervisor_denied ]
}
magicnet_disable_dns_capture() { event dns-clean; }
magicnet_disable_dns_leak_guard() { event guard-clean; }
__START_HELPER__
nohup() { event launch; }
magicnet_singbox_pid_owned() { return 1; }
magicnet_reapply_post_start_policy() { event policy-reapply; }
magicnet_singbox_record_runtime_fingerprint() { event fingerprint; }
magicnet_singbox_supervisor_restore() { event supervisors-restore; }
ip() {
    event "ip:$*"
    [ "$*" != 'link delete magicnet0' ] || rm -f "$MODDIR/foreign-magicnet0"
}
# Exercise the production default grace, regardless of inherited host settings.
unset MAGICNET_SUB_STOP_TIMEOUT
export MAGICNET_SUB_KILL_TIMEOUT=3
export MAGICNET_SUB_READY_TIMEOUT=1
export MAGICNET_SUB_FSWATCH_WAS_ACTIVE=0 MAGICNET_SUB_RESET_BOOTSTRAP_CACHE=0
export MAGICNET_SUB_DEFER_FSWATCH_RESTORE=0
trap ': >"$MODDIR/parent-exit"' EXIT
rc=0
__COMMAND__ || rc=$?
__ASSERTIONS__
# Private process snapshots must be released on success and every failure.
[ -z "$(ls -A "$MODDIR/tmp")" ]
trap >"$MODDIR/traps"
grep -q parent-exit "$MODDIR/traps"
[ ! -e "$MODDIR/parent-exit" ]
[ -e "$MODDIR/foreign-magicnet0" ]
'''
                    script = script.replace("__MODDIR__", shlex.quote(str(mod)))
                    script = script.replace("__SCENARIO__", shlex.quote(scenario))
                    readiness = operation.startswith("magicnet_singbox_ensure_start_owned ")
                    script = script.replace("__READINESS__", "1" if readiness else "0")
                    script = script.replace("__MODE__", shlex.quote(mode))
                    start_helper = "" if readiness else "magicnet_singbox_ensure_start_owned() { event start; }"
                    script = script.replace("__START_HELPER__", start_helper)
                    script = script.replace("__COMMAND__", operation)
                    script = script.replace("__ASSERTIONS__", assertions)
                    result = subprocess.run(shell + ["-c", script], capture_output=True,
                                            text=True, timeout=15)
                    events = (mod / "events").read_text()
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr + events)
                    self.assertEqual(config.read_text(), "{}\n")
                    self.assertTrue((mod / "parent-exit").is_file())

    def lifecycle_cases(self, scenario: str, assertions: str):
        for function in ("magicnet_singbox_restart_owned", "magicnet_singbox_stop_owned_after_failure"):
            self.run_case(scenario, function + ' "$config"', assertions)

    def test_refused_term_preserves_runtime_without_escalation(self):
        for scenario in ("term_denied", "term_denied_unknown"):
            self.lifecycle_cases(scenario, r'''
[ "$rc" = 2 ]
[ "$(cat "$MODDIR/clock")" = 0 ]
grep -qx 'TERM:123:0' "$MODDIR/events"
! grep -Eq '^(KILL:|ip:|start$|supervisors-|dns-clean|guard-clean)' "$MODDIR/events"
''')

    def test_refused_kill_preserves_runtime_and_reports_unknown(self):
        for scenario in ("kill_denied", "kill_denied_unknown"):
            self.lifecycle_cases(scenario, r'''
[ "$rc" = 2 ]
[ "$(cat "$MODDIR/clock")" = 10 ]
grep -qx 'KILL:123:10' "$MODDIR/events"
! grep -Eq '^(ip:|start$|supervisors-|dns-clean|guard-clean)' "$MODDIR/events"
''')

    def test_unknown_discovery_never_becomes_success_or_escalation(self):
        for scenario in ("unknown_initial", "unknown_poll"):
            self.lifecycle_cases(scenario, r'''
[ "$rc" = 2 ]
! grep -Eq '^(KILL:|ip:|start$|supervisors-|dns-clean|guard-clean)' "$MODDIR/events"
''')

    def test_replacement_does_not_inherit_old_kill_deadline(self):
        self.lifecycle_cases("replacement", r'''
[ "$rc" = 2 ]
grep -qx 'TERM:123:0' "$MODDIR/events"
! grep -Eq '^(KILL:|ip:|start$|supervisors-|dns-clean|guard-clean)' "$MODDIR/events"
''')

    def test_fast_exit_signal_errors_are_harmless_only_after_disappearance(self):
        for scenario, elapsed in (("term_exit_race", 0), ("kill_exit_race", 10)):
            for function in ("magicnet_singbox_restart_owned", "magicnet_singbox_stop_owned_after_failure"):
                expect_start = "grep -qx start" if function.endswith("restart_owned") else "! grep -qx start"
                self.run_case(scenario, function + ' "$config"', f'''
[ "$rc" = 0 ]
[ "$(cat "$MODDIR/clock")" = {elapsed} ]
! grep -q '^ip:' "$MODDIR/events"
{expect_start} "$MODDIR/events"
''')

    def test_successful_term_still_completes_both_lifecycle_paths(self):
        self.lifecycle_cases("immediate", r'''
[ "$rc" = 0 ]
[ "$(cat "$MODDIR/clock")" = 0 ]
! grep -q '^KILL:' "$MODDIR/events"
! grep -q '^ip:' "$MODDIR/events"
''')

    def test_three_second_teardown_finishes_without_forced_signal(self):
        self.lifecycle_cases("slow", r'''
[ "$rc" = 0 ]
[ "$(cat "$MODDIR/clock")" = 3 ]
! grep -Eq '^(KILL:|ip:)' "$MODDIR/events"
''')

    def test_default_grace_escalates_only_after_ten_seconds(self):
        self.lifecycle_cases("hung", r'''
[ "$rc" = 0 ]
grep -qx 'KILL:123:10' "$MODDIR/events"
[ "$(cat "$MODDIR/clock")" = 10 ]
! grep -q '^ip:' "$MODDIR/events"
''')

    def test_unowned_tun_survives_standalone_stop_and_restart_in_both_modes(self):
        for mode in ("tun", "ebpf"):
            for function in ("magicnet_singbox_restart_owned", "magicnet_singbox_stop_owned_after_failure"):
                self.run_case("immediate", function + ' "$config"', r'''
[ "$rc" = 0 ]
! grep -q '^ip:' "$MODDIR/events"
[ -e "$MODDIR/foreign-magicnet0" ]
''', mode=mode)

    def test_signal_helper_rejects_noncanonical_or_out_of_range_pids(self):
        for pid in ("", "0", "00", "0123", "-1", "abc", "2147483648", "999999999999999999999999999999999"):
            self.run_case("stopped", f'''printf '%s\\n' {shlex.quote(pid)} >"$MODDIR/invalid-pids"
magicnet_singbox_signal_pids_file "$MODDIR/invalid-pids" 15 "$config"''', r'''
[ "$rc" != 0 ]
! grep -Eq '^(TERM|KILL):' "$MODDIR/events"
''')

    def test_supervisor_failure_still_attempts_both_dns_cleanups(self):
        self.run_case("supervisor_denied", 'magicnet_singbox_restart_owned "$config"', r'''
[ "$rc" = 1 ]
grep -qx supervisors-stop "$MODDIR/events"
grep -qx dns-clean "$MODDIR/events"
grep -qx guard-clean "$MODDIR/events"
! grep -qx start "$MODDIR/events"
''')

    def test_readiness_timeout_propagates_refused_signal_without_retry_or_detach(self):
        for scenario, elapsed in (("term_denied", 1), ("term_denied_unknown", 1),
                                  ("kill_denied", 11), ("kill_denied_unknown", 11)):
            self.run_case(scenario, 'magicnet_singbox_ensure_start_owned "$config"', f'''
[ "$rc" = 2 ]
[ "$(cat "$MODDIR/clock")" = {elapsed} ]
[ "$(grep -c '^launch$' "$MODDIR/events")" = 1 ]
! grep -Eq '^(ip:|start$|supervisors-|dns-clean|guard-clean)' "$MODDIR/events"
''')


if __name__ == "__main__":
    unittest.main()

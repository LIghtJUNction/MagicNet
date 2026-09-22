#!/usr/bin/env python3
"""Run the shipped shell shutdown with simulated process/time side effects.

This verifies lifecycle ordering, not Android firewall or network connectivity.
Set MAGICNET_TEST_SINGBOX_COMPAT=0 for a negative control against pinned kamfw.
The loader and upstream helper are read from the checkout, not reimplemented.
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
KAMFW = ROOT / "src/MagicNet/lib/kamfw"
COMPAT = ROOT / "src/MagicNet/lib/magicnet/singbox_lifecycle.sh"
USE_COMPAT = os.environ.get("MAGICNET_TEST_SINGBOX_COMPAT", "1") != "0"
# Execute the pinned loader verbatim without .kamfwrc's Android initialization.
# Stubs below cover only rich/self and translations, never __singbox__ import.
rc_source = (KAMFW / ".kamfwrc").read_text()
LOADER = rc_source.split("_kamfw_load () {", 1)[1].split("\n_kamfw_list () {", 1)[0]
LOADER = "_kamfw_load () {" + LOADER
ENTRY = ROOT / "src/MagicNet/lib/magicnet.sh"
SHELLS = [["sh"], ["bash"]]
if shutil.which("busybox"):
    SHELLS.append(["busybox", "sh"])


class GracefulStop(unittest.TestCase):
    def run_case(self, scenario: str, assertions: str, *, start: bool = False):
        for shell in SHELLS:
            with self.subTest(shell=shell, scenario=scenario):
                with tempfile.TemporaryDirectory(prefix="magicnet-stop-") as work:
                    mod = Path(work)
                    (mod / "tmp").mkdir()
                    fw = mod / "lib/kamfw"
                    fw.mkdir(parents=True)
                    shutil.copy2(KAMFW / "__singbox__.sh", fw / "__singbox__.sh")
                    for name in ("rich", "self"):
                        (fw / f"{name}.sh").write_text(":\n")
                    (mod / ".config/sing-box").mkdir(parents=True)
                    (mod / ".config/sing-box/config.json").write_text("{}\n")
                    script = r'''
set -eu
MODDIR=__MODDIR__
scenario=__SCENARIO__
export MODDIR
KAMFW_DIR="$MODDIR/lib/kamfw"
KAM_MODULES=""
__LOADER__
import() { _kamfw_load "$@"; }
set_i18n() { :; }
i18n() { printf '%s\n' "$1"; }
print() { :; }
__LOAD_HELPER__
# Production lifecycle/status callers import this again. It must not silently
# restore the pinned one-second implementation after loading the overlay.
import __singbox__
event() { printf '%s\n' "$*" >>"$MODDIR/events"; }
info() { :; }
warn() { event "warn:$*"; }
error() { event "error:$*"; }
success() { event success; }
print() { :; }
magicnet_proc_query_temp_create() { mktemp "$MODDIR/tmp/pids.XXXXXX"; }
reset_core() {
    printf '0\n' >"$MODDIR/clock"
    printf '0\n' >"$MODDIR/queries"
    rm -f "$MODDIR/termed" "$MODDIR/killed"
    : >"$MODDIR/rules"
}
: >"$MODDIR/events"
reset_core
sleep() {
    [ "$scenario" != sleep_error ] || return 1
    case "$1" in
        0.2) step=200 ;;
        1) step=1000 ;;
        *) event "unexpected-sleep:$1"; return 1 ;;
    esac
    now=$(cat "$MODDIR/clock")
    printf '%s\n' "$((now + step))" >"$MODDIR/clock"
}
kill() {
    now=$(cat "$MODDIR/clock")
    case "$1" in
        -9)
            event "KILL:$2:$now"
            [ "$scenario" = unkillable ] || : >"$MODDIR/killed"
            ;;
        *) event "TERM:$1:$now"; : >"$MODDIR/termed" ;;
    esac
}
singbox_pids_to_file() {
    queries=$(cat "$MODDIR/queries")
    queries=$((queries + 1))
    printf '%s\n' "$queries" >"$MODDIR/queries"
    now=$(cat "$MODDIR/clock")
    : >"$1"
    case "$scenario" in
        unknown_initial) return 2 ;;
        unknown_poll) [ "$queries" -le 1 ] || return 2 ;;
        unknown_late) [ "$now" -lt 600 ] || return 2 ;;
        stopped) return 1 ;;
    esac
    [ ! -e "$MODDIR/killed" ] || return 1
    if [ "$scenario" = immediate ] && [ -e "$MODDIR/termed" ]; then
        rm -f "$MODDIR/rules"
        return 1
    fi
    if [ "$scenario" = slow ] && [ -e "$MODDIR/termed" ] && [ "$now" -ge 3000 ]; then
        rm -f "$MODDIR/rules"
        return 1
    fi
    if [ "$scenario" = replacement ] && [ "$queries" -gt 1 ]; then
        printf '456\n' >"$1"
    else
        printf '123\n' >"$1"
    fi
    return 0
}
# Launch effects are inert; shutdown still executes the shipped helper.
is_singbox_running() { return 1; }
singbox_prepare_dataplane() { return 0; }
singbox_prepare_route_config() { :; }
nohup() { :; }
singbox_wait_ready() {
    event launch
    reset_core
    return 1
}
MAGICNET_SINGBOX_START_ATTEMPTS=2
rc=0
__COMMAND__ || rc=$?
__ASSERTIONS__
# Every path must release both private discovery snapshots.
[ -z "$(ls -A "$MODDIR/tmp")" ]
'''
                    script = script.replace("__MODDIR__", shlex.quote(work))
                    script = script.replace("__SCENARIO__", shlex.quote(scenario))
                    script = script.replace("__LOADER__", LOADER)
                    load_helper = (". " + shlex.quote(str(COMPAT))) if USE_COMPAT else "import __singbox__"
                    script = script.replace("__LOAD_HELPER__", load_helper)
                    script = script.replace("__COMMAND__", "singbox_start" if start else "singbox_stop")
                    script = script.replace("__ASSERTIONS__", assertions)
                    result = subprocess.run(shell + ["-c", script], capture_output=True,
                                            text=True, timeout=10)
                    events = (mod / "events").read_text()
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr + events)
                    if "parent-exit" in assertions:
                        self.assertTrue((mod / "parent-exit").is_file())

    def test_overlay_is_in_the_production_entrypoint(self):
        entry = ENTRY.read_text()
        self.assertIn("    singbox_lifecycle " + chr(92) + chr(10), entry)
        self.assertLess(entry.index("    common "), entry.index("    singbox_lifecycle "))

    def test_three_second_teardown_finishes_without_sigkill(self):
        self.run_case("slow", r'''
[ "$rc" = 0 ]
[ ! -e "$MODDIR/rules" ]
! grep -q '^KILL:' "$MODDIR/events"
[ "$(cat "$MODDIR/clock")" = 3000 ]
''')

    def test_immediate_exit_does_not_pay_the_full_grace(self):
        self.run_case("immediate", r'''
[ "$rc" = 0 ]
[ "$(cat "$MODDIR/clock")" = 0 ]
! grep -q '^KILL:' "$MODDIR/events"
''')

    def test_already_stopped_is_idempotent(self):
        self.run_case("stopped", r'''
[ "$rc" = 0 ]
[ "$(cat "$MODDIR/clock")" = 0 ]
! grep -Eq '^(TERM|KILL):' "$MODDIR/events"
''')

    def test_unknown_discovery_never_escalates_or_reports_success(self):
        for scenario in ("unknown_initial", "unknown_poll", "unknown_late"):
            self.run_case(scenario, r'''
[ "$rc" = 2 ]
! grep -q '^KILL:' "$MODDIR/events"
! grep -q '^success$' "$MODDIR/events"
''')

    def test_hung_core_is_killed_only_after_ten_second_budget(self):
        self.run_case("hung", r'''
[ "$rc" = 0 ]
grep -qx 'KILL:123:10000' "$MODDIR/events"
[ "$(grep -c '^KILL:' "$MODDIR/events")" = 1 ]
''')

    def test_sigkill_failure_has_a_bounded_wait_and_error(self):
        self.run_case("unkillable", r'''
[ "$rc" = 1 ]
[ "$(cat "$MODDIR/clock")" = 11000 ]
! grep -q '^success$' "$MODDIR/events"
''')

    def test_replacement_pid_does_not_inherit_old_sigkill_deadline(self):
        self.run_case("replacement", r'''
[ "$rc" = 2 ]
! grep -q '^KILL:' "$MODDIR/events"
''')

    def test_failed_sleep_does_not_shorten_grace_to_immediate_sigkill(self):
        self.run_case("sleep_error", r'''
[ "$rc" = 2 ]
! grep -q '^KILL:' "$MODDIR/events"
''')

    def test_start_failure_uses_graceful_cleanup_between_attempts(self):
        self.run_case("slow", r'''
[ "$rc" = 1 ]
[ "$(grep -c '^launch$' "$MODDIR/events")" = 2 ]
[ "$(grep -c '^TERM:' "$MODDIR/events")" = 2 ]
! grep -q '^KILL:' "$MODDIR/events"
[ ! -e "$MODDIR/rules" ]
''', start=True)

    def test_start_failure_does_not_retry_with_unknown_previous_core(self):
        self.run_case("unknown_poll", r'''
[ "$rc" = 2 ]
[ "$(grep -c '^launch$' "$MODDIR/events")" = 1 ]
! grep -q '^KILL:' "$MODDIR/events"
''', start=True)

    def test_failed_start_does_not_retry_when_sigkill_cannot_stop_core(self):
        self.run_case("unkillable", r'''
[ "$rc" = 2 ]
[ "$(grep -c '^launch$' "$MODDIR/events")" = 1 ]
[ "$(cat "$MODDIR/clock")" = 11000 ]
! grep -q '^success$' "$MODDIR/events"
''', start=True)

    def test_stop_subshell_keeps_parent_exit_trap(self):
        self.run_case("stopped", r'''
trap ': >"$MODDIR/parent-exit"' EXIT
singbox_stop
trap >"$MODDIR/traps"
grep -q parent-exit "$MODDIR/traps"
[ ! -e "$MODDIR/parent-exit" ]
''')


if __name__ == "__main__":
    unittest.main()

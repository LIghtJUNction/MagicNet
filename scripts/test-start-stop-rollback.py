#!/usr/bin/env python3
"""Execute shipped lifecycle orchestration with fault-injected external effects.

These tests certify ordering and restoration, not Android connectivity. Real
route/firewall helpers have separate stateful and network-namespace regressions.
"""
from __future__ import annotations

import os
from pathlib import Path
import shlex
import shutil
import sys
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StartStopRollback(unittest.TestCase):
    def run_case(self, code: str, expected: int = 0, *, real_capture: bool = False):
        with tempfile.TemporaryDirectory(prefix="magicnet-rollback-") as work:
            mod = Path(work) / "module"
            (mod / ".state/hotspot").mkdir(parents=True)
            capture_stub = "" if real_capture else r'''
magicnet_kernel_route_state_capture() {
    event capture
    [ ! -e "$MODDIR/capture-fails" ] || return 2
    : >"$MODDIR/route-owned"
}
'''
            prefix = f'''
set -eu
MODDIR={shlex.quote(str(mod))}
export MODDIR
. {shlex.quote(str(ROOT / "src/MagicNet/lib/magicnet/network.sh"))}
. {shlex.quote(str(ROOT / "src/MagicNet/lib/magicnet/routes.sh"))}
. {shlex.quote(str(ROOT / "src/MagicNet/lib/magicnet/lifecycle.sh"))}
. {shlex.quote(str(ROOT / "src/MagicNet/lib/magicnet/core.sh"))}
event() {{ printf '%s\\n' "$*" >>"$MODDIR/events"; }}
magicnet_warn() {{ event "warn:$*"; }}
magicnet_refresh_status() {{ :; }}
magicnet_kernel_running() {{
    [ ! -e "$MODDIR/unknown" ] || return 2
    [ -e "$MODDIR/core" ]
}}
import() {{ :; }}
magicnet_start_singbox_unlocked() {{
    event start
    : >"$MODDIR/core"
}}
{capture_stub}
magicnet_after_kernel_start_unlocked() {{
    event post-start
    : >"$MODDIR/dns"
    : >"$MODDIR/guard"
    : >"$MODDIR/hotspot"
    return 1
}}
magicnet_hotspot_route_cleanup() {{ event hotspot-clean; rm -f "$MODDIR/hotspot"; }}
magicnet_disable_dns_capture() {{
    event dns-clean
    [ ! -e "$MODDIR/delete-fails" ] || return 1
    rm -f "$MODDIR/dns"
}}
magicnet_disable_dns_leak_guard() {{ event guard-clean; rm -f "$MODDIR/guard"; }}
magicnet_kernel_route_cleanup_after_stop() {{
    event route-clean
    [ ! -e "$MODDIR/core" ] || return 2
    [ ! -e "$MODDIR/route-fails" ] || return 2
    rm -f "$MODDIR/route-owned"
}}
singbox_stop() {{
    event stop
    # A stopped listener must not remain a live DNS redirection target.
    [ ! -e "$MODDIR/dns" ] && [ ! -e "$MODDIR/guard" ] && [ ! -e "$MODDIR/hotspot" ] || return 1
    rm -f "$MODDIR/core"
}}
magicnet_hotspot_offload_value() {{ cat "$MODDIR/offload"; }}
settings() {{
    event "settings:$*"
    [ ! -e "$MODDIR/settings-fails" ] || return 1
    case "$1" in
        put) printf '%s\\n' "$4" >"$MODDIR/offload" ;;
        delete) printf 'null\\n' >"$MODDIR/offload" ;;
        *) return 1 ;;
    esac
}}
export MAGICNET_STOP_CLEANUP_ATTEMPTS=1 MAGICNET_STOP_CLEANUP_DELAY=0
: >"$MODDIR/events"
printf '1\\n' >"$MODDIR/offload"
'''
            shell = os.environ.get("MAGICNET_TEST_SHELL", "sh")
            argv = ["busybox", "sh"] if shell == "busybox" else [shell]
            cp = subprocess.run(argv + ["-c", prefix + code], capture_output=True,
                                text=True, timeout=10)
            events = (mod / "events").read_text()
            self.assertEqual(cp.returncode, expected, cp.stdout + cp.stderr + events)
            return events

    def run_readiness_case(self, code: str):
        # Exercise the shipped readiness probe, capture, and atomic ledger
        # writer. Only external process/interface/netlink effects are modeled.
        # Advancing those effects at sleep makes the startup race deterministic.
        return self.run_case(r'''
magicnet_transparent_mode() { printf 'tun\n'; }
magicnet_iface_exists() {
    event iface-probe
    [ "$1" = magicnet0 ] && [ ! -e "$MODDIR/tun-pending" ]
}
on_core_launch() { :; }
on_route_probe() { :; }
on_wait() { :; }
ip() {
    case "$*" in
        'route show table 2022')
            event route-probe
            on_route_probe
            [ ! -e "$MODDIR/query-fails" ] || return 2
            [ ! -e "$MODDIR/route-pending" ] || return 0
            printf 'default dev magicnet0 scope link\n'
            ;;
        'rule show')
            printf '9002: from 192.0.2.0/24 lookup 2022\n'
            if [ -e "$MODDIR/core" ]; then
                printf '9000: from all fwmark 0x200000 lookup 2022\n'
            fi
            ;;
        '-6 rule show') : ;;
        *) event "unexpected-ip:$*"; return 2 ;;
    esac
}
mv() {
    if [ "$#" -eq 3 ] && [ "$1" = -f ] &&
        [ "$3" = "$(magicnet_kernel_route_state_file)" ]; then
        event "ledger:$(sed -n 's/^phase=//p' "$2")"
    fi
    command mv "$@"
}
magicnet_start_singbox_unlocked() {
    event start
    magicnet_kernel_route_state_begin || return $?
    : >"$MODDIR/core"
    on_core_launch
}
magicnet_after_kernel_start_unlocked() {
    event post-start
    : >"$MODDIR/dns"
    : >"$MODDIR/guard"
    : >"$MODDIR/hotspot"
}
magicnet_singbox_save_last_good() { event checkpoint; }
magicnet_kernel_route_cleanup_after_stop() {
    event route-clean
    [ ! -e "$MODDIR/core" ] || return 2
    rm -f "$(magicnet_kernel_route_state_file)"
}
sleep() {
    event "wait:$*"
    [ "$*" = 0.2 ] || return 81
    # No ownership capture, DNS/hotspot installation, or relaunch while the
    # original generation is alive but its TUN/table is still pending.
    [ -e "$MODDIR/core" ] && [ ! -e "$MODDIR/unknown" ] || return 82
    grep -Fqx 'phase=prepared' "$(magicnet_kernel_route_state_file)" || return 83
    [ "$(grep -cx start "$MODDIR/events")" -eq 1 ] || return 84
    for name in dns guard hotspot; do
        [ ! -e "$MODDIR/$name" ] || return 85
    done
    on_wait
}
''' + code, real_capture=True)

    def test_delayed_tun_and_table_capture_once_before_network_setup(self):
        events = self.run_readiness_case(r'''
: >"$MODDIR/tun-pending"
: >"$MODDIR/route-pending"
on_wait() {
    if [ -e "$MODDIR/tun-pending" ]; then
        rm "$MODDIR/tun-pending"
    else
        rm "$MODDIR/route-pending"
    fi
}
magicnet_start_singbox_ready_unlocked
state="$(magicnet_kernel_route_state_file)"
grep -Fqx 'phase=active' "$state"
grep -Fqx 'rule4=9000: from all fwmark 0x200000 lookup 2022' "$state"
! grep -Fq 'from 192.0.2.0/24' "$state"
for name in core dns guard hotspot; do [ -e "$MODDIR/$name" ] || exit 20; done
''').splitlines()
        self.assertEqual(events.count("start"), 1)
        self.assertEqual(events.count("wait:0.2"), 2)
        self.assertEqual(events.count("ledger:prepared"), 1)
        self.assertEqual(events.count("ledger:active"), 1)
        self.assertEqual(events.count("post-start"), 1)
        self.assertEqual(events.count("checkpoint"), 1)
        self.assertLess(events.index("ledger:active"), events.index("post-start"))
        self.assertNotIn("stop", events)
        self.assertNotIn("route-clean", events)

    def test_never_ready_is_bounded_and_rolls_back_without_network_setup(self):
        for pending in ("tun-pending", "route-pending"):
            with self.subTest(pending=pending):
                events = self.run_readiness_case(f'''
: >"$MODDIR/{pending}"
rc=0
magicnet_start_singbox_ready_unlocked || rc=$?
[ "$rc" = 2 ] || exit 20
[ ! -e "$MODDIR/core" ] || exit 21
[ ! -e "$(magicnet_kernel_route_state_file)" ] || exit 22
''').splitlines()
                self.assertEqual(events.count("iface-probe"), 50)
                self.assertEqual(events.count("wait:0.2"), 49)
                self.assertEqual(events.count("start"), 1)
                self.assertEqual(events.count("stop"), 1)
                self.assertNotIn("ledger:active", events)
                self.assertNotIn("post-start", events)

    def test_last_readiness_attempt_can_succeed_without_extra_wait(self):
        events = self.run_readiness_case(r'''
: >"$MODDIR/route-pending"
on_wait() {
    if [ "$(grep -cx 'wait:0.2' "$MODDIR/events")" -eq 49 ]; then
        rm "$MODDIR/route-pending"
    fi
}
magicnet_start_singbox_ready_unlocked
''').splitlines()
        self.assertEqual(events.count("iface-probe"), 50)
        self.assertEqual(events.count("wait:0.2"), 49)
        self.assertEqual(events.count("start"), 1)
        self.assertEqual(events.count("ledger:active"), 1)
        self.assertEqual(events.count("post-start"), 1)
        self.assertNotIn("stop", events)

    def test_route_query_or_ledger_error_is_not_retried(self):
        for failure in (': >"$MODDIR/query-fails"',
                        'rm "$(magicnet_kernel_route_state_file)"'):
            with self.subTest(failure=failure):
                events = self.run_readiness_case(f'''
on_core_launch() {{ {failure}; }}
rc=0
magicnet_start_singbox_ready_unlocked || rc=$?
[ "$rc" = 2 ] || exit 20
[ ! -e "$MODDIR/core" ] || exit 21
''').splitlines()
                self.assertEqual(events.count("iface-probe"), 1)
                self.assertEqual(events.count("route-probe"), 1)
                self.assertEqual(events.count("stop"), 1)
                self.assertIn("warn:Startup step failed: stage=route-capture exit=2", events)
                self.assertNotIn("wait:0.2", events)
                self.assertNotIn("ledger:active", events)
                self.assertNotIn("post-start", events)

    def test_core_exit_or_unknown_after_pending_probe_does_not_wait(self):
        for outcome, change, expected_rc in (
                ("dead", 'rm "$MODDIR/core"', 1),
                ("unknown", ': >"$MODDIR/unknown"', 2)):
            with self.subTest(outcome=outcome):
                events = self.run_readiness_case(f'''
: >"$MODDIR/route-pending"
# The readiness probe observed a live core before invoking ip. Change its
# identity here to require a fresh liveness check before any retry/sleep.
on_route_probe() {{ {change}; }}
rc=0
magicnet_start_singbox_ready_unlocked || rc=$?
[ "$rc" = 2 ] || exit 20
if [ -e "$MODDIR/unknown" ]; then
    [ -e "$MODDIR/core" ] || exit 21
else
    [ ! -e "$(magicnet_kernel_route_state_file)" ] || exit 22
fi
''').splitlines()
                self.assertEqual(events.count("route-probe"), 1)
                self.assertIn(
                    f"warn:Startup step failed: stage=route-capture exit={expected_rc}", events)
                self.assertNotIn("wait:0.2", events)
                self.assertNotIn("stop", events)
                self.assertNotIn("ledger:active", events)
                self.assertNotIn("post-start", events)

    def test_sleep_failure_aborts_and_rolls_back(self):
        events = self.run_readiness_case(r'''
: >"$MODDIR/route-pending"
on_wait() { return 1; }
rc=0
magicnet_start_singbox_ready_unlocked || rc=$?
[ "$rc" = 2 ] || exit 20
[ ! -e "$MODDIR/core" ] || exit 21
''').splitlines()
        self.assertEqual(events.count("wait:0.2"), 1)
        self.assertEqual(events.count("iface-probe"), 1)
        self.assertEqual(events.count("stop"), 1)
        self.assertIn("warn:Startup step failed: stage=route-capture exit=2", events)
        self.assertNotIn("ledger:active", events)
        self.assertNotIn("post-start", events)

    def test_ebpf_does_not_wait_for_tun_or_capture_a_route_ledger(self):
        events = self.run_readiness_case(r'''
magicnet_transparent_mode() { printf 'ebpf\n'; }
: >"$MODDIR/tun-pending"
: >"$MODDIR/route-pending"
magicnet_start_singbox_ready_unlocked
[ ! -e "$(magicnet_kernel_route_state_file)" ] || exit 20
''').splitlines()
        self.assertEqual(events.count("start"), 1)
        self.assertEqual(events.count("post-start"), 1)
        self.assertNotIn("iface-probe", events)
        self.assertNotIn("wait:0.2", events)
        self.assertNotIn("ledger:active", events)
        self.assertNotIn("stop", events)

    def test_stop_finalization_remains_inside_the_locked_service_operation(self):
        # Contract check complements the executed shell failure tests below.
        service = (ROOT / "crates/magicnet-cli/src/service.rs").read_text()
        stop = service.split("fn stop_all_direct(", 1)[1].split(
            "fn transparent_transaction_active(", 1)[0]
        self.assertGreater(stop.index('run_magicnet_function(app, "magicnet_lifecycle_after_stop")'),
                           stop.index("stop_owned_singbox(app, owned_singbox)"))
        self.assertIn("finalize stopped network: {err}", stop)
        commands = (ROOT / "crates/magicnet-cli/src/commands.rs").read_text()
        handler = commands.split("fn service_command(", 1)[1].split("fn api_command(", 1)[0]
        self.assertNotIn("sync_service_lifecycle", handler)
        self.assertNotIn("magicnet_lifecycle_sync", handler)

    def test_failed_post_start_removes_interception_before_stopping_listener(self):
        events = self.run_case('''
printf 'value=0\\n' >"$MODDIR/.state/hotspot/tether-offload.previous"
if magicnet_start_singbox_ready_unlocked; then exit 20; fi
for name in core dns guard hotspot route-owned; do [ ! -e "$MODDIR/$name" ] || exit 21; done
[ "$(cat "$MODDIR/offload")" = 0 ] || exit 22
[ ! -e "$MODDIR/.state/hotspot/tether-offload.previous" ] || exit 23
''')
        self.assertLess(events.index("capture\n"), events.index("post-start\n"))
        self.assertLess(events.index("dns-clean\n"), events.index("stop\n"))
        self.assertLess(events.index("guard-clean\n"), events.index("stop\n"))
        self.assertLess(events.index("stop\n"), events.index("route-clean\n"))

    def test_failed_ownership_capture_rolls_back_without_installing_dns(self):
        events = self.run_case('''
: >"$MODDIR/capture-fails"
if magicnet_start_singbox_ready_unlocked; then exit 20; fi
[ ! -e "$MODDIR/core" ] || exit 21
[ ! -e "$MODDIR/dns" ] || exit 22
''')
        self.assertNotIn("post-start\n", events)
        self.assertIn("stop\n", events)

    def test_failed_detach_keeps_listener_and_reports_incomplete_rollback(self):
        events = self.run_case('''
: >"$MODDIR/delete-fails"
rc=0
magicnet_start_singbox_ready_unlocked || rc=$?
[ "$rc" = 2 ] || exit 20
[ -e "$MODDIR/core" ] && [ -e "$MODDIR/dns" ] || exit 21
[ -e "$MODDIR/.state/transparent-recent-error" ] || exit 22
''')
        self.assertNotIn("stop\n", events)

    def test_normal_stop_restores_all_original_offload_values(self):
        for value in ("0", "1", "unset"):
            with self.subTest(value=value):
                record = "unset" if value == "unset" else f"value={value}"
                expected = "null" if value == "unset" else value
                self.run_case(f'''
printf '%s\\n' {record} >"$MODDIR/.state/hotspot/tether-offload.previous"
magicnet_lifecycle_after_stop
[ "$(cat "$MODDIR/offload")" = {expected} ] || exit 20
[ ! -e "$MODDIR/.state/hotspot/tether-offload.previous" ] || exit 21
magicnet_lifecycle_after_stop
[ "$(cat "$MODDIR/offload")" = {expected} ] || exit 22
''')

    def test_restore_failure_is_not_a_successful_stop(self):
        self.run_case('''
printf 'value=0\\n' >"$MODDIR/.state/hotspot/tether-offload.previous"
: >"$MODDIR/settings-fails"
if magicnet_lifecycle_after_stop; then exit 20; fi
[ -e "$MODDIR/.state/hotspot/tether-offload.previous" ] || exit 21
[ -e "$MODDIR/.state/transparent-recent-error" ] || exit 22
rm "$MODDIR/settings-fails"
magicnet_lifecycle_after_stop
[ ! -e "$MODDIR/.state/hotspot/tether-offload.previous" ] || exit 23
[ ! -e "$MODDIR/.state/transparent-recent-error" ] || exit 24
''')

    def test_independent_restoration_continues_after_route_cleanup_error(self):
        self.run_case('''
printf 'value=0\\n' >"$MODDIR/.state/hotspot/tether-offload.previous"
: >"$MODDIR/route-fails"
: >"$MODDIR/dns"
: >"$MODDIR/guard"
if magicnet_lifecycle_after_stop; then exit 20; fi
[ "$(cat "$MODDIR/offload")" = 0 ] || exit 21
[ ! -e "$MODDIR/dns" ] && [ ! -e "$MODDIR/guard" ] || exit 22
''')

    def test_unknown_or_live_core_must_not_restore_stopped_state(self):
        for name in ("unknown", "core"):
            with self.subTest(name=name):
                events = self.run_case(f'''
: >"$MODDIR/{name}"
printf 'value=0\\n' >"$MODDIR/.state/hotspot/tether-offload.previous"
if magicnet_lifecycle_after_stop; then exit 20; fi
[ "$(cat "$MODDIR/offload")" = 1 ] || exit 21
''')
                self.assertNotIn("dns-clean\n", events)
                self.assertNotIn("guard-clean\n", events)
                self.assertNotIn("settings:", events)


if __name__ == "__main__":
    if sys.argv[1:] == ["--all-shells"]:
        for shell in ("sh", "bash", "busybox"):
            if shutil.which(shell):
                subprocess.run([sys.executable, __file__], check=True,
                               env=dict(os.environ, MAGICNET_TEST_SHELL=shell))
    else:
        unittest.main()

#!/usr/bin/env python3
"""Boot command-resolution regression. All network operations use private fakes.

Runs the real entrypoints, runtime, phases and route ledger code. This is not
an Android reboot test: a failing shell function models standalone applet
shadowing on hosts whose BusyBox was built without FEATURE_SH_STANDALONE.
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
SOURCE = ROOT / "src/MagicNet"
SHELLS = [[shutil.which("sh") or "/bin/sh"]]
if shutil.which("bash"):
    SHELLS.append([shutil.which("bash")])
if shutil.which("busybox"):
    SHELLS.append([shutil.which("busybox"), "ash"])

OLD_STATE = "schema=2\nphase=active\nboot=previous-boot\ntable=2022\ninterface=magicnet0\n"
BAD_IP = """ip() {
    printf '%s\\n' "$*" >>"$MODDIR/wrong-ip.log"
    case "$*" in *rule*show*) return 0 ;; esac
    printf '%s\\n' "ip: invalid argument '2022' to 'table'" >&2
    return 1
}
"""
FAKE_IP = """#!/bin/sh
printf '%s\\n' "$*" >>"$MODDIR/system-ip.log"
if [ "$1" = __args ]; then
    shift
    printf '<%s>\\n' "$@"
    printf 'ip-stderr\\n' >&2
    exit 23
fi
[ "$1" != -6 ] || shift
case "$*" in
    'rule show')
        if [ -f "$MODDIR/core.started" ]; then
            printf '9000: from all lookup 2022\\n'
        fi
        exit 0 ;;
    'route show table 2022')
        if [ "${IP_MODE:-ok}" = denied ]; then
            printf 'RTNETLINK answers: Operation not permitted\\n' >&2
            exit 2
        fi
        if [ -f "$MODDIR/core.started" ]; then
            printf 'default dev magicnet0\\n'
            exit 0
        fi
        printf 'Error: FIB table does not exist.\\n' >&2
        exit 2 ;;
    *) printf 'Unexpected mutation/query: %s\\n' "$*" >&2; exit 99 ;;
esac
"""


def write(path: Path, text: str, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    if executable:
        path.chmod(0o755)


class Fixture:
    def __init__(self, root: Path, android_ip: bool = True) -> None:
        self.root = root / "module with spaces"
        lib = self.root / "lib/magicnet"
        runtime = (SOURCE / "lib/magicnet.sh").read_text(encoding="utf-8")
        # Substitute ONLY the Android binary location in the fixture; never
        # create /system, modify the host PATH tools, or offer a runtime override.
        system_ip = self.root / "android tools/ip"
        runtime = runtime.replace("/system/bin/ip", shlex.quote(str(system_ip)))
        write(self.root / "lib/magicnet.sh", runtime)
        features = runtime.split("for _magicnet_lib in", 1)[1].split("; do", 1)[0]
        for name in ["primitives", *features.replace("\\", " ").split()]:
            write(lib / f"{name}.sh", "")
        for name in ("entry", "lifecycle", "phases"):
            shutil.copyfile(SOURCE / f"lib/magicnet/{name}.sh", lib / f"{name}.sh")
        for phase in ("service", "boot-completed"):
            shutil.copyfile(SOURCE / f"{phase}.sh", self.root / f"{phase}.sh")
        write(self.root / "lib/kamfw/.kamfwrc", BAD_IP + """
import() { :; }
wait_boot() { :; }
sleep() { :; }
kamfw() {
    case "$2" in
        service) kamfw_phase_service ;;
        boot-completed) kamfw_phase_boot_completed ;;
        *) return 99 ;;
    esac
}
""")
        write(lib / "i18n.sh", "set_i18n() { :; }\n")
        write(lib / "common.sh", """
magicnet_detach_pid_from_app_cgroup() { :; }
magicnet_module_disabled() { [ -f "$MODDIR/disable" ]; }
magicnet_supervisors_stop() { :; }
magicnet_disable_dns_capture() { :; }
magicnet_disable_dns_leak_guard() { :; }
magicnet_hotspot_route_cleanup() { :; }
magicnet_iface_exists() { [ -f "$MODDIR/core.started" ]; }
magicnet_refresh_status() { :; }
magicnet_transparent_mode() { printf 'tun\\n'; }
magicnet_warn() { printf '%s\\n' "$*" >&2; }
""")
        write(lib / "core.sh", """
magicnet_kernel_running() { [ -f "$MODDIR/core.started" ]; }
magicnet_start_kernel() {
    magicnet_kernel_route_state_begin || return $?
    : >"$MODDIR/core.started"
}
""")
        write(self.root / "cli", "#!/bin/sh\nexit 0\n", executable=True)
        # Poison PATH too: removing the function must not silently choose a
        # different fake and make the regression pass by accident.
        write(self.root / "bin/ip", "#!/bin/sh\n" + BAD_IP + 'ip "$@"\n', True)
        if android_ip:
            write(system_ip, FAKE_IP, executable=True)
        self.state = self.root / ".state/network/kernel-route-table.state"
        write(self.state, OLD_STATE)

    def run(self, shell: list[str], *args: str, mode: str = "ok") -> subprocess.CompletedProcess:
        return subprocess.run(
            [*shell, *args], env={**os.environ, "MODDIR": str(self.root),
                                     "ASH_STANDALONE": "1", "IP_MODE": mode},
            text=True, capture_output=True, timeout=10, check=False,
        )


class BootIpDispatchTest(unittest.TestCase):
    def cases(self):
        for shell in SHELLS:
            for phase in ("service", "boot-completed"):
                yield shell, phase

    def test_old_dispatch_reproduces_stale_ledger_boot_failure(self):
        for shell, phase in self.cases():
            with self.subTest(shell=shell, phase=phase), tempfile.TemporaryDirectory() as tmp:
                f = Fixture(Path(tmp), android_ip=False)
                f.run(shell, str(f.root / f"{phase}.sh"))
                self.assertFalse((f.root / "core.started").exists())
                self.assertEqual(f.state.read_text(), OLD_STATE)
                self.assertIn("route show table 2022", (f.root / "wrong-ip.log").read_text())

    def test_both_boot_hooks_rebase_old_ledger_and_capture_current_generation(self):
        for shell, phase in self.cases():
            with self.subTest(shell=shell, phase=phase), tempfile.TemporaryDirectory() as tmp:
                f = Fixture(Path(tmp))
                result = f.run(shell, str(f.root / f"{phase}.sh"))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertTrue((f.root / "core.started").exists())
                state = f.state.read_text()
                self.assertIn("phase=active\n", state)
                self.assertNotIn("previous-boot", state)
                self.assertIn("rule4=9000: from all lookup 2022\n", state)
                calls = (f.root / "system-ip.log").read_text()
                self.assertIn("route show table 2022", calls)
                if Path("/proc/net/if_inet6").exists():
                    self.assertIn("-6 route show table 2022", calls)
                    self.assertIn("rule6=9000: from all lookup 2022\n", state)
                self.assertFalse((f.root / "wrong-ip.log").exists())

    def test_permission_failure_is_not_mistaken_for_an_empty_table(self):
        for shell, phase in self.cases():
            with self.subTest(shell=shell, phase=phase), tempfile.TemporaryDirectory() as tmp:
                f = Fixture(Path(tmp))
                f.run(shell, str(f.root / f"{phase}.sh"), mode="denied")
                self.assertFalse((f.root / "core.started").exists())
                self.assertEqual(f.state.read_text(), OLD_STATE)
                self.assertTrue((f.root / "system-ip.log").exists())
                self.assertFalse((f.root / "wrong-ip.log").exists())

    def test_disabled_module_is_not_started(self):
        for shell, phase in self.cases():
            with self.subTest(shell=shell, phase=phase), tempfile.TemporaryDirectory() as tmp:
                f = Fixture(Path(tmp))
                write(f.root / "disable", "")
                result = f.run(shell, str(f.root / f"{phase}.sh"))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((f.root / "core.started").exists())
                self.assertEqual(f.state.read_text(), OLD_STATE)
                self.assertFalse((f.root / "system-ip.log").exists())

    def test_ip_arguments_exit_code_and_standalone_setting_are_preserved(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as tmp:
                f = Fixture(Path(tmp))
                result = f.run(shell, "-c", '''
. "$MODDIR/lib/magicnet.sh"
ip __args 'one two' '' '*.srs'
rc=$?
[ "$ASH_STANDALONE" = 1 ] || exit 99
exit "$rc"
''')
                self.assertEqual(result.returncode, 23)
                self.assertEqual(result.stdout, "<one two>\n<>\n<*.srs>\n")
                self.assertEqual(result.stderr, "ip-stderr\n")

    def test_non_android_runtime_preserves_host_test_double(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as tmp:
                f = Fixture(Path(tmp), android_ip=False)
                result = f.run(shell, "-c", '''
ip() { printf 'host-ip\\n'; return 17; }
. "$MODDIR/lib/magicnet.sh"
ip route show table 2022
''')
                self.assertEqual(result.returncode, 17)
                self.assertEqual(result.stdout, "host-ip\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)

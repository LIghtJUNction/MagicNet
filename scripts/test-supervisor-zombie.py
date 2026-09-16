#!/usr/bin/env python3
"""Exercise stop with a real unreaped child and indeterminate process reads."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = os.environ.get("MAGICNET_SUPERVISOR_TEST_SOURCE", str(ROOT / "src/MagicNet/lib/magicnet/supervisors.sh"))


class SupervisorExitTests(unittest.TestCase):
    def test_exit_and_unknown_are_distinct(self):
        zombie = os.fork()
        if zombie == 0:
            os._exit(0)
        try:
            for _ in range(100):
                if Path(f"/proc/{zombie}/stat").read_text().rsplit(") ", 1)[1].startswith("Z "):
                    break
                time.sleep(0.01)
            else:
                self.fail("fixture child did not become an unreaped zombie")
            for shell in ("dash", "bash"):
                if not shutil.which(shell):
                    continue
                for mode in ("zombie", "stat-denied", "cmdline-denied", "exit-race"):
                    with self.subTest(shell=shell, mode=mode), tempfile.TemporaryDirectory() as temp:
                        env = dict(os.environ, ROOT=str(ROOT), SOURCE=SOURCE, MODDIR=temp,
                                   TEST_PID=str(zombie), TEST_MODE=mode)
                        result = subprocess.run([shell, "-c", r'''
set -eu
set_i18n() { :; }
. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"
. "$SOURCE"
magicnet_proc_reader_test_hook() {
    [ "$1" = stat ] || return 2
    python3 -S -c 'import pathlib,sys; fields=pathlib.Path(sys.argv[1]).read_text().rsplit(") ",1)[1].split(); print(fields[0],fields[19])' "$2/$3/stat"
}
mkdir -p "$MODDIR/.state/watchdog"
pidfile="$MODDIR/.state/watchdog/magicnet-hotspot-route.pid"
printf '%s\n' "$TEST_PID" >"$pidfile"
kill() { printf '%s\n' "$*" >>"$MODDIR/signals"; return 1; }
case "$TEST_MODE" in
  zombie)
    magicnet_proc_cmdline_lines() { echo unexpected-cmdline-read >&2; return 2; }
    expected=0 ;;
  stat-denied)
    magicnet_proc_state() { return 2; }
    expected=2 ;;
  cmdline-denied)
    magicnet_proc_state() { printf 'S\n'; }
    magicnet_proc_cmdline_lines() { return 2; }
    expected=2 ;;
  exit-race)
    magicnet_proc_state() {
      if [ -f "$MODDIR/read-started" ]; then printf 'Z\n'; else printf 'S\n'; fi
    }
    magicnet_proc_cmdline_lines() { : >"$MODDIR/read-started"; return 2; }
    expected=0 ;;
esac
rc=0
magicnet_supervisor_stop_pidfile "$pidfile" || rc=$?
[ "$rc" -eq "$expected" ] || { echo "expected $expected, got $rc" >&2; exit 1; }
[ ! -e "$MODDIR/signals" ] || { echo "signalled an unverified/dead PID" >&2; exit 1; }
if [ "$expected" -eq 2 ]; then
  [ "$(cat "$pidfile")" = "$TEST_PID" ]
else
  [ ! -e "$pidfile" ]
fi
'''], env=env, capture_output=True, text=True, timeout=15)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertNotIn("unexpected-cmdline-read", result.stderr)
        finally:
            os.waitpid(zombie, 0)


if __name__ == "__main__":
    unittest.main()

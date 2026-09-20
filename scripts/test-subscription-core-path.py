#!/usr/bin/env python3
"""Exercise recovery/checkpoints without module bin in PATH (issue #328).

The production shell and JSON validators run unchanged; only the core is a
fixture. These checks do not claim Android service or network acceptance.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "src/MagicNet/lib/magicnet/singbox_subscribe/bootstrap.sh"
SHELLS = [("sh", [shutil.which("sh")])]
if shutil.which("busybox"):
    SHELLS.append(("ash", [shutil.which("busybox"), "ash"]))
VALID = {"inbounds": [{"type": "tun"}], "outbounds": [{"type": "direct"}]}


class RecoveryCorePath(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="magicnet-core-path-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.module = self.root / "module with spaces"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        (self.module / "bin").mkdir(parents=True)
        self.config = self.module / ".config/sing-box/config.json"
        self.config.parent.mkdir(parents=True)
        self.config.write_text(json.dumps(VALID), encoding="utf-8")
        self.calls = self.module / "core-calls"
        for tool in ("timeout", "mkdir", "chmod", "mktemp", "rm", "mv"):
            executable = shutil.which(tool)
            if executable is None:
                self.fail(f"missing required test tool: {tool}")
            (self.tools / tool).symlink_to(executable)
        jq = shutil.which("jq")
        if jq is None:
            self.fail("missing required test tool: jq")
        (self.module / "bin/jq").symlink_to(jq)
        self.env = {**os.environ, "MODDIR": str(self.module), "PATH": str(self.tools)}

    def core(self, path, identity="bundled", status=0):
        path.write_text(
            '#!/bin/sh\nprintf "%s\\n" "' + identity + '" "$@" >> "$MODDIR/core-calls"\n'
            + f"exit {status}\n", encoding="utf-8"
        )
        path.chmod(0o700)

    def run_shell(self, shell, operation="magicnet_singbox_recovery_config_valid", setup=""):
        self.calls.unlink(missing_ok=True)
        return subprocess.run(
            [*shell, "-c", '. "$1"; magicnet_transparent_mode() { printf "tun\\n"; }; '
             + setup + '\n' + operation + ' "$2"', "core-path-test", str(BOOTSTRAP), str(self.config)],
            env=self.env, capture_output=True, text=True, timeout=25, check=False,
        )

    def test_bundled_core_without_module_path(self):
        self.core(self.module / "bin/sing-box")
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                result = self.run_shell(shell)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls.read_text().splitlines(), [
                    "bundled", "check", "-c", str(self.config), "-D", str(self.config.parent)])

    def test_bundled_core_wins_over_path(self):
        self.core(self.module / "bin/sing-box")
        self.core(self.tools / "sing-box", "path", 41)
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                self.assertEqual(self.run_shell(shell).returncode, 0)
                self.assertEqual(self.calls.read_text().splitlines()[0], "bundled")

    def test_path_fallback_when_bundled_core_absent(self):
        self.core(self.tools / "sing-box", "path")
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                self.assertEqual(self.run_shell(shell).returncode, 0)
                self.assertEqual(self.calls.read_text().splitlines()[0], "path")

    def test_missing_core_fails_closed(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                self.assertNotEqual(self.run_shell(shell).returncode, 0)
                self.assertFalse(self.calls.exists())

    def test_core_rejection_does_not_fall_back(self):
        self.core(self.module / "bin/sing-box", status=42)
        self.core(self.tools / "sing-box", "path")
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                self.assertEqual(self.run_shell(shell).returncode, 42)
                self.assertEqual(self.calls.read_text().splitlines()[0], "bundled")
                self.assertNotIn("path", self.calls.read_text().splitlines())

    def test_invalid_json_never_calls_core(self):
        self.core(self.module / "bin/sing-box")
        for invalid in ("", "null", "[]", "{", '{"inbounds":[],"outbounds":[]}', '{}\n{}'):
            self.config.write_text(invalid, encoding="utf-8")
            for name, shell in SHELLS:
                with self.subTest(shell=name, invalid=invalid):
                    self.assertNotEqual(self.run_shell(shell).returncode, 0)
                    self.assertFalse(self.calls.exists())

    def test_missing_timeout_fails_closed(self):
        self.core(self.module / "bin/sing-box")
        (self.tools / "timeout").unlink()
        # Standalone ash can resolve applets without PATH entries. Model the
        # unavailable capability explicitly, and detect any attempted launch.
        setup = """
command() {
    if [ "$1" = -v ] && [ "${2-}" = timeout ]; then return 1; fi
    (unset -f command; command "$@")
}
timeout() { : > "$MODDIR/unexpected-timeout"; return 99; }
"""
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                self.assertNotEqual(self.run_shell(shell, setup=setup).returncode, 0)
                self.assertFalse(self.calls.exists())
                self.assertFalse((self.module / "unexpected-timeout").exists())

    def test_timeout_budget_and_status_preserved(self):
        self.core(self.module / "bin/sing-box")
        # A shell function takes precedence over both PATH executables and
        # BusyBox applets; a fake executable alone does not isolate ash.
        setup = """
timeout() {
    printf '%s\\n' "$@" > "$MODDIR/timeout-args"
    return 124
}
"""
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                self.assertEqual(self.run_shell(shell, setup=setup).returncode, 124)
                self.assertEqual((self.module / "timeout-args").read_text().splitlines(), [
                    "-k", "2", "15", str(self.module / "bin/sing-box"), "check", "-c",
                    str(self.config), "-D", str(self.config.parent)])
                self.assertFalse(self.calls.exists())

    def test_checkpoint_save_and_restore_without_module_path(self):
        self.core(self.module / "bin/sing-box")
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                self.config.write_text(json.dumps(VALID), encoding="utf-8")
                self.assertEqual(self.run_shell(shell, "magicnet_singbox_save_last_good").returncode, 0)
                self.config.write_text("")
                result = self.run_shell(shell, "magicnet_singbox_restore_last_good")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.config.read_text()), VALID)
                self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main(verbosity=2)

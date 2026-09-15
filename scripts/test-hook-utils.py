#!/usr/bin/env python3
"""Behavioral checks for the shared Bash hook API; no downloads or root needed."""

from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
UTILS = ROOT / "hooks/lib/utils.sh"
MISSING = "magicnet_test_command_that_does_not_exist_46e9b"


class HookUtilsTests(unittest.TestCase):
    def run_shell(self, script: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script, "test-hook-utils", str(UTILS)],
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )

    def test_source_is_silent_and_preserves_callers_environment(self):
        result = self.run_shell('ID=caller; . "$1"; test "$ID" = caller')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_required_command_has_optional_message_and_local_scratch(self):
        result = self.run_shell(
            '. "$1"; command_name=caller; message=caller; '
            'require_command bash; test "$command_name" = caller; test "$message" = caller'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_has_command_failure_returns_instead_of_exiting(self):
        for argument in (MISSING, ""):
            with self.subTest(argument=argument):
                result = self.run_shell(
                    f'. "$1"; if has_command {argument}; then exit 9; fi; printf reached'
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout.endswith("reached"))
                self.assertNotIn("unbound variable", result.stderr)

    def test_missing_requirement_exits_with_literal_message(self):
        for message in ("", "100% unavailable: %s ${HOME}"):
            with self.subTest(message=message):
                result = self.run_shell(
                    f'. "$1"; require_command {MISSING} \'{message}\'; printf unreachable'
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("unreachable", result.stdout)
                self.assertIn(message or f"Command '{MISSING}' is required", result.stdout)
                self.assertEqual(result.stderr, "")

    def test_build_helpers_do_not_replace_installer_functions(self):
        result = self.run_shell(
            'ui_print() { printf installer; }; . "$1"; ui_print'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "installer")


if __name__ == "__main__":
    unittest.main()

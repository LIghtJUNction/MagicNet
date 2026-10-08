#!/usr/bin/env python3
"""Check routing-test dispatch only; fake tools do not attest to network behavior."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY_TEST = "test-maintained-routing.py"

# Run the real shell entrypoints, but record other commands instead of running
# their suites. Execute the asset wrapper so its child status reaches test-host.
PYTHON_STUB = r'''#!/bin/sh
case "${1##*/}" in ci-test-cache.py) shift 4 ;; esac
if [ "$1" = bash ] && [ "${2##*/}" = test-default-routing-policy.sh ]; then
    exec "$@"
fi
{
    printf '%s|' "$@"
    printf '%s|%s\n' "$MAGICNET_ROUTING_CONFIG_DIR" "${CI_TEST_FORCE:-}"
} >>"$ROUTING_TEST_LOG"
case "$*" in *test-maintained-routing.py*) exit "$ROUTING_TEST_EXIT" ;; esac
'''


class RoutingEntrypoints(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="magicnet-routing-entry-")
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        tools = self.work / "bin"
        tools.mkdir()
        python = tools / "python3"
        python.write_text(PYTHON_STUB, encoding="utf-8")
        python.chmod(0o755)
        for name in ("jq", "curl", "openssl", "sing-box"):
            tool = tools / name
            # A legacy jq classifier probe must not decide which suite runs.
            tool.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            tool.chmod(0o755)
        self.log = self.work / "commands.txt"
        config = self.work / "extracted package"
        config.mkdir()
        (config / "config.json").write_text("{}\n", encoding="utf-8")
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                        ROUTING_TEST_LOG=str(self.log), ROUTING_TEST_EXIT="0",
                        MAGICNET_ROUTING_CONFIG_DIR=str(config))
        self.env.pop("CI_TEST_FORCE", None)

    def run_entry(self, name, *arguments, failure=0):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts" / name), *arguments],
            cwd=self.work,
            env=dict(self.env, ROUTING_TEST_EXIT=str(failure)),
            capture_output=True, text=True, timeout=30, check=False,
        )
        records = []
        for line in self.log.read_text().splitlines() if self.log.exists() else []:
            *command, config, force = line.split("|")
            records.append({"command": command, "config": config, "force": force})
        return result, records

    def policy_calls(self, records):
        return [entry for entry in records
                if any(Path(arg).name == POLICY_TEST for arg in entry["command"])]

    def test_package_wrapper_forwards_assets_and_config(self):
        result, records = self.run_entry("test-default-routing-policy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["command"],
                         [str(ROOT / "scripts" / POLICY_TEST), "--assets"])
        self.assertEqual(records[0]["config"], self.env["MAGICNET_ROUTING_CONFIG_DIR"])

    def test_package_wrapper_propagates_failure_without_legacy_fallback(self):
        result, records = self.run_entry("test-default-routing-policy.sh", failure=23)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(self.policy_calls(records)), 1)

    def test_host_runs_structural_policy_once(self):
        result, records = self.run_entry("test-host.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.policy_calls(records)
        self.assertEqual(len(calls), 1)
        self.assertNotIn("--assets", calls[0]["command"])
        self.assertFalse(any("test-wechat-routing.sh" in arg
                             for entry in records for arg in entry["command"]))

    def test_host_runs_asset_policy_once_without_cache(self):
        result, records = self.run_entry("test-host.sh", "--with-routing-assets")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.policy_calls(records)
        self.assertEqual(len(calls), 1)
        self.assertIn("--assets", calls[0]["command"])
        self.assertEqual(calls[0]["force"], "1")

    def test_host_does_not_hide_policy_failures(self):
        for arguments in ((), ("--with-routing-assets",)):
            with self.subTest(arguments=arguments):
                self.log.unlink(missing_ok=True)
                result, records = self.run_entry("test-host.sh", *arguments, failure=23)
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertEqual(len(self.policy_calls(records)), 1)
                self.assertNotIn("host regression suite passed", result.stdout)

    def test_host_rejects_unexpected_arguments(self):
        result, records = self.run_entry("test-host.sh", "--unexpected")
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertEqual(records, [])


if __name__ == "__main__":
    unittest.main()

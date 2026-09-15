#!/usr/bin/env python3
"""Exercise the real rule hook with isolated bundles and forbidden networking."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "hooks/pre-build/5450.update_sing_box_rules.sh"
FILE = "ddch-direct.srs"


class BundledRuleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="magicnet bundle ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.module = self.root / "module"
        self.project = self.root / "project"
        self.bundle = self.project / "rules/dist"
        self.bin = self.root / "bin"
        for path in (self.module / ".config/sing-box", self.bundle, self.bin):
            path.mkdir(parents=True)
        (self.module / ".config/sing-box/config.json").write_text(json.dumps({
            "route": {"rule_set": [{"type": "local", "path": "rules/" + FILE}]}
        }))
        for name in ("git", "curl"):
            executable = self.bin / name
            executable.write_text("#!/bin/sh\necho forbidden-network >&2\nexit 91\n")
            executable.chmod(0o755)
        self.output = self.module / ".config/sing-box/rules" / FILE
        self.write_bundle(b"compiled fixture one\n")

    def write_bundle(self, content):
        (self.bundle / FILE).write_bytes(content)
        self.digest = hashlib.sha256(content).hexdigest()
        (self.bundle / "manifest.json").write_text(json.dumps({
            "version": 1,
            "rulesets": {FILE[:-4]: {"sha256_srs": self.digest}},
        }))

    def invoke(self, **overrides):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   KAM_MODULE_ROOT=str(self.module), KAM_PROJECT_ROOT=str(self.project),
                   KAM_HOOKS_ROOT=str(ROOT / "hooks"))
        env.update(overrides)
        return subprocess.run(["bash", str(HOOK)], env=env, text=True,
                              capture_output=True, timeout=10, check=False)

    def assert_success(self, **overrides):
        result = self.invoke(**overrides)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("forbidden-network", result.stderr)

    def state(self):
        files = list((self.module / ".local/state/sing-box-rules").glob("*.hash"))
        self.assertEqual(len(files), 1)
        return files[0].read_text()

    def test_offline_bundle_has_its_own_digest_identity(self):
        self.assert_success()
        self.assertEqual(self.output.read_bytes(), (self.bundle / FILE).read_bytes())
        self.assertEqual(self.state(), f"bundled:sha256:{self.digest}\n")

    def test_test_environment_does_not_switch_production_paths(self):
        self.assert_success(FAKE_GIT_COUNT_FILE=str(self.root / "unused"))
        self.assertFalse((self.root / "unused").exists())

    def test_corrupt_bundle_preserves_previous_file_and_marker(self):
        self.assert_success()
        previous, state = self.output.read_bytes(), self.state()
        (self.bundle / FILE).write_bytes(b"corruption")
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual(self.state(), state)
        self.assertEqual(list(self.output.parent.glob(".*.??????")), [])

    def test_missing_manifest_does_not_silently_fall_back(self):
        self.assert_success()
        previous = self.output.read_bytes()
        (self.bundle / "manifest.json").unlink()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("forbidden-network", result.stderr)
        self.assertEqual(self.output.read_bytes(), previous)

    def test_unchanged_content_is_not_replaced(self):
        self.assert_success()
        before = self.output.stat().st_mtime_ns
        self.assert_success()
        self.assertEqual(self.output.stat().st_mtime_ns, before)

    def test_changed_bundle_updates_without_a_remote_ref_change(self):
        self.assert_success()
        self.write_bundle(b"compiled fixture two\n")
        self.assert_success()
        self.assertEqual(self.output.read_bytes(), b"compiled fixture two\n")
        self.assertEqual(self.state(), f"bundled:sha256:{self.digest}\n")

    def test_corrupt_destination_is_repaired_despite_matching_marker(self):
        self.assert_success()
        self.output.write_bytes(b"broken destination")
        self.assert_success()
        self.assertEqual(self.output.read_bytes(), (self.bundle / FILE).read_bytes())

    def test_partial_copy_failure_preserves_old_output_and_state(self):
        self.assert_success()
        previous, state = self.output.read_bytes(), self.state()
        self.write_bundle(b"next candidate\n")
        copy = self.bin / "cp"
        copy.write_text('#!/bin/sh\nprintf partial >"$3"\nexit 1\n')
        copy.chmod(0o755)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual(self.state(), state)


if __name__ == "__main__":
    unittest.main()

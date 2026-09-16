#!/usr/bin/env python3
"""Exercise the real Release hook with isolated bundles and forbidden upstream networking."""
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
        self.config = self.module / ".config/sing-box/config.json"
        self.config.write_text(json.dumps({
            "route": {"rule_set": [{"type": "local", "path": "rules/" + FILE}]}
        }))
        for name in ("git", "curl"):
            executable = self.bin / name
            executable.write_text("#!/bin/sh\necho forbidden-network >&2\nexit 91\n")
            executable.chmod(0o755)
        self.output = self.module / ".config/sing-box/rules" / FILE
        self.write_bundle(b"SRS\x02compiled fixture one\n")

    def write_bundle(self, content):
        (self.bundle / FILE).write_bytes(content)
        self.digest = hashlib.sha256(content).hexdigest()
        (self.bundle / "manifest.json").write_text(json.dumps({
            "version": 1,
            "rulesets": {FILE[:-4]: {"sha256_srs": self.digest, "srs_size": len(content)}},
        }))

    def invoke(self, **overrides):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   KAM_MODULE_ROOT=str(self.module), KAM_PROJECT_ROOT=str(self.project),
                   KAM_HOOKS_ROOT=str(ROOT / "hooks"), MAGICNET_RULES_DIR=str(self.bundle))
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

    def write_downloader(self, script):
        folder = self.project / "rules/scripts"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "download_release.py").write_text(script)
        self.write_pin()

    def write_pin(self):
        (self.project / "rules-release.json").write_text(json.dumps({
            "schema": 1, "tag": "rules-test",
            "manifest_sha256": hashlib.sha256((self.bundle / "manifest.json").read_bytes()).hexdigest(),
        }))

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
        self.write_bundle(b"SRS\x02compiled fixture two\n")
        self.assert_success()
        self.assertEqual(self.output.read_bytes(), b"SRS\x02compiled fixture two\n")
        self.assertEqual(self.state(), f"bundled:sha256:{self.digest}\n")

    def test_corrupt_destination_is_repaired_despite_matching_marker(self):
        self.assert_success()
        self.output.write_bytes(b"broken destination")
        self.assert_success()
        self.assertEqual(self.output.read_bytes(), (self.bundle / FILE).read_bytes())

    def test_partial_copy_failure_preserves_old_output_and_state(self):
        self.assert_success()
        previous, state = self.output.read_bytes(), self.state()
        self.write_bundle(b"SRS\x02next candidate\n")
        copy = self.bin / "cp"
        copy.write_text('#!/bin/sh\nprintf partial >"$3"\nexit 1\n')
        copy.chmod(0o755)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual(self.state(), state)

    def test_missing_required_rule_does_not_fetch_upstream(self):
        (self.bundle / FILE).unlink()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("forbidden-network", result.stderr)
        self.assertFalse(self.output.exists())

    def test_all_selected_files_are_validated_before_any_replacement(self):
        self.assert_success()
        previous, state = self.output.read_bytes(), self.state()
        self.write_bundle(b"SRS\x02new candidate\n")
        config = json.loads(self.config.read_text())
        config["route"]["rule_set"].append({"type": "local", "path": "rules/missing.srs"})
        self.config.write_text(json.dumps(config))
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual(self.state(), state)

    def test_unsafe_rule_path_is_rejected(self):
        self.config.write_text(json.dumps({"route": {"rule_set": [
            {"type": "local", "path": "rules/../../escape.srs"}]}}))
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertFalse((self.module / "escape.srs").exists())

    def test_invalid_config_does_not_succeed_with_empty_inventory(self):
        self.config.write_text("not json")
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_default_requires_submodule_even_if_stale_dist_exists(self):
        result = self.invoke(MAGICNET_RULES_DIR="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("submodule is missing", result.stdout)
        self.assertFalse(self.output.exists())

    def test_release_download_failure_preserves_previous_file_and_marker(self):
        self.assert_success()
        previous, state = self.output.read_bytes(), self.state()
        self.write_downloader("raise SystemExit(23)\n")
        result = self.invoke(MAGICNET_RULES_DIR="")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("forbidden-network", result.stderr)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual(self.state(), state)

    def test_release_download_is_retried_on_next_build(self):
        self.write_downloader("from pathlib import Path\nimport sys\n"
            "flag = Path(__file__).parent / 'attempted'\n"
            "if not flag.exists():\n    flag.touch()\n    raise SystemExit(23)\n"
            "assert sys.argv[1] == '--output'\n"
            "assert Path(sys.argv[2]).name == 'dist'\n")
        self.assertNotEqual(self.invoke(MAGICNET_RULES_DIR="").returncode, 0)
        self.assertFalse(self.output.exists())
        self.assert_success(MAGICNET_RULES_DIR="")
        self.assertEqual(self.output.read_bytes(), (self.bundle / FILE).read_bytes())

    def test_release_tag_is_passed_to_the_consumer(self):
        self.write_downloader("import os\nassert os.environ['MAGICNET_RULES_TAG'] == 'rules-test'\n")
        self.assert_success(MAGICNET_RULES_DIR="", MAGICNET_RULES_TAG="rules-test")

    def test_default_download_uses_reviewed_pin_without_environment_override(self):
        self.write_downloader("import os\nassert os.environ['MAGICNET_RULES_TAG'] == 'rules-test'\n")
        self.assert_success(MAGICNET_RULES_DIR="", MAGICNET_RULES_TAG="")

    def test_conflicting_tag_never_downloads_or_replaces_module(self):
        self.assert_success()
        previous, state = self.output.read_bytes(), self.state()
        self.write_downloader("raise AssertionError('unreviewed download must not run')\n")
        result = self.invoke(MAGICNET_RULES_DIR="", MAGICNET_RULES_TAG="rules-other")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicts", result.stdout)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual(self.state(), state)

    def test_changed_release_manifest_preserves_module_and_marker(self):
        self.assert_success()
        previous, state = self.output.read_bytes(), self.state()
        self.write_downloader("pass\n")
        self.write_bundle(b"SRS\x02unreviewed new release\n")
        result = self.invoke(MAGICNET_RULES_DIR="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from reviewed pin", result.stdout)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual(self.state(), state)

    def test_missing_or_invalid_pin_never_publishes_rules(self):
        self.write_downloader("raise AssertionError('invalid pin must not download')\n")
        path = self.project / "rules-release.json"
        for data in (None, "not json", '{"schema":2}', '{"schema":1,"tag":"../main"}'):
            with self.subTest(data=data):
                if data is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_text(data)
                self.assertNotEqual(self.invoke(MAGICNET_RULES_DIR="").returncode, 0)
                self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()

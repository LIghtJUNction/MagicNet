#!/usr/bin/env python3
"""Exercise release preparation against real, isolated git repositories."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest


SCRIPT = Path(__file__).with_name("prepare-release.py").resolve()
VERSION_FILES = ("kam.toml", "src/MagicNet/module.prop", "update.json")
RELEASE_MARKER = ".github/release-request"


class ReleaseWorkflowTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "work"
        self.repo.mkdir()
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.git("init", "--bare", str(self.root / "origin.git"))
        self.git("remote", "add", "origin", str(self.root / "origin.git"))
        self.write("kam.toml", '[prop]\nid = "MagicNet"\nversion = "v1.2.3"\n'
                   'versionCode = 123\nauthor = "Release test"\n'
                   '[kam.build]\noutput_file = "{{id}}"\n')
        self.write("src/MagicNet/module.prop", "id=MagicNet\nversion=v1.2.3\n"
                   "versionCode=123\ndescription=Keep this description.\n")
        self.write("update.json", json.dumps({
            "version": "v1.2.3", "versionCode": 123,
            "zipUrl": "https://example.invalid/releases/latest/MagicNet.zip",
            "changelog": "https://example.invalid/CHANGELOG.md",
        }))
        self.write("README.md", "Release fixture.\n")
        self.before = self.commit()
        self.git("push", "origin", "main")
        self.output = self.root / "github-env"
        self.step_output = self.root / "github-output"

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.repo, text=True, stderr=subprocess.PIPE
        ).strip()

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self, name=None, content=""):
        if name:
            self.write(name, content)
        self.git("add", ".")
        self.git("commit", "-m", "Fixture commit")
        return self.git("rev-parse", "HEAD")

    def run_workflow(self, bump=None, **overrides):
        self.output.unlink(missing_ok=True)
        self.step_output.unlink(missing_ok=True)
        env = dict(os.environ, GITHUB_EVENT_NAME="push", GITHUB_REF="refs/heads/main",
                   GITHUB_SHA=self.git("rev-parse", "HEAD"), PUSH_BEFORE=self.before,
                   RELEASE_INPUT="false", PRERELEASE_INPUT="false",
                   KAM_PRIVATE_KEY_AVAILABLE="1",
                   GITHUB_ENV=str(self.output), GITHUB_OUTPUT=str(self.step_output))
        env.update(overrides)
        command = [sys.executable, str(SCRIPT)]
        if bump is not None:
            command.extend(["--bump", bump])
        return subprocess.run(
            command, cwd=self.repo, env=env,
            text=True, capture_output=True, check=False,
        )

    def run_bump(self, kind="patch", **overrides):
        return self.run_workflow(bump=kind, **{
            "GITHUB_EVENT_NAME": "workflow_dispatch", **overrides,
        })

    def snapshot(self):
        return {
            name: (self.repo / name).read_bytes() if (self.repo / name).exists() else None
            for name in (*VERSION_FILES, RELEASE_MARKER)
        }

    def metadata(self):
        return (
            tomllib.loads((self.repo / "kam.toml").read_text())["prop"],
            dict(line.split("=", 1) for line in
                 (self.repo / "src/MagicNet/module.prop").read_text().splitlines()
                 if "=" in line and not line.startswith("#")),
            json.loads((self.repo / "update.json").read_text()),
        )

    def assert_bump(self, result, version):
        self.assertEqual(result.returncode, 0, result.stderr)
        for metadata in self.metadata():
            self.assertEqual(metadata["version"], version)
            self.assertEqual(str(metadata["versionCode"]), "124")
        self.assertEqual(self.step_output.read_text().splitlines(), [f"version={version}"])
        self.assertFalse(self.output.exists(), "A bump must wait for the version PR to merge")

    def assert_bump_rejected(self, **overrides):
        before = self.snapshot()
        self.assert_rejected(self.run_bump(**overrides))
        self.assertEqual(self.snapshot(), before, "Rejected bump changed release files")
        self.assertFalse(self.step_output.exists())

    def assert_build_only(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build only", result.stdout)
        self.assertFalse(self.output.exists())

    def assert_release(self, result, version="v1.2.3", code=123, prerelease=False):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(dict(line.split("=", 1) for line in self.output.read_text().splitlines()), {
            "RELEASE_REQUESTED": "1", "RELEASE_VERSION": version,
            "RELEASE_VERSION_CODE": str(code), "MAGICNET_SIGN_REQUIRED": "1",
            "RELEASE_PRERELEASE": str(prerelease).lower(),
        })

    def assert_rejected(self, result, message=None):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(result.stderr)
        if message:
            self.assertIn(message, result.stderr)
        self.assertFalse(self.output.exists())

    def test_three_bump_kinds_keep_metadata_in_sync(self):
        for kind, version in (("patch", "v1.2.4"), ("minor", "v1.3.0"), ("major", "v2.0.0")):
            with self.subTest(kind=kind):
                self.git("reset", "--hard", self.before)
                self.assert_bump(self.run_bump(kind), version)
                self.assertFalse((self.repo / RELEASE_MARKER).exists())

    def test_no_bump_keeps_committed_files_unchanged(self):
        before = self.snapshot()
        self.assert_build_only(self.run_workflow(GITHUB_EVENT_NAME="workflow_dispatch"))
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertFalse(self.step_output.exists())

    def test_bump_preserves_non_version_fields(self):
        original = self.metadata()
        original_build = tomllib.loads((self.repo / "kam.toml").read_text())["kam"]
        self.assert_bump(self.run_bump(), "v1.2.4")
        for before, after in zip(original, self.metadata()):
            self.assertEqual(
                {key: value for key, value in before.items() if key not in {"version", "versionCode"}},
                {key: value for key, value in after.items() if key not in {"version", "versionCode"}},
            )
        self.assertEqual(tomllib.loads((self.repo / "kam.toml").read_text())["kam"], original_build)

    def test_repeating_same_base_produces_identical_bump(self):
        self.assert_bump(self.run_bump(RELEASE_INPUT="true", PRERELEASE_INPUT="true"), "v1.2.4")
        first = self.snapshot()
        self.git("reset", "--hard", self.before)
        self.git("clean", "-fd")
        self.assert_bump(self.run_bump(RELEASE_INPUT="true", PRERELEASE_INPUT="true"), "v1.2.4")
        self.assertEqual(self.snapshot(), first)

    def test_bump_rejects_invalid_kind(self):
        self.assert_bump_rejected(kind="nightly")

    def test_bump_requires_main_workflow_dispatch(self):
        for overrides in (
            {"GITHUB_EVENT_NAME": "push"},
            {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_REF": "refs/pull/42/merge"},
            {"GITHUB_REF": "refs/heads/feature"},
        ):
            with self.subTest(**overrides):
                self.assert_bump_rejected(**overrides)

    def test_bump_rejects_stale_checkout_sha(self):
        self.commit("README.md", "Another committed change.\n")
        self.git("push", "origin", "main")
        self.assert_bump_rejected(GITHUB_SHA=self.before)

    def test_bump_rejects_remote_main_advancing(self):
        self.commit("README.md", "Remote main advanced after workflow started.\n")
        self.git("push", "origin", "main")
        self.git("reset", "--hard", self.before)
        self.assert_bump_rejected()

    def test_bump_rejects_dirty_worktree(self):
        for kind in ("tracked", "staged", "untracked"):
            with self.subTest(kind=kind):
                self.git("reset", "--hard", self.before)
                self.git("clean", "-fd")
                self.write("notes.txt" if kind == "untracked" else "README.md", "Keep this edit.\n")
                if kind == "staged":
                    self.git("add", "README.md")
                self.assert_bump_rejected()

    def test_bump_rejects_inconsistent_metadata(self):
        self.commit("src/MagicNet/module.prop", "version=v1.2.3\nversionCode=125\n")
        self.git("push", "origin", "main")
        self.assert_bump_rejected()

    def test_bump_rejects_existing_target_tag(self):
        self.git("tag", "v1.2.4")
        self.git("push", "origin", "refs/tags/v1.2.4")
        self.git("tag", "-d", "v1.2.4")
        self.assert_bump_rejected()

    def test_prerelease_bump_requires_release(self):
        self.assert_bump_rejected(PRERELEASE_INPUT="true")

    def test_bump_release_runs_only_after_merge_and_preserves_prerelease(self):
        for prerelease in (False, True):
            with self.subTest(prerelease=prerelease):
                self.git("reset", "--hard", self.before)
                self.git("clean", "-fd")
                self.git("checkout", "-B", "version-pr", self.before)
                self.assert_bump(self.run_bump(
                    RELEASE_INPUT="true", PRERELEASE_INPUT=str(prerelease).lower()), "v1.2.4")
                self.assertEqual((self.repo / RELEASE_MARKER).read_text().splitlines(),
                                 ["v1.2.4"] + (["prerelease=true"] if prerelease else []))
                self.commit()
                self.assert_build_only(self.run_workflow(
                    GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/42/merge"))
                self.git("checkout", "main")
                self.git("merge", "--no-ff", "version-pr", "-m", "Merge version PR")
                self.assert_release(self.run_workflow(), "v1.2.4", 124, prerelease)

    def test_bump_without_release_merges_as_build_only(self):
        self.git("checkout", "-b", "version-pr")
        self.assert_bump(self.run_bump(), "v1.2.4")
        self.assertFalse((self.repo / RELEASE_MARKER).exists())
        self.commit()
        self.git("checkout", "main")
        self.git("merge", "--no-ff", "version-pr", "-m", "Merge version PR")
        self.assert_build_only(self.run_workflow())

    def test_bump_without_release_preserves_previous_release_marker(self):
        marker = "v1.2.3\nprerelease=true\n"
        self.before = self.commit(RELEASE_MARKER, marker)
        self.git("push", "origin", "main")
        self.assert_bump(self.run_bump(), "v1.2.4")
        self.assertEqual((self.repo / RELEASE_MARKER).read_text(), marker)
        self.commit()
        self.assert_build_only(self.run_workflow())

    def test_pull_request_marker_does_not_release(self):
        self.commit(".github/release-request", "v1.2.3\n")
        self.assert_build_only(self.run_workflow(
            GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/42/merge"))

    def test_main_push_releases_marker_changed_anywhere_in_push(self):
        self.commit(".github/release-request", "v1.2.3\n")
        self.commit("README.md", "A later commit in the same push.\n")
        self.assert_release(self.run_workflow())

    def test_marker_version_mismatch_is_rejected(self):
        self.commit(".github/release-request", "v1.2.4\n")
        self.assert_rejected(self.run_workflow(), "Release request must equal")

    def test_unsupported_release_marker_options_are_rejected(self):
        for option in ("prerelease=false", "prerelease=true\nextra=true"):
            with self.subTest(option=option):
                self.git("reset", "--hard", self.before)
                self.commit(RELEASE_MARKER, f"v1.2.3\n{option}\n")
                self.assert_rejected(self.run_workflow(), "Invalid release request options")

    def test_main_push_without_marker_does_not_release(self):
        self.commit("README.md", "Ordinary change.\n")
        self.assert_build_only(self.run_workflow())

    def test_unchanged_marker_does_not_release(self):
        self.before = self.commit(".github/release-request", "v1.2.3\n")
        self.commit("README.md", "Ordinary change after the release.\n")
        self.assert_build_only(self.run_workflow())

    def test_manual_main_release_requires_true_input(self):
        self.assert_build_only(self.run_workflow(GITHUB_EVENT_NAME="workflow_dispatch"))
        self.assert_release(self.run_workflow(
            GITHUB_EVENT_NAME="workflow_dispatch", RELEASE_INPUT="true"))

    def test_releases_require_a_signing_key_before_exporting_release_state(self):
        self.commit(RELEASE_MARKER, "v1.2.3\n")
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event):
                self.assert_rejected(self.run_workflow(
                    GITHUB_EVENT_NAME=event, RELEASE_INPUT="true",
                    KAM_PRIVATE_KEY_AVAILABLE="0"), "KAM_PRIVATE_KEY")

    def test_builds_without_release_do_not_require_a_signing_key(self):
        self.commit(RELEASE_MARKER, "v1.2.3\n")
        for event, ref in (("workflow_dispatch", "refs/heads/main"),
                           ("pull_request", "refs/pull/42/merge")):
            with self.subTest(event=event):
                self.assert_build_only(self.run_workflow(
                    GITHUB_EVENT_NAME=event, GITHUB_REF=ref,
                    KAM_PRIVATE_KEY_AVAILABLE="0"))

    def test_manual_release_from_another_branch_is_rejected(self):
        self.git("checkout", "-b", "feature")
        self.assert_rejected(self.run_workflow(
            GITHUB_EVENT_NAME="workflow_dispatch", RELEASE_INPUT="true",
            GITHUB_REF="refs/heads/feature"), "Releases must use main")

    def test_metadata_mismatch_is_rejected(self):
        for name, content in (
            ("src/MagicNet/module.prop", "version=v1.2.4\nversionCode=123\n"),
            ("update.json", json.dumps({"version": "v1.2.3", "versionCode": 124})),
        ):
            with self.subTest(file=name):
                self.git("reset", "--hard", self.before)
                self.commit(name, content)
                self.assert_rejected(self.run_workflow(), "Version metadata differs")

    def test_existing_remote_tag_is_rejected(self):
        self.git("tag", "v1.2.3")
        self.git("push", "origin", "refs/tags/v1.2.3")
        self.git("tag", "-d", "v1.2.3")
        self.assert_rejected(self.run_workflow(
            GITHUB_EVENT_NAME="workflow_dispatch", RELEASE_INPUT="true"),
            "already exists; refusing to replace a release")

    def test_checkout_sha_mismatch_is_rejected(self):
        self.commit("README.md", "A different checkout commit.\n")
        self.assert_rejected(self.run_workflow(
            GITHUB_EVENT_NAME="workflow_dispatch", RELEASE_INPUT="true",
            GITHUB_SHA=self.before), "Checkout differs")


if __name__ == "__main__":
    unittest.main()

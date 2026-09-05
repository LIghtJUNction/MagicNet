#!/usr/bin/env python3
"""Exercise release preparation against real, isolated git repositories."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare-release.py").resolve()


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
        self.write("kam.toml", '[prop]\nversion = "v1.2.3"\nversionCode = 123\n')
        self.write("src/MagicNet/module.prop", "version=v1.2.3\nversionCode=123\n")
        self.write("update.json", json.dumps({"version": "v1.2.3", "versionCode": 123}))
        self.before = self.commit()
        self.output = self.root / "github-env"

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

    def run_workflow(self, **overrides):
        self.output.unlink(missing_ok=True)
        env = dict(os.environ, GITHUB_EVENT_NAME="push", GITHUB_REF="refs/heads/main",
                   GITHUB_SHA=self.git("rev-parse", "HEAD"), PUSH_BEFORE=self.before,
                   RELEASE_INPUT="false", GITHUB_ENV=str(self.output))
        env.update(overrides)
        return subprocess.run(
            [sys.executable, str(SCRIPT)], cwd=self.repo, env=env,
            text=True, capture_output=True, check=False,
        )

    def assert_build_only(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build only", result.stdout)
        self.assertFalse(self.output.exists())

    def assert_release(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text().splitlines(), [
            "RELEASE_REQUESTED=1", "RELEASE_VERSION=v1.2.3",
            "RELEASE_VERSION_CODE=123", "MAGICNET_SIGN_REQUIRED=1",
        ])

    def assert_rejected(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.output.exists())

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

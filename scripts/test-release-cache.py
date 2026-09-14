#!/usr/bin/env python3
"""Regress cache-hit release preparation using real isolated Git repositories."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/prepare-release.py"
WORKFLOW = ROOT / ".github/workflows/exec.yml"
CACHE_ACTION = ROOT / ".github/actions/test-cache/action.yml"
VERSION_FILES = ("kam.toml", "src/MagicNet/module.prop", "update.json")
MARKER = ".github/release-request"


class ReleaseCacheTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "work"
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Release cache test")
        self.git("config", "user.email", "cache-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("init", "--bare", str(self.root / "origin.git"))
        self.git("remote", "add", "origin", str(self.root / "origin.git"))
        self.write(".gitignore", (ROOT / ".gitignore").read_text())
        self.write("kam.toml", '[prop]\nid = "MagicNet"\nversion = "v1.2.3"\nversionCode = 123\n')
        self.write("src/MagicNet/module.prop", "id=MagicNet\nversion=v1.2.3\nversionCode=123\n")
        self.write("update.json", json.dumps({"version": "v1.2.3", "versionCode": 123}))
        self.write("README.md", "Keep source edits visible.\n")
        self.commit()
        self.output = self.root / "github-output"
        self.env_file = self.root / "github-env"

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, env=self.env,
                                       text=True, stderr=subprocess.PIPE, timeout=15).strip()

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-m", "Fixture")
        self.git("push", "origin", "main")

    def restore_cache(self):
        # Use the actual action's paths so a new restored directory is covered.
        action = yaml.safe_load(CACHE_ACTION.read_text())
        restore = next(step for step in action["runs"]["steps"]
                       if step.get("uses", "").startswith("actions/cache/restore@"))
        files = {}
        for directory in restore["with"]["path"].splitlines():
            path = Path(directory.strip())
            self.assertFalse(path.is_absolute())
            self.assertNotIn("..", path.parts)
            self.assertNotEqual(path, Path("."))
            name = (path / "fixture" / "cache-record.json").as_posix()
            files[name] = '{"fixture": "restored cache, not release approval"}\n'
            self.write(name, files[name])
        self.assertTrue(files, "cache restore contract is empty")
        return files

    def workflow(self, direct=False, bump=True, **overrides):
        self.output.unlink(missing_ok=True)
        self.env_file.unlink(missing_ok=True)
        sha = self.git("rev-parse", "HEAD")
        env = dict(self.env, GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_REF="refs/heads/main",
                   GITHUB_SHA=sha, RELEASE_COMMIT_SHA=sha, RELEASE_INPUT="true",
                   PRERELEASE_INPUT="false", KAM_PRIVATE_KEY_AVAILABLE="1", BUMP_KIND="patch",
                   GITHUB_OUTPUT=str(self.output), GITHUB_ENV=str(self.env_file),
                   GITHUB_STEP_SUMMARY=str(self.root / "summary"))
        env.update(overrides)
        command = [sys.executable, str(SCRIPT)] + (["--bump", "patch"] if bump else [])
        if direct:
            steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["build"]["steps"]
            step = next(step for step in steps if step["name"] == "Bump and commit version")
            stub = self.root / "bin"
            stub.mkdir(exist_ok=True)
            gh = stub / "gh"
            gh.write_text('#!/bin/sh\nset -eu\n[ "$*" = "auth setup-git" ]\n')
            gh.chmod(0o755)
            env["PATH"] = f"{stub}:{env['PATH']}"
            shell = step["run"].replace("python3 scripts/prepare-release.py",
                                        f"{shlex.quote(sys.executable)} {shlex.quote(str(SCRIPT))}")
            # Only authentication is stubbed. Commit, push, and metadata checks are real.
            command = ["bash", "-euo", "pipefail", "-c", shell]
        return subprocess.run(command, cwd=self.repo, env=env, text=True,
                              capture_output=True, timeout=20, check=False)

    def assert_rejected_without_changes(self, **overrides):
        before = {name: (self.repo / name).read_bytes() for name in VERSION_FILES}
        sha = self.git("rev-parse", "HEAD")
        result = self.workflow(**overrides)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("clean checkout", result.stderr)
        self.assertEqual(before, {name: (self.repo / name).read_bytes() for name in VERSION_FILES})
        self.assertEqual(self.git("rev-parse", "HEAD"), sha)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.env_file.exists())
        self.assertFalse((self.repo / MARKER).exists())

    def test_all_restored_paths_are_ignored_without_deleting_cache(self):
        files = self.restore_cache()
        self.assertEqual(self.git("status", "--porcelain"), "")
        for name, content in files.items():
            self.assertEqual(self.git("check-ignore", name), name)
            self.assertEqual((self.repo / name).read_text(), content)

    def test_cached_manual_bump_commits_only_release_metadata(self):
        files = self.restore_cache()
        before = self.git("rev-parse", "HEAD")
        result = self.workflow(direct=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        after = self.git("rev-parse", "HEAD")
        self.assertNotEqual(before, after)
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").split()[0], after)
        self.assertEqual(set(self.git("diff", "--name-only", before, after).splitlines()),
                         {*VERSION_FILES, MARKER})
        self.assertEqual(self.output.read_text(), "version=v1.2.4\n")
        self.assertEqual((self.repo / MARKER).read_text(), "v1.2.4\n")
        self.assertIn(f"RELEASE_COMMIT_SHA={after}", self.env_file.read_text())
        self.assertEqual(self.git("status", "--porcelain"), "")
        for name, content in files.items():
            self.assertEqual((self.repo / name).read_text(), content)
            self.assertEqual(self.git("ls-files", "--", name), "")

    def test_cache_miss_manual_bump_still_works(self):
        result = self.workflow(direct=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "version=v1.2.4\n")
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_cached_build_only_does_not_bump_or_request_release(self):
        self.restore_cache()
        before = self.git("rev-parse", "HEAD")
        result = self.workflow(bump=False, RELEASE_INPUT="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build only", result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertFalse(self.output.exists())
        self.assertFalse(self.env_file.exists())

    def test_cache_does_not_hide_dirty_source_or_untracked_files(self):
        files = self.restore_cache()
        for kind in ("tracked", "staged", "untracked"):
            with self.subTest(kind=kind):
                self.git("reset", "--hard", "HEAD")
                name = "notes.txt" if kind == "untracked" else "README.md"
                self.write(name, "Uncommitted source must not be released.\n")
                if kind == "staged":
                    self.git("add", name)
                self.assert_rejected_without_changes(direct=True)
                for cached, content in files.items():
                    self.assertEqual((self.repo / cached).read_text(), content)
                if kind == "untracked":
                    (self.repo / name).unlink()

    def test_unrelated_cache_directory_is_not_globally_ignored(self):
        self.restore_cache()
        self.write(".cache/unexpected/source.txt", "Not a declared build cache.\n")
        self.assert_rejected_without_changes()

    def test_tracked_cache_file_changes_remain_visible(self):
        name = ".cache/ci-test-results/tracked.json"
        self.write(name, "{}\n")
        self.git("add", "-f", name)
        self.commit()
        self.write(name, '{"changed":true}\n')
        self.assert_rejected_without_changes()

    def test_bump_precedes_cache_restore_and_submodule_mutation(self):
        steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["build"]["steps"]
        names = [step["name"] for step in steps]
        restore = [i for i, step in enumerate(steps)
                   if step.get("uses") == "./.github/actions/test-cache"
                   and step.get("with", {}).get("mode") == "restore"]
        self.assertEqual(len(restore), 1)
        bump = names.index("Bump and commit version")
        validate = names.index("Validate release request")
        self.assertLess(names.index("Checkout repository"), bump)
        self.assertLess(bump, validate)
        self.assertLess(validate, restore[0])
        self.assertLess(restore[0], names.index("Refresh build submodules"))
        self.assertFalse(any("cache" in step.get("uses", "").lower() for step in steps[:bump]))


if __name__ == "__main__":
    unittest.main()

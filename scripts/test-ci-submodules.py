#!/usr/bin/env python3
"""Offline Git integration checks for CI's moving submodule inputs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SubmoduleUpdateTests(unittest.TestCase):
    def test_recursive_remote_branches_and_fetch_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            env = dict(os.environ, GIT_ALLOW_PROTOCOL="file",
                       GIT_AUTHOR_NAME="Test", GIT_COMMITTER_NAME="Test",
                       GIT_AUTHOR_EMAIL="test@example.invalid",
                       GIT_COMMITTER_EMAIL="test@example.invalid",
                       GITHUB_STEP_SUMMARY=str(work / "summary"))

            def git(repo, *args):
                return subprocess.run(
                    ["git", "-C", str(repo), *args], env=env, check=True,
                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                ).stdout.strip()

            def commit(repo, text):
                (repo / "version").write_text(text)
                git(repo, "add", ".")
                git(repo, "commit", "-m", text)
                return git(repo, "rev-parse", "HEAD")

            def init(name):
                repo = work / name
                repo.mkdir()
                git(repo, "init", "-b", "main")
                commit(repo, "initial")
                return repo

            child, parent, top = (init(name) for name in ("child", "parent", "top"))
            git(child, "checkout", "-b", "testing")
            commit(child, "testing initial")
            git(child, "checkout", "main")
            git(parent, "submodule", "add", "-b", "testing", child.as_uri(), "nested")
            git(parent, "config", "-f", ".gitmodules", "submodule.nested.shallow", "true")
            commit(parent, "parent pin")
            git(top, "submodule", "add", "-b", "main", parent.as_uri(), "vendor/parent")
            git(top, "submodule", "add", child.as_uri(), "vendor/default")
            (top / "scripts").mkdir()
            shutil.copyfile(ROOT / "scripts/update-submodules.sh", top / "scripts/update-submodules.sh")
            commit(top, "top pin")

            expected_default = commit(child, "new default")
            git(child, "checkout", "testing")
            expected_nested = commit(child, "new testing")
            git(child, "checkout", "main")
            expected_parent = commit(parent, "new parent")
            runner = work / "runner"
            git(work, "clone", top.as_uri(), str(runner))
            git(runner, "submodule", "update", "--init", "--depth", "1")
            original_head = git(runner, "rev-parse", "HEAD")

            def update():
                return subprocess.run(
                    ["bash", str(runner / "scripts/update-submodules.sh")],
                    cwd=runner, env=env, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )

            result = update()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(git(runner / "vendor/parent", "rev-parse", "HEAD"), expected_parent)
            self.assertEqual(git(runner / "vendor/parent/nested", "rev-parse", "HEAD"), expected_nested)
            self.assertEqual(git(runner / "vendor/default", "rev-parse", "HEAD"), expected_default)
            self.assertEqual(git(runner, "rev-parse", "HEAD"), original_head)
            self.assertIn(expected_nested, (work / "summary").read_text())

            # A second invocation must fetch new commits despite initialized submodules.
            expected_default = commit(child, "newer default")
            result = update()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(git(runner / "vendor/default", "rev-parse", "HEAD"), expected_default)
            # Updated parent configuration must select its child's new branch.
            git(parent, "config", "-f", ".gitmodules", "submodule.nested.branch", "main")
            commit(parent, "change nested tracking branch")
            result = update()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(git(runner / "vendor/parent/nested", "rev-parse", "HEAD"), expected_default)
            # An unspecified branch follows a changed remote default as well.
            git(child, "checkout", "testing")
            result = update()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(git(runner / "vendor/default", "rev-parse", "HEAD"), expected_nested)
            git(runner, "config", "-f", ".gitmodules", "submodule.vendor/parent.branch", "missing-branch")
            self.assertNotEqual(update().returncode, 0, "stale submodule silently reused")

    def test_workflows_refresh_before_build_inputs(self):
        # PyYAML is already required by the host regression suite.
        import yaml
        build = yaml.safe_load((ROOT / ".github/workflows/exec.yml").read_text())
        steps = build["jobs"]["build"]["steps"]
        refresh = next(i for i, step in enumerate(steps) if "bash scripts/update-submodules.sh" in step.get("run", ""))
        fingerprint = next(i for i, step in enumerate(steps) if step.get("id") == "toolchain")
        self.assertLess(refresh, fingerprint)
        quality = yaml.safe_load((ROOT / ".github/workflows/quality.yml").read_text())
        for job in ("rust", "shell"):
            self.assertIn("update-submodules.sh", quality["jobs"][job]["steps"][1]["run"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Exercise the real post-build cleanup hook with isolated ZIP fixtures.

Only Kam logging helpers and the downstream package validator are stubbed;
archive listing, deletion, and the cleanup hook itself run normally.
"""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "hooks/post-build/7900.sanitize_zip.sh"


class ArtifactCleanupTests(unittest.TestCase):
    def setUp(self):
        for command in ("bash", "zip", "unzip"):
            self.assertIsNotNone(shutil.which(command), f"required tool: {command}")
        temporary = tempfile.TemporaryDirectory(prefix="magicnet-cleanup-")
        self.addCleanup(temporary.cleanup)
        self.project = Path(temporary.name)
        (self.project / "dist").mkdir()
        (self.project / "scripts").mkdir()
        (self.project / "hooks/lib").mkdir(parents=True)
        (self.project / "kam.toml").write_text('[prop]\nid = "MagicNet"\n')
        (self.project / "hooks/lib/utils.sh").write_text(
            'require_command() { command -v "$1" >/dev/null 2>&1 || exit 1; }\n'
            'log_info() { :; }\n'
        )
        self.validator = self.project / "scripts/package-smoke.sh"
        self.validator.write_text(
            '#!/bin/sh\n'
            'test "$1" = "$KAM_PROJECT_ROOT/dist/MagicNet.zip" || exit 1\n'
            ': > "$KAM_PROJECT_ROOT/validated"\n'
        )
        self.validator.chmod(0o755)
        self.archive = self.project / "dist/MagicNet.zip"
        self.keep = {
            "module.prop": b"id=MagicNet\n",
            "service.sh": b"#!/system/bin/sh\nexit 0\n",
            "bin/sing-box": b"core fixture\n",
            ".config/sing-box/config.json": b'{"inbounds":[]}\n',
            ".config/sing-box/rules/example.srs": b"rule fixture\n",
            "lib/kamfw/.kamfwrc": b"# runtime configuration\n",
            "lib/kamfw/__singbox__.sh": b"# unchanged runtime helper\n",
            "lib/kamfw/LICENSE": b"dependency license\n",
            "lib/kamfw/README.md": b"dependency attribution\n",
            "webroot/assets/main.js": b"console.log('fixture');\n",
        }
        self.drop = {
            "lib/kamfw/.git": b"gitdir: fixture\n",
            "nested/.git/config": b"git metadata\n",
            "lib/kamfw/.github/workflows/test.yml": b"CI fixture\n",
            ".agents/skills/example/SKILL.md": b"development instructions\n",
            ".codex/config.toml": b"developer preferences\n",
            ".vscode/settings.json": b"{}\n",
            ".idea/workspace.xml": b"<project/>\n",
            "lib/__pycache__/example.cpython-313.pyc": b"cache\n",
            ".pytest_cache/README.md": b"cache metadata\n",
            "nested/.gitignore": b"ignored\n",
            ".gitattributes": b"* text=auto\n",
            ".gitmodules": b"submodule metadata\n",
            "webroot/.DS_Store": b"OS metadata\n",
            "nested/cache.pyc": b"cache\n",
            "nested/cache.pyo": b"cache\n",
            ".local/subscriptions.env": b"FIXTURE_ONLY=1\n",
            "lib/kamfw/__mihomo__.sh": b"retired helper\n",
            "bin/magicnet-ebpf": b"retired standalone binary\n",
            ".config/sing-box/.dns-fixture.json": b"{}\n",
        }
        with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, content in (self.keep | self.drop).items():
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o755) << 16
                archive.writestr(info, content)
        self.environment = dict(
            os.environ,
            KAM_PROJECT_ROOT=str(self.project),
            KAM_HOOKS_ROOT=str(self.project / "hooks"),
        )

    def run_hook(self):
        return subprocess.run(
            ["bash", str(HOOK)], env=self.environment,
            capture_output=True, text=True, timeout=30,
        )

    def assert_success(self):
        result = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.project / "validated").is_file())

    def test_removes_development_files_and_preserves_runtime(self):
        self.assert_success()
        with zipfile.ZipFile(self.archive) as archive:
            self.assertEqual(set(archive.namelist()), set(self.keep))
            for name, content in self.keep.items():
                self.assertEqual(archive.read(name), content, name)
                self.assertEqual(archive.getinfo(name).external_attr >> 16,
                                 stat.S_IFREG | 0o755, name)

    def test_cleanup_does_not_touch_source_files(self):
        source = self.project / "src/MagicNet/lib/kamfw/.github/workflows/test.yml"
        source.parent.mkdir(parents=True)
        source.write_bytes(b"source must remain available\n")
        self.assert_success()
        self.assertEqual(source.read_bytes(), b"source must remain available\n")

    def test_cleanup_is_idempotent(self):
        self.assert_success()
        first = self.archive.read_bytes()
        self.assert_success()
        self.assertEqual(self.archive.read_bytes(), first)

    def test_failed_deletion_stops_before_package_validation(self):
        tools = self.project / "tools"
        tools.mkdir()
        fake_zip = tools / "zip"
        fake_zip.write_text("#!/bin/sh\nexit 42\n")
        fake_zip.chmod(0o755)
        self.environment["PATH"] = f"{tools}{os.pathsep}{os.environ['PATH']}"
        result = self.run_hook()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Failed to remove archive entry:", result.stderr)
        self.assertFalse((self.project / "validated").exists())

    def test_missing_archive_is_a_noop(self):
        self.archive.unlink()
        result = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.project / "validated").exists())

    def test_package_validator_failure_is_not_hidden(self):
        self.validator.write_text("#!/bin/sh\nexit 17\n")
        result = self.run_hook()
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

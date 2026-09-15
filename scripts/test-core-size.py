#!/usr/bin/env python3
"""Prevent KAM's dereferenced CLI and future build payloads bloating the core."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("package_components", ROOT / "scripts/package-components.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class CoreSizeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / "dist"
        self.output.mkdir()
        # The real pipeline replaces its own original KAM archive in dist/.
        self.source = self.output / "MagicNet.zip"
        self.helper = self.root / "helper"
        self.helper.write_bytes(b"bootstrap fixture, never executed")
        self.cli = b"\x7fELF" + bytes(range(256)) * 1024

    def build_source(self, cli=None, symlink=False):
        entries = {
            "module.prop": b"id=MagicNet\nversion=v1.4.8\nversionCode=123\n",
            "customize.sh": b"import rich\n",
            ".config/sing-box/config.json": b"{}\n",
            "bin/sing-box": b"engine",
            "bin/magicnet-cli": self.cli,
            "bin/magicnet-mcp-server": b"mcp",
            "cli": self.cli if cli is None else cli,
        }
        with zipfile.ZipFile(self.source, "w") as archive:
            for name, data in entries.items():
                info, data = package.zip_entry(name, data, 0o755, symlink and name == "cli")
                archive.writestr(info, data)

    def split(self):
        return package.split(self.source, self.helper, self.output, "LIghtJUNction/MagicNet", "arm64")

    def test_dereferenced_cli_is_not_duplicated_in_core(self):
        self.build_source()
        manifest = self.split()
        with zipfile.ZipFile(self.output / "MagicNet-core.zip") as core:
            entry = core.getinfo("cli")
            self.assertTrue(stat.S_ISLNK(entry.external_attr >> 16))
            self.assertEqual(core.read("cli"), b"bin/magicnet-cli")
            self.assertNotIn("bin/magicnet-cli", core.namelist())
        # The full package must still satisfy the existing Android ELF checker.
        with zipfile.ZipFile(self.output / "MagicNet-full.zip") as full:
            self.assertTrue(stat.S_ISREG(full.getinfo("cli").external_attr >> 16))
            self.assertEqual(full.read("cli"), self.cli)
        component = next(c for c in manifest["components"] if c["id"] == "bin-magicnet-cli")
        with zipfile.ZipFile(self.output / component["asset"]) as payload:
            self.assertEqual(payload.read("bin/magicnet-cli"), self.cli)
        self.assertEqual((self.output / "MagicNet.zip").read_bytes(),
                         (self.output / "MagicNet-core.zip").read_bytes())

    def test_existing_symlink_is_preserved(self):
        self.build_source(b"bin/magicnet-cli", symlink=True)
        self.split()
        for name in ("MagicNet-core.zip", "MagicNet-full.zip"):
            with zipfile.ZipFile(self.output / name) as archive:
                self.assertTrue(stat.S_ISLNK(archive.getinfo("cli").external_attr >> 16))
                self.assertEqual(archive.read("cli"), b"bin/magicnet-cli")

    def test_distinct_launcher_is_not_silently_replaced(self):
        launcher = b'#!/system/bin/sh\nexec "${0%/*}/bin/magicnet-cli" "$@"\n'
        self.build_source(launcher)
        self.split()
        with zipfile.ZipFile(self.output / "MagicNet-core.zip") as core:
            self.assertEqual(core.read("cli"), launcher)

    def test_size_failure_preserves_original_and_all_existing_outputs(self):
        self.build_source()
        original = self.source.read_bytes()
        sentinel = self.output / "MagicNet.zip.sig"
        sentinel.write_bytes(b"original signature")
        self.helper.write_bytes(os.urandom(128 * 1024))
        with patch.object(package, "MAX_CORE_BYTES", 64 * 1024):
            with self.assertRaisesRegex(ValueError, "move large payloads to components"):
                self.split()
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(sentinel.read_bytes(), b"original signature")
        self.assertEqual({p.name for p in self.output.iterdir()}, {"MagicNet.zip", "MagicNet.zip.sig"})

    def test_size_report_uses_actual_core_and_enforced_limit(self):
        self.build_source()
        self.split()
        report = json.loads((self.output / "package-sizes.json").read_text())
        self.assertEqual(report["core_bytes"], (self.output / "MagicNet-core.zip").stat().st_size)
        self.assertEqual(report["core_limit_bytes"], 12 * 1024 * 1024)
        self.assertLessEqual(report["core_bytes"], report["core_limit_bytes"])


if __name__ == "__main__":
    unittest.main()

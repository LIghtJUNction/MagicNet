#!/usr/bin/env python3
"""Regression for KernelSU's SKIPUNZIP module.prop lifecycle.

KernelSU reads module.prop to choose MODID, but with SKIPUNZIP=1 the installer
must still leave $MODPATH/module.prop in place. On upgrades KernelSU copies that
file during its post-customize bookkeeping. Do not pre-seed or restore it in the
test: doing so masked the real-device failure this regression covers.
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "package_components", ROOT / "scripts/package-components.py"
)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class KernelSUInstallerLifecycleTest(unittest.TestCase):
    def test_skipunzip_installer_leaves_module_prop_for_manager_bookkeeping(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "MagicNet-source.zip"
            helper = root / "magicnet-components"
            output = root / "dist"

            helper.write_text("#!/bin/sh\nexit 0\n")
            helper.chmod(0o755)

            entries = {
                "module.prop": b"id=MagicNet\nname=MagicNet\nversion=v1.4.13\nversionCode=143\n",
                "customize.sh": b"export SKIPUNZIP=1\nimport this\n",
                ".config/sing-box/config.json": b"{}\n",
                "bin/sing-box": b"sing-box",
                "bin/magicnet-cli": b"cli",
                "bin/magicnet-mcp-server": b"mcp",
            }
            PACKAGE.write_zip(
                source,
                {
                    name: PACKAGE.zip_entry(name, data, 0o755 if name.startswith("bin/") else 0o644)
                    for name, data in entries.items()
                },
            )
            PACKAGE.split(source, helper, output, "LIghtJUNction/MagicNet", "arm64")
            archive = output / "magicnet_installer.zip"

            # KernelSU resolves MODID from the archive before customize.sh, but it
            # does not populate MODPATH when SKIPUNZIP=1. Keep MODPATH empty here.
            with zipfile.ZipFile(archive) as z:
                props = z.read("module.prop").decode()
                customize = root / "manager-customize.sh"
                customize.write_bytes(z.read("customize.sh"))
            modid = next(line.split("=", 1)[1] for line in props.splitlines() if line.startswith("id="))
            self.assertEqual(modid, "MagicNet")

            nvbase = root / "data/adb"
            modpath = nvbase / "modules_update" / modid
            active = nvbase / "modules" / modid
            modpath.mkdir(parents=True)
            active.mkdir(parents=True)
            self.assertFalse((modpath / "module.prop").exists())

            harness = r'''
set -eu
abort() { printf '%s\n' "$*" >&2; exit 1; }
import() { :; }
. "$CUSTOMIZE"
# KernelSU userspace/ksud/src/installer.sh performs this copy after customize
# for an existing module. This exact step failed on-device when module.prop was
# never extracted into modules_update/MagicNet.
[ -f "$MODPATH/module.prop" ] || abort "KernelSU post-customize module.prop missing"
[ ! -L "$MODPATH/module.prop" ] || abort "KernelSU module.prop became a symlink"
cp -af "$MODPATH/module.prop" "$ACTIVE/module.prop"
'''
            result = subprocess.run(
                ["sh", "-c", harness],
                env={
                    **os.environ,
                    "ZIPFILE": str(archive),
                    "MODPATH": str(modpath),
                    "ACTIVE": str(active),
                    "CUSTOMIZE": str(customize),
                    "MAGICNET_PREV_DIR": str(active),
                },
                text=True,
                capture_output=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((modpath / "module.prop").read_text(), props)
            self.assertEqual((active / "module.prop").read_text(), props)


if __name__ == "__main__":
    unittest.main()

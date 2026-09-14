#!/usr/bin/env python3
"""Offline regressions for the published installer's identity and single transaction.

Use the real packager, generated bootstrap and compiled component helper. Only
manager lifecycle/framework scaffolding is simulated; the helper wrapper adds
--offline so any accidental download fails instead of reaching the Internet.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


package = load("installer_package", "package-components.py")
checker = load("installer_check", "test-downloader-installer.py")


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory()
        cls.helper = Path(cls.tools.name) / "components-host"
        cls.arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
        env = dict(os.environ, GO111MODULE="off", CGO_ENABLED="0")
        env.pop("GOOS", None)
        env.pop("GOARCH", None)
        subprocess.run(["go", "build", "-trimpath", "-o", str(cls.helper), "./installer/components"],
                       cwd=ROOT, env=env, check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tools.cleanup()

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.adb = self.root / "adb"
        self.active = self.adb / "modules"
        self.staged = self.adb / "modules_update"
        self.active.mkdir(parents=True)
        self.staged.mkdir()
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.entries = {
            "module.prop": b"id=MagicNet\nname=MagicNet\nversion=v1.4.11\nversionCode=123\n",
            "customize.sh": b'export SKIPUNZIP=1\nimport this\n'
                            b'unzip -o "$ZIPFILE" "service.sh" -d "$MODPATH" >&2 || abort "scaffold"\n',
            "service.sh": b"#!/system/bin/sh\n# MagicNet runtime fixture\n",
            "cli": b"cli",
            ".config/sing-box/config.json": b'{"inbounds": []}\n',
            "bin/sing-box": b"engine",
            "bin/magicnet-cli": b"cli",
            "bin/magicnet-mcp-server": b"mcp",
            "webroot/index.html": b"webui",
            ".config/sing-box/rules/test.srs": b"rules",
        }

    def build(self, name="release"):
        source = self.root / (name + ".zip")
        package.write_zip(source, {p: package.zip_entry(p, data, 0o755 if p.endswith(".sh") else 0o644)
                                   for p, data in self.entries.items()})
        output = self.root / name
        manifest = package.split(source, self.helper, output, "LIghtJUNction/MagicNet", self.arch)
        return output, manifest

    def seed_cache(self, output, manifest, only=None):
        for component in manifest["components"]:
            if only is None or component["id"] in only:
                shutil.copyfile(output / component["asset"], self.cache / (component["sha256"] + ".zip"))

    def legacy(self, *, staged=False, identity="magicnet_installer"):
        directory = (self.staged if staged else self.active) / "magicnet_installer"
        directory.mkdir()
        (directory / "module.prop").write_text(f"id={identity}\n")
        return directory

    def install(self, archive, *, shell=None, ok=True):
        # Same generated script; the host wrapper ONLY adds offline/cache flags.
        test_archive = self.root / "manager-input.zip"
        with zipfile.ZipFile(archive) as original:
            entries = {info.filename: (info, original.read(info)) for info in original.infolist()}
        wrapper = ("#!/bin/sh\nexec " + shlex.quote(str(self.helper)) +
                   ' "$@" --offline --cache-dir "$TEST_CACHE"\n').encode()
        entries[package.HELPER] = package.zip_entry(package.HELPER, wrapper, 0o755)
        package.write_zip(test_archive, entries)
        harness = r'''
ui_print() { printf '%s\n' "$*"; }
abort() { printf '%s\n' "$*" >&2; exit 1; }
import() { :; }
install_module() { abort "nested manager installation is forbidden"; }
# Managers choose the directory from the ORIGINAL archive, before customize.
MODID=$(unzip -p "$ZIPFILE" module.prop | sed -n 's/^id=//p')
MODPATH="$TEST_STAGED/$MODID"
export MODPATH
mkdir -p "$MODPATH"
unzip -o "$ZIPFILE" module.prop -d "$MODPATH" >&2 || abort "metadata"
unzip -p "$ZIPFILE" customize.sh > "$TEST_SCRIPT" || abort "script"
. "$TEST_SCRIPT"
# Simulate manager post-customize bookkeeping using the original identity.
[ "$MODPATH" = "$TEST_STAGED/$MODID" ] || abort "manager path changed"
unzip -p "$ZIPFILE" module.prop > "$MODPATH/module.prop" || abort "metadata restore"
'''
        result = subprocess.run((shell or ["sh"]) + ["-c", harness],
                                env=dict(os.environ, ZIPFILE=str(test_archive),
                                         TEST_STAGED=str(self.staged), TEST_CACHE=str(self.cache),
                                         TEST_SCRIPT=str(self.root / "customize.sh"),
                                         MAGICNET_PREV_DIR=str(self.active / "MagicNet")),
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        self.assertNotIn("[download]", result.stdout)
        self.assertNotIn("[route]", result.stdout)
        if not ok:
            # The manager discards a failed staging tree; the active module stays.
            shutil.rmtree(self.staged / "MagicNet", ignore_errors=True)
        return result

    def reboot(self):
        # Model staged-module promotion/removal, not an actual Android reboot.
        for source in self.staged.iterdir():
            if not (source / "module.prop").is_file():
                continue
            destination = self.active / source.name
            if destination.exists():
                shutil.rmtree(destination)
            source.rename(destination)
        for directory in list(self.active.iterdir()):
            if (directory / "remove").is_file():
                shutil.rmtree(directory)

    def assert_magicnet(self):
        self.assertEqual({p.name for p in self.active.iterdir()}, {"MagicNet"})
        module = self.active / "MagicNet"
        self.assertIn("id=MagicNet\n", (module / "module.prop").read_text())
        self.assertTrue((module / "service.sh").is_file())
        self.assertFalse((module / "remove").exists())
        self.assertFalse((module / "bin/module-downloader").exists())
        self.assertFalse((module / "download.json").exists())
        state = json.loads((module / "components.installed.json").read_text())
        for component in state["components"]:
            for entry in component["files"]:
                self.assertEqual(hashlib.sha256((module / entry["path"]).read_bytes()).hexdigest(), entry["sha256"])

    def test_published_installer_is_exact_core_with_magicnet_identity(self):
        output, _ = self.build()
        installer = output / "magicnet_installer.zip"
        checker.verify(installer, arch=self.arch, core=output / "MagicNet-core.zip")
        self.assertEqual(installer.read_bytes(), (output / "MagicNet.zip").read_bytes())
        report = json.loads((output / "package-sizes.json").read_text())
        self.assertEqual(report["installer_bytes"], installer.stat().st_size)
        subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=output, check=True, capture_output=True)

    def test_fresh_install_and_reboot_have_only_magicnet(self):
        output, manifest = self.build()
        self.seed_cache(output, manifest)
        result = self.install(output / "magicnet_installer.zip")
        self.assertEqual(result.stdout.count("[cache]"), len(manifest["components"]))
        self.reboot()
        self.assert_magicnet()

    def test_busybox_ash_install(self):
        if not shutil.which("busybox"):
            self.skipTest("BusyBox not installed on this host")
        output, manifest = self.build()
        self.seed_cache(output, manifest)
        self.install(output / "magicnet_installer.zip", shell=["busybox", "ash"])
        self.reboot()
        self.assert_magicnet()

    def test_upgrade_reuses_every_unchanged_component_without_cache(self):
        output, manifest = self.build()
        self.install(output / "MagicNet-full.zip")
        self.reboot()
        self.assertFalse(list(self.cache.glob("*.zip")))
        result = self.install(output / "magicnet_installer.zip")
        self.assertEqual(result.stdout.count("[reuse]"), len(manifest["components"]))
        self.reboot()
        self.assert_magicnet()

    def test_only_changed_webui_needs_a_new_payload(self):
        output, old = self.build()
        self.install(output / "MagicNet-full.zip")
        self.reboot()
        self.entries["webroot/index.html"] = b"new webui"
        self.entries["module.prop"] = self.entries["module.prop"].replace(b"v1.4.11", b"v1.4.12")
        output, new = self.build("upgrade")
        self.assertEqual([a["id"] for a, b in zip(old["components"], new["components"]) if a != b], ["webui"])
        self.seed_cache(output, new, only={"webui"})
        result = self.install(output / "magicnet_installer.zip")
        self.assertEqual(result.stdout.count("[cache]"), 1)
        self.assertEqual(result.stdout.count("[reuse]"), len(new["components"]) - 1)
        self.reboot()
        self.assert_magicnet()

    def test_success_retires_active_and_staged_legacy_installer(self):
        active, staged = self.legacy(), self.legacy(staged=True)
        output, manifest = self.build()
        self.seed_cache(output, manifest)
        self.install(output / "magicnet_installer.zip")
        self.assertTrue((active / "remove").exists())
        self.assertTrue((staged / "remove").exists())
        self.reboot()
        self.assert_magicnet()

    def test_missing_payload_preserves_active_module_and_legacy(self):
        legacy = self.legacy()
        active = self.active / "MagicNet"
        active.mkdir()
        (active / "subscription.url").write_text("private-fixture")
        output, _ = self.build()
        result = self.install(output / "magicnet_installer.zip", ok=False)
        self.assertIn("unavailable offline", result.stderr)
        self.assertEqual((active / "subscription.url").read_text(), "private-fixture")
        self.assertFalse((legacy / "remove").exists())
        self.assertFalse((active / "components.installed.json").exists())

    def test_failed_customization_does_not_retire_legacy(self):
        legacy = self.legacy()
        self.entries["customize.sh"] += b'abort "fixture customization failure"\n'
        output, manifest = self.build()
        self.seed_cache(output, manifest)
        result = self.install(output / "magicnet_installer.zip", ok=False)
        self.assertIn("fixture customization failure", result.stderr)
        self.assertFalse((legacy / "remove").exists())

    def test_corrupt_cached_component_is_not_installed(self):
        legacy = self.legacy()
        output, manifest = self.build()
        self.seed_cache(output, manifest)
        (self.cache / (manifest["components"][0]["sha256"] + ".zip")).write_bytes(b"corrupt")
        self.install(output / "magicnet_installer.zip", ok=False)
        self.assertFalse((legacy / "remove").exists())
        self.assertFalse((self.active / "MagicNet").exists())

    def test_cleanup_ignores_wrong_identity_and_symlink(self):
        wrong = self.legacy(identity="unrelated")
        target = self.root / "unrelated"
        target.mkdir()
        (target / "module.prop").write_text("id=magicnet_installer\n")
        (self.staged / "magicnet_installer").symlink_to(target, target_is_directory=True)
        output, manifest = self.build()
        self.seed_cache(output, manifest)
        self.install(output / "magicnet_installer.zip")
        self.assertFalse((wrong / "remove").exists())
        self.assertFalse((target / "remove").exists())

    def test_final_artifact_check_rejects_old_installer_identity(self):
        output, _ = self.build()
        source = output / "magicnet_installer.zip"
        with zipfile.ZipFile(source) as z:
            entries = {info.filename: (info, z.read(info)) for info in z.infolist()}
        entries["module.prop"] = package.zip_entry("module.prop", b"id=magicnet_installer\n")
        broken = output / "wrong-identity.zip"
        package.write_zip(broken, entries)
        with self.assertRaisesRegex(AssertionError, "wrong module identity"):
            checker.verify(broken, arch=self.arch)


if __name__ == "__main__":
    unittest.main()

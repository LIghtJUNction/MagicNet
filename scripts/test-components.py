#!/usr/bin/env python3
"""Offline packaging/bootstrap regressions; no Android device or live mirror needed."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import tempfile
import unittest
import warnings
import zipfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("package_components", ROOT / "scripts/package-components.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory()
        cls.helper = Path(cls.tools.name) / "helper"
        cls.arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
        env = dict(os.environ, GO111MODULE="off", CGO_ENABLED="0")
        # The surrounding build may export an Android cross-compilation target.
        env.pop("GOOS", None)
        env.pop("GOARCH", None)
        subprocess.run(["go", "build", "-trimpath", "-ldflags=-s -w", "-o", str(cls.helper),
                        "./installer/components"], cwd=ROOT, env=env, check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tools.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.entries = {
            "module.prop": b"id=MagicNet\nversion=v1.4.8\nversionCode=123\n",
            "customize.sh": b"# shellcheck shell=ash\nimport rich\n",
            ".config/sing-box/config.json": b'{"inbounds": []}\n',
            "bin/sing-box": b"engine",
            "bin/magicnet-cli": b"cli",
            "bin/magicnet-mcp-server": b"mcp",
            "bin/yq": b"yq",
            "webroot/index.html": b"<html>webui</html>",
            ".config/sing-box/zashboard/index.html": b"dashboard",
            ".config/sing-box/rules/test.srs": b"rules",
            ".local/state/tools/yq.asset": b"duplicate build cache",
            ".local/state/zashboard.archive": b"duplicate dashboard cache",
            ".local/state/tools/yq.version": b"pinned-version",
        }

    def build(self, name="out", *, entries=None):
        entries = self.entries if entries is None else entries
        source = self.root / (name + "-source.zip")
        with zipfile.ZipFile(source, "w") as archive:
            for path, data in entries.items():
                info = zipfile.ZipInfo(path, (2026, 1, 2, 3, 4, 6))
                info.external_attr = (stat.S_IFREG | 0o700) << 16
                archive.writestr(info, data)
            info = zipfile.ZipInfo("cli")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, b"bin/magicnet-cli")
        output = self.root / name
        m = package.split(source, self.helper, output, "LIghtJUNction/MagicNet", self.arch)
        return output, m

    def invoke(self, output, filename, *, previous=None, cache=None, module=None, ok=True):
        module = module or self.root / "module"
        cache = cache or self.root / "cache"
        result = subprocess.run([str(self.helper), "--archive", str(output / filename),
                                 "--module-dir", str(module), "--previous-dir",
                                 str(previous or self.root / "absent"), "--cache-dir", str(cache),
                                 "--offline"], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return module, result

    def test_core_full_alias_and_manifest(self):
        output, m = self.build()
        with zipfile.ZipFile(output / "MagicNet-core.zip") as core, zipfile.ZipFile(output / "MagicNet-full.zip") as full:
            self.assertNotIn("bin/sing-box", core.namelist())
            self.assertIn("bin/magicnet-components", core.namelist())
            self.assertIn("components.json", core.namelist())
            self.assertEqual(full.read("bin/sing-box"), b"engine")
            self.assertEqual(full.read("cli"), b"bin/magicnet-cli")
            self.assertEqual(json.loads(core.read("components.json")), m)
            self.assertEqual(core.read("customize.sh").count(b"# Component bootstrap:"), 1)
        self.assertEqual((output / "MagicNet.zip").read_bytes(), (output / "MagicNet-core.zip").read_bytes())
        for component in m["components"]:
            blob = (output / component["asset"]).read_bytes()
            self.assertEqual(hashlib.sha256(blob).hexdigest(), component["sha256"])
            self.assertEqual(len(blob), component["size"])
        subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=output, check=True, stdout=subprocess.DEVNULL)

    def test_unchanged_components_stable_across_module_versions(self):
        first, a = self.build("first")
        entries = dict(reversed(list(self.entries.items())))
        entries["module.prop"] = b"id=MagicNet\nversion=v1.4.9\nversionCode=124\n"
        second, b = self.build("second", entries=entries)
        self.assertEqual(a["components"], b["components"])
        for c in a["components"]:
            self.assertEqual((first / c["asset"]).read_bytes(), (second / c["asset"]).read_bytes())

    def test_change_only_changes_affected_component(self):
        _, a = self.build("first")
        self.entries["webroot/index.html"] = b"changed webui"
        _, b = self.build("second")
        changed = [x["id"] for x, y in zip(a["components"], b["components"]) if x != y]
        self.assertEqual(changed, ["webui"])

    def test_build_caches_removed_but_provenance_preserved(self):
        output, _ = self.build()
        report = json.loads((output / "package-sizes.json").read_text())
        self.assertGreater(report["removed_build_cache_bytes"], 0)
        for filename in ("MagicNet-core.zip", "MagicNet-full.zip"):
            with zipfile.ZipFile(output / filename) as z:
                self.assertNotIn(".local/state/tools/yq.asset", z.namelist())
                self.assertNotIn(".local/state/zashboard.archive", z.namelist())
                self.assertIn(".local/state/tools/yq.version", z.namelist())

    def test_rejects_unsafe_or_incomplete_source(self):
        for bad in ("../escape", "/absolute", "webroot/../../escape", "bad\\path", ".git/config"):
            with self.subTest(path=bad):
                entries = dict(self.entries, **{bad: b"bad"})
                with self.assertRaises(ValueError):
                    self.build(entries=entries)
        for required in ("customize.sh", "bin/sing-box", "module.prop"):
            entries = dict(self.entries)
            del entries[required]
            with self.assertRaises(ValueError):
                self.build(entries=entries)

    def test_rejects_duplicate_entries_and_double_split(self):
        output, _ = self.build()
        with self.assertRaises(ValueError):
            package.split(output / "MagicNet-full.zip", self.helper, self.root / "twice", "a/b", self.arch)
        source = self.root / "out-source.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(source, "a") as z:
                z.writestr("bin/sing-box", b"duplicate")
        with self.assertRaises(ValueError):
            package.split(source, self.helper, self.root / "duplicate", "a/b", self.arch)

    def test_full_offline_install_and_executable_modes(self):
        output, m = self.build()
        module, result = self.invoke(output, "MagicNet-full.zip")
        self.assertNotIn("[download]", result.stdout)
        for c in m["components"]:
            for f in c["files"]:
                self.assertEqual((module / f["path"]).read_bytes(), self.entries[f["path"]])
        self.assertEqual((module / "bin/sing-box").stat().st_mode & 0o777, 0o755)
        self.assertEqual(json.loads((module / "components.installed.json").read_text()), m)

    def test_core_upgrade_reuses_monolithic_install(self):
        output, _ = self.build()
        old, _ = self.invoke(output, "MagicNet-full.zip", module=self.root / "old")
        (old / "components.installed.json").unlink()  # Pre-component releases have no manifest.
        module, result = self.invoke(output, "MagicNet-core.zip", previous=old)
        self.assertIn("[reuse]", result.stdout)
        self.assertNotIn("[download]", result.stdout)
        self.assertEqual((module / "bin/sing-box").read_bytes(), b"engine")

    def test_core_uses_only_verified_component_cache(self):
        output, m = self.build()
        cache = self.root / "cache"
        cache.mkdir()
        for c in m["components"]:
            shutil.copyfile(output / c["asset"], cache / (c["sha256"] + ".zip"))
        _, result = self.invoke(output, "MagicNet-core.zip", cache=cache)
        self.assertIn("[cache]", result.stdout)
        self.assertNotIn("[download]", result.stdout)

    def test_incomplete_offline_core_does_not_install(self):
        output, _ = self.invoke if False else self.build()
        module, _ = self.invoke(output, "MagicNet-core.zip", ok=False)
        self.assertFalse((module / "components.installed.json").exists())
        self.assertFalse((module / "bin/sing-box").exists())

    def test_generated_shell_bootstrap_installs_full_payload(self):
        output, _ = self.build()
        module = self.root / "bootstrap-module"
        module.mkdir()
        with zipfile.ZipFile(output / "MagicNet-full.zip") as z:
            script = z.read("customize.sh").decode()
        harness = 'import() { :; }; abort() { printf "%s\\n" "$*" >&2; exit 1; };\n' + script
        result = subprocess.run(["sh", "-c", harness], env=dict(os.environ, MODPATH=str(module),
                                ZIPFILE=str(output / "MagicNet-full.zip")), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((module / "bin/sing-box").read_bytes(), b"engine")
        self.assertTrue((module / "components.installed.json").exists())

    def test_final_assets_signed_after_transformation(self):
        output, _ = self.build()
        key, public = self.root / "private.pem", self.root / "public.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
                        "-out", str(key)], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(public)], check=True,
                       capture_output=True)
        # A stale pre-split signature must not survive transformation.
        (output / "MagicNet.zip.sig").write_text("old signature")
        subprocess.run(["bash", str(ROOT / "scripts/sign-release-assets.sh"), str(output)],
                       env=dict(os.environ, SIGNING_KEY_PEM=key.read_text()), check=True, capture_output=True)
        for asset in output.iterdir():
            if asset.suffix == ".sig":
                continue
            signature = self.root / "signature"
            import base64
            signature.write_bytes(base64.b64decode(Path(str(asset) + ".sig").read_bytes()))
            subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public), "-signature",
                            str(signature), str(asset)], check=True, capture_output=True)
        subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=output, check=True, stdout=subprocess.DEVNULL)


class GateTests(unittest.TestCase):
    def test_release_requires_same_checkout_quality_success(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/exec.yml").read_text())
        self.assertEqual(set(workflow["jobs"]), {"build"})
        steps = workflow["jobs"]["build"]["steps"]
        gate = next(s for s in steps if s.get("id") == "release_quality")
        release = next(s for s in steps if s.get("name") == "Create GitHub release")
        self.assertLess(steps.index(gate), steps.index(release))
        self.assertIn("steps.release_quality.outcome == 'success'", release["if"])
        self.assertNotIn("always()", release["if"])
        self.assertNotIn("continue-on-error", gate)
        self.assertIn("bash scripts/quality-gate.sh all", gate["run"])
        self.assertIn("diff -u", gate["run"])
        self.assertIn("--verify-build", gate["run"])
        self.assertIn('--target "$RELEASE_COMMIT_SHA"', release["run"])
        self.assertIn("--draft)", release["run"])
        self.assertLess(release["run"].index("sha256sum -c"), release["run"].index("gh release create"))
        self.assertLess(release["run"].index("gh release create"), release["run"].index("--draft=false"))

    def test_standalone_and_release_use_identical_quality_groups(self):
        quality = (ROOT / ".github/workflows/quality.yml").read_text()
        gate = (ROOT / "scripts/quality-gate.sh").read_text()
        for group in ("rust", "shell", "components", "webui-check", "webui-browser"):
            self.assertIn("bash scripts/quality-gate.sh " + group, quality)
            self.assertIn(group, gate)
        self.assertNotIn("update-submodules.sh", gate)

    def test_failed_quality_command_stops_gate_before_next_checks(self):
        # Execute the actual shared gate in an isolated tree. A failing format
        # check must stop it, rather than being concealed by a later success.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            shutil.copyfile(ROOT / "scripts/quality-gate.sh", root / "scripts/quality-gate.sh")
            log = root / "commands"
            cargo = root / "bin/cargo"
            cargo.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >>"$COMMAND_LOG"\nexit 17\n')
            cargo.chmod(0o755)
            result = subprocess.run(["bash", str(root / "scripts/quality-gate.sh"), "all"],
                                    env=dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                                             COMMAND_LOG=str(log)), capture_output=True)
            self.assertEqual(result.returncode, 17)
            self.assertEqual(log.read_text().splitlines(), ["fmt --all -- --check"])


if __name__ == "__main__":
    unittest.main()

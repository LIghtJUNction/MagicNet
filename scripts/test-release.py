#!/usr/bin/env python3
"""Exercise release validation using isolated Git repositories and synthetic ZIPs."""

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="magicnet-release-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / RELEASE.SOURCE
        self.source.mkdir(parents=True)
        for repo in (self.root, self.source):
            self.git(repo, "init", "--initial-branch=main")
            self.git(repo, "config", "user.name", "Release test")
            self.git(repo, "config", "user.email", "test@example.invalid")
            self.git(repo, "config", "commit.gpgsign", "false")
        self.update = {
            "version": "v1.2.3", "versionCode": 123,
            "zipUrl": f"https://github.com/{RELEASE.REPOSITORY}/releases/download/v1.2.3/magicnet_installer.zip",
            "changelog": f"https://github.com/{RELEASE.REPOSITORY}/blob/main/docs/releases/v1.2.3.md",
        }
        self.write(self.source / "kam.toml", '[prop]\nid="MagicNet"\nversion="v1.2.3"\nversionCode=123\n'
                   '[mmrl.repo]\nchangelog="' + self.update["changelog"] + '"\n'
                   'changelog_file="docs/releases/v1.2.3.md"\n')
        self.write(self.source / "docs/releases/v1.2.3.md", "Synthetic source release notes.\n")
        self.prop = 'id=MagicNet\nversion=v1.2.3\nversionCode=123\n'
        self.write(self.source / "src/MagicNet/module.prop", self.prop)
        self.write(self.source / "update.json", json.dumps(self.update))
        self.git(self.source, "add", ".")
        self.git(self.source, "commit", "-m", "Synthetic implementation")
        self.source_sha = self.git(self.source, "rev-parse", "HEAD")
        self.write(self.root / "update.json", json.dumps(self.update))
        self.write(self.root / "docs/releases/v1.2.3.md", "Synthetic release notes.\n")
        self.write(self.root / ".gitmodules", f'[submodule "{RELEASE.SOURCE}"]\n'
                   f'path={RELEASE.SOURCE}\nurl=https://github.com/{RELEASE.SOURCE_REPOSITORY}.git\n')
        self.git(self.root, "add", "update.json", ".gitmodules", "docs")
        self.git(self.root, "update-index", "--add", "--cacheinfo", f"160000,{self.source_sha},{RELEASE.SOURCE}")
        self.git(self.root, "commit", "-m", "Synthetic recipe")
        self.environment = dict(GITHUB_SHA=self.git(self.root, "rev-parse", "HEAD"),
                                GITHUB_REF="refs/heads/main", GITHUB_EVENT_NAME="workflow_dispatch",
                                GITHUB_REPOSITORY=RELEASE.REPOSITORY)
        self.directory = self.root / "dist"
        self.directory.mkdir()

    def git(self, repo, *args):
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True, stderr=subprocess.PIPE).strip()

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_build_uses_gitlink_without_changing_metadata_or_contacting_remote(self):
        before = self.git(self.root, "status", "--porcelain")
        result = RELEASE.plan(self.root, "build")
        self.assertEqual(result["source_sha"], self.source_sha)
        self.assertEqual(result["recipe_sha"], self.environment["GITHUB_SHA"])
        self.assertEqual(self.git(self.root, "status", "--porcelain"), before)

    def test_stale_kam_changelog_is_rejected_before_build(self):
        path = self.source / "kam.toml"
        original = path.read_text()
        for old, new, error in (
            (self.update["changelog"], self.update["changelog"].replace("v1.2.3", "v1.2.2"), "KAM changelog URL"),
            ('changelog_file="docs/releases/v1.2.3.md"', 'changelog_file="docs/releases/v1.2.2.md"', "KAM changelog_file"),
        ):
            with self.subTest(field=error):
                self.write(path, original.replace(old, new))
                with self.assertRaisesRegex(ValueError, error):
                    RELEASE.plan(self.root, "build")
        self.write(path, original)
        (self.source / "docs/releases/v1.2.3.md").unlink()
        with self.assertRaisesRegex(ValueError, "Missing source release notes"):
            RELEASE.plan(self.root, "build")

    def test_source_checkout_cannot_follow_newer_main(self):
        self.git(self.source, "commit", "--allow-empty", "-m", "Unselected source commit")
        with self.assertRaisesRegex(ValueError, "gitlink"):
            RELEASE.plan(self.root, "build")

    def test_wrong_repository_or_update_metadata_is_rejected(self):
        for key, value in (("version", "v9.0.0"), ("versionCode", 124),
                           ("zipUrl", "https://example.invalid/installer.zip")):
            with self.subTest(key=key):
                self.write(self.root / "update.json", json.dumps(self.update | {key: value}))
                with self.assertRaisesRegex(ValueError, "update.json"):
                    RELEASE.plan(self.root, "build")
        self.write(self.root / "update.json", json.dumps(self.update))
        self.write(self.root / ".gitmodules", (self.root / ".gitmodules").read_text().replace("magicnet-android.git", "other.git"))
        with self.assertRaisesRegex(ValueError, "repository"):
            RELEASE.plan(self.root, "build")

    def test_latest_update_url_is_rejected_even_if_both_repositories_agree(self):
        update = self.update | {"zipUrl": f"https://github.com/{RELEASE.REPOSITORY}/releases/latest/download/magicnet_installer.zip"}
        for root in (self.root, self.source):
            self.write(root / "update.json", json.dumps(update))
        with self.assertRaisesRegex(ValueError, "versioned"):
            RELEASE.plan(self.root, "build")

    def test_publish_requires_explicit_official_main_dispatch(self):
        for key, value in (("GITHUB_REF", "refs/heads/feature"), ("GITHUB_EVENT_NAME", "push"),
                           ("GITHUB_REPOSITORY", "someone/fork"), ("GITHUB_SHA", "0" * 40)):
            with self.subTest(key=key), patch.dict(os.environ, self.environment | {key: value}):
                with self.assertRaises(ValueError):
                    RELEASE.plan(self.root, "publish")

    def test_existing_release_tag_is_rejected_before_querying_latest_release(self):
        self.git(self.root, "remote", "add", "origin", str(self.root))
        self.git(self.root, "-c", "tag.gpgsign=false", "tag", "v1.2.3")
        with patch.dict(os.environ, self.environment), self.assertRaisesRegex(ValueError, "already exists"):
            RELEASE.plan(self.root, "publish")

    def test_publish_compares_version_and_code_with_previous_release(self):
        self.git(self.root, "remote", "add", "origin", str(self.root))
        real = subprocess.check_output
        for version, code, passes in (("v1.1.0", 122, True), ("v1.1.0", 123, False), ("v2.0.0", 122, False)):
            with self.subTest(version=version, code=code):
                def command(args, **kwargs):
                    if args[:2] == ["gh", "api"]:
                        return json.dumps({"tag_name": version})
                    if args[-2:] == ["show", f"refs/tags/{version}:update.json"]:
                        return json.dumps({"versionCode": code})
                    return real(args, **kwargs)
                with patch.dict(os.environ, self.environment), patch.object(subprocess, "check_output", command):
                    if passes:
                        self.assertEqual(RELEASE.plan(self.root, "publish")["version"], "v1.2.3")
                    else:
                        with self.assertRaises(ValueError):
                            RELEASE.plan(self.root, "publish")

    def assets(self, extra_archive=None, extra_path=None, *, curl_enabled=True, curl_missing=None, curl_extra=None):
        # Rebuilding after a negative assertion must not leave a component from
        # an earlier ZIP timestamp under its former content-addressed filename.
        for previous in self.directory.iterdir():
            previous.unlink()
        component = self.directory / "component.zip"
        with zipfile.ZipFile(component, "w") as archive:
            archive.writestr("bin/synthetic", b"synthetic payload")
            if extra_archive == "component":
                archive.writestr(extra_path, b"synthetic extra entry")
        checksum = RELEASE.digest(component)
        name = f"MagicNet-component-test-{checksum}.zip"
        component.rename(self.directory / name)
        self.manifest = {"schema": 1, "module": "MagicNet", "repository": RELEASE.REPOSITORY,
                         "architecture": "arm64", "version": "v1.2.3", "components": [
                             {"id": "test", "asset": name, "sha256": checksum,
                              "size": (self.directory / name).stat().st_size}]}
        curl_payload = {name: b"synthetic curl payload; never executed\n" for name in RELEASE.CURL_FILES
                        if name != curl_missing} if curl_enabled else {}
        if curl_extra is not None:
            curl_payload[curl_extra] = b"unexpected curl member\n"
        if curl_enabled:
            component = self.directory / "curl-component.zip"
            files = []
            with zipfile.ZipFile(component, "w") as archive:
                for path, content in sorted(curl_payload.items()):
                    mode = 0o755 if path == "bin/curl" else 0o644
                    info = zipfile.ZipInfo(path)
                    info.external_attr = (stat.S_IFREG | mode) << 16
                    archive.writestr(info, content)
                    files.append({"path": path, "sha256": hashlib.sha256(content).hexdigest(),
                                  "size": len(content), "mode": mode})
            checksum = RELEASE.digest(component)
            name = f"MagicNet-component-bin-curl-{checksum}.zip"
            component.rename(self.directory / name)
            self.manifest["components"].append({"id": "bin-curl", "asset": name, "sha256": checksum,
                "size": (self.directory / name).stat().st_size, "files": files})
        self.write(self.directory / "components.json", json.dumps(self.manifest))
        for name in ("MagicNet-core.zip", "MagicNet-full.zip"):
            with zipfile.ZipFile(self.directory / name, "w") as archive:
                archive.writestr("module.prop", self.prop)
                archive.writestr("components.json", json.dumps(self.manifest))
                if name == "MagicNet-full.zip":
                    for path, content in sorted(curl_payload.items()):
                        info = zipfile.ZipInfo(path)
                        info.external_attr = (stat.S_IFREG | (0o755 if path == "bin/curl" else 0o644)) << 16
                        archive.writestr(info, content)
                if extra_archive == name:
                    archive.writestr(extra_path, b"synthetic extra entry")
        for alias in ("MagicNet.zip", "magicnet_installer.zip"):
            (self.directory / alias).write_bytes((self.directory / "MagicNet-core.zip").read_bytes())
        self.write(self.directory / "build-source.json", json.dumps({"schema": 1,
                   "repository": RELEASE.REPOSITORY, "source_repository": RELEASE.SOURCE_REPOSITORY,
                   **RELEASE.metadata(self.root)}))
        self.write(self.directory / "build-submodules.txt", f" {'a' * 40} synthetic (main)\n")
        self.write(self.directory / "update.json", (self.root / "update.json").read_text())
        self.write(self.directory / "package-sizes.json", "{}")
        self.checksums()

    def checksums(self):
        self.write(self.directory / "SHA256SUMS", "".join(
            f"{RELEASE.digest(path)}  {path.name}\n" for path in sorted(self.directory.iterdir()) if path.name != "SHA256SUMS"))

    def test_valid_assets_are_accepted(self):
        self.assets()
        self.assertEqual(RELEASE.verify(self.root, self.directory)["source_sha"], self.source_sha)

    def test_curl_component_missing_or_mixed_files_are_rejected(self):
        self.assets(curl_enabled=False)
        with self.assertRaisesRegex(ValueError, "bin-curl"):
            RELEASE.verify(self.root, self.directory)
        for name in sorted(RELEASE.CURL_FILES):
            with self.subTest(missing=name):
                self.assets(curl_missing=name)
                with self.assertRaisesRegex(ValueError, "curl component"):
                    RELEASE.verify(self.root, self.directory)
        for name in ("licenses/curl/unexpected.txt", "bin/another-tool"):
            with self.subTest(extra=name):
                self.assets(curl_extra=name)
                with self.assertRaisesRegex(ValueError, "curl component"):
                    RELEASE.verify(self.root, self.directory)

    def test_full_curl_bytes_and_executable_mode_are_verified(self):
        for name, wrong_mode in (("bin/curl", False), ("licenses/curl/build-provenance.json", False),
                                 ("bin/curl", True)):
            with self.subTest(name=name, wrong_mode=wrong_mode):
                self.assets()
                path = self.directory / "MagicNet-full.zip"
                with zipfile.ZipFile(path) as archive:
                    members = [(copy.copy(info), archive.read(info)) for info in archive.infolist()]
                with zipfile.ZipFile(path, "w") as archive:
                    for info, data in members:
                        if info.filename == name:
                            if wrong_mode:
                                info.external_attr = (stat.S_IFREG | 0o644) << 16
                            else:
                                data = b"X" * len(data)
                        archive.writestr(info, data)
                self.checksums()
                with self.assertRaisesRegex(ValueError, "curl payload"):
                    RELEASE.verify(self.root, self.directory)

    def test_every_module_and_component_rejects_development_directories(self):
        for name in ("MagicNet-core.zip", "MagicNet-full.zip", "component"):
            for entry in ("tests/test_module.py", ".config/sing-box/tests/test_rules.py",
                          "lib/kamfw/fixtures/input.json", "webroot/__tests__/",
                          "lib/benchmarks/runner", "webroot/node_modules/package/index.js"):
                with self.subTest(archive=name, entry=entry):
                    self.assets(extra_archive=name, extra_path=entry)
                    with self.assertRaisesRegex(ValueError, "ZIP contains development files"):
                        RELEASE.verify(self.root, self.directory)

    def test_runtime_test_names_are_allowed(self):
        for name, entry in (("MagicNet-full.zip", ".config/sing-box/rules/test.srs"),
                            ("component", "bin/test")):
            with self.subTest(archive=name, entry=entry):
                self.assets(extra_archive=name, extra_path=entry)
                self.assertEqual(RELEASE.verify(self.root, self.directory)["source_sha"], self.source_sha)

    def test_server_must_confirm_every_asset_before_draft_is_published(self):
        self.assets()
        response = {"draft": True, "tag_name": "v1.2.3", "target_commitish": self.environment["GITHUB_SHA"],
                    "assets": [{"name": path.name, "size": path.stat().st_size, "state": "uploaded",
                                "digest": f"sha256:{RELEASE.digest(path)}"} for path in self.directory.iterdir()]}
        self.assertEqual(RELEASE.verify_uploaded(self.root, self.directory, response)["version"], "v1.2.3")
        for field, value in (("size", 0), ("digest", "sha256:" + "0" * 64), ("state", "new")):
            changed = copy.deepcopy(response)
            changed["assets"][0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "digest/size"):
                RELEASE.verify_uploaded(self.root, self.directory, changed)
        changed = copy.deepcopy(response)
        changed["assets"].pop()
        with self.assertRaisesRegex(ValueError, "inventory"):
            RELEASE.verify_uploaded(self.root, self.directory, changed)
        for field, value in (("draft", False), ("tag_name", "v9.9.9"), ("target_commitish", "0" * 40)):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "draft identity"):
                RELEASE.verify_uploaded(self.root, self.directory, response | {field: value})

    def run_publisher_after_plan(self, ids="321\n", corrupt=False):
        # Exercise the real publication shell; plan authorization is tested above.
        workflow = Path(__file__).resolve().parent.parent / ".github/workflows/release.yml"
        block = workflow.read_text().split("      - name: Verify final assets and publish\n", 1)[1]
        script = textwrap.dedent(block.split("        run: |\n", 1)[1])
        script = script.replace("python3 scripts/release.py plan --mode publish\n", "")
        script = script.replace("${{ needs.plan.outputs.source_sha }}", self.source_sha)
        self.write(self.root / "scripts/release.py", Path(RELEASE.__file__).read_text())
        response = {"id": 321, "draft": True, "tag_name": "v1.2.3",
                    "target_commitish": self.environment["GITHUB_SHA"],
                    "assets": [{"name": p.name, "size": p.stat().st_size, "state": "uploaded",
                                "digest": f"sha256:{RELEASE.digest(p)}"} for p in self.directory.iterdir()]}
        if corrupt:
            response["assets"][0]["digest"] = "sha256:" + "0" * 64
        self.write(self.root / "draft-response.json", json.dumps(response))
        runner = self.root / "runner"
        runner.mkdir(exist_ok=True)
        published = self.root / "published"
        published.unlink(missing_ok=True)
        executable = self.root / "host-bin/gh"
        self.write(executable, f"#!{sys.executable}\n" + textwrap.dedent('''\
            import json, os, pathlib, sys
            args = sys.argv[1:]
            if args[:2] == ["release", "create"]:
                print("https://example.invalid/releases/tag/untagged-fixture")
            elif args[:1] == ["api"] and "--paginate" in args:
                sys.stdout.write(os.environ["TEST_DRAFT_IDS"])
            elif args[:1] == ["api"] and any(a.endswith("/releases/321") for a in args):
                if "PATCH" in args:
                    assert "draft=false" in args
                    pathlib.Path(os.environ["TEST_PUBLISHED"]).write_text("published")
                else:
                    print(pathlib.Path(os.environ["TEST_RESPONSE"]).read_text())
            else:
                print("gh: Not Found (HTTP 404)", file=sys.stderr)
                sys.exit(1)
            '''))
        executable.chmod(0o755)
        env = dict(os.environ, **self.environment, VERSION="v1.2.3", VERSION_CODE="123",
                   PRERELEASE="false", RUNNER_TEMP=str(runner),
                   PATH=str(executable.parent) + os.pathsep + os.environ["PATH"],
                   TEST_DRAFT_IDS=ids, TEST_PUBLISHED=str(published),
                   TEST_RESPONSE=str(self.root / "draft-response.json"))
        result = subprocess.run(["bash", "-c", script], cwd=self.root, env=env,
                                text=True, capture_output=True, timeout=20, check=False)
        return result, published.exists()

    def test_uploaded_draft_without_public_tag_can_be_published_by_id(self):
        self.assets()
        result, published = self.run_publisher_after_plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(published)

    def test_missing_ambiguous_or_invalid_draft_ids_never_publish(self):
        self.assets()
        for ids in ("", "321\n654\n", "not-an-id\n"):
            with self.subTest(ids=ids):
                result, published = self.run_publisher_after_plan(ids=ids)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(published)

    def test_server_digest_failure_never_reaches_publication(self):
        self.assets()
        result, published = self.run_publisher_after_plan(corrupt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(published)

    def test_corruption_missing_and_unexpected_assets_are_rejected(self):
        self.assets()
        (self.directory / "MagicNet.zip").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "Checksum"):
            RELEASE.verify(self.root, self.directory)
        self.assets()
        (self.directory / "MagicNet.zip").unlink()
        with self.assertRaisesRegex(ValueError, "inventory"):
            RELEASE.verify(self.root, self.directory)
        self.assets()
        self.write(self.directory / "unexpected.env", "SYNTHETIC=fixture")
        self.checksums()
        with self.assertRaisesRegex(ValueError, "Unexpected"):
            RELEASE.verify(self.root, self.directory)

    def test_provenance_and_module_metadata_cannot_be_swapped(self):
        self.assets()
        path = self.directory / "build-source.json"
        original = json.loads(path.read_text())
        for field in ("source_sha", "recipe_sha", "repository"):
            with self.subTest(field=field):
                self.write(path, json.dumps(original | {field: "wrong"}))
                self.checksums()
                with self.assertRaisesRegex(ValueError, "provenance"):
                    RELEASE.verify(self.root, self.directory)
        self.assets()
        with zipfile.ZipFile(self.directory / "MagicNet-full.zip", "w") as archive:
            archive.writestr("module.prop", self.prop.replace("123", "999"))
            archive.writestr("components.json", json.dumps(self.manifest))
        self.checksums()
        with self.assertRaisesRegex(ValueError, "module metadata"):
            RELEASE.verify(self.root, self.directory)

    def test_alias_and_embedded_manifest_mismatch_is_rejected(self):
        self.assets()
        (self.directory / "MagicNet.zip").write_bytes(b"different core")
        self.checksums()
        with self.assertRaisesRegex(ValueError, "aliases"):
            RELEASE.verify(self.root, self.directory)
        self.assets()
        changed = copy.deepcopy(self.manifest)
        changed["repository"] = "someone/fork"
        with zipfile.ZipFile(self.directory / "MagicNet-full.zip", "w") as archive:
            archive.writestr("module.prop", self.prop)
            archive.writestr("components.json", json.dumps(changed))
        self.checksums()
        with self.assertRaisesRegex(ValueError, "Embedded"):
            RELEASE.verify(self.root, self.directory)

    def test_unsafe_checksums_and_changed_submodules_are_rejected(self):
        self.assets()
        path = self.directory / "SHA256SUMS"
        original = path.read_text()
        for text in (f"{'a' * 64}  ../outside\n", original + original.splitlines()[0] + "\n", ""):
            with self.subTest(text=text[:70]):
                path.write_text(text)
                with self.assertRaises(ValueError):
                    RELEASE.verify(self.root, self.directory)
        self.assets()
        self.write(self.directory / "build-submodules.txt", f"+{'a' * 40} changed (main)\n")
        self.checksums()
        with self.assertRaisesRegex(ValueError, "submodule"):
            RELEASE.verify(self.root, self.directory)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Exercise release orchestration with isolated Git remotes and a fake GitHub API."""

import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Reuse only fixture helpers, without inheriting or collecting the validator's
# separate test suite. Both modules must use the very same release validator.
FIXTURE = load_module("release_fixture", "test-release.py")
RELEASE = FIXTURE.RELEASE
with patch.dict(sys.modules, {"release": RELEASE}):
    PLANNER = load_module("release_planner", "release-plan.py")
RECIPES = load_module("recipe_checks", "check-recipes.py")


class FakeGitHub:
    """Model drafts, immutable uploaded assets and publication; never use a network."""

    def __init__(self, test):
        self.test = test
        self.items = []
        self.calls = []
        self.upload_attempts = 0
        self.fail_upload_at = None
        self.corrupt_upload = False

    @property
    def writes(self):
        return [args for args in self.calls if args[:2] == ("release", "create")
                or ("--method" in args and args[args.index("--method") + 1] in ("POST", "PATCH", "DELETE"))]

    def call(self, *args):
        args = tuple(map(str, args))
        self.calls.append(args)
        if args[:2] == ("release", "create"):
            version = args[2]
            if any(item["tag_name"] == version for item in self.items):
                raise AssertionError("The workflow tried to recreate an existing release")
            release_id = 901
            self.items.append({
                "id": release_id, "tag_name": version,
                "target_commitish": args[args.index("--target") + 1],
                "draft": True, "prerelease": "--prerelease" in args,
                "body": Path(args[args.index("--notes-file") + 1]).read_text(),
                "assets": [], "html_url": f"https://github.com/{RELEASE.REPOSITORY}/releases/tag/{version}",
                "upload_url": f"https://uploads.github.com/repos/{RELEASE.REPOSITORY}/releases/{release_id}/assets{{?name,label}}",
            })
            return self.items[-1]["html_url"] + "\n"
        if args[:3] == ("api", "--paginate", "--slurp"):
            if args[3] != f"repos/{RELEASE.REPOSITORY}/releases?per_page=100":
                raise AssertionError(f"Unexpected release listing: {args}")
            return json.dumps([self.items])
        if not args or args[0] != "api":
            raise AssertionError(f"Unexpected gh command: {args}")
        method = args[args.index("--method") + 1] if "--method" in args else "GET"
        endpoint = next((arg for arg in args if arg.startswith("repos/") or arg.startswith("https://")), "")
        if "/tags/" in endpoint:
            raise AssertionError("Draft tags return 404; release requests must use their numeric ID")
        if method == "DELETE":
            prefix = f"repos/{RELEASE.REPOSITORY}/releases/assets/"
            if not endpoint.startswith(prefix) or not endpoint[len(prefix):].isdigit():
                raise AssertionError(f"Unexpected deletion endpoint: {args}")
            asset_id = int(endpoint[len(prefix):])
            for item in self.items:
                for asset in item["assets"]:
                    if asset.get("id") == asset_id:
                        if not item["draft"] or asset["state"] != "starter" or asset["size"] != 0:
                            raise AssertionError("Only empty placeholders in a draft may be deleted")
                        item["assets"].remove(asset)
                        return ""  # The real DELETE endpoint returns HTTP 204, no JSON.
            raise AssertionError("Unknown asset deletion")
        if method == "POST":
            parsed = urlsplit(endpoint)
            release_id = int(parsed.path.split("/")[-2])
            item = next(item for item in self.items if item["id"] == release_id)
            self.upload_attempts += 1
            if self.upload_attempts == self.fail_upload_at:
                raise subprocess.CalledProcessError(1, ["gh", *args], output="Synthetic upload interruption")
            name = parse_qs(parsed.query)["name"][0]
            if any(asset["name"] == name for asset in item["assets"]):
                raise AssertionError("The workflow tried to replace uploaded asset bytes")
            path = Path(args[args.index("--input") + 1])
            asset = {"name": name, "state": "uploaded", "size": path.stat().st_size,
                     "digest": "sha256:" + ("0" * 64 if self.corrupt_upload else RELEASE.digest(path))}
            item["assets"].append(asset)
            return json.dumps(asset)
        prefix = f"repos/{RELEASE.REPOSITORY}/releases/"
        if not endpoint.startswith(prefix) or not endpoint[len(prefix):].isdigit():
            raise AssertionError(f"Unexpected GitHub API endpoint: {args}")
        release_id = int(endpoint[len(prefix):])
        item = next(item for item in self.items if item["id"] == release_id)
        if method == "PATCH":
            if args[-2:] != ("-F", "draft=false"):
                raise AssertionError(f"Unexpected release mutation: {args}")
            self.test.git(self.test.root, "push", "origin",
                          f"{item['target_commitish']}:refs/tags/{item['tag_name']}")
            item["draft"] = False
        elif method != "GET":
            raise AssertionError(f"Unexpected GitHub API method: {args}")
        return json.dumps(item)


class ReleasePlanTest(unittest.TestCase):
    git = FIXTURE.ReleaseTest.git
    write = FIXTURE.ReleaseTest.write
    assets = FIXTURE.ReleaseTest.assets
    checksums = FIXTURE.ReleaseTest.checksums

    def readmes(self, version="v1.2.2", code=122, source_sha=None):
        """Use the maintained README field shapes, plus history using the same old version."""
        source_sha = source_sha or self.source_sha
        tag = f"https://github.com/{RELEASE.REPOSITORY}/releases/tag/{version}"
        notes = f"docs/releases/{version}.md"
        history = ("\nHistorical release: [v1.2.2 / 122]"
                   f"(https://github.com/{RELEASE.REPOSITORY}/releases/tag/v1.2.2). "
                   "[v1.2.2 installation notes](docs/releases/v1.2.2.md).\n"
                   "The source metadata is v1.2.3 / 123; v9.0.0 is only a version example.\n\n")
        return {
            "README.md": (
                "\n# MagicNet\n\n"
                f"  [![Android release](https://img.shields.io/badge/Android-{version}"
                f"%20%2F%20{code}-111111?style=flat-square&logo=android)]({tag})\n\n"
                "| Install and use MagicNet | [Releases]"
                f"(https://github.com/{RELEASE.REPOSITORY}/releases) and "
                f"[{version} installation notes]({notes}) |\n"
                f"| Published Android package | [`{version} / {code}`]({tag}) |\n"
                f"| Fixed implementation commit | `{source_sha}` |\n" + history),
            "README.en.md": (
                "# MagicNet\n\nOriginal v1.2.2 / 122 evidence stays unchanged. "
                f"current gitlink: `{source_sha}`; current Android release: "
                f"[{version} / {code}]({tag}). [Release and installation notes]({notes}).\n" + history),
            "README.ru.md": (
                "# MagicNet\n\nИсторический выпуск v1.2.2 / 122. "
                f"текущий gitlink: `{source_sha}`; текущий выпуск Android: "
                f"[{version} / {code}]({tag}). [Установка и изменения]({notes}).\n" + history),
        }

    def main_readmes(self):
        return {path: subprocess.check_output(
            ["git", "-C", str(self.origin), "show", f"main:{path}"],
        ).decode("utf-8") for path in self.readmes()}

    def setUp(self):
        FIXTURE.ReleaseTest.setUp(self)
        temporary = tempfile.TemporaryDirectory(prefix="magicnet-release-remotes-")
        self.addCleanup(temporary.cleanup)
        self.origin = Path(temporary.name) / "recipe.git"
        self.source_origin = Path(temporary.name) / "source.git"
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.origin))
        self.git(self.root, "clone", "--bare", str(self.source), str(self.source_origin))
        self.git(self.root, "remote", "add", "origin", str(self.origin))
        self.git(self.source, "remote", "add", "origin", str(self.source_origin))
        # The published stable index legitimately lags behind source development.
        self.write(self.root / "update.json", PLANNER.json_text(RELEASE.updater("v1.2.2", 122)))
        for path, text in self.readmes().items():
            self.write(self.root / path, text)
        self.write(self.root / "recipes/magicnet/DEPENDENCIES.md", f"Current source: {self.source_sha}\n")
        self.git(self.root, "add", "update.json", *self.readmes(), "recipes")
        self.git(self.root, "commit", "-m", "Index previous stable release")
        self.git(self.root, "push", "origin", "main")
        self.base = self.git(self.root, "rev-parse", "HEAD")
        self.environment.update(GITHUB_SHA=self.base, GITHUB_RUN_ID="8001", GITHUB_RUN_ATTEMPT="1")
        self.enterContext(patch.dict(os.environ, self.environment))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        # Keep Git execution real, but capture routine fetch/push stderr.
        self.enterContext(patch.object(RELEASE, "git", self.git))
        self.enterContext(patch.object(PLANNER, "git", self.git))
        self.github = FakeGitHub(self)
        self.enterContext(patch.object(PLANNER, "gh", self.github.call))

    def refs(self, repo=None):
        return self.git(repo or self.origin, "for-each-ref", "--format=%(refname) %(objectname)")

    def prepare_publish(self, **kwargs):
        self.selected, self.expected = PLANNER.prepare(self.root, "publish", **kwargs)
        return self.selected, self.expected

    def restart_plan(self):
        self.git(self.root, "checkout", "--detach", self.base)
        self.git(self.source, "checkout", "--detach", self.source_sha)

    def advance_source(self, message):
        self.git(self.source, "checkout", "main")
        self.git(self.source, "commit", "--allow-empty", "-m", message)
        self.git(self.source, "push", "origin", "main")
        return self.git(self.source, "rev-parse", "HEAD")

    def set_remote_main(self, update=None, files=None, source_sha=None):
        parent = self.git(self.origin, "rev-parse", "refs/heads/main")
        changed = dict(files or {})
        if update is not None:
            changed["update.json"] = PLANNER.json_text(update)
        commit = PLANNER.snapshot_commit(self.root, parent, changed, "Advance main during release", source_sha)
        self.git(self.root, "push", "origin", f"{commit}:refs/heads/main")
        return commit

    def seed_published(self, version, code, *, draft=False, prerelease=False):
        commit = PLANNER.snapshot_commit(self.root, self.base,
                                        {"update.json": PLANNER.json_text(RELEASE.updater(version, code))},
                                        f"Published {version}")
        self.git(self.root, "push", "origin", f"{commit}:refs/tags/{version}")
        self.github.items.append({"tag_name": version, "draft": draft, "prerelease": prerelease})
        return commit

    def interrupted_draft(self, *, fail_at=1, prerelease=False):
        self.prepare_publish(prerelease=prerelease)
        self.assets()
        self.github.fail_upload_at = fail_at
        with self.assertRaises(subprocess.CalledProcessError):
            PLANNER.publish(self.root, self.directory, "7001")
        self.github.fail_upload_at = None
        return self.github.items[0]

    def publish_release(self, *, prerelease=False):
        self.prepare_publish(prerelease=prerelease)
        self.assets()
        return PLANNER.publish(self.root, self.directory, "7001")

    def test_version_choices_and_custom_normalization(self):
        source = RELEASE.metadata(self.root)
        stable = RELEASE.updater("v1.2.2", 122)
        cases = (("none", "", "", "v1.2.3", 123),
                 ("patch", "", "", "v1.2.4", 124),
                 ("minor", "", "", "v1.3.0", 124),
                 ("major", "", "", "v2.0.0", 124),
                 ("none", "1.4.2", "", "v1.4.2", 124),
                 ("none", "v1.4.2", "500", "v1.4.2", 500),
                 ("none", "v1.2.3", "", "v1.2.3", 123))
        for bump, version, code, expected_version, expected_code in cases:
            with self.subTest(bump=bump, version=version, code=code):
                self.assertEqual(PLANNER.select_version(source, stable, bump, version, code),
                                 (expected_version, expected_code))

    def test_bump_continues_from_newer_stable_version_and_code(self):
        source = RELEASE.metadata(self.root)
        stable = RELEASE.updater("v1.9.8", 950)
        for bump, version in (("patch", "v1.9.9"), ("minor", "v1.10.0"), ("major", "v2.0.0")):
            with self.subTest(bump=bump):
                self.assertEqual(PLANNER.select_version(source, stable, bump, "", ""), (version, 951))

    def test_invalid_version_code_and_conflicting_inputs_are_rejected(self):
        source = RELEASE.metadata(self.root)
        stable = RELEASE.updater("v1.2.2", 122)
        for code in ("0", "-1", "+1", "1.0", "01", " 123", "123\n", "2147483648"):
            with self.subTest(code=code), self.assertRaises(ValueError):
                PLANNER.select_version(source, stable, "none", "", code)
        for version in ("1.2", "v01.2.3", "v1.2.3-rc.1", "v1.2.2", "garbage"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                PLANNER.select_version(source, stable, "none", version, "")
        with self.assertRaisesRegex(ValueError, "custom version OR a bump"):
            PLANNER.select_version(source, stable, "patch", "v2.0.0", "")
        with self.assertRaisesRegex(ValueError, "Invalid bump"):
            PLANNER.select_version(source, stable, "automatic", "", "")
        with self.assertRaisesRegex(ValueError, "versionCode"):
            PLANNER.select_version(source, RELEASE.updater("v2.0.0", RELEASE.MAX_VERSION_CODE), "patch", "", "")

    def test_build_accepts_stable_source_drift_and_never_contacts_remote(self):
        before = self.refs(), self.refs(self.source_origin), self.git(self.root, "status", "--porcelain")
        real_git = self.git

        def local_git(repo, *args):
            self.assertNotIn(args[0], ("fetch", "push", "ls-remote"))
            return real_git(repo, *args)

        with patch.object(PLANNER, "git", local_git):
            selected, expected = PLANNER.prepare(self.root, "build", bump="minor")
        self.assertEqual((selected["version"], selected["version_code"]), ("v1.3.0", 124))
        self.assertEqual(expected["recipe_sha"], self.base)
        self.assertEqual(expected["source_sha"], self.source_sha)
        self.assertFalse((self.root / RELEASE.PLAN_FILE).exists())
        self.assertEqual(before, (self.refs(), self.refs(self.source_origin), self.git(self.root, "status", "--porcelain")))
        self.assertEqual(self.github.calls, [])

    def test_source_ref_is_resolved_to_a_fixed_commit_without_remote_writes(self):
        selected_sha = self.advance_source("Chosen source commit")
        self.git(self.source, "checkout", "--detach", self.source_sha)
        before = self.refs(), self.refs(self.source_origin)
        selected, expected = PLANNER.prepare(self.root, "build", source_ref="main")
        self.assertEqual(selected["source_sha"], selected_sha)
        self.assertEqual(expected["source_sha"], selected_sha)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), selected_sha)
        self.assertEqual(before, (self.refs(), self.refs(self.source_origin)))
        self.assertEqual(self.github.calls, [])
        self.assertEqual(self.git(self.root, "ls-tree", "HEAD", RELEASE.SOURCE).split()[2], self.source_sha)

    def test_unsafe_source_refs_are_rejected_before_fetch(self):
        for ref in ("--upload-pack=bad", "main;echo bad", "../main", "main//other", "main\nother", "@{1}"):
            with self.subTest(ref=ref), patch.object(PLANNER, "git") as git_mock:
                with self.assertRaisesRegex(ValueError, "source ref"):
                    PLANNER.checkout_source(self.root, ref)
                git_mock.assert_not_called()

    def test_publish_uses_latest_public_version_even_when_main_index_lags(self):
        self.seed_published("v1.9.8", 950)
        self.github.items.append({"tag_name": "v9.0.0", "draft": True, "prerelease": False})
        selected, _ = self.prepare_publish(bump="patch")
        self.assertEqual((selected["version"], selected["version_code"]), ("v1.9.9", 951))
        self.assertEqual(json.loads(self.git(self.origin, "show", "main:update.json"))["version"], "v1.2.2")

    def test_published_prerelease_also_reserves_its_version_and_code(self):
        self.seed_published("v1.3.0", 200, prerelease=True)
        selected, _ = self.prepare_publish(bump="patch")
        self.assertEqual((selected["version"], selected["version_code"]), ("v1.3.1", 201))

    def test_publish_rejects_nonincreasing_version_and_code(self):
        self.seed_published("v1.2.3", 123)
        for kwargs, message in (({}, "Version must exceed"), ({"bump": "patch", "code": "123"}, "versionCode must exceed")):
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(ValueError, message):
                PLANNER.prepare(self.root, "publish", **kwargs)
        self.assertNotIn("refs/heads/release/", self.refs())

    def test_prepare_authorization_fails_before_any_remote_write(self):
        before = self.refs()
        for key, value in (("GITHUB_REF", "refs/heads/feature"), ("GITHUB_EVENT_NAME", "push"),
                           ("GITHUB_REPOSITORY", "someone/fork"), ("GITHUB_SHA", "0" * 40),
                           ("GITHUB_RUN_ID", "../../main")):
            with self.subTest(key=key), patch.dict(os.environ, {key: value}), self.assertRaises(ValueError):
                PLANNER.prepare(self.root, "publish")
        self.assertEqual(self.refs(), before)
        self.assertEqual(self.github.calls, [])

    def test_prerelease_requires_publish_mode(self):
        for mode in ("build", "verify"):
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, "requires mode=publish"):
                PLANNER.prepare(self.root, mode, prerelease=True)

    def test_snapshot_is_immutable_and_same_run_retry_preserves_selected_source(self):
        chosen = self.advance_source("Selected implementation")
        self.git(self.source, "checkout", "--detach", self.source_sha)
        selected, expected = self.prepare_publish(source_ref="main")
        snapshot = expected["recipe_sha"]
        self.assertNotEqual(snapshot, self.base)
        self.assertEqual(self.git(self.origin, "rev-parse", "release/run-8001"), snapshot)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"), self.base)
        self.assertEqual(self.git(self.root, "rev-parse", "HEAD^"), self.base)
        self.assertEqual(json.loads((self.root / RELEASE.PLAN_FILE).read_text()), selected)
        self.assertEqual(self.git(self.root, "ls-tree", "HEAD", RELEASE.SOURCE).split()[2], chosen)
        self.advance_source("New source main after plan")
        self.restart_plan()
        before = self.refs()
        with patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "2"}), \
                patch.object(PLANNER, "latest_published", side_effect=AssertionError("A retry must reuse its plan")):
            resumed, resumed_expected = PLANNER.prepare(self.root, "publish", source_ref="main")
        self.assertEqual((resumed, resumed_expected), (selected, expected))
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), chosen)
        self.assertEqual(self.refs(), before)

    def test_snapshot_ref_cannot_be_reused_with_changed_inputs(self):
        self.prepare_publish()
        before = self.refs()
        self.restart_plan()
        with self.assertRaisesRegex(ValueError, "another request"):
            PLANNER.prepare(self.root, "publish", bump="patch")
        self.assertEqual(self.refs(), before)

    def test_snapshot_with_wrong_parent_is_rejected(self):
        selected, expected = self.prepare_publish()
        forged = PLANNER.snapshot_commit(self.root, expected["recipe_sha"],
                                         {RELEASE.PLAN_FILE: PLANNER.json_text(selected)}, "Wrong snapshot parent")
        self.git(self.root, "push", "origin", f"{forged}:refs/heads/release/run-8001")
        self.restart_plan()
        with self.assertRaisesRegex(ValueError, "parent differs"):
            PLANNER.prepare(self.root, "publish")

    def test_existing_tag_or_draft_is_never_replaced(self):
        self.git(self.root, "push", "origin", f"{self.base}:refs/tags/v1.2.3")
        before = self.refs()
        with self.assertRaisesRegex(ValueError, "tag already exists"):
            self.prepare_publish()
        self.assertEqual(before, self.refs())
        self.git(self.origin, "update-ref", "-d", "refs/tags/v1.2.3")
        self.github.items = [{"tag_name": "v1.2.3", "draft": True, "prerelease": False}]
        with self.assertRaisesRegex(ValueError, "release or draft"):
            self.prepare_publish()
        self.assertEqual(self.github.writes, [])

    def test_publish_resumes_partial_upload_by_numeric_id_without_replacing_assets(self):
        draft = self.interrupted_draft(fail_at=3)
        preserved = copy.deepcopy(draft["assets"])
        self.assertEqual(len(preserved), 2)
        self.github.calls.clear()
        result = PLANNER.publish(self.root, self.directory, "7001")
        self.assertFalse(result["draft"])
        self.assertEqual(draft["assets"][:2], preserved)
        self.assertNotIn(("release", "create"), [call[:2] for call in self.github.calls])
        new_names = [parse_qs(urlsplit(next(arg for arg in call if arg.startswith("https://"))).query)["name"][0]
                     for call in self.github.writes if "POST" in call]
        self.assertEqual(set(new_names), {path.name for path in self.directory.iterdir()} - {asset["name"] for asset in preserved})
        self.assertEqual(self.git(self.origin, "rev-parse", "refs/tags/v1.2.3"), self.expected["recipe_sha"])
        self.assertEqual(json.loads(self.git(self.origin, "show", "main:update.json"))["version"], "v1.2.2")

    def test_existing_asset_mismatch_cannot_be_replaced_or_published(self):
        draft = self.interrupted_draft(fail_at=2)
        original = copy.deepcopy(draft["assets"][0])
        for key, value in (("digest", "sha256:" + "0" * 64), ("size", original["size"] + 1), ("state", "starter")):
            with self.subTest(field=key):
                draft["assets"][0] = original | {key: value}
                self.github.calls.clear()
                with self.assertRaisesRegex(ValueError, "refusing to replace"):
                    PLANNER.publish(self.root, self.directory, "7001")
                self.assertEqual(self.github.writes, [])
                self.assertTrue(draft["draft"])

    def test_empty_starter_from_interrupted_upload_is_removed_only_by_asset_id(self):
        draft = self.interrupted_draft(fail_at=2)
        preserved = copy.deepcopy(draft["assets"][0])
        missing = sorted({path.name for path in self.directory.iterdir()} - {preserved["name"]})
        draft["assets"].append({"id": 4001, "name": missing[0], "state": "starter", "size": 0, "digest": None})
        self.github.calls.clear()
        result = PLANNER.publish(self.root, self.directory, "7001")
        self.assertFalse(result["draft"])
        self.assertEqual(draft["assets"][0], preserved)
        deletions = [call for call in self.github.writes if "DELETE" in call]
        self.assertEqual(deletions, [("api", f"repos/{RELEASE.REPOSITORY}/releases/assets/4001", "--method", "DELETE")])
        self.assertEqual({asset["name"] for asset in draft["assets"]}, {path.name for path in self.directory.iterdir()})

    def test_starter_cleanup_rejects_published_nonempty_or_invalid_id_assets(self):
        draft = self.interrupted_draft()
        name = next(self.directory.iterdir()).name
        placeholder = {"id": 4001, "name": name, "state": "starter", "size": 0, "digest": None}
        cases = ((False, placeholder), (True, placeholder | {"size": 1}),
                 (True, placeholder | {"state": "uploaded"}),
                 *((True, placeholder | {"id": value}) for value in (None, "4001", 0, -1, True)))
        for is_draft, asset in cases:
            with self.subTest(draft=is_draft, asset=asset):
                draft["draft"] = is_draft
                draft["assets"] = [asset]
                self.github.calls.clear()
                with self.assertRaisesRegex(ValueError, "refusing to replace"):
                    PLANNER.publish(self.root, self.directory, "7001")
                self.assertEqual(self.github.writes, [])

    def test_new_asset_digest_mismatch_keeps_release_draft(self):
        self.prepare_publish()
        self.assets()
        self.github.corrupt_upload = True
        with self.assertRaisesRegex(ValueError, "digest/size differs"):
            PLANNER.publish(self.root, self.directory, "7001")
        self.assertTrue(self.github.items[0]["draft"])
        self.assertFalse(any("PATCH" in call for call in self.github.writes))
        self.assertNotIn("refs/tags/v1.2.3", self.refs())

    def test_wrong_artifact_or_existing_release_identity_is_rejected(self):
        draft = self.interrupted_draft()
        original = copy.deepcopy(draft)
        cases = (("artifact", "7002"), ("target_commitish", "0" * 40), ("prerelease", True), ("body", "Unrelated release"))
        for key, value in cases:
            with self.subTest(field=key):
                draft.clear()
                draft.update(copy.deepcopy(original))
                artifact = value if key == "artifact" else "7001"
                if key != "artifact":
                    draft[key] = value
                self.github.calls.clear()
                with self.assertRaisesRegex(ValueError, "another artifact|identity differs"):
                    PLANNER.publish(self.root, self.directory, artifact)
                self.assertEqual(self.github.writes, [])

    def test_ambiguous_or_invalid_numeric_release_ids_are_rejected(self):
        draft = self.interrupted_draft()
        self.github.items.append(copy.deepcopy(draft))
        self.github.calls.clear()
        with self.assertRaisesRegex(ValueError, "Multiple releases"):
            PLANNER.publish(self.root, self.directory, "7001")
        self.assertEqual(self.github.writes, [])
        self.github.items.pop()
        for release_id in ("901", 0, -1, True, None):
            with self.subTest(release_id=release_id):
                draft["id"] = release_id
                self.github.calls.clear()
                with self.assertRaisesRegex(ValueError, "Invalid release ID"):
                    PLANNER.publish(self.root, self.directory, "7001")
                self.assertEqual(self.github.writes, [])

    def test_duplicate_or_unexpected_uploaded_assets_are_rejected(self):
        draft = self.interrupted_draft(fail_at=2)
        original = copy.deepcopy(draft["assets"])
        for assets, message in ((original + original, "Duplicate server asset"),
                                (original + [original[0] | {"name": "unexpected.zip"}], "Unexpected server asset")):
            with self.subTest(message=message):
                draft["assets"] = assets
                self.github.calls.clear()
                with self.assertRaisesRegex(ValueError, message):
                    PLANNER.publish(self.root, self.directory, "7001")
                self.assertEqual(self.github.writes, [])

    def test_published_release_retry_is_idempotent_and_missing_assets_are_not_uploaded(self):
        self.publish_release()
        self.github.calls.clear()
        before = self.refs()
        self.assertFalse(PLANNER.publish(self.root, self.directory, "7001")["draft"])
        self.assertEqual(self.refs(), before)
        self.assertEqual(self.github.writes, [])
        self.github.items[0]["assets"].pop()
        with self.assertRaisesRegex(ValueError, "Published release is missing assets"):
            PLANNER.publish(self.root, self.directory, "7001")
        self.assertEqual(self.github.writes, [])

    def test_publish_and_sync_require_original_run_and_official_dispatch(self):
        self.publish_release()
        for operation in (lambda: PLANNER.publish(self.root, self.directory, "7001"),
                          lambda: PLANNER.sync_index(self.root, self.directory)):
            for key, value in (("GITHUB_RUN_ID", "8002"), ("GITHUB_EVENT_NAME", "push"),
                               ("GITHUB_REPOSITORY", "someone/fork"), ("GITHUB_SHA", "0" * 40)):
                with self.subTest(operation=operation, key=key), patch.dict(os.environ, {key: value}):
                    before = self.refs()
                    self.github.calls.clear()
                    with self.assertRaises(ValueError):
                        operation()
                    self.assertEqual(self.refs(), before)
                    self.assertEqual(self.github.writes, [])

    def test_uncommitted_plan_cannot_impersonate_a_release_snapshot(self):
        selected, _ = PLANNER.prepare(self.root, "build")
        self.assets()
        self.write(self.directory / "update.json", PLANNER.json_text(RELEASE.updater("v1.2.3", 123)))
        self.checksums()
        self.write(self.root / RELEASE.PLAN_FILE, PLANNER.json_text(selected))
        for operation in (lambda: PLANNER.publish(self.root, self.directory, "7001"),
                          lambda: PLANNER.sync_index(self.root, self.directory)):
            with self.subTest(operation=operation), self.assertRaises(ValueError):
                operation()
        self.assertEqual(self.github.writes, [])

    def test_stable_index_waits_for_public_release(self):
        self.interrupted_draft()
        before = self.refs()
        with self.assertRaises(ValueError):
            PLANNER.sync_index(self.root, self.directory)
        self.assertEqual(self.refs(), before)

    def test_stable_index_sync_preserves_new_main_files_and_gitlink_then_is_idempotent(self):
        self.publish_release()
        source_sha = self.advance_source("Main has newer development source")
        concurrent = "Concurrent documentation change: keep v1.2.2 / 122 as historical evidence.\n\n"
        files = {path: text + concurrent for path, text in self.readmes(source_sha=source_sha).items()}
        files["recipes/magicnet/DEPENDENCIES.md"] = f"Current source: {source_sha}\n"
        files["CONTRIBUTING.md"] = "A concurrent document must remain untouched.\n"
        newer_main = self.set_remote_main(files=files, source_sha=source_sha)
        self.git(self.source, "checkout", "--detach", self.source_sha)
        snapshot = self.git(self.root, "rev-parse", "HEAD")
        PLANNER.sync_index(self.root, self.directory)
        updated = self.git(self.origin, "rev-parse", "main")
        self.assertEqual(self.git(self.origin, "rev-parse", "main^"), newer_main)
        self.assertEqual(json.loads(self.git(self.origin, "show", "main:update.json")), RELEASE.updater("v1.2.3", 123))
        expected_readmes = {path: text + concurrent
                            for path, text in self.readmes("v1.2.3", 123, source_sha).items()}
        self.assertEqual(self.main_readmes(), expected_readmes)
        self.assertEqual(self.git(self.origin, "show", "main:CONTRIBUTING.md"), files["CONTRIBUTING.md"].strip())
        self.assertEqual(self.git(self.origin, "ls-tree", "main", RELEASE.SOURCE).split()[2], source_sha)
        self.assertNotIn(RELEASE.PLAN_FILE, self.git(self.origin, "ls-tree", "--name-only", "main"))
        self.assertEqual(self.git(self.root, "rev-parse", "HEAD"), snapshot)
        with tempfile.TemporaryDirectory(prefix="magicnet-synced-pins-") as temporary:
            checkout = Path(temporary) / "recipe"
            self.git(self.root, "clone", str(self.origin), str(checkout))
            self.assertEqual(RECIPES.verify_live_pins(checkout), (source_sha, "v1.2.3", 123))
        PLANNER.sync_index(self.root, self.directory)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"), updated)

    def test_stable_index_repairs_readmes_when_updater_and_notes_are_already_current(self):
        self.publish_release()
        partial = self.readmes()
        partial["README.en.md"] = self.readmes("v1.2.3", 123)["README.en.md"]
        partial["README.md"] += "New main text after the first synchronization.\n"
        previous = self.set_remote_main(RELEASE.updater("v1.2.3", 123), files=partial)
        PLANNER.sync_index(self.root, self.directory)
        updated = self.git(self.origin, "rev-parse", "main")
        self.assertNotEqual(updated, previous)
        self.assertEqual(self.git(self.origin, "rev-parse", "main^"), previous)
        expected = self.readmes("v1.2.3", 123)
        expected["README.md"] += "New main text after the first synchronization.\n"
        self.assertEqual(self.main_readmes(), expected)
        PLANNER.sync_index(self.root, self.directory)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"), updated)

    def test_stable_index_push_retry_preserves_the_newest_readme_edits(self):
        self.publish_release()
        raced = []
        concurrent = "Another maintainer edited this translation while sync was pushing.\n"

        def race_before_first_push(repo, *args):
            if args[:2] == ("push", "origin") and args[-1].endswith(":refs/heads/main") and not raced:
                files = self.readmes()
                files["README.ru.md"] += concurrent
                raced.append(self.set_remote_main(files=files))
            return self.git(repo, *args)

        with patch.object(PLANNER, "git", race_before_first_push):
            PLANNER.sync_index(self.root, self.directory)
        self.assertEqual(len(raced), 1)
        self.assertEqual(self.git(self.origin, "rev-parse", "main^"), raced[0])
        expected = self.readmes("v1.2.3", 123)
        expected["README.ru.md"] += concurrent
        self.assertEqual(self.main_readmes(), expected)

    def test_stable_index_refuses_to_regress_a_newer_readme_release_or_code(self):
        self.publish_release()
        for version, code in (("v1.4.0", 200), ("v1.2.3", 999)):
            with self.subTest(version=version, code=code):
                files = self.readmes()
                files["README.en.md"] = self.readmes(version, code)["README.en.md"]
                previous = self.set_remote_main(files=files)
                before = self.main_readmes()
                with self.assertRaisesRegex(ValueError, "README.en.md.*must not regress"):
                    PLANNER.sync_index(self.root, self.directory)
                self.assertEqual(self.git(self.origin, "rev-parse", "main"), previous)
                self.assertEqual(self.main_readmes(), before)

    def test_stable_index_rejects_missing_or_ambiguous_current_readme_fields(self):
        self.publish_release()
        missing = self.readmes()["README.md"].replace("Published Android package", "Historical Android package")
        duplicate = self.readmes()["README.ru.md"] * 2
        for path, text in (("README.md", missing), ("README.ru.md", duplicate)):
            with self.subTest(path=path):
                files = self.readmes()
                files[path] = text
                previous = self.set_remote_main(files=files)
                with self.assertRaisesRegex(ValueError, "exactly one current"):
                    PLANNER.sync_index(self.root, self.directory)
                self.assertEqual(self.git(self.origin, "rev-parse", "main"), previous)

    def test_stable_index_updates_the_repository_readme_layouts_without_touching_history(self):
        self.publish_release()
        repository = Path(__file__).resolve().parents[1]
        stable = json.loads((repository / "update.json").read_text())
        files = {path: (repository / path).read_text().replace(stable["version"], "v1.2.2")
                 .replace(str(stable["versionCode"]), "122") for path in self.readmes()}
        self.set_remote_main(files=files)
        PLANNER.sync_index(self.root, self.directory)
        updated = self.main_readmes()
        for path, text in updated.items():
            self.assertIn("v1.2.3 / 123", text)
            self.assertIn("docs/releases/v1.2.3.md", text)
            self.assertEqual(text.count("v1.8.0"), files[path].count("v1.8.0"))
            self.assertEqual(text.count("v1.8.1"), files[path].count("v1.8.1"))
        self.assertIn("Android-v1.2.3%20%2F%20123-111111", updated["README.md"])

    def test_stable_index_does_not_downgrade_a_newer_release(self):
        self.publish_release()
        newer = self.set_remote_main(RELEASE.updater("v1.4.0", 200))
        PLANNER.sync_index(self.root, self.directory)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"), newer)
        self.assertEqual(json.loads(self.git(self.origin, "show", "main:update.json")), RELEASE.updater("v1.4.0", 200))

    def test_stable_index_never_regresses_version_code(self):
        self.publish_release()
        newer = self.set_remote_main(RELEASE.updater("v1.2.2", 999))
        with self.assertRaisesRegex(ValueError, "must not regress"):
            PLANNER.sync_index(self.root, self.directory)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"), newer)

    def test_prerelease_never_changes_stable_index(self):
        notes_path = "docs/releases/v1.2.3.md"
        self.git(self.root, "rm", notes_path)
        self.git(self.root, "commit", "-m", "No main notes for the next prerelease yet")
        self.git(self.root, "push", "origin", "main")
        self.base = self.git(self.root, "rev-parse", "HEAD")
        os.environ["GITHUB_SHA"] = self.base
        before_update = subprocess.check_output(["git", "-C", str(self.origin), "show", "main:update.json"])
        before_gitlink = self.git(self.origin, "ls-tree", "main", RELEASE.SOURCE)
        before_readmes = self.main_readmes()
        self.publish_release(prerelease=True)
        PLANNER.sync_index(self.root, self.directory)
        self.assertEqual(self.git(self.origin, "show", f"main:{notes_path}"), (self.root / notes_path).read_text().strip())
        self.assertEqual(subprocess.check_output(["git", "-C", str(self.origin), "show", "main:update.json"]), before_update)
        self.assertEqual(self.git(self.origin, "ls-tree", "main", RELEASE.SOURCE), before_gitlink)
        self.assertEqual(self.main_readmes(), before_readmes)
        self.assertNotIn(RELEASE.PLAN_FILE, self.git(self.origin, "ls-tree", "--name-only", "main"))
        synced = self.git(self.origin, "rev-parse", "main")
        PLANNER.sync_index(self.root, self.directory)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"), synced)

    def test_stable_index_rechecks_immutable_tag_before_update(self):
        self.publish_release()
        self.git(self.origin, "update-ref", "refs/tags/v1.2.3", self.base)
        before = self.refs()
        with self.assertRaisesRegex(ValueError, "tag|snapshot"):
            PLANNER.sync_index(self.root, self.directory)
        self.assertEqual(self.refs(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)

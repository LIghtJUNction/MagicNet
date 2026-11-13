#!/usr/bin/env python3
"""Exercise live gitlink and published-version pin checks."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("check_recipes", Path(__file__).with_name("check-recipes.py"))
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

GITLINK = "b989227b140a7627edff8b60ad87655cb09ac2d0"
OTHER = "8ff1242817038dfe220a68b75934d6b127bea4b1"


class LivePinTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="magicnet-pin-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Pin test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        recipes = self.root / "recipes" / "magicnet"
        recipes.mkdir(parents=True)
        (recipes / "DEPENDENCIES.md").write_text(f"当前固定 {GITLINK}\n")
        (recipes / "BUILD_PROMPT.md").write_text(
            f"# 重建 MagicNet（配方 0.3.21）\n\n- 当前维护实现为 `LIghtJUNction/magicnet-android@{GITLINK}`；\n"
        )
        (recipes / "RECIPE.md").write_text(
            "~~~toml\n[package]\nname = \"magicnet\"\nversion = \"0.3.21\"\n~~~\n"
        )
        workflows = self.root / ".github" / "workflows"
        workflows.mkdir(parents=True)
        (workflows / "release.yml").write_text(
            "jobs:\n  build:\n    uses: LIghtJUNction/magicnet-android/.github/workflows/exec.yml@"
            f"{GITLINK}\n"
            "  android:\n    uses: LIghtJUNction/magicnet-android/.github/workflows/"
            f"android-kernelsu-acceptance.yml@{GITLINK}\n"
        )
        (self.root / "README.md").write_text(
            f"Fixed implementation commit `{GITLINK}`\nPublished Android package v1.8.4 / 10612\n"
        )
        (self.root / "update.json").write_text(json.dumps({
            "changelog": "https://github.com/LIghtJUNction/MagicNet/blob/main/docs/releases/v1.8.4.md",
            "version": "v1.8.4",
            "versionCode": 10612,
            "zipUrl": "https://github.com/LIghtJUNction/MagicNet/releases/download/v1.8.4/magicnet_installer.zip",
        }))
        self.git("add", "recipes", "README.md", "update.json", ".github")
        self.git("update-index", "--add", "--cacheinfo", f"160000,{GITLINK},generated/magicnet-android")
        self.git("commit", "-m", "Synthetic pins")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    def test_matching_pins_are_accepted(self):
        self.assertEqual(CHECK.verify_live_pins(self.root), (GITLINK, "v1.8.4", 10612))

    def test_stale_dependency_gitlink_is_rejected(self):
        path = self.root / "recipes" / "magicnet" / "DEPENDENCIES.md"
        path.write_text(f"当前固定 {OTHER}\n")
        with self.assertRaisesRegex(ValueError, "DEPENDENCIES.md"):
            CHECK.verify_live_pins(self.root)

    def test_stale_readme_gitlink_is_rejected(self):
        path = self.root / "README.md"
        path.write_text(path.read_text().replace(GITLINK, OTHER))
        with self.assertRaisesRegex(ValueError, "README.md does not record the current source gitlink"):
            CHECK.verify_live_pins(self.root)

    def test_stale_build_prompt_gitlink_is_rejected(self):
        path = self.root / "recipes" / "magicnet" / "BUILD_PROMPT.md"
        path.write_text(path.read_text().replace(GITLINK, OTHER))
        with self.assertRaisesRegex(ValueError, "BUILD_PROMPT.md"):
            CHECK.verify_live_pins(self.root)

    def test_stale_reusable_workflow_pin_is_rejected(self):
        path = self.root / ".github" / "workflows" / "release.yml"
        path.write_text(path.read_text().replace(GITLINK, OTHER))
        with self.assertRaisesRegex(ValueError, "release.yml reusable exec.yml"):
            CHECK.verify_live_pins(self.root)

    def test_stale_recipe_version_in_build_prompt_is_rejected(self):
        path = self.root / "recipes" / "magicnet" / "BUILD_PROMPT.md"
        path.write_text(path.read_text().replace("0.3.21", "0.3.20"))
        with self.assertRaisesRegex(ValueError, "BUILD_PROMPT.md does not record the current recipe version"):
            CHECK.verify_live_pins(self.root)

    def test_historical_correct_values_do_not_hide_stale_active_fields(self):
        for name, old, new, historical in (
            ("recipes/magicnet/BUILD_PROMPT.md", GITLINK, OTHER, f"History: {GITLINK}"),
            ("recipes/magicnet/BUILD_PROMPT.md", "0.3.21", "0.3.20", "History: 0.3.21"),
            (".github/workflows/release.yml", GITLINK, OTHER,
             f"# uses: LIghtJUNction/magicnet-android/.github/workflows/exec.yml@{GITLINK}"),
        ):
            path = self.root / name
            original = path.read_text()
            with self.subTest(name=name, value=old):
                path.write_text(original.replace(old, new) + historical + "\n")
                with self.assertRaises(ValueError):
                    CHECK.verify_live_pins(self.root)
            path.write_text(original)

    def test_example_or_comment_only_source_is_rejected(self):
        path = self.root / "recipes/magicnet/BUILD_PROMPT.md"
        original = path.read_text()
        source = next(line for line in original.splitlines() if line.startswith("- 当前维护实现为"))
        for opening, closing in (("```markdown", "```"), ("~~~~", "~~~~"), ("<!--", "-->"), ("<!--", "")):
            with self.subTest(opening=opening):
                path.write_text(original.replace(source, opening + "\n" + source + "\n" + closing))
                with self.assertRaisesRegex(ValueError, "active source"):
                    CHECK.verify_live_pins(self.root)

    def test_malformed_source_plus_valid_example_does_not_pass(self):
        path = self.root / "recipes/magicnet/BUILD_PROMPT.md"
        original = path.read_text()
        path.write_text(original.replace(GITLINK, "main") + "```markdown\n" + original + "```\n")
        with self.assertRaisesRegex(ValueError, "source gitlink"):
            CHECK.verify_live_pins(self.root)

    def test_every_required_workflow_ref_is_checked(self):
        path = self.root / ".github/workflows/release.yml"
        original = path.read_text()
        path.write_text(original.replace(f"android-kernelsu-acceptance.yml@{GITLINK}",
                                        f"android-kernelsu-acceptance.yml@{OTHER}"))
        with self.assertRaisesRegex(ValueError, "android-kernelsu-acceptance.yml"):
            CHECK.verify_live_pins(self.root)

    def test_version_prefix_match_is_not_enough(self):
        path = self.root / "recipes/magicnet/BUILD_PROMPT.md"
        path.write_text(path.read_text().replace("0.3.21", "0.3.210"))
        with self.assertRaisesRegex(ValueError, "current recipe version"):
            CHECK.verify_live_pins(self.root)

    def test_historical_examples_do_not_override_active_fields(self):
        path = self.root / "recipes/magicnet/BUILD_PROMPT.md"
        original = path.read_text()
        path.write_text(original + "\n```markdown\n" + original.replace(GITLINK, OTHER) + "```\n")
        CHECK.verify_live_pins(self.root)

    def test_quoted_refs_and_comments_are_supported(self):
        path = self.root / ".github/workflows/release.yml"
        original = path.read_text()
        for quote in ("'", '"'):
            with self.subTest(quote=quote):
                path.write_text("\n".join(
                    line.replace("uses: ", "uses: " + quote) + quote + " # pinned"
                    if "uses: " in line else line for line in original.splitlines()) + "\n")
                CHECK.verify_live_pins(self.root)

    def test_duplicate_or_comment_only_job_ref_is_rejected(self):
        path = self.root / ".github/workflows/release.yml"
        original = path.read_text()
        for workflow in (original.replace("    uses:", "    # uses:"),
                         original.replace("  build:", "  build:\n    uses: other/workflow@main")):
            with self.subTest(workflow=workflow):
                path.write_text(workflow)
                with self.assertRaises(ValueError):
                    CHECK.verify_live_pins(self.root)

    def test_stale_published_version_is_rejected(self):
        path = self.root / "README.md"
        path.write_text(path.read_text().replace("v1.8.4", "v1.8.1").replace("10612", "10609"))
        with self.assertRaisesRegex(ValueError, "published updater"):
            CHECK.verify_live_pins(self.root)


if __name__ == "__main__":
    unittest.main()

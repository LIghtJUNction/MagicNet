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
        (self.root / "README.md").write_text(
            f"Fixed implementation commit `{GITLINK}`\nPublished Android package v1.8.4 / 10612\n"
        )
        (self.root / "update.json").write_text(json.dumps({
            "changelog": "https://github.com/LIghtJUNction/MagicNet/blob/main/docs/releases/v1.8.4.md",
            "version": "v1.8.4",
            "versionCode": 10612,
            "zipUrl": "https://github.com/LIghtJUNction/MagicNet/releases/download/v1.8.4/magicnet_installer.zip",
        }))
        self.git("add", "recipes", "README.md", "update.json")
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

    def test_stale_published_version_is_rejected(self):
        path = self.root / "README.md"
        path.write_text(path.read_text().replace("v1.8.4", "v1.8.1").replace("10612", "10609"))
        with self.assertRaisesRegex(ValueError, "published updater"):
            CHECK.verify_live_pins(self.root)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Check, pack and inspect the complete Markdown recipe without retaining outputs."""

from pathlib import Path, PurePosixPath
import json
import re
import subprocess
import tarfile
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def identity(body):
    manifest = re.search(r"(?:~~~|```)toml\n(.*?)\n(?:~~~|```)", body, re.S)
    package = tomllib.loads(manifest[1])["package"]
    return package["name"], package["version"]


def gitlink_sha(root):
    entry = subprocess.check_output(
        ["git", "-C", str(root), "ls-tree", "HEAD", "--", "generated/magicnet-android"],
        text=True,
    ).split()
    if len(entry) != 4 or entry[:2] != ["160000", "commit"]:
        raise ValueError("Missing source gitlink")
    return entry[2]


def published_updater(root):
    data = json.loads((root / "update.json").read_text())
    version, code = data.get("version"), data.get("versionCode")
    if not isinstance(version, str) or type(code) is not int:
        raise ValueError("Invalid stable updater")
    return version, code


def verify_live_pins(root):
    """Refuse README/DEPENDENCIES that advertise a SHA or release other than HEAD."""
    gitlink = gitlink_sha(root)
    version, code = published_updater(root)
    dependencies = (root / "recipes/magicnet/DEPENDENCIES.md").read_text()
    readme = (root / "README.md").read_text()
    prompt = (root / "recipes/magicnet/BUILD_PROMPT.md").read_text()
    workflow = (root / ".github/workflows/release.yml").read_text()
    if gitlink not in dependencies:
        raise ValueError("DEPENDENCIES.md does not record the current source gitlink")
    if gitlink not in readme:
        raise ValueError("README.md does not record the current source gitlink")
    if gitlink not in prompt:
        raise ValueError("BUILD_PROMPT.md does not record the current source gitlink")
    for workflow_name in ("exec.yml", "android-kernelsu-acceptance.yml"):
        pin = f"LIghtJUNction/magicnet-android/.github/workflows/{workflow_name}@{gitlink}"
        if pin not in workflow:
            raise ValueError(
                f"release.yml reusable {workflow_name} is not pinned to the current source gitlink"
            )
    if version not in readme or str(code) not in readme:
        raise ValueError("README.md does not record the published updater version")
    return gitlink, version, code


def main():
    def run(*args):
        subprocess.run(["recipkg", *map(str, args)], cwd=ROOT, check=True)

    gitlink, version, code = verify_live_pins(ROOT)
    run("check", "recipes/magicnet")
    with tempfile.TemporaryDirectory(prefix="magicnet-recipe-check-") as temporary:
        archive = Path(temporary) / "magicnet.recipe.tar.gz"
        prompt = Path(temporary) / "build.md"
        run("pack", "recipes/magicnet", "--output", archive)
        run("check", archive)
        run("build", archive, "--lang", "zh-CN", "--output", prompt)
        text = prompt.read_text()
        manifests = []
        count = 0
        with tarfile.open(archive, "r:gz") as package:
            names = set()
            for member in package.getmembers():
                name = PurePosixPath(member.name)
                if not member.isfile() or name.is_absolute() or ".." in name.parts or name.suffix != ".md":
                    raise ValueError(f"Unexpected archive entry: {member.name}")
                if member.name in names:
                    raise ValueError("Duplicate archive path")
                names.add(member.name)
                body = package.extractfile(member).read().decode("utf-8")
                if "\0" in body:
                    raise ValueError("NUL in Markdown")
                if name.name != "LOCK.md" and body not in text:
                    raise ValueError(f"Incomplete build prompt: {member.name}")
                if name.name == "RECIPE.md":
                    manifests.append(identity(body))
                count += 1
        expected = [identity(path.read_text()) for path in sorted((ROOT / "recipes").glob("*/RECIPE.md"))]
        if sorted(manifests) != sorted(expected):
            raise ValueError("Recipe closure differs from the maintained package set")
        print(
            f"Recipe archive and complete prompt verified: {len(manifests)} packages, "
            f"{count} Markdown files; live pin {gitlink} / {version} {code}"
        )


if __name__ == "__main__":
    main()

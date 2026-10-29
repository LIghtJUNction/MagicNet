#!/usr/bin/env python3
"""Check, pack and inspect the complete Markdown recipe without retaining outputs."""

from pathlib import Path, PurePosixPath
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


def main():
    def run(*args):
        subprocess.run(["recipkg", *map(str, args)], cwd=ROOT, check=True)

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
        print(f"Recipe archive and complete prompt verified: {len(manifests)} packages, {count} Markdown files")


if __name__ == "__main__":
    main()

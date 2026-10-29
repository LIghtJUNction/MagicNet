#!/usr/bin/env python3
"""Validate the recipe/source boundary and the exact assets before publishing."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tomllib
import zipfile

REPOSITORY = "LIghtJUNction/MagicNet"
SOURCE_REPOSITORY = "LIghtJUNction/magicnet-android"
SOURCE = "generated/magicnet-android"


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def metadata(root):
    source = root / SOURCE
    entry = git(root, "ls-tree", "HEAD", "--", SOURCE).split()
    require(len(entry) == 4 and entry[:2] == ["160000", "commit"], "Missing source gitlink")
    source_sha = entry[2]
    require(git(source, "rev-parse", "HEAD") == source_sha, "Source checkout differs from gitlink")
    url = git(root, "config", "-f", ".gitmodules", "--get", f"submodule.{SOURCE}.url")
    require(url == f"https://github.com/{SOURCE_REPOSITORY}.git", "Unexpected source repository")
    prop = tomllib.loads((source / "kam.toml").read_text())["prop"]
    module = dict(line.split("=", 1) for line in (source / "src/MagicNet/module.prop").read_text().splitlines()
                  if "=" in line and not line.startswith("#"))
    update = json.loads((source / "update.json").read_text())
    version, code = prop["version"], prop["versionCode"]
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version), "Invalid software version")
    require(type(code) is int and 1 <= code <= 2147483647, "Invalid versionCode")
    require(prop["id"] == module["id"] == "MagicNet", "Invalid module identity")
    for other in (module, update):
        require(other["version"] == version and str(other["versionCode"]) == str(code),
                "Source version metadata differs")
    require(json.loads((root / "update.json").read_text()) == update, "Root/source update.json differs")
    base = f"https://github.com/{REPOSITORY}"
    require(update["zipUrl"] == f"{base}/releases/download/{version}/magicnet_installer.zip",
            "Updater must use the official versioned installer")
    require(update["changelog"] == f"{base}/blob/main/docs/releases/{version}.md", "Invalid changelog URL")
    return {"source_sha": source_sha, "recipe_sha": git(root, "rev-parse", "HEAD"),
            "version": version, "version_code": str(code)}


def plan(root, mode):
    result = metadata(root)
    if mode == "publish":
        require(os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
                and os.environ.get("GITHUB_REF") == "refs/heads/main"
                and os.environ.get("GITHUB_REPOSITORY") == REPOSITORY,
                "Publishing requires an explicit dispatch on official main")
        require(result["recipe_sha"] == os.environ.get("GITHUB_SHA"), "Recipe checkout differs from run")
        require((root / f"docs/releases/{result['version']}.md").is_file(), "Missing release notes")
        tags = git(root, "ls-remote", "--tags", "origin", f"refs/tags/{result['version']}")
        require(not tags, "Version tag already exists; refusing to replace a release")
        latest = json.loads(subprocess.check_output(
            ["gh", "api", f"repos/{REPOSITORY}/releases/latest"], text=True))
        tag = latest["tag_name"]
        require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "Invalid latest release version")
        previous = json.loads(git(root, "show", f"refs/tags/{tag}:update.json"))
        require(int(result["version_code"]) > previous["versionCode"], "versionCode must increase")
        require(tuple(map(int, result["version"][1:].split("."))) > tuple(map(int, tag[1:].split("."))),
                "Software version must increase")
    return result


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify(root, directory):
    expected = metadata(root)
    entries = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        require(match is not None, "Unsafe checksum entry")
        checksum, name = match.groups()
        require(name not in entries and name != "SHA256SUMS", "Duplicate/self checksum entry")
        entries[name] = checksum
    require(entries, "Empty checksums")
    require({p.name for p in directory.iterdir()} == set(entries) | {"SHA256SUMS"},
            "Asset inventory differs from checksums")
    for name, checksum in entries.items():
        path = directory / name
        require(path.is_file() and not path.is_symlink(), "Asset must be a regular file")
        require(digest(path) == checksum, f"Checksum mismatch: {name}")
    provenance = json.loads((directory / "build-source.json").read_text())
    require(provenance == {"schema": 1, "repository": REPOSITORY, "source_repository": SOURCE_REPOSITORY,
                           **expected}, "Build provenance differs from selected commits")
    require((directory / "update.json").read_bytes() == (root / "update.json").read_bytes(),
            "Published updater differs from committed updater")
    manifest = json.loads((directory / "components.json").read_text())
    require(manifest["schema"] == 1 and manifest["module"] == "MagicNet"
            and manifest["repository"] == REPOSITORY and manifest["architecture"] == "arm64"
            and manifest["version"] == expected["version"], "Invalid component manifest identity")
    assets = {"MagicNet.zip", "MagicNet-core.zip", "magicnet_installer.zip", "MagicNet-full.zip",
              "components.json", "package-sizes.json", "build-source.json", "build-submodules.txt", "update.json"}
    require(manifest["components"], "Missing components")
    for component in manifest["components"]:
        asset = component["asset"]
        require(asset == f"MagicNet-component-{component['id']}-{component['sha256']}.zip"
                and re.fullmatch(r"[a-z0-9_-]+", component["id"]), "Invalid component asset")
        require(asset not in assets and entries.get(asset) == component["sha256"], "Component digest differs")
        require((directory / asset).stat().st_size == component["size"], "Component size differs")
        assets.add(asset)
    require(set(entries) == assets, "Unexpected or missing release assets")
    aliases = ["MagicNet-core.zip", "MagicNet.zip", "magicnet_installer.zip"]
    require(len({entries[name] for name in aliases}) == 1, "Core aliases differ")
    for name in ("MagicNet-core.zip", "MagicNet-full.zip"):
        with zipfile.ZipFile(directory / name) as archive:
            require(archive.testzip() is None, "Corrupt module ZIP")
            prop = dict(line.split("=", 1) for line in archive.read("module.prop").decode().splitlines()
                        if "=" in line and not line.startswith("#"))
            require(prop["id"] == "MagicNet" and prop["version"] == expected["version"]
                    and prop["versionCode"] == expected["version_code"], "ZIP module metadata differs")
            require(json.loads(archive.read("components.json")) == manifest, "Embedded manifest differs")
    submodules = (directory / "build-submodules.txt").read_text().splitlines()
    require(submodules and all(re.match(r"^ [0-9a-f]{40} ", line) for line in submodules),
            "Incomplete or changed submodule snapshot")
    return expected


def verify_uploaded(root, directory, response):
    expected = verify(root, directory)
    require(response["draft"] is True and response["tag_name"] == expected["version"]
            and response["target_commitish"] == expected["recipe_sha"], "Unexpected draft identity")
    assets = response["assets"]
    local = {path.name: path for path in directory.iterdir()}
    require(len(assets) == len(local) and {asset["name"] for asset in assets} == set(local),
            "Uploaded asset inventory differs")
    for asset in assets:
        path = local[asset["name"]]
        require(asset["state"] == "uploaded" and asset["size"] == path.stat().st_size
                and asset["digest"] == f"sha256:{digest(path)}", "Uploaded asset digest/size differs")
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "verify", "verify-uploaded"))
    parser.add_argument("--mode", choices=("build", "publish"), default="build")
    parser.add_argument("--directory", type=Path, default=Path("dist"))
    parser.add_argument("--response", type=Path)
    args = parser.parse_args()
    root = Path.cwd()
    try:
        if args.command == "plan":
            result = plan(root, args.mode)
        elif args.command == "verify":
            result = verify(root, args.directory)
        else:
            require(args.response is not None, "Missing release API response")
            result = verify_uploaded(root, args.directory, json.loads(args.response.read_text()))
        if args.command == "plan" and os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                stream.write("".join(f"{key}={value}\n" for key, value in result.items()))
        print(json.dumps(result, sort_keys=True))
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        raise SystemExit(f"::error::{error}") from error


if __name__ == "__main__":
    main()

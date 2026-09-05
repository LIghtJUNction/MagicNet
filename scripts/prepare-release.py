#!/usr/bin/env python3
"""Validate committed metadata and resolve an explicit release request."""

import json
import os
from pathlib import Path
import re
import subprocess
import tomllib


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def prepare():
    prop = tomllib.loads(Path("kam.toml").read_text())["prop"]
    module = dict(
        line.split("=", 1)
        for line in Path("src/MagicNet/module.prop").read_text().splitlines()
        if "=" in line and not line.startswith("#")
    )
    update = json.loads(Path("update.json").read_text())
    version, code = prop["version"], prop["versionCode"]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Expected a committed vMAJOR.MINOR.PATCH version")
    if type(code) is not int or code <= 0:
        raise ValueError("versionCode must be a positive integer")
    for metadata in (module, update):
        if metadata["version"] != version or str(metadata["versionCode"]) != str(code):
            raise ValueError("Version metadata differs; update all three files in a PR")

    event = os.environ.get("GITHUB_EVENT_NAME", "")
    ref = os.environ.get("GITHUB_REF", "")
    requested = event == "workflow_dispatch" and os.environ.get("RELEASE_INPUT") == "true"
    marker = Path(".github/release-request")
    if event == "push" and ref == "refs/heads/main" and marker.exists():
        changed = git("diff", "--name-only", os.environ["PUSH_BEFORE"],
                      os.environ["GITHUB_SHA"], "--", str(marker))
        if changed:
            if marker.read_text().strip() != version:
                raise ValueError("Release request must equal the committed module version")
            requested = True
    if not requested:
        print(f"Validated {version}; build only")
        return
    if ref != "refs/heads/main":
        raise ValueError("Releases must use main after the version PR is merged")
    if git("rev-parse", "HEAD") != os.environ["GITHUB_SHA"]:
        raise ValueError("Checkout differs from the requested release commit")
    if git("ls-remote", "--tags", "origin", f"refs/tags/{version}"):
        raise ValueError(f"Tag {version} already exists; refusing to replace a release")
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"RELEASE_REQUESTED=1\nRELEASE_VERSION={version}\n")
        output.write(f"RELEASE_VERSION_CODE={code}\nMAGICNET_SIGN_REQUIRED=1\n")
    print(f"Release requested: {version} at {os.environ['GITHUB_SHA']}")


if __name__ == "__main__":
    try:
        prepare()
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"::error::{error}") from error

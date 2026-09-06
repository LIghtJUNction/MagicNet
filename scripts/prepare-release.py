#!/usr/bin/env python3
"""Validate committed metadata and resolve an explicit release request."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tomllib


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def read_metadata():
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
    return version, code


def require_main_checkout():
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Releases must use main after the version PR is merged")
    if git("rev-parse", "HEAD") != os.environ["GITHUB_SHA"]:
        raise ValueError("Checkout differs from the requested release commit")


def require_new_tag(version):
    if git("ls-remote", "--tags", "origin", f"refs/tags/{version}"):
        raise ValueError(f"Tag {version} already exists; refusing to replace a release")


def bump(kind):
    version, code = read_metadata()
    require_main_checkout()
    if os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise ValueError("Version bumps require workflow_dispatch")
    remote = git("ls-remote", "origin", "refs/heads/main").split()
    if not remote or remote[0] != os.environ["GITHUB_SHA"]:
        raise ValueError("Remote main changed; start a new workflow run")
    if git("status", "--porcelain"):
        raise ValueError("Version bump requires a clean checkout")
    release = os.environ.get("RELEASE_INPUT") == "true"
    prerelease = os.environ.get("PRERELEASE_INPUT") == "true"
    if prerelease and not release:
        raise ValueError("prerelease requires release=true")
    parts = list(map(int, version[1:].split(".")))
    index = ("major", "minor", "patch").index(kind)
    parts[index] += 1
    parts[index + 1:] = [0] * (2 - index)
    version = "v" + ".".join(map(str, parts))
    require_new_tag(version)
    code += 1

    def replace_fields(text, values):
        for key, value in values.items():
            text, count = re.subn(rf"(?m)^({key}[ \t]*=[ \t]*)[^\n]*$",
                                 lambda match: match[1] + value, text)
            if count != 1:
                raise ValueError(f"Expected exactly one {key} field")
        return text

    toml = Path("kam.toml").read_text()
    prop = re.search(r"(?ms)^\[prop\][^\n]*\n(.*?)(?=^\[|\Z)", toml)
    if prop is None:
        raise ValueError("Missing [prop] section")
    replacement = replace_fields(prop[1], {"version": json.dumps(version), "versionCode": str(code)})
    module = replace_fields(Path("src/MagicNet/module.prop").read_text(),
                            {"version": version, "versionCode": str(code)})
    update = json.loads(Path("update.json").read_text())
    update.update(version=version, versionCode=code)
    # Calculate and validate every replacement before changing the checkout.
    Path("kam.toml").write_text(toml[:prop.start(1)] + replacement + toml[prop.end(1):])
    Path("src/MagicNet/module.prop").write_text(module)
    Path("update.json").write_text(json.dumps(update, ensure_ascii=False, indent=2) + "\n")
    if release:
        marker = Path(".github/release-request")
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(version + ("\nprerelease=true\n" if prerelease else "\n"))
    read_metadata()
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"version={version}\n")
    print(f"Prepared {version} (versionCode={code}); release after merge: {release}")


def report_pr():
    url = os.environ.get("PR_URL", "")
    if os.environ.get("PR_OUTCOME") == "success" and url:
        summary = f"Version PR: {url}\n\nReview and merge after its checks pass.\n"
    else:
        version = os.environ["VERSION"]
        if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version):
            raise ValueError("Invalid version branch")
        branch = f"automation/release-{version}"
        git("fetch", "--no-tags", "origin", f"refs/heads/{branch}")
        if git("rev-parse", "FETCH_HEAD^{tree}") != os.environ["EXPECTED_TREE"]:
            raise ValueError("Remote version branch differs from the prepared content")
        if git("show", "-s", "--format=%P", "FETCH_HEAD") != os.environ["GITHUB_SHA"]:
            raise ValueError("Remote version branch has a different release base")
        url = (f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}"
               f"/compare/main...{branch}?expand=1")
        print("::warning::Automatic PR creation did not complete. The version branch "
              "was verified; use the summary link to open its PR manually.")
        summary = (f"Prepared {version}; manual PR creation required.\n\n"
                   f"[Create the version PR]({url}), then review and merge after checks pass.\n\n"
                   "No release has been published. See the PR action log for the original error.\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
        output.write(summary)


def verify_build():
    read_metadata()
    require_main_checkout()
    git("diff", "--exit-code", "HEAD", "--", "kam.toml", "src/MagicNet/module.prop")
    # Kam serializes update.json again, including removing its final newline.
    # Compare every JSON field while allowing serialization-only differences.
    def canonical(text):
        return json.dumps(json.loads(text), sort_keys=True, allow_nan=False)

    if canonical(Path("update.json").read_text()) != canonical(git("show", "HEAD:update.json")):
        raise ValueError("Build changed update.json metadata")
    print("Build metadata matches the release commit")


def prepare():
    version, code = read_metadata()

    event = os.environ.get("GITHUB_EVENT_NAME", "")
    ref = os.environ.get("GITHUB_REF", "")
    requested = event == "workflow_dispatch" and os.environ.get("RELEASE_INPUT") == "true"
    prerelease = os.environ.get("PRERELEASE_INPUT") == "true"
    marker = Path(".github/release-request")
    if event == "push" and ref == "refs/heads/main" and marker.exists():
        changed = git("diff", "--name-only", os.environ["PUSH_BEFORE"],
                      os.environ["GITHUB_SHA"], "--", str(marker))
        if changed:
            request = marker.read_text().strip().splitlines()
            if not request or request[0] != version:
                raise ValueError("Release request must equal the committed module version")
            if request[1:] not in ([], ["prerelease=true"]):
                raise ValueError("Invalid release request options")
            prerelease = request[1:] == ["prerelease=true"]
            requested = True
    if not requested:
        print(f"Validated {version}; build only")
        return
    require_main_checkout()
    if os.environ.get("KAM_PRIVATE_KEY_AVAILABLE") != "1":
        raise ValueError("Publishing requires the KAM_PRIVATE_KEY signing secret")
    require_new_tag(version)
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"RELEASE_REQUESTED=1\nRELEASE_VERSION={version}\n")
        output.write(f"RELEASE_VERSION_CODE={code}\nMAGICNET_SIGN_REQUIRED=1\n")
        output.write(f"RELEASE_PRERELEASE={str(prerelease).lower()}\n")
    print(f"Release requested: {version} at {os.environ['GITHUB_SHA']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--bump", choices=("patch", "minor", "major"))
    mode.add_argument("--report-pr", action="store_true")
    mode.add_argument("--verify-build", action="store_true")
    args = parser.parse_args()
    try:
        if args.report_pr:
            report_pr()
        elif args.verify_build:
            verify_build()
        else:
            bump(args.bump) if args.bump else prepare()
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"::error::{error}") from error

#!/usr/bin/env python3
"""Select, snapshot and publish a MagicNet release with the repository token."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

import release

REPO = release.REPOSITORY
SOURCE = release.SOURCE
PLAN = release.PLAN_FILE
require = release.require
git = release.git


def json_text(value):
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def gh(*args):
    return subprocess.check_output(["gh", *map(str, args)], text=True)


def api(path, *args):
    return json.loads(gh("api", path, *args))


def releases():
    pages = json.loads(gh("api", "--paginate", "--slurp", f"repos/{REPO}/releases?per_page=100"))
    return [item for page in pages for item in page]


def authorize(root, base_sha):
    require(os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and os.environ.get("GITHUB_REF") == "refs/heads/main"
            and os.environ.get("GITHUB_REPOSITORY") == REPO,
            "Publishing requires an explicit workflow dispatch on official main")
    require(base_sha == os.environ.get("GITHUB_SHA"), "Release plan differs from the requested recipe commit")


def checkout_source(root, ref):
    require(isinstance(ref, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", ref)
            and ".." not in ref and "//" not in ref, "Invalid source ref")
    source = root / SOURCE
    git(source, "fetch", "--no-tags", "--depth=1", "origin", ref)
    git(source, "checkout", "--detach", "FETCH_HEAD")
    return git(source, "rev-parse", "HEAD")


def latest_published(root, fallback):
    published = []
    for item in releases():
        if item["draft"]:
            continue
        try:
            version = release.version_tuple(item["tag_name"])
        except ValueError:
            continue
        published.append((version, item["tag_name"]))
    if not published:
        return fallback
    _, tag = max(published)
    git(root, "fetch", "--no-tags", "origin", f"refs/tags/{tag}:refs/tags/{tag}")
    previous = json.loads(git(root, "show", f"refs/tags/{tag}:update.json"))
    require(previous == release.updater(tag, previous["versionCode"]),
            "Published tag has inconsistent update metadata")
    return previous


def select_version(source, stable, bump, version, code):
    require(bump in ("none", "patch", "minor", "major"), "Invalid bump kind")
    require(not version or bump == "none", "Choose a custom version OR a bump, not both")
    baseline = max(release.version_tuple(source["version"]), release.version_tuple(stable["version"]))
    if version:
        version = version if version.startswith("v") else "v" + version
        target = release.version_tuple(version)
        require(target >= release.version_tuple(source["version"]), "Custom version is older than the selected source")
    elif bump != "none":
        target = list(baseline)
        index = ("major", "minor", "patch").index(bump)
        target[index] += 1
        target[index + 1:] = [0] * (2 - index)
        version = "v" + ".".join(map(str, target))
    else:
        version = source["version"]
    if code:
        require(re.fullmatch(r"[1-9][0-9]*", code), "version_code must be a positive decimal integer")
        result_code = int(code)
    elif version == source["version"]:
        result_code = int(source["version_code"])
    else:
        result_code = max(int(source["version_code"]), stable["versionCode"]) + 1
    release.updater(version, result_code)
    return version, result_code


def snapshot_commit(root, parent, files, message, source_sha=None):
    """Make a small commit without staging unrelated working-tree files."""
    with tempfile.TemporaryDirectory(prefix="magicnet-release-index-") as temporary:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(temporary) / "index"),
                   GIT_AUTHOR_NAME="github-actions[bot]", GIT_COMMITTER_NAME="github-actions[bot]",
                   GIT_AUTHOR_EMAIL="41898282+github-actions[bot]@users.noreply.github.com",
                   GIT_COMMITTER_EMAIL="41898282+github-actions[bot]@users.noreply.github.com")
        # Deterministic identity also makes a concurrent retry create the same snapshot.
        date = git(root, "show", "-s", "--format=%cI", parent)
        env.update(GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)

        def command(*args, input=None):
            return subprocess.check_output(["git", "-C", str(root), *args], env=env,
                                           input=input, text=True).strip()

        command("read-tree", parent)
        for name, text in files.items():
            blob = command("hash-object", "-w", "--stdin", input=text)
            command("update-index", "--add", "--cacheinfo", f"100644,{blob},{name}")
        if source_sha:
            command("update-index", "--add", "--cacheinfo", f"160000,{source_sha},{SOURCE}")
        return command("-c", "commit.gpgsign=false", "commit-tree", command("write-tree"),
                       "-p", parent, "-m", message)


def prepare(root, mode, bump="none", version="", code="", source_ref="", prerelease=False):
    require(mode in ("build", "verify", "publish"), "Invalid release mode")
    require(not prerelease or mode == "publish", "prerelease requires mode=publish")
    base = git(root, "rev-parse", "HEAD")
    run_id = os.environ.get("GITHUB_RUN_ID", "1")
    inputs = dict(bump=bump, version=version, version_code=code, source_ref=source_ref,
                  prerelease=prerelease)
    branch = f"refs/heads/release/run-{run_id}"
    if mode == "publish":
        authorize(root, base)
        require(re.fullmatch(r"[1-9][0-9]*", run_id), "Invalid workflow run ID")
        existing = git(root, "ls-remote", "origin", branch).split()
        if existing:
            git(root, "fetch", "--no-tags", "origin", branch)
            saved = release.validate_selection(json.loads(git(root, "show", f"{existing[0]}:{PLAN}")))
            require(saved["base_sha"] == base and saved["run_id"] == run_id and saved["inputs"] == inputs,
                    "Existing release snapshot belongs to another request")
            require(git(root, "rev-parse", f"{existing[0]}^") == base, "Release snapshot parent differs")
            checkout_source(root, saved["source_sha"])
            git(root, "checkout", "--detach", existing[0])
            return saved, release.metadata(root)

    current = release.metadata(root)
    selected_sha = checkout_source(root, source_ref) if source_ref else current["source_sha"]
    # Read and validate the selected source independently of the stable updater.
    selected = {"schema": 1, "repository": REPO, "source_repository": release.SOURCE_REPOSITORY,
                "base_sha": base, "source_sha": selected_sha, "version": current["version"],
                "version_code": int(current["version_code"]), "prerelease": prerelease, "run_id": run_id}
    if source_ref:
        import tomllib
        prop = tomllib.loads((root / SOURCE / "kam.toml").read_text())["prop"]
        selected.update(version=prop["version"], version_code=prop["versionCode"])
        current = release.metadata(root, selected)
    stable = json.loads((root / "update.json").read_text())
    if mode == "publish":
        stable = latest_published(root, stable)
    target, target_code = select_version(current, stable, bump, version, code)
    selected.update(version=target, version_code=target_code, inputs=inputs)
    release.validate_selection(selected)
    if mode == "publish":
        require(release.version_tuple(target) > release.version_tuple(stable["version"]),
                "Version must exceed published releases; choose patch/minor/major or a newer custom version")
        require(target_code > stable["versionCode"], "versionCode must exceed published releases")
        require(not git(root, "ls-remote", "--tags", "origin", f"refs/tags/{target}"),
                "Version tag already exists; refusing to replace it")
        require(not any(item["tag_name"] == target for item in releases()),
                "A release or draft already uses this version; resume its original workflow run")
        notes_path = f"docs/releases/{target}.md"
        candidates = (root / notes_path, root / SOURCE / notes_path)
        notes = next((path.read_text() for path in candidates if path.is_file()),
                     f"# MagicNet {target}\n\n"
                     f"Source: [{selected_sha}](https://github.com/{release.SOURCE_REPOSITORY}/commit/{selected_sha})\n\n"
                     "Built and verified by the MagicNet release workflow.\n")
        files = {PLAN: json_text(selected), "update.json": json_text(release.updater(target, target_code)),
                 notes_path: notes}
        commit = snapshot_commit(root, base, files, f"chore(release): prepare {target} (run {run_id})", selected_sha)
        git(root, "push", "origin", f"{commit}:{branch}")
        git(root, "checkout", "--detach", commit)
        return selected, release.metadata(root)
    return selected, release.metadata(root, selected)


def one_release(version):
    found = [item for item in releases() if item["tag_name"] == version]
    require(len(found) <= 1, "Multiple releases have the requested version")
    return found[0] if found else None


def marker(plan, snapshot, artifact):
    require(re.fullmatch(r"[1-9][0-9]*", artifact), "Missing immutable build artifact ID")
    return f"<!-- magicnet-release run={plan['run_id']} artifact={artifact} snapshot={snapshot} -->"


def publish(root, directory, artifact):
    selected = release.validate_selection(json.loads((root / PLAN).read_text()))
    authorize(root, selected["base_sha"])
    require(selected["run_id"] == os.environ.get("GITHUB_RUN_ID"), "Release snapshot belongs to another workflow run")
    expected = release.verify(root, directory)
    identity = marker(selected, expected["recipe_sha"], artifact)
    version = expected["version"]
    found = one_release(version)
    if found is None:
        require(not git(root, "ls-remote", "--tags", "origin", f"refs/tags/{version}"),
                "Version tag already exists; refusing to replace it")
        notes = (root / f"docs/releases/{version}.md").read_text()
        with tempfile.TemporaryDirectory(prefix="magicnet-release-notes-") as temporary:
            path = Path(temporary) / "notes.md"
            path.write_text(notes + f"\n\nRecipe snapshot: {expected['recipe_sha']}\n"
                            f"Source commit: {expected['source_sha']}\n\n{identity}\n")
            args = ["release", "create", version, "--repo", REPO, "--target", expected["recipe_sha"],
                    "--draft", "--title", f"MagicNet-{expected['version_code']}-{version}",
                    "--notes-file", str(path)]
            if selected["prerelease"]:
                args += ["--prerelease", "--latest=false"]
            gh(*args)
        found = one_release(version)
        require(found is not None, "Created draft could not be found")
    require(identity in (found.get("body") or ""),
            "Existing release belongs to another artifact; rerun failed jobs in the original run")
    require(found["target_commitish"] == expected["recipe_sha"]
            and found["prerelease"] == selected["prerelease"], "Existing release identity differs")
    release_id = found["id"]
    require(type(release_id) is int and release_id > 0, "Invalid release ID")
    response = api(f"repos/{REPO}/releases/{release_id}")
    require(identity in (response.get("body") or "") and response["tag_name"] == version
            and response["target_commitish"] == expected["recipe_sha"]
            and response["prerelease"] == selected["prerelease"], "Release identity changed before asset upload")
    local = {path.name: path for path in directory.iterdir()}
    uploaded = response["assets"]
    require(len({asset["name"] for asset in uploaded}) == len(uploaded), "Duplicate server asset")
    incomplete = []
    for asset in uploaded:
        require(asset["name"] in local, "Unexpected server asset")
        if asset["state"] == "starter":
            require(response["draft"] is True and type(asset["size"]) is int and asset["size"] == 0
                    and type(asset.get("id")) is int and asset["id"] > 0,
                    "Unsafe incomplete asset; refusing to replace uploaded bytes")
            incomplete.append(asset)
            continue
        path = local[asset["name"]]
        require(asset["state"] == "uploaded" and asset["size"] == path.stat().st_size
                and asset["digest"] == f"sha256:{release.digest(path)}",
                "Existing asset differs; refusing to replace uploaded bytes")
    # GitHub can leave an empty `starter` asset after a 502 upload failure.
    # Remove only these placeholders in our verified draft, never uploaded bytes.
    for asset in incomplete:
        gh("api", f"repos/{REPO}/releases/assets/{asset['id']}", "--method", "DELETE")
    uploaded = [asset for asset in uploaded if asset["state"] != "starter"]
    missing = sorted(set(local) - {asset["name"] for asset in uploaded})
    if missing:
        require(response["draft"] is True, "Published release is missing assets")
        # Upload by numeric ID: draft tags may deliberately return HTTP 404.
        upload_url = response["upload_url"].split("{", 1)[0]
        require(upload_url == f"https://uploads.github.com/repos/{REPO}/releases/{release_id}/assets",
                "Unexpected release upload endpoint")
        for name in missing:
            gh("api", "--method", "POST", f"{upload_url}?name={name}",
               "-H", "Content-Type: application/octet-stream", "--input", str(local[name]))
    response = api(f"repos/{REPO}/releases/{release_id}")
    release.verify_uploaded(root, directory, response, draft=response["draft"])
    if response["draft"]:
        api(f"repos/{REPO}/releases/{release_id}", "--method", "PATCH", "-F", "draft=false")
    response = api(f"repos/{REPO}/releases/{release_id}")
    release.verify_uploaded(root, directory, response, draft=False)
    require(response["prerelease"] == selected["prerelease"], "Published prerelease flag differs")
    tag = git(root, "ls-remote", "--tags", "origin", f"refs/tags/{version}").split()
    require(tag and tag[0] == expected["recipe_sha"], "Published tag differs from release snapshot")
    print(f"Release published: {response['html_url']}")
    return response


def sync_index(root, directory):
    selected = release.validate_selection(json.loads((root / PLAN).read_text()))
    authorize(root, selected["base_sha"])
    require(selected["run_id"] == os.environ.get("GITHUB_RUN_ID"), "Release snapshot belongs to another workflow run")
    expected = release.verify(root, directory)
    found = one_release(expected["version"])
    require(found is not None, "Release must exist before updating the stable index")
    release.verify_uploaded(root, directory, found, draft=False)
    require(found["prerelease"] == selected["prerelease"], "Release prerelease flag differs")
    tag = git(root, "ls-remote", "--tags", "origin", f"refs/tags/{expected['version']}").split()
    require(tag and tag[0] == expected["recipe_sha"], "Published tag differs from release snapshot")
    update = json.loads((directory / "update.json").read_text())
    notes_path = f"docs/releases/{expected['version']}.md"
    files = {notes_path: (root / notes_path).read_text()}
    if not found["prerelease"]:
        files["update.json"] = (directory / "update.json").read_text()
    for _ in range(3):
        git(root, "fetch", "--no-tags", "origin", "refs/heads/main")
        head = git(root, "rev-parse", "FETCH_HEAD")
        current = json.loads(git(root, "show", f"{head}:update.json"))
        require(current == release.updater(current["version"], current["versionCode"]), "Invalid stable updater")
        if not found["prerelease"] and release.version_tuple(current["version"]) > release.version_tuple(update["version"]):
            print("A newer stable release is already indexed")
            return
        if found["prerelease"] or current == update:
            try:
                if git(root, "show", f"{head}:{notes_path}") == files[notes_path].strip():
                    print("Release notes and stable updater are already current")
                    return
            except subprocess.CalledProcessError:
                pass
        else:
            require(update["versionCode"] > current["versionCode"], "Stable updater must not regress")
        commit = snapshot_commit(root, head, files, f"chore(release): index {expected['version']}")
        try:
            git(root, "push", "origin", f"{commit}:refs/heads/main")
            print(f"Release metadata synchronized at {commit}; stable updater "
                  + ("preserved for prerelease" if found["prerelease"] else "updated"))
            return
        except subprocess.CalledProcessError:
            if git(root, "ls-remote", "origin", "refs/heads/main").split()[0] == head:
                break
    raise ValueError("Release is public, but stable updater synchronization failed; rerun the failed publish job")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "publish", "sync-index"))
    parser.add_argument("--mode", choices=("build", "verify", "publish"), default="build")
    parser.add_argument("--bump", choices=("none", "patch", "minor", "major"), default="none")
    parser.add_argument("--version", default="")
    parser.add_argument("--version-code", default="")
    parser.add_argument("--source-ref", default="")
    parser.add_argument("--prerelease", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("plan") / PLAN)
    parser.add_argument("--directory", type=Path, default=Path("dist"))
    parser.add_argument("--artifact-id", default="")
    args = parser.parse_args()
    root = Path.cwd()
    try:
        if args.command == "prepare":
            selected, expected = prepare(root, args.mode, args.bump, args.version, args.version_code,
                                         args.source_ref, args.prerelease)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json_text(selected))
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                    stream.write("".join(f"{key}={value}\n" for key, value in expected.items()))
            if os.environ.get("GITHUB_STEP_SUMMARY"):
                with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
                    stream.write(f"## MagicNet {args.mode}\n\nVersion: **{expected['version']}** "
                                 f"(versionCode {expected['version_code']})\n\n"
                                 f"Source: `{expected['source_sha']}`\n\nRecipe: `{expected['recipe_sha']}`\n")
            print(json_text(expected), end="")
        elif args.command == "publish":
            publish(root, args.directory, args.artifact_id)
        else:
            sync_index(root, args.directory)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"::error::{error}") from error


if __name__ == "__main__":
    main()

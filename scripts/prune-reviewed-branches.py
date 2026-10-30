#!/usr/bin/env python3
"""Delete only reviewed, unchanged branch heads already contained in main."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    repository = "LIghtJUNction/MagicNet"
    if manifest["repository"] != repository:
        raise ValueError("Unexpected repository")
    head = run("git", "rev-parse", "HEAD")
    subprocess.run(["git", "merge-base", "--is-ancestor", manifest["reviewed_main"], head], check=True)
    branches = manifest["branches"]
    if not branches or len({entry["name"] for entry in branches}) != len(branches):
        raise ValueError("Empty or duplicate branch list")
    for entry in branches:
        name, sha = entry["name"], entry["sha"]
        if name in ("main", "HEAD") or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("Invalid deletion target")
        subprocess.run(["git", "check-ref-format", "refs/heads/" + name], check=True)
        subprocess.run(["git", "merge-base", "--is-ancestor", sha, head], check=True)
    print(f"Verified {len(branches)} reviewed ancestors of {head}", flush=True)
    if not args.execute:
        return
    if os.environ.get("GITHUB_REPOSITORY") != repository or os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Deletion is restricted to the official main workflow")
    if os.environ.get("GITHUB_SHA") != head:
        raise ValueError("Workflow checkout does not match its triggering commit")
    remote = run("git", "remote", "get-url", "origin")
    if remote not in (f"https://github.com/{repository}", f"https://github.com/{repository}.git"):
        raise ValueError("Unexpected origin URL")
    pulls = json.loads(run("gh", "api", "--paginate", "--slurp", f"repos/{repository}/pulls?state=open&per_page=100"))
    active = {
        pr["head"]["ref"]
        for page in pulls for pr in page
        if pr["head"].get("repo") and pr["head"]["repo"]["full_name"] == repository
    }
    if active.intersection(entry["name"] for entry in branches):
        raise ValueError("A reviewed branch now has an open pull request")
    remote_refs = dict(line.split()[::-1] for line in run("git", "ls-remote", "--heads", "origin").splitlines())
    if remote_refs.get("refs/heads/main") != head:
        raise ValueError("main moved after this maintenance task was prepared")
    for entry in branches:
        if remote_refs.get("refs/heads/" + entry["name"]) != entry["sha"]:
            raise ValueError("A reviewed branch head changed or disappeared: " + entry["name"])
    command = ["git", "push", "--atomic", "origin"]
    command.extend(f"--force-with-lease=refs/heads/{entry['name']}:{entry['sha']}" for entry in branches)
    command.extend(":refs/heads/" + entry["name"] for entry in branches)
    subprocess.run(command, check=True)
    remaining = dict(line.split()[::-1] for line in run("git", "ls-remote", "--heads", "origin").splitlines())
    if any("refs/heads/" + entry["name"] in remaining for entry in branches):
        raise ValueError("A requested branch is still present")
    summary = f"Deleted {len(branches)} reviewed branches; {len(remaining)} branches remain.\n"
    print(summary, flush=True)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a") as output:
            output.write(summary + "\nMain at cleanup: `" + head + "`\n\n")
            output.write("| Branch | Preserved commit in main |\n| --- | --- |\n")
            for entry in branches:
                output.write(f"| `{entry['name']}` | `{entry['sha']}` |\n")


if __name__ == "__main__":
    main()

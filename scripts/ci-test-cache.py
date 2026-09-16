#!/usr/bin/env python3
"""Content-addressed, successful-only CI test results (not release approval).

Known test families declare conservative source roots so unrelated Rust, WebUI,
network, or host changes do not invalidate each other. Unknown scopes remain
repository-wide. Never infer safety from an Actions cache prefix hit, the
commit SHA alone, or the presence of an output file.
"""
from __future__ import annotations

import argparse
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = 3
SCOPES = {
    "rust": (
        "Cargo.toml", "Cargo.lock", ".cargo", "crates", "rust-toolchain.toml",
        "src/MagicNet/.config/sing-box",
    ),
    # Host regressions intentionally cover the module/build surface, but Rust
    # crate-only and WebUI-only edits cannot affect these fixture-based checks.
    "host": (
        "src", "scripts", "hooks", "installer", ".github", "sing-box",
        "sing-box.version", "README.md", "kam.toml", "update.json", ".gitmodules",
        "rules", "rules-release.json",
    ),
    # Network regression jobs use production network/DNS policy plus the exact
    # test command operand. Keep UI, packaging, and unrelated Rust edits out.
    "network": (
        "src/MagicNet/network-check.sh",
        "src/MagicNet/lib/magicnet",
        "src/MagicNet/.config/magicnet",
        "src/MagicNet/.config/sing-box",
        "src/MagicNet/service.sh",
        "src/MagicNet/post-fs-data.sh",
    ),
    "components": ("installer", "src", "hooks", "scripts", ".github", "kam.toml", "update.json"),
    "webui": ("webui", "src", "scripts", "installer", ".github", "kam.toml"),
    "singbox": ("sing-box", "sing-box.version", "scripts/build-sing-box.sh", ".gitmodules"),
}
COMMON = (
    "scripts/ci-test-cache.py",
    "scripts/quality-gate.sh",
    ".github/actions/test-cache/action.yml",
    ".gitmodules",
)
TOOLS = {
    "bash": ["--version"], "sh": [], "python3": ["--version"],
    "git": ["--version"], "jq": ["--version"], "curl": ["--version"],
    "openssl": ["version"], "zip": ["-v"], "unzip": ["-v"],
    "tar": ["--version"], "shellcheck": ["--version"], "rg": ["--version"],
    "rustc": ["-vV"], "cargo": ["--version"], "go": ["version"],
    "node": ["--version"], "npm": ["--version"], "sing-box": ["version"],
    # Deterministic network-namespace regressions are reusable only when the
    # runner's networking toolchain is identical too.
    "ip": ["-V"], "iptables": ["--version"], "ip6tables": ["--version"],
    "unshare": ["--version"],
}
ENV_KEYS = ("CI", "ImageOS", "ImageVersion", "LANG", "LC_ALL", "TZ", "RUSTFLAGS",
            "CARGO_BUILD_TARGET", "GOFLAGS", "GOOS", "GOARCH", "CGO_ENABLED",
            "GOTOOLCHAIN", "GOWORK", "NODE_OPTIONS", "CI_TEST_CACHE_EPOCH")


def git_files(root: Path):
    """Fingerprint Git inputs without rereading every clean file.

    For clean tracked files, the index mode/blob SHA identifies the checked-out
    bytes exactly. For clean submodules, the parent gitlink plus checked-out HEAD
    identifies the full tracked tree, including nested gitlinks, so recursively
    hashing a large dependency tree adds no information. Dirty paths fall back to
    real worktree bytes, preserving mutation/untracked-file safety.
    """
    result = subprocess.run(["git", "ls-files", "--stage", "-z"], cwd=root,
                            check=True, capture_output=True).stdout
    dirty_output = subprocess.run(
        ["git", "diff-files", "--name-only", "-z"], cwd=root,
        check=True, capture_output=True,
    ).stdout
    dirty = {os.fsdecode(name) for name in dirty_output.split(b"\0") if name}
    seen = set()
    for entry in result.split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, revision, stage = metadata.split()
        if stage != b"0":
            raise ValueError("unmerged index cannot reuse test results")
        name = os.fsdecode(raw_name)
        seen.add(name)
        path = root / name
        if mode == b"160000":
            # A non-recursive checkout is a different input, never the parent HEAD.
            if not (path / ".git").exists():
                yield path, b"gitlink:" + revision + b":uninitialized"
                continue
            actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path).strip()
            yield path, b"gitlink:" + revision + b":" + actual
            # A clean commit already identifies every tracked byte and nested
            # gitlink. Recurse only when the worktree has information not present
            # in that commit (modified/staged/untracked or dirty nested modules).
            status = subprocess.run(
                ["git", "status", "--porcelain=v1", "-z", "--untracked-files=all",
                 "--ignore-submodules=none"], cwd=path, check=True,
                capture_output=True,
            ).stdout
            if status:
                yield from git_files(path)
        elif mode == b"120000" or name in dirty:
            # Symlinks deliberately include their resolved bytes; dirty regular
            # paths include unstaged content/deletion/mode changes.
            yield path, file_digest(path)
        else:
            # Staged content is represented by the current index blob SHA, not
            # HEAD, so staged edits invalidate results without reading the file.
            yield path, b"index:" + mode + b":" + revision
    others = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root)
    for raw_name in others.split(b"\0"):
        if raw_name and os.fsdecode(raw_name) not in seen:
            path = root / os.fsdecode(raw_name)
            # Never make the result store or generated logs inputs to themselves.
            if not any(part in (".cache", "__pycache__", "node_modules", "target", "dist") for part in path.relative_to(ROOT).parts):
                yield path, file_digest(path)


def file_digest(path: Path) -> bytes:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return b"missing"
    mode = str(stat.S_IMODE(info.st_mode)).encode()
    if path.is_symlink():
        # Record link identity AND the data it resolves to; broken links differ.
        target = os.readlink(path).encode()
        if path.is_dir():
            raise ValueError(f"directory symlink requires explicit inputs: {path}")
        data = path.read_bytes() if path.is_file() else b"not-a-file"
        return b"link:" + mode + b":" + target + b":" + hashlib.sha256(data).digest()
    if not path.is_file():
        raise ValueError(f"not a regular input: {path}")
    return mode + b":" + hashlib.sha256(path.read_bytes()).digest()


@lru_cache(maxsize=1)
def tool_fingerprint() -> dict:
    versions = {}
    for name, args in TOOLS.items():
        executable = shutil.which(name)
        if not executable:
            versions[name] = "missing"
            continue
        if not args:
            versions[name] = hashlib.sha256(Path(executable).read_bytes()).hexdigest()
            continue
        result = subprocess.run([executable, *args], capture_output=True, timeout=15)
        versions[name] = [result.returncode, hashlib.sha256(result.stdout + result.stderr).hexdigest()]
    versions["python"] = sys.version
    versions["platform"] = [platform.system(), platform.machine(), platform.libc_ver()]
    # PyYAML is a host test dependency, not necessarily present in every job.
    try:
        import yaml
        versions["yaml"] = yaml.__version__
    except ImportError:
        versions["yaml"] = "missing"
    return versions


def fingerprint(scope: str, command: list[str]) -> str:
    roots = SCOPES.get(scope)
    selected = []
    operands = {arg for arg in command if (ROOT / arg).is_file()}
    for path, digest in git_files(ROOT):
        relative = path.relative_to(ROOT).as_posix()
        inputs = (*roots, *COMMON) if roots else ("",)
        if relative in operands or any(not prefix or relative == prefix or relative.startswith(prefix + "/") for prefix in inputs):
            selected.append((relative, digest.hex()))
    if not selected:
        raise ValueError("no test inputs found")
    environment = {key: os.environ.get(key, "") for key in ENV_KEYS}
    for key, value in os.environ.items():
        if key.startswith(("KAM_", "MAGICNET_", "SINGBOX_", "CARGO_", "RUST", "GO", "VITE_", "PLAYWRIGHT_", "npm_config_", "NPM_CONFIG_")):
            if not any(secret in key.upper() for secret in ("TOKEN", "SECRET", "PASSWORD", "PRIVATE_KEY", "AUTH")):
                environment[key] = value
    payload = {"schema": SCHEMA, "scope": scope, "command": command,
               "files": sorted(selected), "tools": tool_fingerprint(),
               "env": environment}
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def output_digest(paths: list[str]) -> str | None:
    files = []
    for name in paths:
        path = ROOT / name
        if not path.exists():
            return None
        if path.is_dir():
            children = sorted(p for p in path.rglob("*") if p.is_file() or p.is_symlink())
            if not children:
                return None
        else:
            children = [path]
        files.extend((p.relative_to(ROOT).as_posix(), file_digest(p).hex()) for p in children)
    return hashlib.sha256(json.dumps(files).encode()).hexdigest()


def run_check(command: list[str], timeout: int, name: str) -> int:
    print(f"[ci-test] RUN  {name}", flush=True)
    start = time.monotonic()
    # Successful negative cases stay in this log, not as misleading ERROR lines.
    # On failure print ALL diagnostics; never filter errors from a failed test.
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            result = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            result = 124
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        if result or os.environ.get("CI_TEST_VERBOSE") == "1":
            log.seek(0)
            shutil.copyfileobj(log, sys.stdout.buffer)
            sys.stdout.flush()
    label = "PASS" if result == 0 else "FAIL"
    print(f"[ci-test] {label} {name} ({time.monotonic() - start:.2f}s, exit={result})", flush=True)
    return result if result >= 0 else 128 - result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", action="append", default=[])
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--lookup-only", action="store_true",
                        help="return 0 for an exact reusable success and 1 for a miss without running")
    parser.add_argument("scope")
    parser.add_argument("name")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.timeout <= 0 or not re.fullmatch(r"[A-Za-z0-9_.-]+", args.name):
        parser.error("provide a safe check name, positive timeout, and a command")
    enabled = os.environ.get("CI_TEST_CACHE") == "1"
    force = os.environ.get("CI_TEST_FORCE") == "1"
    store = ROOT / ".cache" / "ci-test-results" / args.name
    key = None
    if enabled:
        try:
            key = fingerprint(args.scope, command)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f"[ci-test] cache unavailable; {'miss' if args.lookup_only else 'running ' + args.name}: {error}", flush=True)
    record = store / f"{key}.json"
    if key and not force:
        try:
            saved = json.loads(record.read_text())
            outputs = output_digest(args.output)
            if saved == {"schema": SCHEMA, "key": key, "outputs": outputs} and outputs is not None:
                print(f"[ci-test] HIT  {args.name} {key[:12]}", flush=True)
                return 0
        except (OSError, ValueError):
            pass
    if args.lookup_only:
        suffix = f" {key[:12]}" if key else ""
        print(f"[ci-test] MISS {args.name}{suffix}", flush=True)
        return 1
    if key:
        # An explicit recheck/failure must revoke an earlier pass for this key.
        try:
            record.unlink(missing_ok=True)
        except OSError as error:
            print(f"[ci-test] cannot revoke record; cache disabled: {error}", flush=True)
            key = None
    result = run_check(command, args.timeout, args.name)
    if result == 0 and key:
        # Tests that mutate their inputs must not leave reusable success records.
        try:
            outputs = output_digest(args.output)
            if outputs is not None and fingerprint(args.scope, command) == key:
                store.mkdir(parents=True, exist_ok=True)
                fd, temporary = tempfile.mkstemp(dir=store, prefix=".pending-")
                try:
                    with os.fdopen(fd, "w") as stream:
                        json.dump({"schema": SCHEMA, "key": key, "outputs": outputs}, stream)
                    os.replace(temporary, record)
                finally:
                    Path(temporary).unlink(missing_ok=True)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f"[ci-test] result not cached: {error}", flush=True)
    return result


if __name__ == "__main__":
    sys.exit(main())

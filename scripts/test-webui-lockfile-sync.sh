#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# hooks/pre-build/2000.BUILD_WEBUI.sh (the release build) and
# scripts/pre-commit.sh both prefer bun over npm whenever bun is installed,
# and install with --frozen-lockfile, which refuses to touch the lockfile and
# fails outright if it has drifted from package.json. npm-based CI (webui.yml,
# quality.yml) never exercises that path, so a dependency-only change to
# webui/package.json can merge green and only break the bun-based build/hook
# later. Catch that drift here instead.
if ! command -v bun >/dev/null 2>&1; then
    printf 'bun is not installed; skipping webui/bun.lock sync check\n'
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/webui/package.json" "$ROOT/webui/bun.lock" "$WORK/"

if ! (cd "$WORK" && bun install --frozen-lockfile) >"$WORK/bun-install.log" 2>&1; then
    cat "$WORK/bun-install.log" >&2
    printf 'webui/bun.lock is out of sync with webui/package.json; run "cd webui && bun install" and commit the refreshed lockfile\n' >&2
    exit 1
fi

printf 'webui bun.lock sync check passed\n'

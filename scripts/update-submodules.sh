#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Resolve every configured tracking branch once, before tests/cache keys/builds.
# Ignore shallow recommendations so non-default tracking branches are fetched.
# Failed fetches abort the build instead of silently reusing an old gitlink.
git submodule sync --recursive
git submodule update --init --remote --recursive --checkout --no-recommend-shallow

git submodule status --recursive >submodule-revisions.txt
cat submodule-revisions.txt
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        printf '### Submodule revisions used by this build\n\n```text\n'
        cat submodule-revisions.txt
        printf '```\n'
    } >>"$GITHUB_STEP_SUMMARY"
fi

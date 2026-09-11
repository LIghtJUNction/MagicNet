#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'usage: bash scripts/update-build-submodules.sh <revision-manifest>\n' >&2
    exit 64
fi
manifest="$1"
: >"$manifest"

# --remote follows .gitmodules branch settings (sing-box: testing), falling
# back to the remote HEAD when no branch is configured. Never reuse stale
# revisions after a failed fetch. --checkout also ignores merge/rebase modes.
git submodule sync --recursive
# Do not let shallow recommendations clone only the remote default branch:
# the configured tracking branch may differ (for example main vs testing).
git submodule update --init --recursive --remote --checkout --no-recommend-shallow
# shellcheck disable=SC2016
git submodule foreach --quiet --recursive \
    'printf "%s %s\n" "$(git rev-parse HEAD)" "$displaypath"' | tee "$manifest"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        printf '### Build submodule revisions\n\n```text\n'
        cat "$manifest"
        printf '```\n'
    } >>"$GITHUB_STEP_SUMMARY"
fi

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
"")
    cd "$ROOT"
    MAGICNET_SUBMODULE_UPDATE_SCRIPT="$ROOT/scripts/update-submodules.sh"
    export MAGICNET_SUBMODULE_UPDATE_SCRIPT
    ;;
--nested) ;;
*) printf 'usage: bash scripts/update-submodules.sh\n' >&2; exit 64 ;;
esac

# Update one level at a time: a parent's new .gitmodules may change child
# URLs/branches. Initialize children only after checking out that parent.
git submodule sync
git submodule update --init --checkout --no-single-branch
git submodule foreach '
    set -eu
    # Shallow checkout can otherwise fetch only the default branch, leaving
    # a configured non-default branch such as sing-box/testing unresolved.
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    git fetch --prune origin
    git remote set-head origin --auto
'
# Every child was just fetched; resolve .gitmodules branches or remote HEAD.
# A fetch failure above aborts the run rather than building a stale revision.
git submodule update --remote --no-fetch --checkout
git submodule foreach --quiet 'bash "$MAGICNET_SUBMODULE_UPDATE_SCRIPT" --nested'

if [[ $# -eq 0 ]]; then
    git submodule status --recursive
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            printf '\n### Build submodule revisions\n\n```text\n'
            git submodule status --recursive
            printf '```\n'
        } >>"$GITHUB_STEP_SUMMARY"
    fi
fi

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
"")
    cd "$ROOT"
    MAGICNET_SUBMODULE_UPDATE_SCRIPT="$ROOT/scripts/update-submodules.sh"
    export MAGICNET_SUBMODULE_UPDATE_SCRIPT
    # A failed refresh must not leave a prior build's snapshot looking current.
    rm -f "$ROOT/submodule-revisions.txt"
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
    git fetch --no-recurse-submodules --prune origin
    git remote set-head origin --auto
'
# Every child was just fetched. Remote-tracking submodules move to their
# configured branch (or remote HEAD), while explicitly pinned submodules stay
# at the superproject gitlink so immutable config/template pins cannot drift.
while read -r key path; do
    name="${key#submodule.}"
    name="${name%.path}"
    pinned="$(git config -f .gitmodules --bool --get "submodule.$name.magicnet-pinned" 2>/dev/null || true)"
    if [[ "$pinned" == "true" ]]; then
        printf 'Keeping pinned submodule %s at recorded gitlink\n' "$path"
        continue
    fi
    git submodule update --remote --no-fetch --checkout -- "$path"
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
# Expand the exported path inside each child shell, preserving spaces.
# shellcheck disable=SC2016
git submodule foreach --quiet 'bash "$MAGICNET_SUBMODULE_UPDATE_SCRIPT" --nested'

if [[ $# -eq 0 ]]; then
    git submodule status --recursive >"$ROOT/submodule-revisions.txt"
    cat "$ROOT/submodule-revisions.txt"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            printf '\n### Build submodule revisions\n\n```text\n'
            cat "$ROOT/submodule-revisions.txt"
            printf '```\n'
        } >>"$GITHUB_STEP_SUMMARY"
    fi
fi

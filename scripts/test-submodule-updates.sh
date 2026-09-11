#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Only these disposable local repositories may use the file transport.
export GIT_ALLOW_PROTOCOL=file
export GIT_AUTHOR_NAME=fixture GIT_COMMITTER_NAME=fixture
export GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_EMAIL=fixture@example.invalid
new_repo() { git init -q -b main "$1"; }
commit_file() {
    printf '%s\n' "$2" >"$1/content"
    git -C "$1" add content
    git -C "$1" commit -qm "$2"
}
new_repo "$WORK/leaf"
commit_file "$WORK/leaf" old-leaf
new_repo "$WORK/dependency"
commit_file "$WORK/dependency" old-dependency
git -C "$WORK/dependency" submodule add -q "$WORK/leaf" nested
git -C "$WORK/dependency" commit -qam nested
git -C "$WORK/dependency" checkout -qb testing
commit_file "$WORK/dependency" old-testing
new_repo "$WORK/project"
commit_file "$WORK/project" project
git -C "$WORK/project" submodule add -q "$WORK/dependency" dependency
git -C "$WORK/project" submodule add -q "$WORK/leaf" default-branch
git -C "$WORK/project" config -f .gitmodules submodule.dependency.branch testing
git -C "$WORK/project" config -f .gitmodules submodule.dependency.shallow true
git -C "$WORK/project" add .
git -C "$WORK/project" commit -qm submodules
parent=$(git -C "$WORK/project" rev-parse HEAD)
commit_file "$WORK/dependency" latest-testing
commit_file "$WORK/leaf" latest-leaf
expected_dependency=$(git -C "$WORK/dependency" rev-parse HEAD)
# CI starts without initialized submodules; testing is not the remote HEAD.
git -C "$WORK/dependency" checkout -q main
git clone -q --no-recurse-submodules "$WORK/project" "$WORK/checkout"
mkdir -p "$WORK/checkout/scripts"
cp "$ROOT/scripts/update-submodules.sh" "$ROOT/scripts/verify-submodule-revisions.sh" "$WORK/checkout/scripts/"
export GITHUB_STEP_SUMMARY="$WORK/summary"
verify() { bash "$WORK/checkout/scripts/verify-submodule-revisions.sh"; }
reject_snapshot() {
    if verify >>"$WORK/verify.log" 2>&1; then
        printf 'submodule integrity accepted %s\n' "$1" >&2
        exit 1
    fi
}
check_snapshot() {
    local expected_leaf
    expected_leaf=$(git -C "$WORK/leaf" rev-parse HEAD)
    [ "$(git -C "$WORK/checkout/dependency" rev-parse HEAD)" = "$expected_dependency" ]
    for path in default-branch dependency/nested; do
        [ "$(git -C "$WORK/checkout/$path" rev-parse HEAD)" = "$expected_leaf" ]
        grep -Fq "$expected_leaf $path" "$WORK/checkout/submodule-revisions.txt"
    done
    [ "$(git -C "$WORK/checkout" rev-parse HEAD)" = "$parent" ]
    git -C "$WORK/checkout" diff --cached --exit-code
    verify >>"$WORK/verify.log"
}
bash "$WORK/checkout/scripts/update-submodules.sh" >"$WORK/update.log" 2>&1
check_snapshot
commit_file "$WORK/leaf" next-build-leaf
bash "$WORK/checkout/scripts/update-submodules.sh" >>"$WORK/update.log" 2>&1
check_snapshot
grep -Fq "$expected_dependency dependency" "$WORK/summary"

# Integrity follows the resolved snapshot, including nested modules, not old pins.
expected_leaf=$(git -C "$WORK/leaf" rev-parse HEAD)
git -C "$WORK/checkout/dependency/nested" checkout -q HEAD^
reject_snapshot 'nested checkout drift'
git -C "$WORK/checkout/dependency/nested" checkout -q "$expected_leaf"
cp "$WORK/checkout/submodule-revisions.txt" "$WORK/snapshot"
: >"$WORK/checkout/submodule-revisions.txt"
reject_snapshot 'an empty snapshot'
rm "$WORK/checkout/submodule-revisions.txt"
reject_snapshot 'unrecorded remote updates'
cp "$WORK/snapshot" "$WORK/checkout/submodule-revisions.txt"
verify >>"$WORK/verify.log"
git -C "$WORK/checkout" submodule deinit -q -f default-branch
reject_snapshot 'an uninitialized module'
bash "$WORK/checkout/scripts/update-submodules.sh" >>"$WORK/update.log" 2>&1
check_snapshot

# A normal pinned checkout is still valid without a remote-update manifest.
git clone -q --recurse-submodules "$WORK/project" "$WORK/pinned" >"$WORK/pinned.log" 2>&1
mkdir -p "$WORK/pinned/scripts"
cp "$ROOT/scripts/verify-submodule-revisions.sh" "$WORK/pinned/scripts/"
bash "$WORK/pinned/scripts/verify-submodule-revisions.sh" >>"$WORK/verify.log"

# A failed fetch must never be treated as a successful build using old sources.
git -C "$WORK/checkout" config -f .gitmodules submodule.default-branch.url "$WORK/missing"
if bash "$WORK/checkout/scripts/update-submodules.sh" >>"$WORK/update.log" 2>&1; then
    printf '%s\n' 'submodule fetch failure was ignored' >&2
    exit 1
fi
printf '%s\n' 'Remote submodule update regressions passed'

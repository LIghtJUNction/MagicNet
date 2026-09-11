#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Only these isolated fixture repositories may use the file transport.
export GIT_CONFIG_COUNT=4
export GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=fixture
export GIT_CONFIG_KEY_2=user.email GIT_CONFIG_VALUE_2=fixture@example.invalid
export GIT_CONFIG_KEY_3=commit.gpgsign GIT_CONFIG_VALUE_3=false
export GITHUB_STEP_SUMMARY="$WORK/summary"

commit_file() {
    printf '%s\n' "$2" >"$1/value"
    git -C "$1" add .
    git -C "$1" commit -qm "$2"
}
for repo in leaf dependency parent; do
    git init -q --initial-branch=main "$WORK/$repo"
    commit_file "$WORK/$repo" initial
done
# The nested dependency has no branch override and follows remote HEAD.
git -C "$WORK/dependency" submodule add -q "file://$WORK/leaf" nested
git -C "$WORK/dependency" commit -qam 'pin nested dependency'
git -C "$WORK/dependency" switch -qc testing
commit_file "$WORK/dependency" testing-initial
git -C "$WORK/parent" submodule add -q -b testing "file://$WORK/dependency" dependency
git -C "$WORK/parent" config -f .gitmodules submodule.dependency.shallow true
git -C "$WORK/parent" commit -qam 'pin dependency'
pinned="$(git -C "$WORK/parent" rev-parse HEAD:dependency)"
# A fresh Actions checkout does not initialize pinned submodules.
git clone -q "$WORK/parent" "$WORK/checkout"
cd "$WORK/checkout"

for generation in newer newest; do
    commit_file "$WORK/leaf" "$generation"
    git -C "$WORK/dependency" switch -q testing
    commit_file "$WORK/dependency" "$generation"
    # The remote default differs from the configured shallow tracking branch.
    git -C "$WORK/dependency" switch -q main
    bash "$ROOT/scripts/update-build-submodules.sh" "$WORK/revisions" >"$WORK/update.log" 2>&1 || {
        cat "$WORK/update.log" >&2
        exit 1
    }
    [ "$(git -C dependency rev-parse HEAD)" = "$(git -C "$WORK/dependency" rev-parse testing)" ]
    [ "$(git -C dependency/nested rev-parse HEAD)" = "$(git -C "$WORK/leaf" rev-parse HEAD)" ]
    grep -Fxq "$(git -C dependency rev-parse HEAD) dependency" "$WORK/revisions"
    grep -Fxq "$(git -C dependency/nested rev-parse HEAD) dependency/nested" "$WORK/revisions"
    [ "$(git rev-parse HEAD:dependency)" = "$pinned" ]
done

# A fetch failure must fail the build, not accept the previous cached HEAD.
git config -f .gitmodules submodule.dependency.url "$WORK/missing.git"
if bash "$ROOT/scripts/update-build-submodules.sh" "$WORK/revisions" >"$WORK/failure.log" 2>&1; then
    printf 'submodule fetch failure was ignored\n' >&2
    exit 1
fi
[ ! -s "$WORK/revisions" ] || { printf 'stale revision manifest survived fetch failure\n' >&2; exit 1; }
grep -Fq 'Build submodule revisions' "$WORK/summary"
printf 'Latest recursive build submodule tests passed\n'

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
for repo in inner leaf dependency parent; do
    git init -q --initial-branch=main "$WORK/$repo"
    commit_file "$WORK/$repo" initial
done
# Include a deeper submodule and a space in its path to exercise recursion.
git -C "$WORK/leaf" submodule add -q "file://$WORK/inner" 'deep child'
git -C "$WORK/leaf" commit -qam 'pin deep dependency'
# The nested dependency has no branch override and follows remote HEAD.
git -C "$WORK/dependency" submodule add -q "file://$WORK/leaf" nested
git -C "$WORK/dependency" commit -qam 'pin nested dependency'
git -C "$WORK/dependency" switch -qc testing
mkdir -p "$WORK/dependency/release"
printf 'module github.com/sagernet/sing-box\n' >"$WORK/dependency/go.mod"
printf 'with_ebpf\n' >"$WORK/dependency/release/DEFAULT_BUILD_TAGS_OTHERS"
printf '%s\n' '-checklinkname=0' >"$WORK/dependency/release/LDFLAGS"
commit_file "$WORK/dependency" testing-initial
git -C "$WORK/parent" submodule add -q -b testing "file://$WORK/dependency" dependency
git -C "$WORK/parent" config -f .gitmodules submodule.dependency.shallow true
git -C "$WORK/parent" commit -qam 'pin dependency'
pinned="$(git -C "$WORK/parent" rev-parse HEAD:dependency)"
# A fresh Actions checkout does not initialize pinned submodules.
git clone -q "$WORK/parent" "$WORK/checkout"
cd "$WORK/checkout"

for generation in newer newest; do
    commit_file "$WORK/inner" "$generation"
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
    [ "$(git -C 'dependency/nested/deep child' rev-parse HEAD)" = "$(git -C "$WORK/inner" rev-parse HEAD)" ]
    grep -Fxq "$(git -C 'dependency/nested/deep child' rev-parse HEAD) dependency/nested/deep child" "$WORK/revisions"
    [ "$(git rev-parse HEAD:dependency)" = "$pinned" ]
done

# Exercise the production build entry point after refreshing nested gitlinks.
# Git is real; only the compiler is stubbed so host tests need no Go toolchain.
mkdir -p "$WORK/bin"
export FAKE_GO_CALLED="$WORK/go-called"
cat >"$WORK/bin/go" <<'SH'
#!/bin/sh
set -eu
[ "$1" = build ] || exit 64
: >"$FAKE_GO_CALLED"
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        printf 'fixture binary\n' >"$2"
        exit 0
    fi
    shift
done
exit 64
SH
chmod +x "$WORK/bin/go"

build_fixture() {
    PATH="$WORK/bin:$PATH" MAGICNET_SINGBOX_SOURCE_DIR="$WORK/checkout/dependency" \
        bash "$ROOT/scripts/build-sing-box.sh" linux amd64 "$WORK/output"
}
assert_rejected() {
    rm -f "$FAKE_GO_CALLED"
    if build_fixture >"$WORK/rejected.log" 2>&1; then
        printf 'dirty source was accepted: %s\n' "$1" >&2
        exit 1
    fi
    grep -Fq 'uncommitted changes' "$WORK/rejected.log"
    [ ! -e "$FAKE_GO_CALLED" ] || { printf 'dirty source reached the compiler\n' >&2; exit 1; }
}

[ -n "$(git -C dependency status --porcelain --ignore-submodules=none)" ]
if ! build_fixture >"$WORK/build.log" 2>&1; then
    cat "$WORK/build.log" >&2
    exit 1
fi
[ -x "$WORK/output" ] && [ -e "$FAKE_GO_CALLED" ]
grep -Fxq "LIghtJUNction/sing-box@$(git -C dependency rev-parse HEAD)" "$WORK/build.log"
# User ignore settings must not conceal edits in any nested working tree.
git -C dependency config submodule.nested.ignore all
for tree in dependency dependency/nested 'dependency/nested/deep child'; do
    printf 'local edit\n' >>"$tree/value"
    assert_rejected "$tree: unstaged edit"
    grep -Fxq 'local edit' "$tree/value"
    git -C "$tree" add value
    assert_rejected "$tree: staged edit"
    git -C "$tree" restore --source=HEAD --staged --worktree -- value
    printf 'untracked source\n' >"$tree/untracked.go"
    assert_rejected "$tree: untracked file"
    rm -f "$tree/untracked.go"
done
# Only checked-out gitlink drift is allowed; staging a different gitlink is
# still an uncommitted index change, even with submodule ignore configured.
git -C dependency add nested
assert_rejected 'staged gitlink'
git -C dependency restore --source=HEAD --staged -- nested
build_fixture >"$WORK/restored.log" 2>&1
# Neither preflight nor compilation may reset the freshly resolved commits.
# shellcheck disable=SC2016
git submodule foreach --quiet --recursive \
    'printf "%s %s\n" "$(git rev-parse HEAD)" "$displaypath"' | diff "$WORK/revisions" -

# A fetch failure must fail the build, not accept the previous cached HEAD.
git config -f .gitmodules submodule.dependency.url "$WORK/missing.git"
if bash "$ROOT/scripts/update-build-submodules.sh" "$WORK/revisions" >"$WORK/failure.log" 2>&1; then
    printf 'submodule fetch failure was ignored\n' >&2
    exit 1
fi
[ ! -s "$WORK/revisions" ] || { printf 'stale revision manifest survived fetch failure\n' >&2; exit 1; }
grep -Fq 'Build submodule revisions' "$WORK/summary"
printf 'Latest recursive build submodule tests passed\n'

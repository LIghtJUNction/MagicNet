#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'sing-box source regression failed: %s\n' "$*" >&2; exit 1; }
init_repo() {
    git init -q -b main "$1"
    git -C "$1" config user.name 'MagicNet Test'
    git -C "$1" config user.email 'test@example.invalid'
    printf 'fixture\n' >"$1/README"
    git -C "$1" add README
    git -C "$1" commit -qm 'initial fixture'
}

# Real local Git repositories exercise recursive gitlink updates without network.
init_repo "$WORK/leaf"
init_repo "$WORK/client"
git -c protocol.file.allow=always -C "$WORK/client" submodule add -q "$WORK/leaf" 'sdk files'
git -C "$WORK/client" commit -qam 'add nested SDK'
init_repo "$WORK/source"
mkdir -p "$WORK/source/release" "$WORK/project/scripts" "$WORK/bin"
printf 'module github.com/sagernet/sing-box\n' >"$WORK/source/go.mod"
printf 'with_ebpf\n' >"$WORK/source/release/DEFAULT_BUILD_TAGS_OTHERS"
printf '%s\n' '-checklinkname=0' >"$WORK/source/release/LDFLAGS"
git -c protocol.file.allow=always -C "$WORK/source" submodule add -q "$WORK/client" clients/android
git -C "$WORK/source" add .
git -C "$WORK/source" commit -qm 'add core and client fixture'
git -c protocol.file.allow=always -C "$WORK/source" submodule update --init --recursive >/dev/null 2>&1
cp "$ROOT/scripts/build-sing-box.sh" "$WORK/project/scripts/"
printf '1.0.0\n' >"$WORK/project/sing-box.version"

# Stub only the compiler; the actual build script and Git checks run unchanged.
cat >"$WORK/bin/go" <<'STUB'
#!/bin/sh
printf 'called\n' >"$BUILD_TEST_COMPILER_CALLED"
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        shift
        printf 'fixture binary\n' >"$1"
        exit 0
    fi
    shift
done
exit 64
STUB
chmod +x "$WORK/bin/go"
export PATH="$WORK/bin:$PATH"
export BUILD_TEST_COMPILER_CALLED="$WORK/compiler-called"
export MAGICNET_SINGBOX_SOURCE_DIR="$WORK/source"
build() {
    bash "$WORK/project/scripts/build-sing-box.sh" linux amd64 "$WORK/output" >"$WORK/build.log" 2>&1
}
accept() {
    rm -f "$BUILD_TEST_COMPILER_CALLED"
    build || { cat "$WORK/build.log" >&2; fail "$1"; }
    [[ -s "$BUILD_TEST_COMPILER_CALLED" && -x "$WORK/output" ]] || fail "$1: compiler was not reached"
}
reject() {
    rm -f "$BUILD_TEST_COMPILER_CALLED"
    if build; then fail "$1: dirty source accepted"; fi
    grep -Fq 'source submodule has uncommitted changes' "$WORK/build.log" || fail "$1: wrong failure"
    [[ ! -e "$BUILD_TEST_COMPILER_CALLED" ]] || fail "$1: compiler ran with dirty source"
    grep -Fxq 'fixture binary' "$WORK/output" || fail "$1: existing output changed"
}

accept 'clean source'
printf 'remote update\n' >>"$WORK/leaf/README"
git -C "$WORK/leaf" commit -qam 'advance SDK remote'
printf 'remote update\n' >>"$WORK/client/README"
git -C "$WORK/client" commit -qam 'advance client remote'
git -c protocol.file.allow=always -C "$WORK/source" submodule update --remote --recursive >/dev/null 2>&1
[[ -n "$(git -C "$WORK/source" status --porcelain)" ]] || fail 'fixture did not advance gitlinks'
accept 'committed recursive submodule updates'

for repo in "$WORK/source" "$WORK/source/clients/android" "$WORK/source/clients/android/sdk files"; do
    printf 'dirty\n' >>"$repo/README"
    reject "unstaged source: $repo"
    git -C "$repo" add README
    reject "staged source: $repo"
    git -C "$repo" restore --staged --worktree README
    printf 'untracked\n' >"$repo/untracked.go"
    reject "untracked source: $repo"
    rm "$repo/untracked.go"
done

git -C "$WORK/source" add clients/android
reject 'staged gitlink change'
git -C "$WORK/source" restore --staged clients/android
accept 'restored source with latest submodules'
printf 'sing-box source cleanliness regressions passed\n'

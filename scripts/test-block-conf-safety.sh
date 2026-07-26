#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
blocklist="$repo_root/src/MagicNet/lib/magicnet/blocklist.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-block-conf-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

export MODDIR="$test_dir/module"
conf="$MODDIR/.config/magicnet/block.conf"
marker="$test_dir/injected-marker"
default_url='https://raw.githubusercontent.com/LIghtJUNction/MagicNet/main/src/MagicNet/.config/magicnet/community-ban.yaml'

mkdir -p "$(dirname "$conf")"
# This only loads function definitions. The assertions invoke the parser
# directly and never touch a device runtime or network endpoint.
# shellcheck source=../src/MagicNet/lib/magicnet/blocklist.sh
. "$blocklist"

assert_eq() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    if [[ "$actual" != "$expected" ]]; then
        printf 'assertion failed: %s\n' "$label" >&2
        exit 1
    fi
}

printf '%s\n' \
    'MAGICNET_BLOCK_ENABLED=0' \
    'MAGICNET_BLOCK_COMMUNITY_ENABLED=1' \
    'MAGICNET_BLOCK_URL=https://example.com/community.yaml?profile=phone' \
    >"$conf"
magicnet_block_load_conf
assert_eq "$MAGICNET_BLOCK_ENABLED" '0' 'valid enabled flag'
assert_eq "$MAGICNET_BLOCK_COMMUNITY_ENABLED" '1' 'valid community flag'
assert_eq "$MAGICNET_BLOCK_URL" 'https://example.com/community.yaml?profile=phone' 'valid URL'

printf '%s\n' \
    'MAGICNET_BLOCK_ENABLED=0' \
    'MAGICNET_BLOCK_COMMUNITY_ENABLED=0' \
    "MAGICNET_BLOCK_URL=https://example.com/list; touch '$marker'" \
    >"$conf"
magicnet_block_load_conf
[[ ! -e "$marker" ]] || {
    printf 'injected block.conf command executed\n' >&2
    exit 1
}
assert_eq "$MAGICNET_BLOCK_ENABLED" '1' 'injected config uses safe enabled default'
assert_eq "$MAGICNET_BLOCK_COMMUNITY_ENABLED" '1' 'injected config uses safe community default'
assert_eq "$MAGICNET_BLOCK_URL" "$default_url" 'injected config uses safe URL default'

printf '%s\n' \
    'MAGICNET_BLOCK_ENABLED=0' \
    'MAGICNET_BLOCK_ENABLED=1' \
    'MAGICNET_BLOCK_COMMUNITY_ENABLED=0' \
    'MAGICNET_BLOCK_URL=https://example.com/community.yaml' \
    >"$conf"
magicnet_block_load_conf
assert_eq "$MAGICNET_BLOCK_ENABLED" '1' 'duplicate field is rejected'
assert_eq "$MAGICNET_BLOCK_URL" "$default_url" 'duplicate field resets URL'

printf '%s\n' \
    'MAGICNET_BLOCK_ENABLED=0' \
    'MAGICNET_BLOCK_COMMUNITY_ENABLED=0' \
    'MAGICNET_BLOCK_URL=https://example.com/community.yaml' \
    'UNEXPECTED_BLOCK_SETTING=1' \
    >"$conf"
magicnet_block_load_conf
assert_eq "$MAGICNET_BLOCK_ENABLED" '1' 'unknown field is rejected'
assert_eq "$MAGICNET_BLOCK_URL" "$default_url" 'unknown field resets URL'

printf 'block.conf parser safety test passed\n'

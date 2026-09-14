#!/bin/sh
set -eu

SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" != "$0" ] || SCRIPT_DIR=.
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
HELPER="$ROOT/src/MagicNet/lib/magicnet/install_onboarding.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

MODPATH="$TMP/module"
export MODPATH
mkdir -p "$MODPATH/.config/sing-box" "$MODPATH/lib/magicnet/onboarding"
: >"$MODPATH/lib/magicnet/onboarding/messages.sh"

# Only the decision logic is under test here. The full browser/CGI path remains
# covered by install-onboarding-test.py and the Playwright workflow.
# shellcheck source=/dev/null
. "$HELPER"
magicnet_onboarding_allowed() { return 0; }
magicnet_onboarding_collect() {
    printf '%s\n' collected >"$TMP/collected"
    return 0
}

printf '%s\n' 'https://existing.example.test/sub' >"$MODPATH/.config/sing-box/subscription.url"
magicnet_install_onboarding || fail 'routine upgrade fast path failed'
[ ! -e "$TMP/collected" ] || fail 'routine upgrade unexpectedly opened onboarding'

rm -f "$MODPATH/.config/sing-box/subscription.url" "$TMP/collected"
magicnet_install_onboarding || fail 'fresh install onboarding failed'
[ -f "$TMP/collected" ] || fail 'fresh install did not open onboarding'

rm -f "$TMP/collected"
printf '%s\n' 'https://existing.example.test/sub' >"$MODPATH/.config/sing-box/subscription.url"
MAGICNET_SETUP=force
export MAGICNET_SETUP
magicnet_install_onboarding || fail 'forced upgrade onboarding failed'
[ -f "$TMP/collected" ] || fail 'forced upgrade did not open onboarding'

printf '%s\n' 'ok - install onboarding fast paths'

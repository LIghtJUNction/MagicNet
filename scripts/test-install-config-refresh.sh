#!/usr/bin/env bash
# Migration contract tests. The subscription generator/core are controlled
# fixtures here; their protocol and policy behavior have separate runtime tests.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MODPATH="$TMP/module" MAGICNET_BACKUP_DIR="$TMP/previous" ZIPFILE="$TMP/module.zip"
mkdir -p "$MODPATH"/{bin,lib,.config/sing-box,.state/sing-box/subscription-work} \
    "$MAGICNET_BACKUP_DIR/.config/sing-box"
CONFIG="$MODPATH/.config/sing-box/config.json"
PREVIOUS="$MAGICNET_BACKUP_DIR/.config/sing-box/config.json"
CACHE="$MODPATH/.state/sing-box/subscription-work/outbounds.json"
MARKER="$MODPATH/.config/sing-box/standalone-config"
export CONFIG
python3 - "$ZIPFILE" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('.config/sing-box/config.json', '{"dns":{"tag":"new"},"route":{"final":"proxy"},"inbounds":[{"type":"tun"}],"outbounds":[]}')
PY
cat >"$MODPATH/lib/magicnet_singbox_subscribe.sh" <<'FIXTURE'
magicnet_singbox_build_outbounds_file_with_jq() {
    [ -f "$2" ] || return 1
    jq '[.[] | select(.type == "trojan" and .tag != "HK filtered")] + [{"type":"selector","tag":"proxy","default":"new-policy"}]' "$1" >"$3"
}
magicnet_singbox_update_config_with_nodes() (
    trap 'rm -f "${MAGICNET_SUB_CONFIG_FILE}.new"' 0
    jq --slurpfile nodes "$1" '.outbounds = $nodes[0]' \
        "$MAGICNET_SUB_CONFIG_FILE" >"${MAGICNET_SUB_CONFIG_FILE}.new" || return 1
    sing-box check -c "${MAGICNET_SUB_CONFIG_FILE}.new" -D "${MAGICNET_SUB_CONFIG_FILE%/*}" || return 1
    mv "${MAGICNET_SUB_CONFIG_FILE}.new" "$MAGICNET_SUB_CONFIG_FILE"
)
FIXTURE
cat >"$MODPATH/bin/sing-box" <<'FIXTURE'
#!/bin/sh
[ "${REJECT_CONFIG:-0}" != 1 ] || exit 1
[ "$1" = check ] && [ "$2" = -c ] && [ "$4" = -D ] && [ "$5" = "${CONFIG%/*}" ] || exit 1
jq -e 'type == "object"' "$3" >/dev/null
FIXTURE
chmod +x "$MODPATH/bin/sing-box"
cat >"$TMP/runner.sh" <<'SHRUN'
set -eu
info() { printf '%s\n' "$*"; }
error() { printf '%s\n' "$*" >&2; }
. "$1"
magicnet_refresh_install_config
SHRUN
run_refresh() { "${TEST_SHELL:-sh}" "$TMP/runner.sh" "$ROOT/src/MagicNet/lib/magicnet/install_config.sh" >"$TMP/log" 2>&1; }
expect_failure() { if run_refresh; then echo 'expected migration failure' >&2; exit 1; fi; }
no_temporary_files() {
    [[ -z "$(find "$MODPATH" -name 'install-config.*' -o -name '*.install-new.*')" ]]
}
# Fresh install: use the ZIP even if an unrelated config already exists.
printf '%s\n' '{"old":true}' >"$CONFIG"
run_refresh
jq -e '.dns.tag == "new" and (has("old") | not)' "$CONFIG" >/dev/null
[[ "$(stat -c %a "$CONFIG")" == 600 ]]
# Preserve source files byte-for-byte; no network access is needed.
for item in subscription.url subscription.local subscription.user-agent subscription-filter.list; do
    printf 'saved-%s\n' "$item" >"$MODPATH/.config/sing-box/$item"
done
printf '%s\n' '{"old":true,"dns":{"tag":"old"},"outbounds":[{"type":"trojan","tag":"US saved","server":"node.example","server_port":443,"password":"fixture-secret"}]}' >"$PREVIOUS"
printf '%s\n' '[{"type":"trojan","tag":"US cached","server":"node.example","server_port":443,"password":"fixture-secret"},{"type":"trojan","tag":"HK filtered","server":"hk.example","server_port":443,"password":"fixture-secret"},{"type":"selector","tag":"proxy","default":"old-policy"}]' >"$CACHE"
run_refresh
jq -e '.dns.tag == "new" and .inbounds[0].type == "tun" and .route.final == "proxy" and (has("old") | not) and any(.outbounds[]; .tag == "US cached" and .password == "fixture-secret") and any(.outbounds[]; .tag == "proxy" and .default == "new-policy") and all(.outbounds[]; .tag != "HK filtered")' "$CONFIG" >/dev/null
cmp "$PREVIOUS" "$CONFIG.pre-upgrade"
[[ "$(stat -c %a "$CONFIG.pre-upgrade")" == 600 ]]
for item in subscription.url subscription.local subscription.user-agent subscription-filter.list; do
    [[ "$(cat "$MODPATH/.config/sing-box/$item")" == "saved-$item" ]]
done
! grep -q 'fixture-secret' "$TMP/log"
no_temporary_files
# Corrupt/missing caches fall back to nodes from the previous full config.
printf 'broken cache\n' >"$CACHE"
: >"$MARKER"
run_refresh
jq -e 'any(.outbounds[]; .tag == "US saved")' "$CONFIG" >/dev/null
[[ ! -e "$MARKER" ]]
rm "$CACHE"
run_refresh
# Legacy cached fragments are still usable.
printf '"outbounds": [{"type":"trojan","tag":"US legacy","server":"node.example","server_port":443,"password":"fixture-secret"}],\n' >"$CACHE"
run_refresh
jq -e 'any(.outbounds[]; .tag == "US legacy")' "$CONFIG" >/dev/null
# Failed validation leaves both the existing file and standalone marker intact.
cp "$CONFIG" "$TMP/before"
: >"$MARKER"
export REJECT_CONFIG=1
expect_failure
unset REJECT_CONFIG
cmp "$CONFIG" "$TMP/before"
[[ -f "$MARKER" ]]
no_temporary_files
# A broken ZIP or unsafe backup path must never overwrite the active config.
SAVED_ZIP="$ZIPFILE"; export ZIPFILE="$TMP/missing.zip"
expect_failure
cmp "$CONFIG" "$TMP/before"
export ZIPFILE="$SAVED_ZIP"
rm "$CONFIG.pre-upgrade"
ln -s "$TMP/before" "$CONFIG.pre-upgrade"
expect_failure
cmp "$CONFIG" "$TMP/before"
rm "$CONFIG.pre-upgrade"
# Unsupported standalone configurations fail instead of silently losing access.
printf '{"outbounds":[]}\n' >"$PREVIOUS"
rm "$CACHE"
expect_failure
cmp "$CONFIG" "$TMP/before"
no_temporary_files
# The installer snapshots the old file, restores subscriptions, then rebuilds.
python3 - "$ROOT/src/MagicNet/customize.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
a, b = s.split('if [ "$MAGICNET_BACKUP_READY" = 1 ]; then', 1)
assert '".config/sing-box/config.json"' in a
assert '".config/sing-box/config.json"' not in b.split('# The repository selector', 1)[0]
assert 'confirm_update_file' not in s
assert b.index('magicnet_refresh_install_config ||') < b.index('magicnet_cleanup_install_backup ||')
PY
printf '%s\n' 'install config refresh: all migration contract checks passed'

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
    z.writestr('.config/sing-box/rules/fixture.srs', 'fixture')
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
cp "$(command -v jq)" "$MODPATH/bin/jq"
cat >"$MODPATH/bin/sing-box" <<'FIXTURE'
#!/bin/sh
[ "${REJECT_CONFIG:-0}" != 1 ] || exit 1
[ "$1" = check ] && [ "$2" = -c ] && [ "$4" = -D ] && [ "$5" = "${3%/*}" ] || exit 1
[ -s "$5/rules/fixture.srs" ] || exit 1
jq -e 'type == "object"' "$3" >/dev/null
FIXTURE
chmod +x "$MODPATH/bin/sing-box"
python3 - "$ZIPFILE" "$MODPATH" <<'PY'
import pathlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a') as z:
    for name in ('jq', 'sing-box'):
        z.write(pathlib.Path(sys.argv[2]) / 'bin' / name, 'bin/' + name)
PY
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
# Published core/installer ZIPs have no rule or executable entries. Their
# component bootstrap has already installed verified payloads before refresh.
mkdir "$MODPATH/.config/sing-box/rules"
unzip -p "$ZIPFILE" .config/sing-box/rules/fixture.srs >"$MODPATH/.config/sing-box/rules/fixture.srs"
python3 - "$ZIPFILE" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    template = z.read('.config/sing-box/config.json')
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('components.json', '{"schema":1}')
    z.writestr('.config/sing-box/config.json', template)
PY
# Preserve source files byte-for-byte; no network access is needed.
for item in subscription.url subscription.local subscription.user-agent subscription-filter.list; do
    printf 'saved-%s\n' "$item" >"$MODPATH/.config/sing-box/$item"
done
printf '%s\n' '{"old":true,"dns":{"tag":"old"},"outbounds":[{"type":"trojan","tag":"US saved","server":"node.example","server_port":443,"password":"fixture-secret"}]}' >"$PREVIOUS"
printf '%s\n' '[{"type":"trojan","tag":"US cached","server":"node.example","server_port":443,"password":"fixture-secret"},{"type":"trojan","tag":"HK filtered","server":"hk.example","server_port":443,"password":"fixture-secret"},{"type":"selector","tag":"proxy","default":"old-policy"}]' >"$CACHE"
printf 'stale template\n' >"$CONFIG.update"
run_refresh
[[ ! -e "$CONFIG.update" ]]
jq -e '.dns.tag == "new" and .inbounds[0].type == "tun" and .route.final == "proxy" and (has("old") | not) and any(.outbounds[]; .tag == "US cached" and .password == "fixture-secret") and any(.outbounds[]; .tag == "proxy" and .default == "new-policy") and all(.outbounds[]; .tag != "HK filtered")' "$CONFIG" >/dev/null
cmp "$PREVIOUS" "$CONFIG.pre-upgrade"
[[ "$(stat -c %a "$CONFIG.pre-upgrade")" == 600 ]]
for item in subscription.url subscription.local subscription.user-agent subscription-filter.list; do
    [[ "$(cat "$MODPATH/.config/sing-box/$item")" == "saved-$item" ]]
done
if grep -q 'fixture-secret' "$TMP/log"; then
    printf '%s\n' 'migration leaked subscription credentials into the log' >&2
    exit 1
else
    grep_status=$?
    [[ "$grep_status" -eq 1 ]] || exit "$grep_status"
fi
no_temporary_files
# Missing verified rules aborts a core upgrade before publishing or fetching.
mv "$MODPATH/.config/sing-box/rules" "$TMP/rules-before"
cp "$CONFIG" "$TMP/before-missing-rules"
expect_failure
grep -q 'phase=rules-component' "$TMP/log"
cmp "$CONFIG" "$TMP/before-missing-rules"
mv "$TMP/rules-before" "$MODPATH/.config/sing-box/rules"
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
printf 'pending update\n' >"$CONFIG.update"
export REJECT_CONFIG=1
expect_failure
unset REJECT_CONFIG
cmp "$CONFIG" "$TMP/before"
[[ -f "$MARKER" ]]
[[ "$(cat "$CONFIG.update")" == "pending update" ]]
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
# An upgrade without saved nodes still validates before publishing. Rejection
# must not replace the active config, backup, or standalone marker.
rm "$PREVIOUS"
cp "$CONFIG" "$TMP/before-no-nodes"
printf 'private rollback fixture\n' >"$CONFIG.pre-upgrade"
cp "$CONFIG.pre-upgrade" "$TMP/backup-before-no-nodes"
rm "$MARKER"
export REJECT_CONFIG=1
expect_failure
unset REJECT_CONFIG
cmp "$CONFIG" "$TMP/before-no-nodes"
cmp "$CONFIG.pre-upgrade" "$TMP/backup-before-no-nodes"
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

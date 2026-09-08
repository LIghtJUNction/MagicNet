#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/magicnet-runtime-fingerprint.XXXXXX")
trap 'rm -rf "$fixture"' 0
export MODDIR="$fixture/module"
REAL_JQ=$(command -v jq)
FAIL_STAGE=''
export REAL_JQ FAIL_STAGE
mkdir -p "$MODDIR/bin" "$MODDIR/.config/sing-box/rules"
. "$ROOT/src/MagicNet/lib/magicnet/runtime_config.sh"

cat >"$MODDIR/bin/jq" <<'SH'
#!/bin/sh
if [ "$FAIL_STAGE" = jq ]; then
    for arg do
        if [ "$arg" = -S ]; then
            printf '%s\n' '{"partial":true}'
            exit 1
        fi
    done
fi
exec "$REAL_JQ" "$@"
SH
chmod +x "$MODDIR/bin/jq"

find() { [ "$FAIL_STAGE" != find ] && command find "$@"; }
sort() { [ "$FAIL_STAGE" != sort ] && command sort; }
cksum() {
    [ "$FAIL_STAGE" != checksum ] || return 1
    if [ "$FAIL_STAGE" = rule ] && [ "$#" -gt 0 ]; then return 1; fi
    if [ "$FAIL_STAGE" = final-checksum ] && [ "$#" -eq 0 ]; then
        input=$(cat)
        case "$input" in
        '{'*) printf '%s\n' "$input" | command cksum; return ;;
        *) return 1 ;;
        esac
    fi
    command cksum "$@"
}
fail() { printf 'runtime fingerprint safety: %s\n' "$*" >&2; exit 1; }
assert_failure() {
    if magicnet_singbox_runtime_fingerprint >"$fixture/result" 2>/dev/null; then
        fail "$1 produced a successful fingerprint"
    fi
    [ ! -s "$fixture/result" ] || fail "$1 exposed a partial fingerprint"
    if magicnet_singbox_runtime_fingerprint_matches 2>/dev/null; then
        fail "$1 matched the running configuration"
    fi
    if magicnet_singbox_record_runtime_fingerprint 2>/dev/null; then
        fail "$1 recorded a failed fingerprint"
    fi
    [ "$(cat "$stored")" = "$baseline" ] || fail "$1 replaced the last good fingerprint"
    [ ! -e "$stored.new.$$" ] || fail "$1 leaked a staging file"
}

config="$MODDIR/.config/sing-box/config.json"
auth="$MODDIR/.config/sing-box/tailscale-auth.json"
rule="$MODDIR/.config/sing-box/rules/test.srs"
printf '%s\n' '{"route":{"final":"direct"},"inbounds":[]}' >"$config"
printf '%s\n' '{"tailscale":"test-key"}' >"$auth"
printf '%s\n' 'initial rule' >"$rule"
baseline=$(magicnet_singbox_runtime_fingerprint)
# Preserve existing checksum framing to avoid a restart after this upgrade.
expected=$(
    {
        printf '%s\n' '{"inbounds":[],"route":{"final":"direct"}}' | cksum
        printf '%s\n' '{"tailscale":"test-key"}' | cksum
        cksum "$rule"
    } | cksum | awk '{ print $1 ":" $2 }'
)
[ "$baseline" = "$expected" ] || fail 'checksum framing changed'
magicnet_singbox_record_runtime_fingerprint
stored=$(magicnet_singbox_runtime_fingerprint_file)
magicnet_singbox_runtime_fingerprint_matches

# JSON formatting and mutable UI/cache data must keep long-lived sockets intact.
printf '%s\n' '{ "inbounds": [], "route": { "final": "direct" } }' >"$config"
printf '%s\n' 'mutable cache' >"$MODDIR/.config/sing-box/cache.db"
[ "$(magicnet_singbox_runtime_fingerprint)" = "$baseline" ] || fail 'equivalent inputs changed the fingerprint'
printf '%s\n' 'updated rule' >"$rule"
[ "$(magicnet_singbox_runtime_fingerprint)" != "$baseline" ] || fail 'changed rule was ignored'
printf '%s\n' 'initial rule' >"$rule"

cp "$config" "$fixture/good-config"
for invalid in '{invalid' ''; do
    printf '%s' "$invalid" >"$config"
    assert_failure 'invalid/empty config'
done
cp "$fixture/good-config" "$config"
printf '%s\n' '{invalid' >"$auth"
assert_failure 'invalid authentication JSON'
printf '%s\n' '{"tailscale":"test-key"}' >"$auth"
for FAIL_STAGE in jq find sort checksum rule final-checksum; do
    assert_failure "$FAIL_STAGE failure"
done
FAIL_STAGE=''
magicnet_singbox_runtime_fingerprint_matches
printf '%s\n' 'runtime fingerprint safety test passed'

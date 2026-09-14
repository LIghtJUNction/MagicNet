#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/magicnet-cloudflared-auth.XXXXXX")
trap 'rm -rf "$fixture"' 0
export MODDIR="$fixture/module"
mkdir -p "$MODDIR/bin" "$MODDIR/.config/sing-box/rules"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"
. "$ROOT/src/MagicNet/lib/magicnet/runtime_config.sh"

fail() {
    printf 'cloudflared auth test: %s\n' "$*" >&2
    exit 1
}

config="$MODDIR/.config/sing-box/config.json"
auth="$MODDIR/.config/sing-box/cloudflared-auth.json"
cat >"$config" <<'JSON'
{
  "inbounds": [
    {"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":1080},
    {"type":"cloudflared","tag":"cf-main","token":"tagged-secret","protocol":"quic","ha_connections":2},
    {"type":"cloudflared","token":"index-secret","protocol":"http2"}
  ],
  "route":{"final":"direct"}
}
JSON
chmod 600 "$config"

magicnet_cloudflared_apply_unlocked || fail 'apply failed'
[ -s "$auth" ] || fail 'private token sidecar was not created'
[ "$(stat -c '%a' "$auth")" = 600 ] || fail 'private token sidecar permissions are not 0600'
"$MODDIR/bin/jq" -e '
  (.inbounds[0].tag == "mixed-in") and
  (.inbounds[1] | has("token") | not) and
  (.inbounds[2] | has("token") | not)
' "$config" >/dev/null || fail 'tokens were not removed from resting config'
"$MODDIR/bin/jq" -e '
  .["tag:cf-main"] == "tagged-secret" and
  .["index:2"] == "index-secret"
' "$auth" >/dev/null || fail 'sidecar token identity mapping is incorrect'

baseline=$(magicnet_singbox_runtime_fingerprint) || fail 'baseline fingerprint failed'
cp "$auth" "$fixture/auth.good"
"$MODDIR/bin/jq" '.["tag:cf-main"] = "rotated-secret"' "$auth" >"$fixture/auth.new"
mv "$fixture/auth.new" "$auth"
[ "$(magicnet_singbox_runtime_fingerprint)" != "$baseline" ] || fail 'token rotation did not change runtime fingerprint'
cp "$fixture/auth.good" "$auth"
chmod 600 "$auth"

magicnet_cloudflared_inject_token || fail 'token injection failed'
"$MODDIR/bin/jq" -e '
  .inbounds[0].tag == "mixed-in" and
  .inbounds[1].token == "tagged-secret" and
  .inbounds[2].token == "index-secret"
' "$config" >/dev/null || fail 'tokens were not injected into matching inbounds'

magicnet_cloudflared_scrub_token || fail 'token scrub failed'
"$MODDIR/bin/jq" -e '
  [.inbounds[] | select(.type == "cloudflared" and has("token"))] | length == 0
' "$config" >/dev/null || fail 'tokens remained in config after scrub'
"$MODDIR/bin/jq" -e '.inbounds[0].tag == "mixed-in"' "$config" >/dev/null || fail 'non-cloudflared inbound was modified'

printf '%s\n' 'cloudflared auth test passed'

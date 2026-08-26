#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-dns-profile.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MODDIR="$WORK/module"
export MODDIR
mkdir -p "$MODDIR/.config/sing-box" "$MODDIR/bin"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"

cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "dns": {
    "servers": [
      {"type": "https", "tag": "bootstrap-local-dns", "server": "223.5.5.5"},
      {"type": "https", "tag": "cloudflare-backup-dns", "server": "1.0.0.1"},
      {"type": "https", "tag": "doh-cloudflare", "server": "1.1.1.1", "detour": "proxy"},
      {"type": "udp", "tag": "retained-udp", "server": "9.9.9.9"}
    ]
  }
}
EOF

# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"
. "$ROOT/src/MagicNet/lib/magicnet/subscribe_bootstrap.sh"
. "$ROOT/src/MagicNet/lib/magicnet/dns.sh"

assert_profile_uses_proxy_detour() {
    local profile="$1"
    local expected_type="$2"
    local expected_port="$3"
    MAGICNET_DNS_PROFILE="$profile" magicnet_dns_apply_singbox

    jq -e --arg expected_type "$expected_type" --argjson expected_port "$expected_port" '
      ([.dns.servers[]
        | select(.tag == "cloudflare-profile-dns" or .tag == "cloudflare-backup-dns")
        | select(.type == $expected_type and .detour == "proxy")
        | select((.server_port // 53) == $expected_port)] | length) == 2
        and .dns.final == "cloudflare-profile-dns"
        and ([.dns.servers[] | select(.tag == "bootstrap-local-dns")
          | .type == "https" and .server == "223.5.5.5" and has("detour") | not] | length) == 1
    ' "$MODDIR/.config/sing-box/config.json" >/dev/null || {
        printf 'DNS profile %s must use proxy detour for both managed %s servers\n' \
            "$profile" "$expected_type" >&2
        exit 1
    }
}

assert_profile_uses_proxy_detour cloudflare-udp udp 53
assert_profile_uses_proxy_detour cloudflare-dot tls 853
assert_profile_uses_proxy_detour cloudflare-doh https 443

MAGICNET_DNS_PROFILE=default magicnet_dns_apply_singbox
jq -e '
  .dns.final == "bootstrap-local-dns"
    and ([.dns.servers[] | select(.tag == "cloudflare-profile-dns" or .tag == "cloudflare-backup-dns")] | length) == 0
    and ([.dns.servers[] | select(.tag == "retained-udp") | .routing_mark] == [1073741824])
' "$MODDIR/.config/sing-box/config.json" >/dev/null || {
    printf 'default DNS profile must restore direct bootstrap final and remove managed profile servers\n' >&2
    exit 1
}

FULL_MODDIR="$WORK/full-module"
mkdir -p "$FULL_MODDIR/.config/sing-box" "$FULL_MODDIR/bin"
ln -s "$(command -v jq)" "$FULL_MODDIR/bin/jq"
cp "$ROOT/src/MagicNet/.config/sing-box/config.json" "$FULL_MODDIR/.config/sing-box/config.json"
cp -R "$ROOT/src/MagicNet/.config/sing-box/rules" "$FULL_MODDIR/.config/sing-box/"
MODDIR="$FULL_MODDIR" MAGICNET_DNS_PROFILE=cloudflare-udp magicnet_dns_apply_singbox
(cd "$FULL_MODDIR/.config/sing-box" && sing-box check -c config.json -D "$FULL_MODDIR/.config/sing-box") >/dev/null

printf 'DNS profile safety test passed\n'

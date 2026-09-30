#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-dns-profile.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

with_routing_assets=0
case "${1:-}" in
"") ;;
--with-routing-assets)
  with_routing_assets=1
  shift
  ;;
*)
  printf 'usage: bash scripts/test-dns-profile-safety.sh [--with-routing-assets]\n' >&2
  exit 64
  ;;
esac
[ "$#" -eq 0 ] || {
  printf 'unexpected arguments\n' >&2
  exit 64
}

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
        and ([.dns.rules[] | select(.tag == "magicnet-final-dns")] ==
          [{"action":"evaluate","server":"cloudflare-profile-dns","tag":"magicnet-final-dns"}])
        and .dns.rules[-1] == {"match_response":"magicnet-final-dns","action":"respond"}
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
    and ([.dns.rules[] | select(.tag == "magicnet-final-dns")] ==
      [{"action":"evaluate","server":"bootstrap-local-dns","tag":"magicnet-final-dns"}])
    and .dns.rules[-1] == {"match_response":"magicnet-final-dns","action":"respond"}
    and (.dns.rules | length) == 2
    and ([.dns.servers[] | select(.tag == "cloudflare-profile-dns" or .tag == "cloudflare-backup-dns")] | length) == 0
    and ([.dns.servers[] | select(.tag == "retained-udp") | .routing_mark] == [1073741824])
    and .dns.timeout == "8s"
    and .dns.cache_capacity == 4096
    and .dns.optimistic == {"enabled": true, "timeout": "30m"}
    and .experimental.cache_file.enabled == true
    and .experimental.cache_file.store_dns == true
' "$MODDIR/.config/sing-box/config.json" >/dev/null || {
  printf 'default DNS profile must restore direct bootstrap and conservative sing-box 1.14 cache defaults\n' >&2
  exit 1
}

cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "dns": {
    "servers": [
      {"type": "https", "tag": "bootstrap-local-dns", "server": "223.5.5.5"},
      {"type": "udp", "tag": "retained-udp", "server": "9.9.9.9"}
    ],
    "timeout": "12s",
    "cache_capacity": 2048,
    "optimistic": false
  },
  "experimental": {
    "cache_file": {
      "enabled": false
    }
  }
}
EOF
MAGICNET_DNS_PROFILE=default magicnet_dns_apply_singbox
jq -e '
  .dns.timeout == "12s"
    and .dns.cache_capacity == 2048
    and .dns.optimistic == false
    and .experimental.cache_file.enabled == false
    and (.experimental.cache_file | has("store_dns") | not)
' "$MODDIR/.config/sing-box/config.json" >/dev/null || {
  printf 'explicit DNS cache and timeout preferences must be preserved\n' >&2
  exit 1
}

cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{"dns":{"servers":[{"type":"hosts","tag":"offline","predefined":{"magicnet.test":["198.18.0.42"]}}],
"final":"offline","rules":[{"domain":"magicnet.test","server":"offline"}]},"route":{}}
EOF
printf 'validated\n' >"$MODDIR/.config/sing-box/standalone-config"
MAGICNET_DNS_PROFILE=default magicnet_dns_apply_singbox
jq -e '
  .dns.servers == [{"type":"hosts","tag":"offline","predefined":{"magicnet.test":["198.18.0.42"]}}]
    and .dns.final == "offline"
    and .dns.rules == [{"domain":"magicnet.test","server":"offline"}]
    and .route.default_domain_resolver == "offline"
' "$MODDIR/.config/sing-box/config.json" >/dev/null || {
  printf 'standalone DNS graph and explicit 1.14 resolver were not preserved\n' >&2
  exit 1
}
cp "$MODDIR/.config/sing-box/config.json" "$WORK/standalone-dns.json"
MAGICNET_DNS_PROFILE=default magicnet_dns_apply_singbox
cmp "$WORK/standalone-dns.json" "$MODDIR/.config/sing-box/config.json"
jq '.route.default_domain_resolver={"server":"offline","strategy":"ipv4_only","timeout":"3s"}' \
  "$MODDIR/.config/sing-box/config.json" >"$WORK/explicit-resolver.json"
cp "$WORK/explicit-resolver.json" "$MODDIR/.config/sing-box/config.json"
MAGICNET_DNS_PROFILE=cloudflare-doh magicnet_dns_apply_singbox
jq -e '
  .route.default_domain_resolver == {"server":"offline","strategy":"ipv4_only","timeout":"3s"}
    and .dns.final == "cloudflare-profile-dns"
    and ([.dns.servers[] | select(.tag == "offline")] | length) == 1
' "$MODDIR/.config/sing-box/config.json" >/dev/null || {
  printf 'explicit resolver or selected standalone DNS profile was overwritten\n' >&2
  exit 1
}

# A standalone config may leave resolution entirely to the system. The
# default profile must preserve the absence of a managed DNS server graph.
for dns in '"omitted"' null '{}' '{"servers":null}' '{"servers":[]}' '{"disable_cache":true}'; do
  jq -n --argjson dns "$dns" '
    {inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:2080}],
     outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}
    + (if $dns == "omitted" then {} else {dns:$dns} end)
  ' >"$WORK/no-dns-original.json"
  cp "$WORK/no-dns-original.json" "$MODDIR/.config/sing-box/config.json"
  MAGICNET_DNS_PROFILE=default magicnet_dns_apply_singbox
  jq -s -e 'length == 2 and .[0] == .[1]' \
    "$WORK/no-dns-original.json" "$MODDIR/.config/sing-box/config.json" >/dev/null || {
    printf 'standalone config without DNS servers was changed: %s\n' "$dns" >&2
    exit 1
  }
  cp "$MODDIR/.config/sing-box/config.json" "$WORK/no-dns-once.json"
  MAGICNET_DNS_PROFILE=default magicnet_dns_apply_singbox
  cmp "$WORK/no-dns-once.json" "$MODDIR/.config/sing-box/config.json"
done

# An invalid DNS field is not the same as an omitted graph. Failure must not
# overwrite the original file or leave a partially rendered candidate.
for dns in '"invalid"' false '[]' '{"servers":"invalid"}' '{"servers":false}' '{"servers":{}}'; do
  jq -n --argjson dns "$dns" '{dns:$dns,outbounds:[{type:"direct",tag:"direct"}]}' \
    >"$WORK/invalid-dns.json"
  cp "$WORK/invalid-dns.json" "$MODDIR/.config/sing-box/config.json"
  if MAGICNET_DNS_PROFILE=default magicnet_dns_apply_singbox 2>"$WORK/invalid-dns.log"; then
    printf 'malformed standalone DNS was accepted: %s\n' "$dns" >&2
    exit 1
  fi
  cmp "$WORK/invalid-dns.json" "$MODDIR/.config/sing-box/config.json"
  [ ! -e "$MODDIR/.config/sing-box/config.json.magicnet-dns.new" ]
done

rm -f "$MODDIR/.config/sing-box/standalone-config"

if [ "$with_routing_assets" -eq 1 ]; then
  command -v sing-box >/dev/null 2>&1 || {
    printf 'prepared DNS checks require sing-box and rule-set assets\n' >&2
    exit 127
  }
  FULL_MODDIR="$WORK/full-module"
  mkdir -p "$FULL_MODDIR/.config/sing-box" "$FULL_MODDIR/bin"
  ln -s "$(command -v jq)" "$FULL_MODDIR/bin/jq"
  cp "$ROOT/src/MagicNet/.config/sing-box/config.json" "$FULL_MODDIR/.config/sing-box/config.json"
  cp -R "$ROOT/src/MagicNet/.config/sing-box/rules" "$FULL_MODDIR/.config/sing-box/"
  MODDIR="$FULL_MODDIR" MAGICNET_DNS_PROFILE=cloudflare-udp magicnet_dns_apply_singbox
  (cd "$FULL_MODDIR/.config/sing-box" && sing-box check -c config.json -D "$FULL_MODDIR/.config/sing-box") >/dev/null
else
  printf 'Prepared sing-box DNS asset check excluded; use --with-routing-assets to include it.\n'
fi

printf 'DNS profile safety test passed\n'

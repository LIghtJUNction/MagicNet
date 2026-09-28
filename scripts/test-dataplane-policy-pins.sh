#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-dataplane-policy.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$1" >&2
        exit 127
    }
}
need jq

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

HOST_JQ="$(command -v jq)"
MODDIR="$WORK/module"
export MODDIR
mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/bin" "$MODDIR/lib/magicnet"
ln -s "$HOST_JQ" "$MODDIR/bin/jq"
cp "$ROOT/src/MagicNet/lib/magicnet/primitives.sh" "$MODDIR/lib/magicnet/primitives.sh"
cp "$ROOT/src/MagicNet/lib/magicnet/transparent_dns.sh" "$MODDIR/lib/magicnet/transparent_dns.sh"
cp "$ROOT/src/MagicNet/lib/magicnet/network.sh" "$MODDIR/lib/magicnet/network.sh"

import() { :; }
# shellcheck disable=SC1091
. "$MODDIR/lib/magicnet/transparent_dns.sh"
# shellcheck disable=SC1091
. "$MODDIR/lib/magicnet/network.sh"

[ "$(magicnet_dns_capture_port)" = 1053 ] || fail "default DNS capture port drifted"
[ "$(magicnet_tun_inet)" = 172.19.0.1/30 ] || fail "default TUN IPv4 drifted"
[ "$(magicnet_tun_inet6)" = fdfe:dcba:9876::1/126 ] || fail "default TUN IPv6 drifted"

magicnet_ipv4_tun_cidr_valid 172.19.0.1/30 || fail "default TUN IPv4 rejected"
magicnet_ipv4_tun_cidr_valid 127.0.0.1/30 && fail "loopback TUN IPv4 accepted"
magicnet_ipv4_tun_cidr_valid 172.19.0.1/31 && fail "too-narrow TUN IPv4 accepted"
magicnet_ipv6_tun_cidr_valid fdfe:dcba:9876::1/126 || fail "default TUN IPv6 rejected"
magicnet_ipv6_tun_cidr_valid fe80::1/64 && fail "link-local TUN IPv6 accepted"
magicnet_ipv6_tun_cidr_valid 2001:db8::1/64 && fail "global TUN IPv6 accepted"

export MAGIC_DNS_CAPTURE_PORT=15353
export MAGICNET_TUN_INET=172.20.0.1/30
export MAGICNET_TUN_INET6=fd12:3456:789a::1/64
[ "$(magicnet_dns_capture_port)" = 15353 ] || fail "env DNS capture port ignored"
[ "$(magicnet_tun_inet)" = 172.20.0.1/30 ] || fail "env TUN IPv4 ignored"
[ "$(magicnet_tun_inet6)" = fd12:3456:789a::1/64 ] || fail "env TUN IPv6 ignored"
unset MAGIC_DNS_CAPTURE_PORT MAGICNET_TUN_INET MAGICNET_TUN_INET6

cat >"$MODDIR/.config/magicnet/network-policy.conf" <<'CONF'
MAGICNET_IPV6_MODE=prefer_ipv4
MAGICNET_TUN_MTU=1400
MAGICNET_UDP_TIMEOUT=5m
MAGICNET_DNS_CAPTURE_PORT=15353
MAGICNET_TUN_INET=172.20.0.1/30
MAGICNET_TUN_INET6=fd12:3456:789a::1/64
CONF
[ "$(magicnet_dns_capture_port)" = 15353 ] || fail "policy DNS capture port ignored"
[ "$(magicnet_tun_inet)" = 172.20.0.1/30 ] || fail "policy TUN IPv4 ignored"
[ "$(magicnet_tun_inet6)" = fd12:3456:789a::1/64 ] || fail "policy TUN IPv6 ignored"

# Invalid policy values must fall back instead of being copied into sing-box.
cat >"$MODDIR/.config/magicnet/network-policy.conf" <<'CONF'
MAGICNET_DNS_CAPTURE_PORT=not-a-port
MAGICNET_TUN_INET=127.0.0.1/30
MAGICNET_TUN_INET6=fe80::1/64
CONF
[ "$(magicnet_dns_capture_port)" = 1053 ] || fail "invalid DNS port was accepted"
[ "$(magicnet_tun_inet)" = 172.19.0.1/30 ] || fail "invalid TUN IPv4 was accepted"
[ "$(magicnet_tun_inet6)" = fdfe:dcba:9876::1/126 ] || fail "invalid TUN IPv6 was accepted"

# Apply the same jq surface used by the installed module. Do not load kamfw;
# this fixture only needs the transparent rewrite and policy helpers.
cp "$ROOT/src/MagicNet/lib/magicnet/transparent.sh" "$MODDIR/lib/magicnet/transparent.sh"
mkdir -p "$MODDIR/.config/sing-box"
cat >"$MODDIR/.config/magicnet/network-policy.conf" <<'CONF'
MAGICNET_IPV6_MODE=prefer_ipv4
MAGICNET_TUN_MTU=1400
MAGICNET_UDP_TIMEOUT=5m
MAGICNET_DNS_CAPTURE_PORT=15353
MAGICNET_TUN_INET=172.20.0.1/30
MAGICNET_TUN_INET6=fd12:3456:789a::1/64
CONF
cat >"$MODDIR/.config/sing-box/config.json" <<'JSON'
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7892},
    {"type": "tun", "tag": "tun-in", "interface_name": "magicnet0", "address": ["172.19.0.1/30"]},
    {"type": "direct", "tag": "magicnet-dns-in", "listen": "127.0.0.1", "listen_port": 1053}
  ],
  "route": {"rules": [
    {"inbound": ["mixed-in", "tun-in"], "action": "sniff"},
    {"inbound": ["magicnet-dns-in"], "action": "hijack-dns"}
  ]}
}
JSON
chmod 600 "$MODDIR/.config/sing-box/config.json"

magicnet_transparent_mode() { printf '%s\n' tun; }
magicnet_ebpf_publish_state() { return 0; }
singbox_prepare_route_config() { return 0; }
magicnet_warn() { :; }
# shellcheck disable=SC1091
. "$MODDIR/lib/magicnet/transparent.sh"

magicnet_singbox_apply_transparent_mode || fail "transparent apply failed with policy pins"

"$HOST_JQ" -e '
  ([.inbounds[] | select(.tag == "magicnet-dns-in" and .listen_port == 15353)] | length) == 1
  and ([.inbounds[] | select(.tag == "magicnet-dns6-in" and .listen_port == 15353)] | length) == 1
  and ([.inbounds[] | select(.tag == "tun-in" and .address == ["172.20.0.1/30", "fd12:3456:789a::1/64"])] | length) == 1
' "$MODDIR/.config/sing-box/config.json" >/dev/null ||
    fail "transparent apply did not materialize policy DNS/TUN pins"

printf '%s\n' 'dataplane policy pin test passed'

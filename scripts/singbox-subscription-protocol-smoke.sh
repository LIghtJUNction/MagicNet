#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_ROOT="${1:-$ROOT/src/MagicNet}"

fail() {
    printf 'sing-box subscription protocol smoke failed: %s\n' "$*" >&2
    exit 1
}

for tool in base64 jq; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

[[ -f "$MODULE_ROOT/lib/magicnet_singbox_subscribe.sh" ]] \
    || fail "subscription library not found under module root: $MODULE_ROOT"

tmp_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

# shellcheck disable=SC2034
MODDIR="$MODULE_ROOT"
# shellcheck disable=SC1090
. "$MODULE_ROOT/lib/magicnet_singbox_subscribe.sh"

links_fixture="$tmp_dir/mixed-links.txt"
cat >"$links_fixture" <<'EOF'
vless://00000000-0000-4000-8000-000000000001@vless.invalid:443#fixture-vless
anytls://fixture-password@anytls.invalid:443#fixture-anytls
tuic://00000000-0000-4000-8000-000000000002:fixture-password@tuic.invalid:443#fixture-tuic
socks://fixture%20user:fixture%40password@socks.invalid:1080#fixture%20socks
socks5://Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ@socks5.invalid:1081#fixture-socks5
EOF

assert_extracted_links() {
    local source_file="$1"
    local case_name="$2"
    local nodes_dir="$tmp_dir/$case_name-nodes"
    local count

    count="$(magicnet_singbox_extract_share_links "$source_file" "$nodes_dir")"
    [[ "$count" == "5" ]] || fail "$case_name extraction returned $count nodes, expected 5"
    [[ "$(wc -l <"$nodes_dir/links.txt")" == "5" ]] \
        || fail "$case_name links.txt does not contain exactly 5 links"
    for scheme in vless anytls tuic socks socks5; do
        grep -Eq "^${scheme}://" "$nodes_dir/links.txt" \
            || fail "$case_name links.txt is missing ${scheme}://"
    done
}

assert_extracted_links "$links_fixture" plain
base64 <"$links_fixture" >"$tmp_dir/mixed-links.base64"
assert_extracted_links "$tmp_dir/mixed-links.base64" base64

vmess_link_file="$tmp_dir/node-vmess-unicode.link"
vmess_payload='{"v":"2","ps":"\u9999\u6e2f-\u4f18\u5316","add":"vmess.invalid","port":"443","id":"00000000-0000-4000-8000-000000000009","aid":"0","net":"tcp","tls":"tls","sni":"vmess.invalid"}'
printf 'vmess://%s\n' "$(printf '%s' "$vmess_payload" | base64 | tr -d '\n')" >"$vmess_link_file"
vmess_json="$(magicnet_singbox_emit_share_link_json "$vmess_link_file")" \
    || fail "emit_share_link_json failed for VMess Unicode fixture"
printf '%s\n' "$vmess_json" | jq -e '.tag == "香港-优化"' >/dev/null \
    || fail "VMess JSON Unicode escapes were not decoded: $vmess_json"

vmess_ws_link_file="$tmp_dir/node-vmess-ws.link"
vmess_ws_payload='{"v":"2","ps":"fixture-vmess-ws","add":"origin.invalid","port":"443","id":"00000000-0000-4000-8000-000000000010","aid":"0","net":"ws","path":"/edge/path","host":"host.invalid","tls":"tls","sni":"sni.invalid"}'
printf 'vmess://%s\n' "$(printf '%s' "$vmess_ws_payload" | base64 | tr -d '\n')" >"$vmess_ws_link_file"
vmess_ws_json="$(magicnet_singbox_emit_share_link_json "$vmess_ws_link_file")" \
    || fail "emit_share_link_json failed for VMess WebSocket fixture"
printf '%s\n' "$vmess_ws_json" | jq -e '
  .server == "origin.invalid"
  and .transport.type == "ws"
  and .transport.path == "/edge/path"
  and .transport.headers.Host == "host.invalid"
  and .tls.server_name == "sni.invalid"
' >/dev/null || fail "VMess WebSocket fields were not preserved independently: $vmess_ws_json"

# Exercise the Android/no-jq fallback without changing the host installation.
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "jq" ]]; then
        return 1
    fi
    builtin command "$@"
}
vmess_ws_nojq_json="$(magicnet_singbox_emit_share_link_json "$vmess_ws_link_file")" \
    || fail "no-jq emit_share_link_json failed for VMess WebSocket fixture"
unset -f command
printf '%s\n' "$vmess_ws_nojq_json" | jq -e '
  .server == "origin.invalid"
  and .transport.type == "ws"
  and .transport.path == "/edge/path"
  and .transport.headers.Host == "host.invalid"
  and .tls.server_name == "sni.invalid"
' >/dev/null || fail "no-jq VMess WebSocket fields were not preserved independently: $vmess_ws_nojq_json"

socks_link_file="$tmp_dir/node-socks.link"
printf '%s\n' 'socks://fixture%20user:fixture%40password@socks.invalid:1080#fixture%20socks' >"$socks_link_file"
socks_json="$(magicnet_singbox_emit_share_link_json "$socks_link_file")" \
    || fail "emit_share_link_json failed for percent-encoded socks:// credentials"
printf '%s\n' "$socks_json" | jq -e '
  .type == "socks"
  and .tag == "fixture socks"
  and .server == "socks.invalid"
  and .server_port == 1080
  and .version == "5"
  and .username == "fixture user"
  and .password == "fixture@password"
' >/dev/null || fail "percent-encoded socks:// JSON did not match expected shape: $socks_json"

socks5_link_file="$tmp_dir/node-socks5.link"
printf '%s\n' 'socks5://Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ@socks5.invalid:1081#fixture-socks5' >"$socks5_link_file"
socks5_json="$(magicnet_singbox_emit_share_link_json "$socks5_link_file")" \
    || fail "emit_share_link_json failed for base64 socks5:// credentials"
printf '%s\n' "$socks5_json" | jq -e '
  .type == "socks"
  and .tag == "fixture-socks5"
  and .server == "socks5.invalid"
  and .server_port == 1081
  and .version == "5"
  and .username == "fixture-user"
  and .password == "fixture-password"
' >/dev/null || fail "base64 socks5:// JSON did not match expected shape: $socks5_json"

socks_unauth_file="$tmp_dir/node-socks-unauth.link"
printf '%s\n' 'socks://socks-unauth.invalid:1082#fixture-unauth' >"$socks_unauth_file"
socks_unauth_json="$(magicnet_singbox_emit_share_link_json "$socks_unauth_file")" \
    || fail "emit_share_link_json failed for unauthenticated socks://"
printf '%s\n' "$socks_unauth_json" | jq -e '
  .type == "socks"
  and .version == "5"
  and (has("username") | not)
  and (has("password") | not)
' >/dev/null || fail "unauthenticated socks:// emitted unexpected credentials: $socks_unauth_json"

socks_malformed_file="$tmp_dir/node-socks-malformed.link"
printf '%s\n' 'socks://not-valid-base64@socks.invalid:1080#fixture-invalid' >"$socks_malformed_file"
if magicnet_singbox_emit_share_link_json "$socks_malformed_file" >"$tmp_dir/malformed-socks.json"; then
    fail "malformed SOCKS credentials were accepted"
fi

# Drive the real share-link emitter (not a hand-built JSON fixture) for anytls.
anytls_link_file="$tmp_dir/node-anytls.link"
printf '%s\n' 'anytls://fixture-password@anytls.invalid:443?sni=edge.example&fp=chrome&insecure=1&alpn=h2,http/1.1#fixture-anytls' \
    >"$anytls_link_file"
anytls_json="$(magicnet_singbox_emit_share_link_json "$anytls_link_file")" \
    || fail "emit_share_link_json failed for anytls://"
printf '%s\n' "$anytls_json" | jq -e '
  .type == "anytls"
  and .tag == "fixture-anytls"
  and .server == "anytls.invalid"
  and .server_port == 443
  and .password == "fixture-password"
  and .tls.enabled == true
  and .tls.server_name == "edge.example"
  and .tls.insecure == true
  and .tls.utls.enabled == true
  and .tls.utls.fingerprint == "chrome"
  and (.tls.alpn | index("h2")) != null
' >/dev/null || fail "anytls share-link JSON did not match expected sing-box outbound shape: $anytls_json"

# Clash YAML anytls node path.
anytls_yaml_file="$tmp_dir/node-anytls.yaml"
cat >"$anytls_yaml_file" <<'YAML'
name: clash-anytls
type: anytls
server: clash-anytls.invalid
port: 8443
password: clash-secret
sni: sni.example
client-fingerprint: firefox
skip-cert-verify: true
alpn: [h2, http/1.1]
YAML
anytls_yaml_json="$(magicnet_singbox_emit_node_json "$anytls_yaml_file")" \
    || fail "emit_node_json failed for Clash anytls"
printf '%s\n' "$anytls_yaml_json" | jq -e '
  .type == "anytls"
  and .tag == "clash-anytls"
  and .server == "clash-anytls.invalid"
  and .server_port == 8443
  and .password == "clash-secret"
  and .tls.enabled == true
  and .tls.server_name == "sni.example"
  and .tls.insecure == true
  and .tls.utls.fingerprint == "firefox"
' >/dev/null || fail "Clash anytls JSON did not match expected shape: $anytls_yaml_json"

# Drive real share-link emitter for tuic (not Proxylink-only).
tuic_link_file="$tmp_dir/node-tuic.link"
printf '%s\n' 'tuic://00000000-0000-4000-8000-000000000002:fixture-password@tuic.invalid:443?sni=tuic.example&congestion_control=bbr&alpn=h3#fixture-tuic' \
    >"$tuic_link_file"
tuic_json="$(magicnet_singbox_emit_share_link_json "$tuic_link_file")" \
    || fail "emit_share_link_json failed for tuic://"
printf '%s\n' "$tuic_json" | jq -e '
  .type == "tuic"
  and .tag == "fixture-tuic"
  and .server == "tuic.invalid"
  and .server_port == 443
  and .uuid == "00000000-0000-4000-8000-000000000002"
  and .password == "fixture-password"
  and .congestion_control == "bbr"
  and .tls.enabled == true
  and .tls.server_name == "tuic.example"
  and (.tls.alpn | index("h3")) != null
' >/dev/null || fail "tuic share-link JSON did not match expected shape: $tuic_json"

tuic_yaml_file="$tmp_dir/node-tuic.yaml"
cat >"$tuic_yaml_file" <<'YAML'
name: clash-tuic
type: tuic
server: clash-tuic.invalid
port: 443
uuid: 00000000-0000-4000-8000-000000000003
password: clash-tuic-secret
sni: tuic-sni.example
congestion-controller: cubic
skip-cert-verify: true
YAML
tuic_yaml_json="$(magicnet_singbox_emit_node_json "$tuic_yaml_file")" \
    || fail "emit_node_json failed for Clash tuic"
printf '%s\n' "$tuic_yaml_json" | jq -e '
  .type == "tuic"
  and .tag == "clash-tuic"
  and .uuid == "00000000-0000-4000-8000-000000000003"
  and .password == "clash-tuic-secret"
  and .congestion_control == "cubic"
  and .tls.insecure == true
' >/dev/null || fail "Clash tuic JSON did not match expected shape: $tuic_yaml_json"

# Mixed outbounds from native emitters land in proxy selector.
nodes_json="$tmp_dir/outbounds.json"
jq -n --argjson anytls "$anytls_json" --argjson tuic "$tuic_json" --argjson socks "$socks_json" '
[
  {
    "type": "vless",
    "tag": "fixture-vless",
    "server": "vless.invalid",
    "server_port": 443,
    "uuid": "00000000-0000-4000-8000-000000000001"
  },
  $anytls,
  $tuic,
  $socks
]
' >"$nodes_json"

valid_count="$(magicnet_singbox_count_valid_outbounds_nodes "$nodes_json")"
[[ "$valid_count" == "4" ]] || fail "valid outbound count was $valid_count, expected 4"

invalid_socks_nodes="$tmp_dir/invalid-socks-nodes.json"
jq -n '[
  {
    "type": "socks",
    "tag": "invalid-version",
    "server": "socks.invalid",
    "server_port": 1080,
    "version": "6"
  },
  {
    "type": "socks",
    "tag": "incomplete-credentials",
    "server": "socks.invalid",
    "server_port": 1080,
    "version": "5",
    "username": "fixture-user"
  }
]' >"$invalid_socks_nodes"
invalid_socks_count="$(magicnet_singbox_count_valid_outbounds_nodes "$invalid_socks_nodes")"
[[ "$invalid_socks_count" == "0" ]] \
    || fail "invalid SOCKS outbounds passed production validation: $invalid_socks_count"

outbounds_fragment="$tmp_dir/generated-outbounds.fragment"
magicnet_singbox_write_outbounds_from_json "$nodes_json" "$outbounds_fragment"
{
    printf '{\n'
    sed 's/,$//' "$outbounds_fragment"
    printf '\n}\n'
} >"$tmp_dir/generated-outbounds.json"

jq -e '
  ([.outbounds[] | select(.type == "vless" or .type == "anytls" or .type == "tuic" or .type == "socks")] | length) == 4
  and ([.outbounds[] | select(.type == "vless") | .tag] == ["fixture-vless"])
  and ([.outbounds[] | select(.type == "anytls") | .tag] == ["fixture-anytls"])
  and ([.outbounds[] | select(.type == "tuic") | .tag] == ["fixture-tuic"])
  and ([.outbounds[] | select(.type == "socks") | .tag] == ["fixture socks"])
  and ((.outbounds[] | select(.type == "selector" and .tag == "proxy") | .outbounds) as $proxy
    | ($proxy | index("fixture-vless")) != null
    and ($proxy | index("fixture-anytls")) != null
    and ($proxy | index("fixture-tuic")) != null
    and ($proxy | index("fixture socks")) != null)
' "$tmp_dir/generated-outbounds.json" >/dev/null \
    || fail "generated outbounds did not preserve all protocols in the proxy selector"

# Configured keywords exclude matching tags before selectors are generated.
MODDIR="$tmp_dir/module"
mkdir -p "$MODDIR/.config/sing-box"
printf '%s\n' 'FREE' '香港' >"$MODDIR/.config/sing-box/subscription-filter.list"
filtered_nodes="$tmp_dir/filtered-nodes.json"
jq '. + [
  {
    "type": "vless",
    "tag": "Free trial",
    "server": "free.invalid",
    "server_port": 443,
    "uuid": "00000000-0000-4000-8000-000000000004"
  },
  {
    "type": "vless",
    "tag": "香港 01",
    "server": "hk.invalid",
    "server_port": 443,
    "uuid": "00000000-0000-4000-8000-000000000005"
  }
]' "$nodes_json" >"$filtered_nodes"
filtered_fragment="$tmp_dir/filtered-outbounds.fragment"
magicnet_singbox_write_outbounds_from_json "$filtered_nodes" "$filtered_fragment"
{
    printf '{\n'
    sed 's/,$//' "$filtered_fragment"
    printf '\n}\n'
} >"$tmp_dir/filtered-outbounds.json"
jq -e '
  ([.outbounds[] | select(.tag == "Free trial" or .tag == "香港 01")] | length) == 0
  and ((.outbounds[] | select(.type == "selector" and .tag == "proxy") | .outbounds) as $proxy
    | ($proxy | index("Free trial")) == null
    and ($proxy | index("香港 01")) == null
    and ($proxy | index("fixture-vless")) != null)
' "$tmp_dir/filtered-outbounds.json" >/dev/null \
    || fail "subscription keyword filters were not applied to nodes and selectors"

printf 'sing-box subscription protocol smoke passed\n'

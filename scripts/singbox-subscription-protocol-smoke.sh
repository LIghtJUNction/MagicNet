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

# The isolated bootstrap provides command discovery only as a fallback. Tests
# and embedding callers may inject a narrower resolver before sourcing it.
(
    magicnet_cmd_exists() { [[ "$1" == fixture-command ]]; }
    # shellcheck disable=SC1090
    . "$MODULE_ROOT/lib/magicnet/subscribe_bootstrap.sh"
    magicnet_cmd_exists fixture-command \
        || fail "subscription bootstrap replaced an injected command resolver"
    ! magicnet_cmd_exists curl \
        || fail "injected command resolver no longer controls discovery"
)

# shellcheck disable=SC1090
. "$MODULE_ROOT/lib/magicnet_singbox_subscribe.sh"

type magicnet_singbox_api_has_nodes >/dev/null 2>&1 \
    || fail "standalone subscription loader omitted sing-box API validation"
curl() {
    printf '%s\n' '{"proxies":{"fixture":{"type":"VLESS"}}}'
}
magicnet_singbox_api_has_nodes \
    || fail "standalone sing-box API validation rejected a node response"
unset -f curl

magicnet_singbox_tag_is_reserved hotspot \
    || fail "jq-free reserved-tag fallback does not protect the hotspot selector"

links_fixture="$tmp_dir/mixed-links.txt"
cat >"$links_fixture" <<'EOF'
vless://00000000-0000-4000-8000-000000000001@vless.invalid:443#fixture-vless
anytls://fixture-password@anytls.invalid:443#fixture-anytls
tuic://00000000-0000-4000-8000-000000000002:fixture-password@tuic.invalid:443#fixture-tuic
TROJAN://fixture%40password@trojan.invalid:443?sni=trojan%2Eexample&allowInsecure=1#fixture-trojan
socks://fixture%20user:fixture%40password@socks.invalid:1080#fixture%20socks
socks5://Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ@socks5.invalid:1081#fixture-socks5
EOF

assert_extracted_links() {
    local source_file="$1"
    local case_name="$2"
    local nodes_dir="$tmp_dir/$case_name-nodes"
    local count

    count="$(magicnet_singbox_extract_share_links "$source_file" "$nodes_dir")"
    [[ "$count" == "6" ]] || fail "$case_name extraction returned $count nodes, expected 6"
    [[ "$(wc -l <"$nodes_dir/links.txt")" == "6" ]] \
        || fail "$case_name links.txt does not contain exactly 6 links"
    for scheme in vless anytls tuic trojan socks socks5; do
        grep -Eiq "^${scheme}://" "$nodes_dir/links.txt" \
            || fail "$case_name links.txt is missing ${scheme}://"
    done
}

assert_extracted_links "$links_fixture" plain
{
    printf '\n# leading comment should not change plain-link detection\n'
    cat "$links_fixture"
} >"$tmp_dir/leading-links.txt"
assert_extracted_links "$tmp_dir/leading-links.txt" leading-plain
base64 <"$links_fixture" >"$tmp_dir/mixed-links.base64"
assert_extracted_links "$tmp_dir/mixed-links.base64" base64

# Proxylink uses -singbox for a full sing-box JSON document. Keep this path
# isolated from the bundled ARM binary by observing the production wrapper's
# arguments with a test double.
proxylink_args="$tmp_dir/proxylink-args"
proxylink_output="$tmp_dir/proxylink-output.json"
proxylink_json="$tmp_dir/proxylink-source.json"
proxylink_bin_definition="$(declare -f magicnet_singbox_proxylink_bin)"
proxylink_run_definition="$(declare -f magicnet_singbox_run_proxylink)"
printf '%s\n' '{"outbounds":[{"type":"vless","tag":"fixture-json","server":"json.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000003"}]}' >"$proxylink_json"
magicnet_singbox_proxylink_bin() { printf '%s\n' fixture-proxylink; }
magicnet_singbox_run_proxylink() {
    printf '%s\n' "$@" >"$proxylink_args"
    local output_file=""
    while [[ "$#" -gt 0 ]]; do
        if [[ "$1" == "-o" ]]; then
            shift
            output_file="$1"
        fi
        shift
    done
    printf '%s\n' '{"outbounds":[]}' >"$output_file"
}
magicnet_singbox_run_proxylink_source fixture-proxylink "$proxylink_json" "$proxylink_output" \
    || fail "sing-box JSON was not accepted by the Proxylink source wrapper"
grep -Fx -- '-singbox' "$proxylink_args" >/dev/null \
    || fail "sing-box JSON was not passed with -singbox"
if grep -Fx -- '-file' "$proxylink_args" >/dev/null 2>&1; then
    fail "sing-box JSON was incorrectly passed with -file"
fi
base64 <"$proxylink_json" >"$tmp_dir/proxylink-source.base64"
: >"$proxylink_args"
magicnet_singbox_run_proxylink_source fixture-proxylink "$tmp_dir/proxylink-source.base64" "$proxylink_output" \
    || fail "Base64 sing-box JSON was not accepted by the Proxylink source wrapper"
grep -Fx -- '-singbox' "$proxylink_args" >/dev/null \
    || fail "Base64 sing-box JSON was not passed with -singbox"
eval "$proxylink_bin_definition"
eval "$proxylink_run_definition"
unset proxylink_bin_definition proxylink_run_definition

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

# A missing JSON parser is a packaging failure and must be rejected before
# emitting a partially parsed node.
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "jq" ]]; then
        return 1
    fi
    builtin command "$@"
}
if magicnet_singbox_emit_share_link_json "$vmess_ws_link_file" >/dev/null 2>&1; then
    fail "VMess parsing unexpectedly succeeded without jq"
fi
unset -f command

vmess_escaped_link_file="$tmp_dir/node-vmess-escaped.link"
vmess_escaped_payload='{"v":"2","ps":"escaped \"tag\"","add":"origin.invalid","port":"443","id":"00000000-0000-4000-8000-000000000011","aid":"0","net":"ws","path":"/edge/\"path","host":"host.invalid","tls":"tls","sni":"sni.invalid"}'
printf 'vmess://%s\n' "$(printf '%s' "$vmess_escaped_payload" | base64 | tr -d '\n')" >"$vmess_escaped_link_file"
vmess_escaped_json="$(magicnet_singbox_emit_share_link_json "$vmess_escaped_link_file")" \
    || fail "emit_share_link_json failed for escaped VMess fields"
printf '%s\n' "$vmess_escaped_json" | jq -e '
  .tag == "escaped \"tag\""
  and .transport.path == "/edge/\"path"
' >/dev/null || fail "VMess escaped fields were corrupted: $vmess_escaped_json"

vmess_invalid_aid_payload=$(printf '%s' '{"v":"2","ps":"invalid aid","add":"vmess.invalid","port":"443","id":"00000000-0000-4000-8000-000000000099","aid":"0} , \"injected\": true","net":"tcp"}' | base64 | tr -d '\n')
printf 'vmess://%s\n' "$vmess_invalid_aid_payload" >"$tmp_dir/node-vmess-invalid-aid.link"
if magicnet_singbox_emit_share_link_json "$tmp_dir/node-vmess-invalid-aid.link" >/dev/null 2>&1; then
  fail "VMess parser accepted a non-numeric alter_id"
fi

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

socks_corrupt_base64_file="$tmp_dir/node-socks-corrupt-base64.link"
printf '%s\n' 'socks://YTph!!!!@socks.invalid:1080#fixture-corrupt-base64' >"$socks_corrupt_base64_file"
if magicnet_singbox_emit_share_link_json "$socks_corrupt_base64_file" >"$tmp_dir/corrupt-base64-socks.json"; then
    fail "base64 credentials with trailing garbage were accepted"
fi

socks_malformed_percent_file="$tmp_dir/node-socks-malformed-percent.link"
printf '%s\n' 'socks://user%ZZ:password@socks.invalid:1080#fixture-malformed-percent' >"$socks_malformed_percent_file"
if magicnet_singbox_emit_share_link_json "$socks_malformed_percent_file" >"$tmp_dir/malformed-percent-socks.json"; then
    fail "malformed percent-encoded SOCKS credentials were accepted"
fi

trojan_link_file="$tmp_dir/node-trojan.link"
printf '%s\n' 'trojan://fixture%40+password@trojan.invalid:443?sni=trojan%2Eexample&allowInsecure=1&alpn=h2#fixture-trojan' \
    >"$trojan_link_file"
trojan_json="$(magicnet_singbox_emit_share_link_json "$trojan_link_file")" \
    || fail "emit_share_link_json failed for trojan://"
printf '%s\n' "$trojan_json" | jq -e '
  .type == "trojan"
  and .tag == "fixture-trojan"
  and .server == "trojan.invalid"
  and .server_port == 443
  and .password == "fixture@+password"
  and .tls.enabled == true
  and .tls.server_name == "trojan.example"
  and .tls.insecure == true
  and (.tls.alpn | index("h2")) != null
' >/dev/null || fail "trojan share-link JSON did not match expected shape: $trojan_json"

trojan_backslash_file="$tmp_dir/node-trojan-backslash.link"
printf '%s\n' 'trojan://fixture%5Cn@trojan.invalid:443#fixture-trojan-backslash' \
    >"$trojan_backslash_file"
trojan_backslash_json="$(magicnet_singbox_emit_share_link_json "$trojan_backslash_file")" \
    || fail "emit_share_link_json failed for a backslash-containing trojan password"
printf '%s\n' "$trojan_backslash_json" | jq -e \
    '.password == ("fixture" + "\\" + "n")' >/dev/null \
    || fail "percent-decoded backslash was interpreted as an escape: $trojan_backslash_json"

hysteria2_link_file="$tmp_dir/node-hysteria2.link"
printf '%s\n' 'hysteria2://fixture%40password@hysteria.invalid:443?sni=hysteria%2Eexample&alpn=h3#fixture-hysteria2' \
    >"$hysteria2_link_file"
hysteria2_json="$(magicnet_singbox_emit_share_link_json "$hysteria2_link_file")" \
    || fail "emit_share_link_json failed for hysteria2://"
printf '%s\n' "$hysteria2_json" | jq -e '
  .type == "hysteria2"
  and .tag == "fixture-hysteria2"
  and .server == "hysteria.invalid"
  and .server_port == 443
  and .password == "fixture@password"
  and .tls.server_name == "hysteria.example"
  and (.tls.alpn | index("h3")) != null
' >/dev/null || fail "hysteria2 share-link JSON did not decode credentials/query values: $hysteria2_json"

ipv6_link_file="$tmp_dir/node-ipv6.link"
printf '%s\n' 'trojan://fixture-password@[2001:db8::7]:443#fixture-ipv6' >"$ipv6_link_file"
ipv6_json="$(magicnet_singbox_emit_share_link_json "$ipv6_link_file")" \
    || fail "emit_share_link_json failed for a bracketed IPv6 share link"
printf '%s\n' "$ipv6_json" | jq -e '
  .type == "trojan"
  and .server == "2001:db8::7"
  and .server_port == 443
' >/dev/null || fail "bracketed IPv6 authority was not normalized: $ipv6_json"

vless_reality_file="$tmp_dir/node-vless-reality.link"
printf '%s\n' 'VLESS://00000000%2D0000%2D4000%2D8000%2D000000000001@reality.invalid:443?security=Reality&sni=reality.example&pbk=fixture-public-key&sid=abcd#fixture-reality' \
    >"$vless_reality_file"
vless_reality_json="$(magicnet_singbox_emit_share_link_json "$vless_reality_file")" \
    || fail "emit_share_link_json failed for VLESS Reality"
printf '%s\n' "$vless_reality_json" | jq -e '
  .type == "vless"
  and .uuid == "00000000-0000-4000-8000-000000000001"
  and .tls.reality.enabled == true
  and .tls.reality.public_key == "fixture-public-key"
  and .tls.reality.short_id == "abcd"
' >/dev/null || fail "VLESS Reality fields were not validated or normalized: $vless_reality_json"

vless_reality_missing_key="$tmp_dir/node-vless-reality-missing-key.link"
printf '%s\n' 'vless://00000000-0000-4000-8000-000000000001@reality.invalid:443?security=reality&sni=reality.example#fixture-reality-missing-key' \
    >"$vless_reality_missing_key"
if magicnet_singbox_emit_share_link_json "$vless_reality_missing_key" >"$tmp_dir/vless-reality-missing-key.json"; then
    fail "VLESS Reality without a public key was accepted"
fi

invalid_port_file="$tmp_dir/node-invalid-port.link"
printf '%s\n' 'trojan://fixture-password@trojan.invalid:65536#fixture-invalid-port' >"$invalid_port_file"
if magicnet_singbox_emit_share_link_json "$invalid_port_file" >"$tmp_dir/invalid-port.json"; then
    fail "share-link emitter accepted an out-of-range port"
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

outbounds_array="$tmp_dir/generated-outbounds.array.json"
magicnet_singbox_write_outbounds_from_json "$nodes_json" "$outbounds_array"
jq -n --slurpfile generated_outbounds "$outbounds_array" \
    '{outbounds: $generated_outbounds[0]}' >"$tmp_dir/generated-outbounds.json"

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
filtered_array="$tmp_dir/filtered-outbounds.array.json"
magicnet_singbox_write_outbounds_from_json "$filtered_nodes" "$filtered_array"
jq -n --slurpfile generated_outbounds "$filtered_array" \
    '{outbounds: $generated_outbounds[0]}' >"$tmp_dir/filtered-outbounds.json"
jq -e '
  ([.outbounds[] | select(.tag == "Free trial" or .tag == "香港 01")] | length) == 0
  and ((.outbounds[] | select(.type == "selector" and .tag == "proxy") | .outbounds) as $proxy
    | ($proxy | index("Free trial")) == null
    and ($proxy | index("香港 01")) == null
    and ($proxy | index("fixture-vless")) != null)
' "$tmp_dir/filtered-outbounds.json" >/dev/null \
    || fail "subscription keyword filters were not applied to nodes and selectors"

printf 'sing-box subscription protocol smoke passed\n'

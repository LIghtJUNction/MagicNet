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
EOF

assert_extracted_links() {
    local source_file="$1"
    local case_name="$2"
    local nodes_dir="$tmp_dir/$case_name-nodes"
    local count

    count="$(magicnet_singbox_extract_share_links "$source_file" "$nodes_dir")"
    [[ "$count" == "3" ]] || fail "$case_name extraction returned $count nodes, expected 3"
    [[ "$(wc -l <"$nodes_dir/links.txt")" == "3" ]] \
        || fail "$case_name links.txt does not contain exactly 3 links"
    for scheme in vless anytls tuic; do
        grep -Eq "^${scheme}://" "$nodes_dir/links.txt" \
            || fail "$case_name links.txt is missing ${scheme}://"
    done
}

assert_extracted_links "$links_fixture" plain
base64 <"$links_fixture" >"$tmp_dir/mixed-links.base64"
assert_extracted_links "$tmp_dir/mixed-links.base64" base64

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

# Mixed outbounds (pre-built + emitted anytls) still land in proxy selector.
nodes_json="$tmp_dir/outbounds.json"
jq -n --argjson anytls "$anytls_json" '
[
  {
    "type": "vless",
    "tag": "fixture-vless",
    "server": "vless.invalid",
    "server_port": 443,
    "uuid": "00000000-0000-4000-8000-000000000001"
  },
  $anytls,
  {
    "type": "tuic",
    "tag": "fixture-tuic",
    "server": "tuic.invalid",
    "server_port": 443,
    "uuid": "00000000-0000-4000-8000-000000000002",
    "password": "fixture-password"
  }
]
' >"$nodes_json"

valid_count="$(magicnet_singbox_count_valid_outbounds_nodes "$nodes_json")"
[[ "$valid_count" == "3" ]] || fail "valid outbound count was $valid_count, expected 3"

outbounds_fragment="$tmp_dir/generated-outbounds.fragment"
magicnet_singbox_write_outbounds_from_json "$nodes_json" "$outbounds_fragment"
{
    printf '{\n'
    sed 's/,$//' "$outbounds_fragment"
    printf '\n}\n'
} >"$tmp_dir/generated-outbounds.json"

jq -e '
  ([.outbounds[] | select(.type == "vless" or .type == "anytls" or .type == "tuic")] | length) == 3
  and ([.outbounds[] | select(.type == "vless") | .tag] == ["fixture-vless"])
  and ([.outbounds[] | select(.type == "anytls") | .tag] == ["fixture-anytls"])
  and ([.outbounds[] | select(.type == "tuic") | .tag] == ["fixture-tuic"])
  and ((.outbounds[] | select(.type == "selector" and .tag == "proxy") | .outbounds) as $proxy
    | ($proxy | index("fixture-vless")) != null
    and ($proxy | index("fixture-anytls")) != null
    and ($proxy | index("fixture-tuic")) != null)
' "$tmp_dir/generated-outbounds.json" >/dev/null \
    || fail "generated outbounds did not preserve all protocols in the proxy selector"

printf 'sing-box subscription protocol smoke passed\n'

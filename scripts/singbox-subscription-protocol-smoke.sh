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

nodes_json="$tmp_dir/outbounds.json"
cat >"$nodes_json" <<'JSON'
[
  {
    "type": "vless",
    "tag": "fixture-vless",
    "server": "vless.invalid",
    "server_port": 443,
    "uuid": "00000000-0000-4000-8000-000000000001"
  },
  {
    "type": "anytls",
    "tag": "fixture-anytls",
    "server": "anytls.invalid",
    "server_port": 443,
    "password": "fixture-password"
  },
  {
    "type": "tuic",
    "tag": "fixture-tuic",
    "server": "tuic.invalid",
    "server_port": 443,
    "uuid": "00000000-0000-4000-8000-000000000002",
    "password": "fixture-password"
  }
]
JSON

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

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_ROOT="$ROOT/src/MagicNet"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
fail() { printf 'pinned AI routing test failed: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2034
MODDIR="$MODULE_ROOT"
. "$MODULE_ROOT/lib/magicnet_singbox_subscribe.sh"
selector_tags_json=$(magicnet_selector_tags_json \
  "$(printf '%s\n%s\n%s\n' 'node "one"' direct 'node "one"')" 'fallback\path')
[[ "$selector_tags_json" == '["node \"one\"", "direct", "fallback\\path", "block"]' ]] ||
  fail "selector tag ordering, uniqueness, or JSON escaping mismatch: $selector_tags_json"
normalized_selector_tags_json=$(magicnet_selector_tags_json \
  "$(printf '%s\n%s\n' $'node\tspace' 'node space')" $'node\tspace')
[[ "$normalized_selector_tags_json" == '["node space", "direct", "block"]' ]] ||
  fail "selector tag final-value deduplication mismatch: $normalized_selector_tags_json"
cat >"$tmp_dir/nodes.json" <<'JSON'
[
 {"type":"vless","tag":"US stable","server":"us.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"},
 {"type":"vless","tag":"上海 node","server":"cn.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000002"},
 {"type":"vless","tag":"CN node","server":"cn2.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000003"},
 {"type":"vless","tag":"CN2 premium","server":"opaque.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000004"},
 {"type":"vless","tag":"opaque-42","server":"opaque2.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000005"},
 {"type":"vless","tag":"Mainland premium","server":"mainland.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000006"},
 {"type":"vless","tag":"Beijing edge","server":"beijing.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000007"},
 {"type":"vless","tag":"Shanghai edge","server":"shanghai.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000008"},
 {"type":"vless","tag":"Guangzhou edge","server":"guangzhou.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000009"},
 {"type":"vless","tag":"Shenzhen edge","server":"shenzhen.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000010"},
 {"type":"vless","tag":"Sichuan edge","server":"sichuan.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000011"},
 {"type":"vless","tag":"Inner-Mongolia edge","server":"mongolia.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000012"},
 {"type":"vless","tag":"Xinjiang edge","server":"xinjiang.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000013"}
 ,{"type":"vless","tag":"香港 edge","server":"hk-cn.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000014"}
 ,{"type":"vless","tag":"Hong Kong edge","server":"hongkong.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000015"}
 ,{"type":"vless","tag":"Hong-Kong edge","server":"hong-kong.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000016"}
 ,{"type":"vless","tag":"Hong_Kong edge","server":"hong_kong.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000017"}
 ,{"type":"vless","tag":"HK edge","server":"hk.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000018"}
 ,{"type":"vless","tag":"HKG edge","server":"hkg.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000019"}
 ,{"type":"vless","tag":"HKT edge","server":"hkt.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000020"}
 ,{"type":"vless","tag":"CHK edge","server":"chk.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000021"}
 ,{"type":"vless","tag":"hk01 edge","server":"hk01.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000022"}
 ,{"type":"vless","tag":"myhk edge","server":"myhk.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000023"}
 ,{"type":"vless","tag":"hk-01 edge","server":"hk-dash.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000024"}
 ,{"type":"vless","tag":"hk_01 edge","server":"hk-underscore.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000025"}
 ,{"type":"vless","tag":"HKG01 edge","server":"hkg01.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000026"}
 ,{"type":"vless","tag":"HongKong01 edge","server":"hongkong01.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000027"}
]
JSON
magicnet_singbox_write_outbounds_from_json "$tmp_dir/nodes.json" "$tmp_dir/outbounds.fragment"
{ printf '{\n'; sed 's/,$//' "$tmp_dir/outbounds.fragment"; printf '\n}\n'; } >"$tmp_dir/generated.json"
jq -e '
  [
    {name: "ai-chatgpt", url: "https://chatgpt.com/"},
    {name: "ai-gemini", url: "https://gemini.google.com/"},
    {name: "ai-grok", url: "https://grok.com/"},
    {name: "ai-claude", url: "https://claude.ai/"}
  ] as $services
  | [.outbounds[]
      | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
          or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
      | .tag] as $node_tags
  | (.outbounds | INDEX(.tag)) as $by_tag
  | [.outbounds[] | select(.tag == "proxy-auto")] as $proxy_auto
  | (.outbounds[] | select(.tag == "ai-proxy")) as $ai_proxy
  | ($proxy_auto == [{
      type: "urltest",
      tag: "proxy-auto",
      outbounds: $node_tags,
      url: "https://www.gstatic.com/generate_204",
      interval: "3m",
      tolerance: 30,
      idle_timeout: "10m",
      interrupt_exist_connections: false
    }])
    and ($by_tag.proxy == {
      type: "selector",
      tag: "proxy",
      outbounds: (["proxy-auto"] + $node_tags + ["direct", "block"]),
      default: "proxy-auto"
    })
    and ([.outbounds[] | select(.type == "selector")] | all(. as $selector
      | ($selector.outbounds | length) == ($selector.outbounds | unique | length)
        and (($selector.outbounds | index($selector.default)) != null)))
    and ($ai_proxy.default == "US stable" and $ai_proxy.outbounds == ["US stable", "CN2 premium", "opaque-42", "HKT edge", "CHK edge", "myhk edge"])
    and ($by_tag["cn-direct"] == {type: "selector", tag: "cn-direct", outbounds: ["direct", "proxy", "block"], default: "direct"})
    and ($by_tag.final == {type: "selector", tag: "final", outbounds: ["proxy", "direct", "block"], default: "proxy"})
    and ($services | all(. as $service
      | ($service.name + "-auto") as $auto
      | $by_tag[$service.name].type == "selector"
        and $by_tag[$service.name].default == $ai_proxy.outbounds[0]
        and $by_tag[$service.name].outbounds == ($ai_proxy.outbounds + ["block", $auto])
        and $by_tag[$auto] == {
          type: "urltest",
          tag: $auto,
          outbounds: $ai_proxy.outbounds,
          url: $service.url,
          interval: "10m",
          tolerance: 30,
          idle_timeout: "10m",
          interrupt_exist_connections: false
        }
    ))
' "$tmp_dir/generated.json" >/dev/null || fail "jq generator selector mismatch"
cat >"$tmp_dir/adversarial-nodes.json" <<'JSON'
[
 {"type":"vless","tag":"direct","server":"reserved-direct.invalid","server_port":443,"uuid":"10000000-0000-4000-8000-000000000001"},
 {"type":"vless","tag":"proxy-auto","server":"reserved-auto.invalid","server_port":443,"uuid":"10000000-0000-4000-8000-000000000002"},
 {"type":"vless","tag":"node-x","server":"node-x.invalid","server_port":443,"uuid":"10000000-0000-4000-8000-000000000003"},
 {"type":"vless","tag":"node-x","server":"duplicate.invalid","server_port":443,"uuid":"10000000-0000-4000-8000-000000000004"},
 {"type":"vless","tag":"node\tspace","server":"tab.invalid","server_port":443,"uuid":"10000000-0000-4000-8000-000000000005"},
 {"type":"vless","tag":"node space","server":"space.invalid","server_port":443,"uuid":"10000000-0000-4000-8000-000000000006"},
 {"type":"vless","tag":"\u0001","server":"empty.invalid","server_port":443,"uuid":"10000000-0000-4000-8000-000000000007"}
]
JSON
[[ "$(magicnet_singbox_count_valid_outbounds_nodes "$tmp_dir/adversarial-nodes.json")" == 2 ]] ||
  fail "jq adversarial valid-node count mismatch"
magicnet_singbox_write_outbounds_from_json \
  "$tmp_dir/adversarial-nodes.json" "$tmp_dir/adversarial-jq.fragment"
{ printf '{\n'; sed 's/,$//' "$tmp_dir/adversarial-jq.fragment"; printf '\n}\n'; } \
  >"$tmp_dir/adversarial-jq.json"
jq -e '
  [.outbounds[]
    | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
        or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
    | .tag] as $node_tags
  | (.outbounds | INDEX(.tag)) as $by_tag
  | $node_tags == ["node-x", "node space"]
    and $by_tag["proxy-auto"].outbounds == $node_tags
    and ($by_tag["proxy-auto"].outbounds | index("proxy-auto")) == null
    and $by_tag.proxy.outbounds == (["proxy-auto"] + $node_tags + ["direct", "block"])
    and ([.outbounds[].tag] | length) == ([.outbounds[].tag] | unique | length)
' "$tmp_dir/adversarial-jq.json" >/dev/null || fail "jq adversarial tag filtering mismatch"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/generated.json" || fail "jq canonical validator rejected generated auto groups"
jq '(.outbounds[] | select(.tag == "proxy") | .interrupt_exist_connections) = true' \
  "$tmp_dir/generated.json" >"$tmp_dir/kamfw-proxy-runtime.json"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/kamfw-proxy-runtime.json" ||
  fail "jq canonical validator rejected kamfw proxy runtime field"
special_tag='edge } { "quoted" \path,comma'
jq --arg special "$special_tag" '
  .outbounds |= map(
    (if .tag == "US stable" then
      .tag = $special
      | .tls = {
          enabled: true,
          reality: {public_key: "nested } { quote \" backslash \\ and comma, remain data"}
        }
      | .transport = {type: "ws", headers: {"X-Test": "nested } { object-like text"}}
    else . end)
    | (if ((.outbounds? | type) == "array") then
        .outbounds |= map(if . == "US stable" then $special else . end)
      else . end)
    | (if .default? == "US stable" then .default = $special else . end)
  )
' "$tmp_dir/generated.json" >"$tmp_dir/structural-special-tag.json"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/structural-special-tag.json" ||
  fail "jq canonical validator rejected nested special-tag config"
jq '.outbounds += [(.outbounds[]
      | select(.type == "vless" and .tag == "US stable")
      | .server = "duplicate.invalid")]' \
  "$tmp_dir/generated.json" >"$tmp_dir/duplicate-proxy-node.json"
jq '[.outbounds[]
      | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
          or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
      | .tag]
    | reduce .[] as $tag ([]; if index($tag) == null then . + [$tag] else . end)' \
  "$tmp_dir/duplicate-proxy-node.json" >"$tmp_dir/expected-unique-node-tags.json"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/duplicate-proxy-node.json" 2>/dev/null ||
  fail "jq canonical validator accepted duplicate proxy node tag"
cp "$tmp_dir/duplicate-proxy-node.json" "$tmp_dir/repaired-duplicate-proxy-node.json"
magicnet_singbox_sanitize_generated_config "$tmp_dir/repaired-duplicate-proxy-node.json"
jq -e --slurpfile expected "$tmp_dir/expected-unique-node-tags.json" '
  [.outbounds[]
    | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
        or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
    | .tag] as $node_tags
  | (.outbounds | INDEX(.tag)) as $by_tag
  | $node_tags == $expected[0]
    and ($node_tags | length) == ($node_tags | unique | length)
    and ([.outbounds[] | select(.type == "vless" and .tag == "US stable")] | length) == 1
    and ([.outbounds[] | select(.type == "vless" and .tag == "US stable")][0].server == "us.invalid")
    and $by_tag["proxy-auto"].outbounds == $node_tags
    and $by_tag.proxy.outbounds == (["proxy-auto"] + $node_tags + ["direct", "block"])
' "$tmp_dir/repaired-duplicate-proxy-node.json" >/dev/null ||
  fail "sanitizer did not preserve first proxy node and unique source order"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/repaired-duplicate-proxy-node.json" ||
  fail "jq canonical validator rejected repaired duplicate proxy nodes"
cat >"$tmp_dir/schema-nodes.json" <<'JSON'
[
  {"type":"shadowsocks","tag":"schema-ss","server":"ss.invalid","server_port":443,"method":"aes-128-gcm","password":"secret"},
  {"type":"vmess","tag":"schema-vmess","server":"vmess.invalid","server_port":443,"uuid":"30000000-0000-4000-8000-000000000001"},
  {"type":"vless","tag":"schema-vless","server":"vless.invalid","server_port":443,"uuid":"30000000-0000-4000-8000-000000000002"},
  {"type":"trojan","tag":"schema-trojan","server":"trojan.invalid","server_port":443,"password":"secret"},
  {"type":"hysteria2","tag":"schema-hysteria2","server":"hysteria2.invalid","server_port":443,"password":"secret"},
  {"type":"anytls","tag":"schema-anytls","server":"anytls.invalid","server_port":443,"password":"secret"},
  {"type":"tuic","tag":"schema-tuic","server":"tuic.invalid","server_port":443,"uuid":"30000000-0000-4000-8000-000000000003","password":"secret"}
]
JSON
magicnet_singbox_write_outbounds_from_json \
  "$tmp_dir/schema-nodes.json" "$tmp_dir/schema-generated.fragment"
{ printf '{\n'; sed 's/,$//' "$tmp_dir/schema-generated.fragment"; printf '\n}\n'; } \
  >"$tmp_dir/schema-generated.json"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/schema-generated.json" ||
  fail "jq canonical validator rejected all-protocol schema fixture"
schema_requirements=(
  'shadowsocks method'
  'shadowsocks password'
  'vmess uuid'
  'vless uuid'
  'trojan password'
  'hysteria2 password'
  'anytls password'
  'tuic uuid'
  'tuic password'
)
invalid_schema_node_configs=()
invalid_schema_raw_node_files=()
for schema_requirement in "${schema_requirements[@]}"; do
  read -r schema_type schema_field <<<"$schema_requirement"
  missing_schema_config="$tmp_dir/invalid-schema-$schema_type-missing-$schema_field.json"
  wrong_schema_config="$tmp_dir/invalid-schema-$schema_type-non-string-$schema_field.json"
  jq --arg type "$schema_type" --arg field "$schema_field" \
    'del(.outbounds[] | select(.type == $type) | .[$field])' \
    "$tmp_dir/schema-generated.json" >"$missing_schema_config"
  jq --arg type "$schema_type" --arg field "$schema_field" \
    '(.outbounds[] | select(.type == $type) | .[$field]) = 123' \
    "$tmp_dir/schema-generated.json" >"$wrong_schema_config"
  invalid_schema_node_configs+=("$missing_schema_config" "$wrong_schema_config")
  missing_schema_raw="$tmp_dir/invalid-raw-$schema_type-missing-$schema_field.json"
  wrong_schema_raw="$tmp_dir/invalid-raw-$schema_type-non-string-$schema_field.json"
  jq --arg type "$schema_type" --arg field "$schema_field" \
    '[.[] | select(.type == $type) | del(.[$field])]' \
    "$tmp_dir/schema-nodes.json" >"$missing_schema_raw"
  jq --arg type "$schema_type" --arg field "$schema_field" \
    '[.[] | select(.type == $type) | .[$field] = 123]' \
    "$tmp_dir/schema-nodes.json" >"$wrong_schema_raw"
  invalid_schema_raw_node_files+=("$missing_schema_raw" "$wrong_schema_raw")
done
jq -s 'add' "${invalid_schema_raw_node_files[@]}" >"$tmp_dir/invalid-schema-raw-nodes.json"
for invalid_config in "${invalid_schema_node_configs[@]}"; do
  ! magicnet_singbox_ai_selectors_canonical "$invalid_config" 2>/dev/null ||
    fail "jq canonical validator accepted invalid type-specific proxy node: $invalid_config"
done
cat >"$tmp_dir/adversarial-endpoint-nodes.json" <<'JSON'
[
  {"type":"vless","tag":"valid-endpoint","server":"valid.invalid","server_port":443,"uuid":"40000000-0000-4000-8000-000000000001"},
  {"type":"vless","tag":"numeric-server","server":123,"server_port":443,"uuid":"40000000-0000-4000-8000-000000000002"},
  {"type":"vless","tag":"string-port","server":"string-port.invalid","server_port":"443","uuid":"40000000-0000-4000-8000-000000000003"},
  {"type":"vless","tag":"fractional-port","server":"fractional.invalid","server_port":443.5,"uuid":"40000000-0000-4000-8000-000000000004"},
  {"type":"vless","tag":"zero-port","server":"zero.invalid","server_port":0,"uuid":"40000000-0000-4000-8000-000000000005"},
  {"type":"vless","tag":"high-port","server":"high.invalid","server_port":65536,"uuid":"40000000-0000-4000-8000-000000000006"},
  {"type":"vless","tag":"missing-uuid","server":"missing-uuid.invalid","server_port":443},
  {"type":"vless","tag":"warp","server":"reserved.invalid","server_port":443,"uuid":"40000000-0000-4000-8000-000000000007"}
]
JSON
[[ "$(magicnet_singbox_count_valid_outbounds_nodes "$tmp_dir/adversarial-endpoint-nodes.json")" == 1 ]] ||
  fail "jq valid-node count accepted malformed endpoint or type-specific fields"
magicnet_singbox_write_outbounds_from_json \
  "$tmp_dir/adversarial-endpoint-nodes.json" "$tmp_dir/adversarial-endpoint.fragment"
{ printf '{\n'; sed 's/,$//' "$tmp_dir/adversarial-endpoint.fragment"; printf '\n}\n'; } \
  >"$tmp_dir/adversarial-endpoint.json"
jq -e '
  [.outbounds[]
    | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
        or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
    | .tag] == ["valid-endpoint"]
' "$tmp_dir/adversarial-endpoint.json" >/dev/null ||
  fail "jq generator emitted malformed endpoint or type-specific nodes"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/adversarial-endpoint.json" ||
  fail "jq adversarial generator output failed its canonical validator"
jq -s '.[0] + .[1] + .[2]' \
  "$tmp_dir/schema-nodes.json" \
  "$tmp_dir/invalid-schema-raw-nodes.json" \
  "$tmp_dir/adversarial-endpoint-nodes.json" \
  >"$tmp_dir/adversarial-all-nodes.json"
[[ "$(magicnet_singbox_count_valid_outbounds_nodes "$tmp_dir/adversarial-all-nodes.json")" == 8 ]] ||
  fail "jq valid-node count diverged across endpoint and type-specific adversarial inputs"
magicnet_singbox_write_outbounds_from_json \
  "$tmp_dir/adversarial-all-nodes.json" "$tmp_dir/adversarial-all.fragment"
{ printf '{\n'; sed 's/,$//' "$tmp_dir/adversarial-all.fragment"; printf '\n}\n'; } \
  >"$tmp_dir/adversarial-all.json"
jq -e '
  [.outbounds[]
    | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
        or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
    | .tag] == [
      "schema-ss", "schema-vmess", "schema-vless", "schema-trojan",
      "schema-hysteria2", "schema-anytls", "schema-tuic", "valid-endpoint"
    ]
' "$tmp_dir/adversarial-all.json" >/dev/null ||
  fail "jq generator count and emitted valid-node set diverged"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/adversarial-all.json" ||
  fail "jq mixed adversarial generator output failed its canonical validator"
jq --slurpfile invalid_schema "$tmp_dir/invalid-schema-raw-nodes.json" \
  --slurpfile invalid_endpoint "$tmp_dir/adversarial-endpoint-nodes.json" '
    .outbounds += ($invalid_schema[0] + $invalid_endpoint[0])
  ' "$tmp_dir/schema-generated.json" >"$tmp_dir/sanitizer-adversarial.json"
magicnet_singbox_sanitize_generated_config "$tmp_dir/sanitizer-adversarial.json"
jq -e '
  [.outbounds[]
    | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
        or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
    | .tag] == [
      "schema-ss", "schema-vmess", "schema-vless", "schema-trojan",
      "schema-hysteria2", "schema-anytls", "schema-tuic", "valid-endpoint"
    ]
' "$tmp_dir/sanitizer-adversarial.json" >/dev/null ||
  fail "jq sanitizer retained malformed endpoint or type-specific nodes"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/sanitizer-adversarial.json" ||
  fail "jq sanitizer adversarial output failed its canonical validator"
sed '$d' "$tmp_dir/generated.json" >"$tmp_dir/invalid-missing-root.json"
{
  cat "$tmp_dir/generated.json"
  printf '}\n'
} >"$tmp_dir/invalid-extra-root-close.json"
printf '{"outbounds":[' >"$tmp_dir/invalid-truncated-outbounds.json"
printf '{"outbounds":[{"type":"selector","tag":"proxy"' >"$tmp_dir/invalid-truncated-object.json"
printf '{"outbounds":[{"type":"selector","tag":"unterminated' >"$tmp_dir/invalid-truncated-string.json"
printf '{"route":{}}\n' >"$tmp_dir/missing-root-outbounds.json"
printf '{"outbounds":[],"outbounds":[]}\n' >"$tmp_dir/duplicate-root-outbounds.json"
jq -c . "$tmp_dir/generated.json" >"$tmp_dir/syntax-base-compact.json"
sed 's/},{/}{/' "$tmp_dir/syntax-base-compact.json" >"$tmp_dir/invalid-missing-outbound-object-comma.json"
sed 's/,"tag"/"tag"/' "$tmp_dir/syntax-base-compact.json" >"$tmp_dir/invalid-missing-field-comma.json"
sed 's/"outbounds":/"outbounds"/' "$tmp_dir/syntax-base-compact.json" >"$tmp_dir/invalid-missing-colon.json"
sed 's/,"tag"/,,"tag"/' "$tmp_dir/syntax-base-compact.json" >"$tmp_dir/invalid-duplicate-object-comma.json"
sed 's/^{/{,/' "$tmp_dir/syntax-base-compact.json" >"$tmp_dir/invalid-leading-object-comma.json"
sed 's/}$/ ,}/' "$tmp_dir/syntax-base-compact.json" >"$tmp_dir/invalid-trailing-object-comma.json"
sed 's/"outbounds":\[/"outbounds":[,/' "$tmp_dir/syntax-base-compact.json" >"$tmp_dir/invalid-leading-array-comma.json"
sed 's/],"url"/,],"url"/' "$tmp_dir/syntax-base-compact.json" >"$tmp_dir/invalid-trailing-array-comma.json"
sed 's/},{/},,{/' "$tmp_dir/syntax-base-compact.json" >"$tmp_dir/invalid-duplicate-array-comma.json"
jq '.syntax_probe = {
      empty_object: {},
      empty_array: [],
      primitives: [null, true, false, 0, -1, 1.25, 1e2, "escaped \"quote\", slash \\, brackets ][, comma,"]
    }' "$tmp_dir/generated.json" >"$tmp_dir/valid-json-syntax-probe.json"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/valid-json-syntax-probe.json" ||
  fail "jq canonical validator rejected valid JSON syntax probe"
jq '.syntax_probe = true' "$tmp_dir/generated.json" >"$tmp_dir/valid-literal-true.json"
jq '.syntax_probe = false' "$tmp_dir/generated.json" >"$tmp_dir/valid-literal-false.json"
jq '.syntax_probe = null' "$tmp_dir/generated.json" >"$tmp_dir/valid-literal-null.json"
valid_literal_configs=(
  "$tmp_dir/valid-literal-true.json"
  "$tmp_dir/valid-literal-false.json"
  "$tmp_dir/valid-literal-null.json"
)
for valid_literal_config in "${valid_literal_configs[@]}"; do
  magicnet_singbox_ai_selectors_canonical "$valid_literal_config" ||
    fail "jq canonical validator rejected lowercase JSON literal: $valid_literal_config"
done
sed 's/"syntax_probe": true/"syntax_probe": TRUE/' "$tmp_dir/valid-literal-true.json" >"$tmp_dir/invalid-literal-TRUE.json"
sed 's/"syntax_probe": true/"syntax_probe": TrUe/' "$tmp_dir/valid-literal-true.json" >"$tmp_dir/invalid-literal-mixed-true.json"
sed 's/"syntax_probe": false/"syntax_probe": FALSE/' "$tmp_dir/valid-literal-false.json" >"$tmp_dir/invalid-literal-FALSE.json"
sed 's/"syntax_probe": false/"syntax_probe": FaLsE/' "$tmp_dir/valid-literal-false.json" >"$tmp_dir/invalid-literal-mixed-false.json"
sed 's/"syntax_probe": null/"syntax_probe": NULL/' "$tmp_dir/valid-literal-null.json" >"$tmp_dir/invalid-literal-NULL.json"
sed 's/"syntax_probe": null/"syntax_probe": NuLl/' "$tmp_dir/valid-literal-null.json" >"$tmp_dir/invalid-literal-mixed-null.json"
jq '(.outbounds[] | select(.tag == "proxy") | .tag) = "PROXY"' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-uppercase-proxy-tag.json"
jq '(.outbounds[] | select(.tag == "proxy") | .type) = "SELECTOR"' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-uppercase-proxy-type.json"
jq '(.outbounds[] | select(.tag == "proxy-auto") | .url) = "HTTPS://WWW.GSTATIC.COM/GENERATE_204"' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-uppercase-proxy-auto-url.json"
invalid_configs=(
  "$tmp_dir/invalid-missing-root.json"
  "$tmp_dir/invalid-extra-root-close.json"
  "$tmp_dir/invalid-truncated-outbounds.json"
  "$tmp_dir/invalid-truncated-object.json"
  "$tmp_dir/invalid-truncated-string.json"
  "$tmp_dir/invalid-missing-outbound-object-comma.json"
  "$tmp_dir/invalid-missing-field-comma.json"
  "$tmp_dir/invalid-missing-colon.json"
  "$tmp_dir/invalid-duplicate-object-comma.json"
  "$tmp_dir/invalid-leading-object-comma.json"
  "$tmp_dir/invalid-trailing-object-comma.json"
  "$tmp_dir/invalid-leading-array-comma.json"
  "$tmp_dir/invalid-trailing-array-comma.json"
  "$tmp_dir/invalid-duplicate-array-comma.json"
  "$tmp_dir/invalid-literal-TRUE.json"
  "$tmp_dir/invalid-literal-mixed-true.json"
  "$tmp_dir/invalid-literal-FALSE.json"
  "$tmp_dir/invalid-literal-mixed-false.json"
  "$tmp_dir/invalid-literal-NULL.json"
  "$tmp_dir/invalid-literal-mixed-null.json"
)
for invalid_config in "${invalid_configs[@]}"; do
  ! jq -e . "$invalid_config" >/dev/null 2>&1 || fail "jq parser accepted invalid JSON: $invalid_config"
  ! magicnet_singbox_ai_selectors_canonical "$invalid_config" 2>/dev/null ||
    fail "jq canonical validator accepted invalid JSON: $invalid_config"
done
jq '
  .outbounds |= map(
    (if .type == "vless" and .tag == "US stable" then .tag = "warp" else . end)
    | (if (.outbounds? | type) == "array" then
        .outbounds |= map(if . == "US stable" then "warp" else . end)
      else . end)
    | (if .default? == "US stable" then .default = "warp" else . end)
  )
' "$tmp_dir/generated.json" >"$tmp_dir/invalid-reserved-proxy-node-tag.json"
jq 'del(.outbounds[] | select(.type == "vless" and .tag == "US stable") | .server)' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-proxy-node-missing-server.json"
jq '(.outbounds[] | select(.type == "vless" and .tag == "US stable") | .server) = ""' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-proxy-node-empty-server.json"
jq '(.outbounds[] | select(.type == "vless" and .tag == "US stable") | .server) = 123' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-proxy-node-non-string-server.json"
jq 'del(.outbounds[] | select(.type == "vless" and .tag == "US stable") | .server_port)' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-proxy-node-missing-server-port.json"
jq '(.outbounds[] | select(.type == "vless" and .tag == "US stable") | .server_port) = "443"' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-proxy-node-string-server-port.json"
jq '(.outbounds[] | select(.type == "vless" and .tag == "US stable") | .server_port) = 443.5' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-proxy-node-fractional-server-port.json"
jq '(.outbounds[] | select(.type == "vless" and .tag == "US stable") | .server_port) = 0' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-proxy-node-zero-server-port.json"
jq '(.outbounds[] | select(.type == "vless" and .tag == "US stable") | .server_port) = 65536' \
  "$tmp_dir/generated.json" >"$tmp_dir/invalid-proxy-node-out-of-range-server-port.json"
invalid_proxy_node_configs=(
  "$tmp_dir/invalid-reserved-proxy-node-tag.json"
  "$tmp_dir/invalid-proxy-node-missing-server.json"
  "$tmp_dir/invalid-proxy-node-empty-server.json"
  "$tmp_dir/invalid-proxy-node-non-string-server.json"
  "$tmp_dir/invalid-proxy-node-missing-server-port.json"
  "$tmp_dir/invalid-proxy-node-string-server-port.json"
  "$tmp_dir/invalid-proxy-node-fractional-server-port.json"
  "$tmp_dir/invalid-proxy-node-zero-server-port.json"
  "$tmp_dir/invalid-proxy-node-out-of-range-server-port.json"
)
for invalid_config in "${invalid_proxy_node_configs[@]}"; do
  ! magicnet_singbox_ai_selectors_canonical "$invalid_config" 2>/dev/null ||
    fail "jq canonical validator accepted invalid proxy node: $invalid_config"
done
semantic_invalid_configs=(
  "$tmp_dir/missing-root-outbounds.json"
  "$tmp_dir/duplicate-root-outbounds.json"
  "$tmp_dir/invalid-uppercase-proxy-tag.json"
  "$tmp_dir/invalid-uppercase-proxy-type.json"
  "$tmp_dir/invalid-uppercase-proxy-auto-url.json"
)
for invalid_config in "${semantic_invalid_configs[@]}"; do
  ! magicnet_singbox_ai_selectors_canonical "$invalid_config" 2>/dev/null ||
    fail "jq canonical validator accepted invalid canonical fields: $invalid_config"
done
jq '(.outbounds[] | select(.tag == "ai-chatgpt-auto") | .url) = "https://invalid.example/"' \
  "$tmp_dir/generated.json" >"$tmp_dir/bad-auto-url.json"
jq '(.outbounds[] | select(.tag == "ai-chatgpt-auto") | .outbounds) += ["stale-missing-node"]' \
  "$tmp_dir/generated.json" >"$tmp_dir/bad-auto-member.json"
jq 'del(.outbounds[] | select(.tag == "ai-chatgpt-auto"))' \
  "$tmp_dir/generated.json" >"$tmp_dir/missing-auto.json"
jq '.outbounds += [.outbounds[] | select(.tag == "ai-chatgpt-auto")]' \
  "$tmp_dir/generated.json" >"$tmp_dir/duplicate-auto.json"
jq '(.outbounds[] | select(.tag == "proxy-auto") | .tolerance) = 100' \
  "$tmp_dir/generated.json" >"$tmp_dir/stale-proxy-auto-tolerance.json"
jq 'del(.outbounds[] | select(.tag == "proxy-auto"))' \
  "$tmp_dir/generated.json" >"$tmp_dir/missing-proxy-auto.json"
jq '.outbounds += [.outbounds[] | select(.tag == "proxy-auto")]' \
  "$tmp_dir/generated.json" >"$tmp_dir/duplicate-proxy-auto.json"
jq '(.outbounds[] | select(.tag == "proxy-auto") | .url) = "https://invalid.example/"' \
  "$tmp_dir/generated.json" >"$tmp_dir/malformed-proxy-auto.json"
jq '(.outbounds[] | select(.tag == "proxy-auto") | .outbounds) += ["stale-missing-node"]' \
  "$tmp_dir/generated.json" >"$tmp_dir/stale-proxy-auto-member.json"
jq '(.outbounds[] | select(.tag == "proxy-auto")) |=
      (.url = "https://www.google.com/generate_204" | .interval = "10m")' \
  "$tmp_dir/generated.json" >"$tmp_dir/stale-legacy-proxy-auto.json"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/bad-auto-url.json" 2>/dev/null || fail "jq canonical validator accepted wrong auto URL"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/bad-auto-member.json" 2>/dev/null || fail "jq canonical validator accepted stale auto member"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/missing-auto.json" 2>/dev/null || fail "jq canonical validator accepted missing auto group"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/duplicate-auto.json" 2>/dev/null || fail "jq canonical validator accepted duplicate auto group"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/stale-proxy-auto-tolerance.json" 2>/dev/null || fail "jq canonical validator accepted stale proxy-auto tolerance"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/missing-proxy-auto.json" 2>/dev/null || fail "jq canonical validator accepted missing proxy-auto"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/duplicate-proxy-auto.json" 2>/dev/null || fail "jq canonical validator accepted duplicate proxy-auto"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/malformed-proxy-auto.json" 2>/dev/null || fail "jq canonical validator accepted malformed proxy-auto"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/stale-proxy-auto-member.json" 2>/dev/null || fail "jq canonical validator accepted stale proxy-auto member"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/stale-legacy-proxy-auto.json" 2>/dev/null || fail "jq canonical validator accepted legacy proxy-auto probe policy"
magicnet_singbox_sanitize_generated_config "$tmp_dir/stale-proxy-auto-tolerance.json"
jq -e '
  [.outbounds[]
    | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
        or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
    | .tag] as $node_tags
  | (.outbounds | INDEX(.tag)) as $by_tag
  | ([.outbounds[] | select(.tag == "proxy-auto")] == [{
      type: "urltest", tag: "proxy-auto", outbounds: $node_tags,
      url: "https://www.gstatic.com/generate_204", interval: "3m", tolerance: 30,
      idle_timeout: "10m", interrupt_exist_connections: false
    }])
    and ($by_tag.proxy == {
      type: "selector", tag: "proxy",
      outbounds: (["proxy-auto"] + $node_tags + ["direct", "block"]), default: "proxy-auto"
    })
' "$tmp_dir/stale-proxy-auto-tolerance.json" >/dev/null || fail "sanitizer did not repair stale proxy-auto tolerance"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/stale-proxy-auto-tolerance.json" || fail "sanitizer repair is not canonical"
cp "$tmp_dir/stale-legacy-proxy-auto.json" "$tmp_dir/repaired-legacy-proxy-auto.json"
magicnet_singbox_sanitize_generated_config "$tmp_dir/repaired-legacy-proxy-auto.json"
jq -e '
  (.outbounds | INDEX(.tag)) as $by_tag
  | $by_tag["proxy-auto"].url == "https://www.gstatic.com/generate_204"
    and $by_tag["proxy-auto"].interval == "3m"
    and (["ai-chatgpt-auto", "ai-gemini-auto", "ai-grok-auto", "ai-claude-auto"]
      | all(. as $tag | $by_tag[$tag].interval == "10m"))
' "$tmp_dir/repaired-legacy-proxy-auto.json" >/dev/null ||
  fail "sanitizer did not migrate legacy proxy-auto probe policy without changing AI intervals"
magicnet_singbox_ai_selectors_canonical "$tmp_dir/repaired-legacy-proxy-auto.json" ||
  fail "legacy proxy-auto repair is not canonical"
printf '%s\n' 'US stable' '上海 node' 'CN node' 'CN2 premium' 'opaque-42' 'Mainland premium' 'Beijing edge' 'Shanghai edge' 'Guangzhou edge' 'Shenzhen edge' 'Sichuan edge' 'Inner-Mongolia edge' 'Xinjiang edge' '香港 edge' 'Hong Kong edge' 'Hong-Kong edge' 'Hong_Kong edge' 'HK edge' 'HKG edge' 'HKT edge' 'CHK edge' 'hk01 edge' 'myhk edge' 'hk-01 edge' 'hk_01 edge' 'HKG01 edge' 'HongKong01 edge' >"$tmp_dir/tags"
magicnet_singbox_emit_selector_block "$tmp_dir/tags" >"$tmp_dir/no-jq.fragment"
{
  printf '{"outbounds":['
  cat "$tmp_dir/no-jq.fragment"
  printf ',\n'
  sed '1d;$d' "$tmp_dir/nodes.json"
  printf ']}\n'
} >"$tmp_dir/no-jq.json"
jq -e '
  [
    {name: "ai-chatgpt", url: "https://chatgpt.com/"},
    {name: "ai-gemini", url: "https://gemini.google.com/"},
    {name: "ai-grok", url: "https://grok.com/"},
    {name: "ai-claude", url: "https://claude.ai/"}
  ] as $services
  | [.outbounds[]
      | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
          or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
      | .tag] as $node_tags
  | (.outbounds | INDEX(.tag)) as $by_tag
  | [.outbounds[] | select(.tag == "proxy-auto")] as $proxy_auto
  | (.outbounds[] | select(.tag == "ai-proxy")) as $ai_proxy
  | ($proxy_auto == [{
      type: "urltest",
      tag: "proxy-auto",
      outbounds: $node_tags,
      url: "https://www.gstatic.com/generate_204",
      interval: "3m",
      tolerance: 30,
      idle_timeout: "10m",
      interrupt_exist_connections: false
    }])
    and ($by_tag.proxy == {
      type: "selector",
      tag: "proxy",
      outbounds: (["proxy-auto"] + $node_tags + ["direct", "block"]),
      default: "proxy-auto"
    })
    and ($ai_proxy.default == "US stable" and $ai_proxy.outbounds == ["US stable", "CN2 premium", "opaque-42", "HKT edge", "CHK edge", "myhk edge"])
    and ($by_tag["cn-direct"] == {type: "selector", tag: "cn-direct", outbounds: ["direct", "proxy", "block"], default: "direct"})
    and ($by_tag.final == {type: "selector", tag: "final", outbounds: ["proxy", "direct", "block"], default: "proxy"})
    and ([.outbounds[] | select(.type == "selector")] | all(. as $selector
      | ($selector.outbounds | length) == ($selector.outbounds | unique | length)
        and (($selector.outbounds | index($selector.default)) != null)))
    and ($services | all(. as $service
      | ($service.name + "-auto") as $auto
      | $by_tag[$service.name].type == "selector"
        and $by_tag[$service.name].default == $ai_proxy.outbounds[0]
        and $by_tag[$service.name].outbounds == ($ai_proxy.outbounds + ["block", $auto])
        and $by_tag[$auto] == {
          type: "urltest",
          tag: $auto,
          outbounds: $ai_proxy.outbounds,
          url: $service.url,
          interval: "10m",
          tolerance: 30,
          idle_timeout: "10m",
          interrupt_exist_connections: false
        }
    ))
' "$tmp_dir/no-jq.json" >/dev/null || fail "no-jq generator selector mismatch"
mkdir "$tmp_dir/native-nodes"
printf '%s\n' 'vless://20000000-0000-4000-8000-000000000001@native.invalid:443#node-x' \
  >"$tmp_dir/native-nodes/node-1.link"
printf '%s\n' 'vless://20000000-0000-4000-8000-000000000002@native.invalid:443#direct' \
  >"$tmp_dir/native-nodes/node-2.link"
printf '%s\n' 'vless://20000000-0000-4000-8000-000000000003@native.invalid:443#proxy-auto' \
  >"$tmp_dir/native-nodes/node-3.link"
printf '%s\n' 'vless://20000000-0000-4000-8000-000000000004@native.invalid:443#node-x' \
  >"$tmp_dir/native-nodes/node-4.link"
printf '%s\n' 'vless://20000000-0000-4000-8000-000000000005@native.invalid:443#node%09space' \
  >"$tmp_dir/native-nodes/node-5.link"
printf '%s\n' 'vless://20000000-0000-4000-8000-000000000006@native.invalid:443#node%20space' \
  >"$tmp_dir/native-nodes/node-6.link"
printf '%s\n' 'vless://20000000-0000-4000-8000-000000000007@native.invalid:443#%01' \
  >"$tmp_dir/native-nodes/node-7.link"
printf '%s\n' 'vless://20000000-0000-4000-8000-000000000008@native.invalid:0#zero-port' \
  >"$tmp_dir/native-nodes/node-8.link"
printf '%s\n' 'vless://20000000-0000-4000-8000-000000000009@native.invalid:65536#high-port' \
  >"$tmp_dir/native-nodes/node-9.link"
printf '%s\n' 'vless://20000000-0000-4000-8000-000000000010@native.invalid:443.5#fractional-port' \
  >"$tmp_dir/native-nodes/node-10.link"
native_counts=$(
  (
    # shellcheck disable=SC2329
    magicnet_singbox_build_outbounds_file_with_jq() { return 1; }
    magicnet_singbox_build_outbounds_file \
      "$tmp_dir/native-nodes" "$tmp_dir/adversarial-native.fragment" "$tmp_dir/adversarial-native.tags"
  )
)
[[ "$native_counts" == '2 8' ]] || fail "native adversarial counts mismatch: $native_counts"
[[ "$(cat "$tmp_dir/adversarial-native.tags")" == $'node-x\nnode space' ]] ||
  fail "native adversarial accepted tags mismatch"
{ printf '{\n'; sed '$s/,$//' "$tmp_dir/adversarial-native.fragment"; printf '\n}\n'; } \
  >"$tmp_dir/adversarial-native.json"
jq -e '
  [.outbounds[]
    | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
        or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
    | .tag] as $node_tags
  | (.outbounds | INDEX(.tag)) as $by_tag
  | $node_tags == ["node-x", "node space"]
    and $by_tag["proxy-auto"].outbounds == $node_tags
    and ($by_tag["proxy-auto"].outbounds | index("proxy-auto")) == null
    and ([.outbounds[].tag] | length) == ([.outbounds[].tag] | unique | length)
' "$tmp_dir/adversarial-native.json" >/dev/null || fail "native adversarial tag filtering mismatch"
printf '[]\n' >"$tmp_dir/empty-nodes.json"
: >"$tmp_dir/empty-tags"
magicnet_singbox_write_outbounds_from_json "$tmp_dir/empty-nodes.json" "$tmp_dir/empty-jq.fragment"
{ printf '{\n'; sed 's/,$//' "$tmp_dir/empty-jq.fragment"; printf '\n}\n'; } >"$tmp_dir/empty-jq.json"
magicnet_singbox_emit_selector_block "$tmp_dir/empty-tags" >"$tmp_dir/empty-no-jq.fragment"
{ printf '{"outbounds":['; cat "$tmp_dir/empty-no-jq.fragment"; printf ']}\n'; } >"$tmp_dir/empty-no-jq.json"
for empty_config in "$tmp_dir/empty-jq.json" "$tmp_dir/empty-no-jq.json"; do
  jq -e '
    (.outbounds | INDEX(.tag)) as $by_tag
    | ([.outbounds[] | select(.tag == "proxy-auto")] | length) == 0
      and ($by_tag.proxy == {type: "selector", tag: "proxy", outbounds: ["block"], default: "block"})
      and ([.outbounds[] | select(.type == "selector")] | all(. as $selector
        | ($selector.outbounds | length) == ($selector.outbounds | unique | length)
          and (($selector.outbounds | index($selector.default)) != null)))
  ' "$empty_config" >/dev/null || fail "empty-node proxy fallback mismatch: $empty_config"
done
mkdir "$tmp_dir/no-jq-bin"
ln -s "$(command -v awk)" "$tmp_dir/no-jq-bin/awk"
ln -s "$(command -v mv)" "$tmp_dir/no-jq-bin/mv"
ln -s "$(command -v rm)" "$tmp_dir/no-jq-bin/rm"
jq . "$tmp_dir/no-jq.json" >"$tmp_dir/no-jq-pretty.json"
cp "$tmp_dir/adversarial-native.json" "$tmp_dir/no-jq-current.json"
cp "$tmp_dir/no-jq-current.json" "$tmp_dir/no-jq-current.before.json"
PATH="$tmp_dir/no-jq-bin" magicnet_singbox_sanitize_generated_config \
  "$tmp_dir/no-jq-current.json" || fail "no-jq sanitizer rejected current canonical input"
cmp -s "$tmp_dir/no-jq-current.before.json" "$tmp_dir/no-jq-current.json" ||
  fail "no-jq sanitizer rewrote current canonical input"
for legacy_format in compact pretty; do
  if [[ "$legacy_format" == "compact" ]]; then
    jq -c '(.outbounds[] | select(.tag == "proxy-auto")) |=
        (.url = "https://www.google.com/generate_204" | .interval = "10m")' \
      "$tmp_dir/adversarial-native.json" >"$tmp_dir/no-jq-legacy-$legacy_format.json"
  else
    jq '(.outbounds[] | select(.tag == "proxy-auto")) |=
        (.url = "https://www.google.com/generate_204" | .interval = "10m")' \
      "$tmp_dir/adversarial-native.json" >"$tmp_dir/no-jq-legacy-$legacy_format.json"
  fi
  cp "$tmp_dir/no-jq-legacy-$legacy_format.json" \
    "$tmp_dir/no-jq-legacy-$legacy_format.before.json"
  ! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical \
    "$tmp_dir/no-jq-legacy-$legacy_format.json" ||
    fail "pure-shell current canonical accepted $legacy_format legacy proxy-auto"
  PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical \
    "$tmp_dir/no-jq-legacy-$legacy_format.json" \
    "https://www.google.com/generate_204" "10m" ||
    fail "pure-shell legacy canonical rejected $legacy_format native fixture"
  if PATH="$tmp_dir/no-jq-bin" magicnet_singbox_sanitize_generated_config \
    "$tmp_dir/no-jq-legacy-$legacy_format.json"; then
    legacy_sanitize_rc=0
  else
    legacy_sanitize_rc=$?
  fi
  if ((legacy_sanitize_rc != 0)); then
    cmp -s "$tmp_dir/no-jq-legacy-$legacy_format.before.json" \
      "$tmp_dir/no-jq-legacy-$legacy_format.json" ||
      fail "failed no-jq sanitizer modified $legacy_format legacy input"
    fail "no-jq sanitizer returned $legacy_sanitize_rc for $legacy_format legacy proxy-auto"
  fi
  [[ -z "${_sanitize_return+x}" ]] || fail "no-jq sanitizer leaked _sanitize_return"
  jq -S '(.outbounds[] | select(.tag == "proxy-auto")) |=
      (.url = "<probe-url>" | .interval = "<probe-interval>")' \
    "$tmp_dir/no-jq-legacy-$legacy_format.before.json" \
    >"$tmp_dir/no-jq-legacy-$legacy_format.before.structure.json"
  jq -S '(.outbounds[] | select(.tag == "proxy-auto")) |=
      (.url = "<probe-url>" | .interval = "<probe-interval>")' \
    "$tmp_dir/no-jq-legacy-$legacy_format.json" \
    >"$tmp_dir/no-jq-legacy-$legacy_format.after.structure.json"
  cmp -s "$tmp_dir/no-jq-legacy-$legacy_format.before.structure.json" \
    "$tmp_dir/no-jq-legacy-$legacy_format.after.structure.json" ||
    fail "no-jq sanitizer changed fields outside proxy-auto probe policy"
  jq -e '
    (.outbounds | INDEX(.tag)) as $by_tag
    | $by_tag["proxy-auto"].url == "https://www.gstatic.com/generate_204"
      and $by_tag["proxy-auto"].interval == "3m"
      and (["ai-chatgpt-auto", "ai-gemini-auto", "ai-grok-auto", "ai-claude-auto"]
        | all(. as $tag | $by_tag[$tag].interval == "10m"))
  ' "$tmp_dir/no-jq-legacy-$legacy_format.json" >/dev/null ||
    fail "no-jq sanitizer produced wrong $legacy_format probe policy"
  magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-legacy-$legacy_format.json" ||
    fail "jq canonical validator rejected native no-jq $legacy_format repair"
  PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical \
    "$tmp_dir/no-jq-legacy-$legacy_format.json" ||
    fail "pure-shell canonical validator rejected native no-jq $legacy_format repair"
done
jq '(.outbounds[] | select(.tag == "proxy-auto")) |=
      (.url = "https://www.google.com/generate_204" | .interval = "10m")
    | (.outbounds[] | select(.tag == "ai-chatgpt-auto") | .interval) = "9m"' \
  "$tmp_dir/adversarial-native.json" >"$tmp_dir/no-jq-noncanonical-legacy.json"
cp "$tmp_dir/no-jq-noncanonical-legacy.json" "$tmp_dir/no-jq-noncanonical-legacy.before.json"
if PATH="$tmp_dir/no-jq-bin" magicnet_singbox_sanitize_generated_config \
  "$tmp_dir/no-jq-noncanonical-legacy.json"; then
  fail "no-jq sanitizer accepted a noncanonical file containing the legacy probe pair"
fi
cmp -s "$tmp_dir/no-jq-noncanonical-legacy.before.json" \
  "$tmp_dir/no-jq-noncanonical-legacy.json" ||
  fail "no-jq sanitizer modified rejected noncanonical input"
[[ ! -e "$tmp_dir/no-jq-noncanonical-legacy.json.sanitized" ]] ||
  fail "no-jq sanitizer left a temporary file for rejected input"
PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-pretty.json" || fail "pure-shell canonical validator rejected generated auto groups"
PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/syntax-base-compact.json" ||
  fail "pure-shell canonical validator rejected compact JSON"
PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/kamfw-proxy-runtime.json" ||
  fail "pure-shell canonical validator rejected kamfw proxy runtime field"
PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/structural-special-tag.json" ||
  fail "pure-shell canonical validator rejected nested special-tag config"
PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/valid-json-syntax-probe.json" ||
  fail "pure-shell canonical validator rejected valid JSON syntax probe"
for valid_literal_config in "${valid_literal_configs[@]}"; do
  PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$valid_literal_config" ||
    fail "pure-shell canonical validator rejected lowercase JSON literal: $valid_literal_config"
done
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/duplicate-proxy-node.json" 2>/dev/null ||
  fail "pure-shell canonical validator accepted duplicate proxy node tag"
PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/repaired-duplicate-proxy-node.json" ||
  fail "pure-shell canonical validator rejected repaired duplicate proxy nodes"
PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/schema-generated.json" ||
  fail "pure-shell canonical validator rejected all-protocol schema fixture"
for invalid_config in "${invalid_schema_node_configs[@]}"; do
  ! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$invalid_config" 2>/dev/null ||
    fail "pure-shell canonical validator accepted invalid type-specific proxy node: $invalid_config"
done
for invalid_config in "${invalid_configs[@]}"; do
  ! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$invalid_config" 2>/dev/null ||
    fail "pure-shell canonical validator accepted invalid JSON: $invalid_config"
done
for invalid_config in "${semantic_invalid_configs[@]}"; do
  ! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$invalid_config" 2>/dev/null ||
    fail "pure-shell canonical validator accepted invalid canonical fields: $invalid_config"
done
for invalid_config in "${invalid_proxy_node_configs[@]}"; do
  ! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$invalid_config" 2>/dev/null ||
    fail "pure-shell canonical validator accepted invalid proxy node: $invalid_config"
done
jq '(.outbounds[] | select(.tag == "ai-chatgpt-auto") | .url) = "https://invalid.example/"' \
  "$tmp_dir/no-jq-pretty.json" >"$tmp_dir/no-jq-bad-auto-url.json"
jq '(.outbounds[] | select(.tag == "ai-chatgpt-auto") | .outbounds) += ["stale-missing-node"]' \
  "$tmp_dir/no-jq-pretty.json" >"$tmp_dir/no-jq-bad-auto-member.json"
jq '(.outbounds[] | select(.tag == "proxy-auto") | .tolerance) = 100' \
  "$tmp_dir/no-jq-pretty.json" >"$tmp_dir/no-jq-stale-proxy-auto-tolerance.json"
jq 'del(.outbounds[] | select(.tag == "proxy-auto"))' \
  "$tmp_dir/no-jq-pretty.json" >"$tmp_dir/no-jq-missing-proxy-auto.json"
jq '.outbounds += [.outbounds[] | select(.tag == "proxy-auto")]' \
  "$tmp_dir/no-jq-pretty.json" >"$tmp_dir/no-jq-duplicate-proxy-auto.json"
jq '(.outbounds[] | select(.tag == "proxy-auto") | .url) = "https://invalid.example/"' \
  "$tmp_dir/no-jq-pretty.json" >"$tmp_dir/no-jq-malformed-proxy-auto.json"
jq '(.outbounds[] | select(.tag == "proxy-auto") | .outbounds) += ["stale-missing-node"]' \
  "$tmp_dir/no-jq-pretty.json" >"$tmp_dir/no-jq-stale-proxy-auto-member.json"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-bad-auto-url.json" 2>/dev/null || fail "pure-shell canonical validator accepted wrong auto URL"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-bad-auto-member.json" 2>/dev/null || fail "pure-shell canonical validator accepted stale auto member"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-stale-proxy-auto-tolerance.json" 2>/dev/null || fail "pure-shell canonical validator accepted stale proxy-auto tolerance"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-missing-proxy-auto.json" 2>/dev/null || fail "pure-shell canonical validator accepted missing proxy-auto"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-duplicate-proxy-auto.json" 2>/dev/null || fail "pure-shell canonical validator accepted duplicate proxy-auto"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-malformed-proxy-auto.json" 2>/dev/null || fail "pure-shell canonical validator accepted malformed proxy-auto"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-stale-proxy-auto-member.json" 2>/dev/null || fail "pure-shell canonical validator accepted stale proxy-auto member"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/stale-legacy-proxy-auto.json" 2>/dev/null || fail "pure-shell canonical validator accepted legacy proxy-auto probe policy"
magicnet_singbox_pinned_ai_tags "$tmp_dir/tags" >"$tmp_dir/pinned-ai-tags"
grep -Fxq 'CN2 premium' "$tmp_dir/pinned-ai-tags" || fail "CN2 false positive"
grep -Fxq 'opaque-42' "$tmp_dir/pinned-ai-tags" || fail "opaque node filtered"
! grep -Fxq '上海 node' "$tmp_dir/pinned-ai-tags" || fail "mainland node retained"
for tag in 'Mainland premium' 'Beijing edge' 'Shanghai edge' 'Guangzhou edge' 'Shenzhen edge' 'Sichuan edge' 'Inner-Mongolia edge' 'Xinjiang edge'; do
  ! grep -Fxq "$tag" "$tmp_dir/pinned-ai-tags" || fail "English mainland label retained: $tag"
done
for tag in '香港 edge' 'Hong Kong edge' 'Hong-Kong edge' 'Hong_Kong edge' 'HK edge' 'HKG edge' 'hk01 edge' 'hk-01 edge' 'hk_01 edge' 'HKG01 edge' 'HongKong01 edge'; do
  ! grep -Fxq "$tag" "$tmp_dir/pinned-ai-tags" || fail "Hong Kong label retained: $tag"
done
for tag in 'HKT edge' 'CHK edge' 'myhk edge'; do
  grep -Fxq "$tag" "$tmp_dir/pinned-ai-tags" || fail "Hong Kong boundary false positive: $tag"
done
jq 'del(.outbounds[] | select(.tag == "ai-chatgpt" or .tag == "ai-gemini" or .tag == "ai-grok" or .tag == "ai-claude"
      or .tag == "ai-chatgpt-auto" or .tag == "ai-gemini-auto" or .tag == "ai-grok-auto" or .tag == "ai-claude-auto"))' \
  "$tmp_dir/generated.json" >"$tmp_dir/legacy-cached.json"
cp "$tmp_dir/legacy-cached.json" "$tmp_dir/legacy-cached.before.json"
magicnet_singbox_sanitize_generated_config "$tmp_dir/legacy-cached.json"
jq -e '
  [
    {name: "ai-chatgpt", url: "https://chatgpt.com/"},
    {name: "ai-gemini", url: "https://gemini.google.com/"},
    {name: "ai-grok", url: "https://grok.com/"},
    {name: "ai-claude", url: "https://claude.ai/"}
  ] as $services
  | (.outbounds | INDEX(.tag)) as $by_tag
  | (.outbounds[] | select(.tag == "ai-proxy")) as $ai_proxy
  | ($ai_proxy.default == "US stable" and $ai_proxy.outbounds == ["US stable", "CN2 premium", "opaque-42", "HKT edge", "CHK edge", "myhk edge"])
    and ($services | all(. as $service
      | ($service.name + "-auto") as $auto
      | $by_tag[$service.name].type == "selector"
        and $by_tag[$service.name].default == $ai_proxy.outbounds[0]
        and $by_tag[$service.name].outbounds == ($ai_proxy.outbounds + ["block", $auto])
        and $by_tag[$auto].type == "urltest"
        and $by_tag[$auto].outbounds == $ai_proxy.outbounds
        and $by_tag[$auto].url == $service.url
        and $by_tag[$auto].interval == "10m"
        and $by_tag[$auto].tolerance == 30
        and $by_tag[$auto].idle_timeout == "10m"
        and $by_tag[$auto].interrupt_exist_connections == false
    ))
' "$tmp_dir/legacy-cached.json" >/dev/null || fail "legacy cached config AI selector repair mismatch"
jq '.outbounds += [
      {"type":"direct","tag":"ai-chatgpt"},
      {"type":"selector","tag":"ai-gemini","outbounds":["direct"],"default":"direct"},
      {"type":"selector","tag":"ai-chatgpt-auto","outbounds":["missing"]},
      {"type":"urltest","tag":"ai-chatgpt-auto","outbounds":["stale-missing-node"],"url":"https://invalid.example/"}
    ]
    | (.outbounds[] | select(.tag == "ai-grok") | .default) = "direct"' \
  "$tmp_dir/generated.json" >"$tmp_dir/malformed-cached.json"
cp "$tmp_dir/malformed-cached.json" "$tmp_dir/malformed-cached.before.json"
magicnet_singbox_sanitize_generated_config "$tmp_dir/malformed-cached.json"
jq -e '
  [
    {name: "ai-chatgpt", url: "https://chatgpt.com/"},
    {name: "ai-gemini", url: "https://gemini.google.com/"},
    {name: "ai-grok", url: "https://grok.com/"},
    {name: "ai-claude", url: "https://claude.ai/"}
  ] as $services
  | ($services | map([.name, (.name + "-auto")]) | add) as $expected_tags
  | (.outbounds | INDEX(.tag)) as $by_tag
  | (.outbounds[] | select(.tag == "ai-proxy")) as $ai_proxy
  | ([.outbounds[] | select(.tag as $tag | ($expected_tags | index($tag)) != null)] | length) == 8
    and ($ai_proxy.default == "US stable" and $ai_proxy.outbounds == ["US stable", "CN2 premium", "opaque-42", "HKT edge", "CHK edge", "myhk edge"])
    and ($services | all(. as $service
      | ($service.name + "-auto") as $auto
      | $by_tag[$service.name].type == "selector"
        and $by_tag[$service.name].default == $ai_proxy.outbounds[0]
        and $by_tag[$service.name].outbounds == ($ai_proxy.outbounds + ["block", $auto])
        and $by_tag[$auto].type == "urltest"
        and $by_tag[$auto].outbounds == $ai_proxy.outbounds
        and $by_tag[$auto].url == $service.url
        and $by_tag[$auto].interval == "10m"
        and $by_tag[$auto].tolerance == 30
        and $by_tag[$auto].idle_timeout == "10m"
        and $by_tag[$auto].interrupt_exist_connections == false
    ))
' "$tmp_dir/malformed-cached.json" >/dev/null || fail "malformed or duplicate AI selectors not canonicalized"
base_config="$MODULE_ROOT/.config/sing-box/config.json"
magicnet_singbox_ai_selectors_canonical "$base_config" || fail "jq canonical validator rejected fresh empty-node config"
jq 'del(.outbounds[] | select(.tag == "ai-chatgpt"))' "$base_config" >"$tmp_dir/no-jq-legacy.json"
jq '(.outbounds[] | select(.tag == "ai-grok") | .default) = "direct"' "$base_config" >"$tmp_dir/no-jq-malformed.json"
jq '(.outbounds[] | select(.tag == "ai-chatgpt") | .outbounds) += ["stale-missing-node"]' "$base_config" >"$tmp_dir/no-jq-stale-member.json"
jq 'del(.outbounds[] | select(.tag == "ai-proxy"))' "$base_config" >"$tmp_dir/no-jq-missing-ai-proxy.json"
jq '(.outbounds[] | select(.tag == "ai-proxy")) = {"type":"selector","tag":"ai-proxy","outbounds":["proxy"],"default":"proxy"}' \
  "$base_config" >"$tmp_dir/no-jq-generic-ai-proxy.json"
jq '(.outbounds[] | select(.tag == "ai-proxy")) = {"type":"selector","tag":"ai-proxy","outbounds":["上海 node"],"default":"上海 node"}' \
  "$tmp_dir/generated.json" >"$tmp_dir/mainland-ai-proxy.json"
jq '(.outbounds[] | select(.tag == "ai-proxy")) = {"type":"selector","tag":"ai-proxy","outbounds":["proxy-rule"],"default":"proxy-rule"}' \
  "$tmp_dir/generated.json" >"$tmp_dir/nested-selector-ai-proxy.json"
jq '(.outbounds[] | select(.tag == "ai-proxy") | .default) = "opaque-42"' \
  "$tmp_dir/generated.json" >"$tmp_dir/nonfirst-default-ai-proxy.json"
jq '(.outbounds[] | select(.tag == "ai-proxy")) = {"type":"selector","tag":"ai-proxy","outbounds":["block"],"default":"block"}' \
  "$tmp_dir/generated.json" >"$tmp_dir/block-with-nodes-ai-proxy.json"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/mainland-ai-proxy.json" 2>/dev/null || fail "jq canonical validator accepted mainland AI proxy"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/nested-selector-ai-proxy.json" 2>/dev/null || fail "jq canonical validator accepted nested selector AI proxy"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/nonfirst-default-ai-proxy.json" 2>/dev/null || fail "jq canonical validator accepted non-first AI proxy default"
! magicnet_singbox_ai_selectors_canonical "$tmp_dir/block-with-nodes-ai-proxy.json" 2>/dev/null || fail "jq canonical validator accepted block fallback with nodes"
PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$base_config" || fail "pure-shell canonical validator rejected fresh config"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-legacy.json" 2>/dev/null || fail "pure-shell canonical validator accepted missing selectors"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-malformed.json" 2>/dev/null || fail "pure-shell canonical validator accepted malformed selectors"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-stale-member.json" 2>/dev/null || fail "pure-shell canonical validator accepted undefined selector member"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-missing-ai-proxy.json" 2>/dev/null || fail "pure-shell canonical validator accepted missing AI proxy"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/no-jq-generic-ai-proxy.json" 2>/dev/null || fail "pure-shell canonical validator accepted generic AI proxy"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/mainland-ai-proxy.json" 2>/dev/null || fail "pure-shell canonical validator accepted mainland AI proxy"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/nested-selector-ai-proxy.json" 2>/dev/null || fail "pure-shell canonical validator accepted nested selector AI proxy"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/nonfirst-default-ai-proxy.json" 2>/dev/null || fail "pure-shell canonical validator accepted non-first AI proxy default"
! PATH="$tmp_dir/no-jq-bin" magicnet_singbox_ai_selectors_canonical "$tmp_dir/block-with-nodes-ai-proxy.json" 2>/dev/null || fail "pure-shell canonical validator accepted block fallback with nodes"
jq -e '
  ["ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude"] as $names
  | ($names | map(. + "-auto")) as $auto_names
  | [.outbounds[] | select(.tag as $tag | $names | index($tag))] as $groups
  | [.outbounds[] | select(.tag as $tag | $auto_names | index($tag))] as $auto_groups
  | ($groups | length) == 4
    and ($groups | all(.type == "selector" and .default == "block" and .outbounds == ["block"]))
    and ($auto_groups | length) == 0
' "$MODULE_ROOT/.config/sing-box/config.json" >/dev/null || fail "base config not fail closed"
jq -e '.outbounds[] | select(.tag == "ai-proxy") | .default == "block" and .outbounds == ["block"]' \
  "$MODULE_ROOT/.config/sing-box/config.json" >/dev/null || fail "base config AI proxy not fail closed"
python3 - "$MODULE_ROOT/.config/sing-box/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8")); rules = c["route"]["rules"]
groups = {"ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude"}
ai_domains = {
    "ai-chatgpt": {"openai.com", "chatgpt.com", "chat.openai.com", "auth.openai.com", "oaistatic.com", "oaiusercontent.com", "oaistatsig.com", "openaiapi-site.azureedge.net"},
    "ai-gemini": {"gemini.google.com", "bard.google.com", "generativelanguage.googleapis.com", "ai.google.dev"},
    "ai-grok": {"grok.com", "x.ai", "api.x.ai"},
    "ai-claude": {"anthropic.com", "claude.ai"},
}
ai_rule_sets = {"lyc-geosite-ai", "yuu-geosite-ai", "karing-acl4ssr-ai"}
generic_rule_sets = {"lyc-geosite-gfw", "ddch-gfw", "lyc-geosite-proxy", "metacubex-geosite-geolocation-not-cn", "ddch-proxy", "karing-acl4ssr-proxy-lite", "karing-acl4ssr-proxy-gfwlist"}
def rule_sets(rule):
    value = rule.get("rule_set", [])
    return set(value if isinstance(value, list) else [value])
broad_udp443_routes = [
    r for r in rules
    if r.get("network") == "udp"
    and r.get("port") == 443
    and r.get("outbound") == "proxy-rule"
    and ai_rule_sets <= rule_sets(r)
]
assert not broad_udp443_routes, broad_udp443_routes
generic_routes = [
    (i, r) for i, r in enumerate(rules)
    if r.get("outbound") == "proxy-rule" and generic_rule_sets <= rule_sets(r)
]
assert len(generic_routes) == 1, generic_routes
generic_index, generic_rule = generic_routes[0]
assert "network" not in generic_rule and "port" not in generic_rule, generic_rule
ai_routes = [
    (i, r) for i, r in enumerate(rules)
    if r.get("outbound") == "ai-proxy" and ai_rule_sets <= rule_sets(r)
]
assert len(ai_routes) == 1, ai_routes
ai_index, ai_rule = ai_routes[0]
assert "network" not in ai_rule and "port" not in ai_rule, ai_rule
assert ai_index < generic_index, (ai_index, generic_index)
for group, expected_domains in ai_domains.items():
    domain_routes = [
        i for i, r in enumerate(rules)
        if r.get("outbound") == group
        and set(r.get("domain_suffix", [])) == expected_domains
    ]
    assert len(domain_routes) == 1, (group, domain_routes)
generic = next(i for i, r in enumerate(rules) if r.get("outbound") == "ai-proxy" and "rule_set" in r)
assert all(any(i < generic and r.get("outbound") == group for i, r in enumerate(rules)) for group in groups)
domains = {}
for rule in rules:
    if rule.get("outbound") in groups:
        for domain in rule.get("domain_suffix", []):
            assert domain not in domains, (domain, domains[domain], rule["outbound"])
            domains[domain] = rule["outbound"]
for rule in rules:
    if rule.get("outbound") == "ai-proxy":
        assert not (set(rule.get("domain_suffix", [])) & set(domains))
packages = {r["outbound"]: set(r.get("package_name", [])) for r in rules if r.get("outbound") in groups and "package_name" in r}
assert {"com.openai.chatgpt", "com.openai.chat", "ai.openai.chatgpt"} <= packages["ai-chatgpt"]
assert "com.google.android.apps.bard" in packages["ai-gemini"]
assert "ai.x.grok" in packages["ai-grok"]
assert "com.anthropic.claude" in packages["ai-claude"]
PY
printf 'pinned AI routing test passed\n'

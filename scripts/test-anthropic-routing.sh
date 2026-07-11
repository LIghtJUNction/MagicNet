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
]
JSON
magicnet_singbox_write_outbounds_from_json "$tmp_dir/nodes.json" "$tmp_dir/outbounds.fragment"
{ printf '{\n'; sed 's/,$//' "$tmp_dir/outbounds.fragment"; printf '\n}\n'; } >"$tmp_dir/generated.json"
jq -e '
  ["ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude"] as $names
  | [.outbounds[] | select(.tag as $tag | $names | index($tag))] as $groups
  | ($groups | length) == 4
    and ($groups | all(.type == "selector" and .default == "block" and .outbounds == ["block", "US stable", "CN2 premium", "opaque-42", "HKT edge", "CHK edge", "hk01 edge", "myhk edge"] and (.outbounds | index("proxy") == null and index("direct") == null)))
' "$tmp_dir/generated.json" >/dev/null || fail "jq generator selector mismatch"
printf '%s\n' 'US stable' '上海 node' 'CN node' 'CN2 premium' 'opaque-42' 'Mainland premium' 'Beijing edge' 'Shanghai edge' 'Guangzhou edge' 'Shenzhen edge' 'Sichuan edge' 'Inner-Mongolia edge' 'Xinjiang edge' '香港 edge' 'Hong Kong edge' 'Hong-Kong edge' 'Hong_Kong edge' 'HK edge' 'HKG edge' 'HKT edge' 'CHK edge' 'hk01 edge' 'myhk edge' >"$tmp_dir/tags"
magicnet_singbox_emit_selector_block "$tmp_dir/tags" 'US stable' >"$tmp_dir/no-jq.fragment"
{ printf '{"outbounds":['; cat "$tmp_dir/no-jq.fragment"; printf ']}\n'; } >"$tmp_dir/no-jq.json"
jq -e '
  ["ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude"] as $names
  | [.outbounds[] | select(.tag as $tag | $names | index($tag))] as $groups
  | ($groups | length) == 4
    and ($groups | all(.type == "selector" and .default == "block" and .outbounds == ["block", "US stable", "CN2 premium", "opaque-42", "HKT edge", "CHK edge", "hk01 edge", "myhk edge"] and (.outbounds | index("proxy") == null and index("direct") == null)))
' "$tmp_dir/no-jq.json" >/dev/null || fail "no-jq generator selector mismatch"
magicnet_singbox_pinned_ai_tags "$tmp_dir/tags" >"$tmp_dir/pinned-ai-tags"
grep -Fxq 'CN2 premium' "$tmp_dir/pinned-ai-tags" || fail "CN2 false positive"
grep -Fxq 'opaque-42' "$tmp_dir/pinned-ai-tags" || fail "opaque node filtered"
! grep -Fxq '上海 node' "$tmp_dir/pinned-ai-tags" || fail "mainland node retained"
for tag in 'Mainland premium' 'Beijing edge' 'Shanghai edge' 'Guangzhou edge' 'Shenzhen edge' 'Sichuan edge' 'Inner-Mongolia edge' 'Xinjiang edge'; do
  ! grep -Fxq "$tag" "$tmp_dir/pinned-ai-tags" || fail "English mainland label retained: $tag"
done
for tag in '香港 edge' 'Hong Kong edge' 'Hong-Kong edge' 'Hong_Kong edge' 'HK edge' 'HKG edge'; do
  ! grep -Fxq "$tag" "$tmp_dir/pinned-ai-tags" || fail "Hong Kong label retained: $tag"
done
for tag in 'HKT edge' 'CHK edge' 'hk01 edge' 'myhk edge'; do
  grep -Fxq "$tag" "$tmp_dir/pinned-ai-tags" || fail "Hong Kong boundary false positive: $tag"
done
jq -e '
  ["ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude"] as $names
  | [.outbounds[] | select(.tag as $tag | $names | index($tag))]
  | length == 4 and all(.default == "block" and .outbounds == ["block"])
' "$MODULE_ROOT/.config/sing-box/config.json" >/dev/null || fail "base config not fail closed"
python3 - "$MODULE_ROOT/.config/sing-box/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8")); rules = c["route"]["rules"]
groups = {"ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude"}
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

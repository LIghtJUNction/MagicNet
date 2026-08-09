#!/bin/bash
# shellcheck source=hooks/lib/utils.sh

set -euo pipefail

. "$KAM_HOOKS_ROOT/lib/utils.sh"

require_command curl "curl not found!"
require_command jq "jq not found!"
require_command python3 "python3 not found!"

CONFIG_FILE="$KAM_MODULE_ROOT/.config/sing-box/config.json"
STATE_DIR="$KAM_MODULE_ROOT/.local/state/chatgpt-voice"
VOICE_URL="${MAGICNET_CHATGPT_VOICE_URL:-https://openai.com/chatgpt-voice.json}"

[ -f "$CONFIG_FILE" ] || {
    log_warn "sing-box config not found; ChatGPT Voice rule update skipped"
    exit 0
}

mkdir -p "$STATE_DIR"
VOICE_RESPONSE="$STATE_DIR/voice.json.tmp.$$"
CONFIG_CANDIDATE="$STATE_DIR/config.json.tmp.$$"

cleanup() {
    rm -f "$VOICE_RESPONSE" "$CONFIG_CANDIDATE"
}
trap cleanup EXIT HUP INT TERM

log_info "Refreshing ChatGPT Voice IP prefixes from OpenAI"
curl -fsSL --retry 3 --retry-delay 1 "$VOICE_URL" -o "$VOICE_RESPONSE" || {
    log_error "ChatGPT Voice prefix download failed"
    exit 1
}

jq -e '
  type == "object"
  and (.creationTime | type == "string" and length > 0)
  and (.prefixes | type == "array" and length > 0)
  and all(.prefixes[];
    type == "object"
    and ((has("ipv4Prefix") and (has("ipv6Prefix") | not))
      or (has("ipv6Prefix") and (has("ipv4Prefix") | not)))
    and ((.ipv4Prefix // .ipv6Prefix) | type == "string")
    and ((.ipv4Prefix // .ipv6Prefix) | test("^[0-9A-Fa-f:.]+/[0-9]{1,3}$"))
  )
' "$VOICE_RESPONSE" >/dev/null || {
    log_error "ChatGPT Voice prefix response is invalid or empty"
    exit 1
}

python3 - "$VOICE_RESPONSE" <<'PY' || {
import ipaddress
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    response = json.load(handle)

for item in response["prefixes"]:
    ipaddress.ip_network(item.get("ipv4Prefix") or item["ipv6Prefix"], strict=True)
PY
    log_error "ChatGPT Voice response contains an invalid IP prefix"
    exit 1
}

jq --slurpfile voice "$VOICE_RESPONSE" '
  ($voice[0].prefixes
    | map(.ipv4Prefix // .ipv6Prefix)
    | reduce .[] as $prefix ([]; if index($prefix) == null then . + [$prefix] else . end)
  ) as $prefixes
  | ([.route.rules | to_entries[]
      | select(
          .value.network == "udp"
          and .value.port == 3478
          and .value.outbound == "ai-chatgpt"
          and (.value.ip_cidr | type) == "array"
        )]) as $voice_rules
  | if ($voice_rules | length) != 1
    then error("expected exactly one canonical ChatGPT Voice route")
    else .route.rules[$voice_rules[0].key].ip_cidr = $prefixes
    end
' "$CONFIG_FILE" >"$CONFIG_CANDIDATE" || {
    log_error "Canonical ChatGPT Voice route is missing or ambiguous"
    exit 1
}

jq empty "$CONFIG_CANDIDATE"
if cmp -s "$CONFIG_FILE" "$CONFIG_CANDIDATE"; then
    log_info "ChatGPT Voice prefixes are already current"
else
    mv "$CONFIG_CANDIDATE" "$CONFIG_FILE"
    log_success "ChatGPT Voice prefixes updated"
fi
jq -r '.creationTime' "$VOICE_RESPONSE" >"$STATE_DIR/creation-time"

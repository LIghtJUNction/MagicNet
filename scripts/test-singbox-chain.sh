#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

command -v jq >/dev/null 2>&1 || {
  printf '%s\n' 'jq is required for the sing-box chain test' >&2
  exit 1
}

export MODDIR="$tmp/module"
mkdir -p "$MODDIR/.config/sing-box" "$MODDIR/.config/magicnet"

magicnet_warn() {
  printf '[warn] %s\n' "$1" >&2
}

. "$ROOT/src/MagicNet/lib/magicnet/chain.sh"

config="$MODDIR/.config/sing-box/config.json"
policy="$MODDIR/.config/magicnet/proxy-chain.json"

cat >"$config" <<'EOF'
{
  "outbounds": [
    {"type":"socks","tag":"node-us","server":"127.0.0.1","server_port":1080,"version":"5"},
    {"type":"socks","tag":"node-jp","server":"127.0.0.1","server_port":1081,"version":"5"},
    {"type":"urltest","tag":"proxy-auto","outbounds":["node-us","node-jp"],"url":"https://www.gstatic.com/generate_204","interval":"3m","tolerance":30,"idle_timeout":"10m","interrupt_exist_connections":false},
    {"type":"selector","tag":"proxy","outbounds":["node-us","node-jp","proxy-auto","direct","block"],"default":"node-us"},
    {"type":"selector","tag":"ai-proxy","outbounds":["node-us","node-jp"],"default":"node-us"},
    {"type":"urltest","tag":"ai-chatgpt-auto","outbounds":["node-us","node-jp"],"url":"https://chatgpt.com/","interval":"10m","tolerance":30,"idle_timeout":"10m","interrupt_exist_connections":false},
    {"type":"selector","tag":"ai-chatgpt","outbounds":["node-us","node-jp","block","ai-chatgpt-auto"],"default":"node-us"},
    {"type":"urltest","tag":"ai-gemini-auto","outbounds":["node-us","node-jp"],"url":"https://gemini.google.com/","interval":"10m","tolerance":30,"idle_timeout":"10m","interrupt_exist_connections":false},
    {"type":"selector","tag":"ai-gemini","outbounds":["node-us","node-jp","block","ai-gemini-auto"],"default":"node-us"},
    {"type":"urltest","tag":"ai-grok-auto","outbounds":["node-us","node-jp"],"url":"https://grok.com/","interval":"10m","tolerance":30,"idle_timeout":"10m","interrupt_exist_connections":false},
    {"type":"selector","tag":"ai-grok","outbounds":["node-us","node-jp","block","ai-grok-auto"],"default":"node-us"},
    {"type":"urltest","tag":"ai-claude-auto","outbounds":["node-us","node-jp"],"url":"https://claude.ai/","interval":"10m","tolerance":30,"idle_timeout":"10m","interrupt_exist_connections":false},
    {"type":"selector","tag":"ai-claude","outbounds":["node-us","node-jp","block","ai-claude-auto"],"default":"node-us"},
    {"type":"direct","tag":"direct"},
    {"type":"block","tag":"block"}
  ]
}
EOF

cat >"$policy" <<'EOF'
{
  "enabled": true,
  "mode": "manual",
  "upstream": ["node-jp"],
  "exit": ["node-us"]
}
EOF

magicnet_singbox_chain_apply "$config"
jq -e '
  ([.outbounds[].tag] | index("chain")) != null
  and ([.outbounds[].tag] | index("chain-hop1")) != null
  and ([.outbounds[].tag] | index("chain-exit")) != null
  and ([.outbounds[].tag] | index("chain-auto")) != null
  and ([.outbounds[].tag] | index("magicnet-chain-exit::node-us")) != null
  and (any(.outbounds[]; .tag == "proxy" and .default == "chain"))
  and (any(.outbounds[]; .tag == "ai-proxy" and .outbounds == ["chain","block"]))
  and (any(.outbounds[]; .tag == "ai-chatgpt-auto" and .outbounds == ["chain"]))
  and (any(.outbounds[]; .tag == "magicnet-chain-exit::node-us"
      and .detour == "chain-hop1" and .network == "tcp"))
' "$config" >/dev/null

if command -v sing-box >/dev/null 2>&1; then
  sing-box check -c "$config" -D "$(dirname "$config")" >/dev/null
fi

sha256sum "$config" | cut -d' ' -f1 >"$tmp/enabled.sha256"

cat >"$policy" <<'EOF'
{
  "enabled": false,
  "mode": "manual",
  "upstream": ["node-jp"],
  "exit": ["node-us"]
}
EOF

magicnet_singbox_chain_apply "$config"
jq -e '
  (all(.outbounds[]; ((.tag // "") | startswith("magicnet-chain-") | not)))
  and (all(.outbounds[]; (((.outbounds // []) | index("chain")) == null)))
  and (any(.outbounds[]; .tag == "proxy"
      and .outbounds == ["node-us","node-jp","proxy-auto","direct","block"]
      and .default == "node-us"))
  and (any(.outbounds[]; .tag == "ai-proxy"
      and .outbounds == ["node-us","node-jp"] and .default == "node-us"))
  and (any(.outbounds[]; .tag == "ai-chatgpt-auto" and .outbounds == ["node-us","node-jp"]))
  and (any(.outbounds[]; .tag == "ai-chatgpt"
      and .outbounds == ["node-us","node-jp","block","ai-chatgpt-auto"]
      and .default == "node-us"))
' "$config" >/dev/null

if command -v sing-box >/dev/null 2>&1; then
  sing-box check -c "$config" -D "$(dirname "$config")" >/dev/null
fi

sha256sum "$config" | cut -d' ' -f1 >"$tmp/disabled-before.sha256"
magicnet_singbox_chain_apply "$config"
sha256sum "$config" | cut -d' ' -f1 >"$tmp/disabled-after.sha256"
cmp "$tmp/disabled-before.sha256" "$tmp/disabled-after.sha256"

printf '%s\n' 'sing-box chain materialization and rollback test passed'

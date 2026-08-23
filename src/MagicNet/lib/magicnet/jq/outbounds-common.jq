def normalize_tag:
  if type == "string"
  then gsub("[\\r\\n\\t]"; " ") | gsub("[[:cntrl:]]"; "")
  else ""
  end;

def reserved_tag:
  . as $tag
  | [
      "proxy-auto", "proxy", "select", "lan", "hotspot", "ad-block", "ad-allow", "cn-direct",
      "chain", "chain-hop1", "chain-exit", "chain-auto",
      "apple-cn", "microsoft-cn", "google-cn", "icloud", "bing", "dns-guard", "network-test",
      "ai-proxy", "ai-chatgpt", "ai-chatgpt-auto", "ai-gemini", "ai-gemini-auto",
      "ai-grok", "ai-grok-auto", "ai-claude", "ai-claude-auto", "proxy-rule", "dev-proxy",
      "social-proxy", "media-proxy", "game-proxy", "telegram-proxy", "download-direct",
      "final", "direct", "block", "warp"
    ]
  | index($tag) != null or ($tag | startswith("magicnet-chain-"));

def valid_proxy_node:
  (.tag | type == "string" and length > 0 and (reserved_tag | not))
    and (.server | type == "string" and length > 0)
    and (.server_port
      | type == "number" and . == floor and . >= 1 and . <= 65535)
    and (if .type == "shadowsocks" then
        (.method | type == "string" and length > 0)
          and (.password | type == "string" and length > 0)
      elif .type == "vmess" or .type == "vless" then
        (.uuid | type == "string" and length > 0)
      elif .type == "trojan" or .type == "hysteria2" or .type == "anytls" then
        (.password | type == "string" and length > 0)
      elif .type == "tuic" then
        (.uuid | type == "string" and length > 0)
          and (.password | type == "string" and length > 0)
      elif .type == "socks" then
        (.version == "4" or .version == "4a" or .version == "5")
          and (((has("username") | not) and (has("password") | not))
            or ((.username | type == "string" and length > 0)
              and (.password | type == "string" and length > 0)))
      else false
      end);

def proxy_node_type:
  .type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
    or .type == "hysteria2" or .type == "anytls" or .type == "tuic" or .type == "socks";

def proxy_node_kind:
  ((.tag // "") | startswith("magicnet-chain-") | not) and proxy_node_type;

def proxy_node:
  proxy_node_type
    and ((.tag // "") | startswith("magicnet-chain-") | not)
    and (.tag | type == "string" and length > 0 and (reserved_tag | not))
    and (.server | type == "string" and length > 0)
    and (.server_port
      | type == "number" and . == floor and . >= 1 and . <= 65535)
    and (if .type == "shadowsocks" then
        (.method | type == "string" and length > 0)
          and (.password | type == "string" and length > 0)
      elif .type == "vmess" or .type == "vless" then
        (.uuid | type == "string" and length > 0)
      elif .type == "trojan" or .type == "hysteria2" or .type == "anytls" then
        (.password | type == "string" and length > 0)
      elif .type == "tuic" then
        (.uuid | type == "string" and length > 0)
          and (.password | type == "string" and length > 0)
      elif .type == "socks" then
        (.version == "4" or .version == "4a" or .version == "5")
          and (((has("username") | not) and (has("password") | not))
            or ((.username | type == "string" and length > 0)
              and (.password | type == "string" and length > 0)))
      else false
      end);

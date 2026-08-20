#!/bin/bash
# shellcheck source=hooks/lib/utils.sh

set -euo pipefail

. "$KAM_HOOKS_ROOT/lib/utils.sh"

require_command jq "jq not found!"

CONFIG_FILE="$KAM_MODULE_ROOT/.config/sing-box/config.json"
STATE_DIR="$KAM_MODULE_ROOT/.local/state/chatgpt-webview"
CONFIG_CANDIDATE="$STATE_DIR/config.json.tmp.$$"

[ -f "$CONFIG_FILE" ] || {
    log_warn "sing-box config not found; ChatGPT WebView route update skipped"
    exit 0
}

mkdir -p "$STATE_DIR"
cleanup() {
    rm -f "$CONFIG_CANDIDATE"
}
trap cleanup EXIT HUP INT TERM

# Android WebView can open sockets from an isolated process. Those connections
# may have neither package metadata nor a visible TLS hostname, so a poisoned or
# overlapping CN GeoIP entry can win before the ChatGPT domain rule. Give only
# the existing canonical ChatGPT domain set a small FakeIP pool, then route that
# pool to the fail-closed ChatGPT selector before destination-IP classification.
jq '
  "chatgpt-fakeip" as $server_tag
  | "198.18.0.0/24" as $fakeip_range
  | ([.route.rules[]
      | select(
          .outbound == "ai-chatgpt"
          and (.domain_suffix | type) == "array"
          and (.domain_suffix | index("chatgpt.com")) != null
        )
      | .domain_suffix]) as $domain_sets
  | (if ($domain_sets | length) != 1
      then error("expected exactly one canonical ChatGPT domain route")
      else $domain_sets[0]
    end) as $domains
  | {
      type: "fakeip",
      tag: $server_tag,
      inet4_range: $fakeip_range
    } as $fakeip_server
  | {
      domain_suffix: $domains,
      server: $server_tag
    } as $fakeip_dns_rule
  | {
      ip_cidr: [$fakeip_range],
      outbound: "ai-chatgpt"
    } as $fakeip_route_rule
  | ([.dns.servers[]? | select(.tag? == $server_tag)]) as $tagged_servers
  | if any($tagged_servers[]; . != $fakeip_server)
      then error("conflicting ChatGPT FakeIP DNS server")
      else .
    end
  | ([.dns.rules[]? | select(.server? == $server_tag)]) as $tagged_dns_rules
  | if any($tagged_dns_rules[]; . != $fakeip_dns_rule)
      then error("conflicting ChatGPT FakeIP DNS rule")
      else .
    end
  | ([.route.rules[]?
      | select((.ip_cidr? // []) == [$fakeip_range])]) as $fakeip_range_routes
  | if any($fakeip_range_routes[]; . != $fakeip_route_rule)
      then error("conflicting ChatGPT FakeIP route")
      else .
    end
  | .dns.servers = ([.dns.servers[] | select(.tag? != $server_tag)] + [$fakeip_server])
  | .dns.rules = [.dns.rules[] | select(.server? != $server_tag)]
  | ([.dns.rules | to_entries[]
      | select(
          .value.server? == "bootstrap-local-dns"
          and ((.value.rule_set? // []) | index("lyc-geosite-cn")) != null
          and ((.value.rule_set? // []) | index("lyc-geoip-cn")) != null
          and ((.value.rule_set? // []) | index("metacubex-geoip-cn")) != null
          and ((.value.rule_set? // []) | index("karing-acl4ssr-china-ip")) != null
        )
      | .key]) as $dns_cn
  | (if ($dns_cn | length) != 1
      then error("expected exactly one canonical CN DNS rule")
      else $dns_cn[0]
    end) as $dns_insert
  | .dns.rules = (
      .dns.rules[0:$dns_insert]
      + [$fakeip_dns_rule]
      + .dns.rules[$dns_insert:]
    )
  | .route.rules = [.route.rules[] | select((.ip_cidr? // []) != [$fakeip_range])]
  | ([.route.rules | to_entries[]
      | select(
          .value.outbound? == "cn-direct"
          and (.value.rule_set? // []) == [
            "lyc-geoip-cn",
            "metacubex-geoip-cn",
            "karing-acl4ssr-china-ip"
          ]
        )
      | .key]) as $route_cn_ip
  | (if ($route_cn_ip | length) != 1
      then error("expected exactly one canonical CN destination-IP route")
      else $route_cn_ip[0]
    end) as $route_insert
  | .route.rules = (
      .route.rules[0:$route_insert]
      + [$fakeip_route_rule]
      + .route.rules[$route_insert:]
    )
  | .experimental.cache_file.store_fakeip = true
' "$CONFIG_FILE" >"$CONFIG_CANDIDATE" || {
    log_error "Failed to install the canonical ChatGPT WebView route"
    exit 1
}

jq empty "$CONFIG_CANDIDATE"
if cmp -s "$CONFIG_FILE" "$CONFIG_CANDIDATE"; then
    log_info "ChatGPT WebView route is already current"
else
    mv -f "$CONFIG_CANDIDATE" "$CONFIG_FILE"
    log_success "ChatGPT WebView route installed"
fi

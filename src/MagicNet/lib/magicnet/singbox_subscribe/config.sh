magicnet_singbox_emitted_node_port_valid() {
    _emitted_port=$(printf '%s' "$1" |
        sed -n 's/.*"server_port":\([0-9][0-9]*\)[,}].*/\1/p')
    case "$_emitted_port" in
    '' | 0 | 0* | *[!0-9]*) return 1 ;;
    esac
    [ "$_emitted_port" -le 65535 ] 2>/dev/null
}

magicnet_singbox_build_outbounds_file() (
    _nodes_dir="$1"
    _out_file="$2"
    _tags_file="$3"
    trap 'rm -f "${_out_file}.nodes"' 0 1 2 3 15
    _first=1
    _imported=0
    _skipped=0

    : >"$_tags_file"
    printf '[' >"${_out_file}.nodes"
    for _node_file in "$_nodes_dir"/node-*.yaml "$_nodes_dir"/node-*.link; do
        [ -f "$_node_file" ] || continue
        case "$_node_file" in
        *.link) _json=$(magicnet_singbox_emit_share_link_json "$_node_file" 2>/dev/null) ;;
        *) _json=$(magicnet_singbox_emit_node_json "$_node_file" 2>/dev/null) ;;
        esac
        if [ -n "$_json" ] && magicnet_singbox_emitted_node_port_valid "$_json"; then
            _tag=$(printf '%s' "$_json" | sed -n 's/.*"tag":"\([^"]*\)".*/\1/p')
            if [ -z "$_tag" ] || magicnet_singbox_tag_is_reserved "$_tag" ||
                grep -F -x "$_tag" "$_tags_file" >/dev/null 2>&1 ||
                magicnet_singbox_is_info_tag "$_tag" ||
                magicnet_singbox_tag_matches_filter "$_tag"; then
                _skipped=$((_skipped + 1))
                continue
            fi
            [ "$_first" -eq 1 ] || printf ',' >>"${_out_file}.nodes"
            printf '%s' "$_json" >>"${_out_file}.nodes"
            printf '%s\n' "$_tag" >>"$_tags_file"
            _first=0
            _imported=$((_imported + 1))
        else
            _skipped=$((_skipped + 1))
        fi
    done
    printf ']' >>"${_out_file}.nodes"

    magicnet_singbox_build_outbounds_file_with_jq \
        "${_out_file}.nodes" "$_tags_file" "$_out_file" || return 1
    printf '%s %s\n' "$_imported" "$_skipped"
)

magicnet_singbox_build_outbounds_file_with_jq() (
    _nodes_json="$1"
    _tags_file="$2"
    _out_file="$3"
    command -v jq >/dev/null 2>&1 || return 1
    _tags_json="${_out_file}.tags.json"
    _out_tmp="${_out_file}.new.$$"
    trap 'rm -f "$_tags_json" "$_out_tmp"' 0 1 2 3 15
    _filter_file=$(magicnet_singbox_subscription_filter_file)
    [ -f "$_filter_file" ] || _filter_file=/dev/null
    jq -R -s 'split("\n") | map(select(length > 0))' "$_tags_file" >"$_tags_json" || return 1
    _ai_lib="$(magicnet_jq_ai_tags_lib)"
    jq -L "$_ai_lib" -n --slurpfile nodes "$_nodes_json" --slurpfile tags "$_tags_json" \
        --rawfile configured_filters "$_filter_file" -e 'include "ai-node-tags";
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
      def with_base($outs; $fallback):
        reduce ([$fallback] + $outs + ["direct", "block"])[] as $item
          ([]; if ($item == "" or index($item)) then . else . + [$item] end);
    def selector($tag; $outs; $fallback):
      (with_base($outs; $fallback)) as $items
      | {"type": "selector", "tag": $tag, "outbounds": $items, "default": $items[0]};
    def selector_exact($tag; $outs; $fallback):
      (reduce ([$fallback] + $outs)[] as $item
        ([]; if ($item == "" or index($item)) then . else . + [$item] end)) as $items
      | {"type": "selector", "tag": $tag, "outbounds": $items, "default": $fallback};
    def urltest($tag; $url; $interval; $tags):
      {"type": "urltest", "tag": $tag, "outbounds": $tags,
       "url": $url, "interval": $interval, "tolerance": 30, "idle_timeout": "10m",
       "interrupt_exist_connections": false};
    def proxy_selector($tags):
      if ($tags | length) > 0
        then {"type": "selector", "tag": "proxy",
              "outbounds": ($tags + ["proxy-auto", "direct", "block"]),
              "default": $tags[0]}
        else {"type": "selector", "tag": "proxy", "outbounds": ["block"], "default": "block"}
        end;
    def network_test_selector($tags):
      if ($tags | length) > 0
        then {"type": "selector", "tag": "network-test",
              "outbounds": ["proxy-auto", "proxy", "direct", "block"],
              "default": "proxy-auto"}
        else {"type": "selector", "tag": "network-test",
              "outbounds": ["block"], "default": "block"}
        end;
    def ai_proxy_selector($tags):
      if ($tags | length) > 0
        then {"type": "selector", "tag": "ai-proxy", "outbounds": $tags, "default": $tags[0]}
        else {"type": "selector", "tag": "ai-proxy", "outbounds": ["block"], "default": "block"}
        end;
    def ai_urltest($tag; $url; $tags):
      urltest(($tag + "-auto"); $url; "10m"; $tags);
    # Manual-first: list all eligible nodes, default to first node.
    # Keep *-auto urltest as an optional choice for users who still want auto.
    def pinned_ai_selector($tag; $tags):
      if ($tags | length) > 0
      then {"type": "selector", "tag": $tag,
            "outbounds": ($tags + ["block", ($tag + "-auto")]),
            "default": $tags[0]}
      else {"type": "selector", "tag": $tag, "outbounds": ["block"], "default": "block"}
      end;
    def ai_service_outbounds($tags):
      [
        {tag: "ai-chatgpt", url: "https://chatgpt.com/"},
        {tag: "ai-gemini", url: "https://gemini.google.com/"},
        {tag: "ai-grok", url: "https://grok.com/"},
        {tag: "ai-claude", url: "https://claude.ai/"}
      ]
      | map(. as $service
          | if ($tags | length) > 0
            then [ai_urltest($service.tag; $service.url; $tags), pinned_ai_selector($service.tag; $tags)]
            else [pinned_ai_selector($service.tag; $tags)]
            end)
      | add;
      ($configured_filters
        | split("\n")
        | map(gsub("\r"; "") | select(length > 0) | ascii_downcase)) as $filters
      | ($nodes[0] // []
        | map(.tag = ((.tag // "") | normalize_tag))
        | map(select(
            valid_proxy_node
            and (((.tag // "") | test("剩余流量|到期|过期|套餐|官网|订阅|Traffic|traffic|Expire|expire|Expired|expired|Subscription|subscription|官方网站|更新订阅")) | not)
            and ((.tag // "" | ascii_downcase) as $tag
              | ($filters | any(. as $filter | $tag | contains($filter))) | not)
          ))
        | reduce .[] as $node
            ([]; if (map(.tag) | index($node.tag)) != null then . else . + [$node] end)
      ) as $nodes
      | ([ $nodes[] | .tag ]) as $tags
      | ($tags | prioritize_ai_tags) as $ai_tags
      | (if ($tags | length) > 0
          then [urltest("proxy-auto"; "https://www.gstatic.com/generate_204"; "3m"; $tags)]
          else []
        end) + [
          proxy_selector($tags),
          selector("select"; ["proxy", "direct"]; "proxy"),
          selector("lan"; ["direct"]; "direct"),
          selector_exact("hotspot"; ["direct", "proxy"]; "direct"),
          selector("ad-block"; ["block", "direct", "proxy"]; "block"),
          selector_exact("ad-allow"; ["final", "direct", "proxy"]; "final"),
          selector("cn-direct"; ["direct", "proxy"]; "direct"),
          selector("apple-cn"; ["direct", "proxy"]; "direct"),
          selector("microsoft-cn"; ["direct", "proxy"]; "direct"),
          selector("icloud"; ["direct", "proxy"]; "direct"),
          selector("bing"; ["proxy", "direct"]; "proxy"),
          selector("dns-guard"; ["proxy", "block", "direct"]; "proxy"),
          network_test_selector($tags),
          ai_proxy_selector($ai_tags)
        ] + ai_service_outbounds($ai_tags) + [
          selector("proxy-rule"; ["proxy", "direct"]; "proxy"),
          selector("dev-proxy"; ["proxy", "direct"]; "proxy"),
          selector("social-proxy"; ["proxy", "direct"]; "proxy"),
          selector("media-proxy"; ["proxy", "direct"]; "proxy"),
          selector("game-proxy"; ["proxy", "direct"]; "proxy"),
          selector("telegram-proxy"; ["proxy", "direct"]; "proxy"),
          selector("download-direct"; ["direct", "proxy"]; "direct"),
          selector("final"; ["proxy", "direct", "block"]; "proxy")
        ] + $nodes + [
          {"type": "direct", "tag": "direct"},
          {"type": "block", "tag": "block"}
        ]
    ' >"$_out_tmp" || return 1
    chmod 600 "$_out_tmp" && mv -f "$_out_tmp" "$_out_file"
)

magicnet_singbox_count_valid_outbounds_nodes() {
    _nodes_json="$1"
    command -v jq >/dev/null 2>&1 || return 1
    jq -n -r --slurpfile nodes "$_nodes_json" '
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
      ($nodes[0] // []
        | map(.tag = ((.tag // "") | normalize_tag))
        | map(select(
            valid_proxy_node
            and (((.tag // "") | test("剩余流量|到期|过期|套餐|官网|订阅|Traffic|traffic|Expire|expire|Expired|expired|Subscription|subscription|官方网站|更新订阅")) | not)
          ))
        | reduce .[] as $node
            ([]; if (map(.tag) | index($node.tag)) != null then . else . + [$node] end)
        | length
      ) // 0
    '
}

magicnet_singbox_sanitize_generated_config() {
    _sanitize_config_file="$1"
    _sanitize_jq="$(command -v jq 2>/dev/null || true)"
    _sanitize_filter_file=$(magicnet_singbox_subscription_filter_file)
    [ -f "$_sanitize_filter_file" ] || _sanitize_filter_file=/dev/null
    [ -n "$_sanitize_jq" ] || return 1

    _sanitize_tmp_file="${_sanitize_config_file}.sanitized"
    _sanitize_ai_lib="$(magicnet_jq_ai_tags_lib)"
    # shellcheck disable=SC2016
    (
        umask 077
        "$_sanitize_jq" -L "$_sanitize_ai_lib" --rawfile configured_filters "$_sanitize_filter_file" -e 'include "ai-node-tags";
      def proxy_node_type:
        .type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
          or .type == "hysteria2" or .type == "anytls" or .type == "tuic" or .type == "socks";
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
      def dedupe_proxy_nodes:
        reduce .[] as $outbound (
          {items: [], node_tags: []};
          if ($outbound | proxy_node) then
            ($outbound.tag // "") as $tag
            | if (.node_tags | index($tag)) == null
              then .items += [$outbound] | .node_tags += [$tag]
              else .
              end
          elif ($outbound | proxy_node_type) then .
          else .items += [$outbound]
          end
        )
        | .items;
      def proxy_urltest($tags):
        {"type": "urltest", "tag": "proxy-auto", "outbounds": $tags,
         "url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 30,
         "idle_timeout": "10m", "interrupt_exist_connections": false};
      def proxy_selector($tags):
        if ($tags | length) > 0
        then {"type": "selector", "tag": "proxy",
              "outbounds": ($tags + ["proxy-auto", "direct", "block"]), "default": $tags[0]}
        else {"type": "selector", "tag": "proxy", "outbounds": ["block"], "default": "block"}
        end;
      def proxy_outbounds($tags):
        if ($tags | length) > 0 then [proxy_urltest($tags), proxy_selector($tags)]
        else [proxy_selector($tags)]
        end;
      def ai_proxy_selector($tags):
        if ($tags | length) > 0
        then {"type": "selector", "tag": "ai-proxy", "outbounds": $tags, "default": $tags[0]}
        else {"type": "selector", "tag": "ai-proxy", "outbounds": ["block"], "default": "block"}
        end;
      def ai_urltest($tag; $url; $tags):
        {"type": "urltest", "tag": ($tag + "-auto"), "outbounds": $tags,
         "url": $url, "interval": "10m", "tolerance": 30, "idle_timeout": "10m",
         "interrupt_exist_connections": false};
      # Manual-first AI service selectors
      def pinned_ai_selector($tag; $tags):
        if ($tags | length) > 0
        then {"type": "selector", "tag": $tag,
              "outbounds": ($tags + ["block", ($tag + "-auto")]),
              "default": $tags[0]}
        else {"type": "selector", "tag": $tag, "outbounds": ["block"], "default": "block"}
        end;
      def ai_service_outbounds($tags):
        [
          {tag: "ai-chatgpt", url: "https://chatgpt.com/"},
          {tag: "ai-gemini", url: "https://gemini.google.com/"},
          {tag: "ai-grok", url: "https://grok.com/"},
          {tag: "ai-claude", url: "https://claude.ai/"}
        ]
        | map(. as $service
            | if ($tags | length) > 0
              then [ai_urltest($service.tag; $service.url; $tags), pinned_ai_selector($service.tag; $tags)]
              else [pinned_ai_selector($service.tag; $tags)]
              end)
        | add;
      def has_match($rule):
        [
          "inbound",
          "clash_mode",
          "package_name",
          "domain",
          "domain_suffix",
          "domain_keyword",
          "rule_set",
          "network",
          "port",
          "protocol",
          "ip_cidr",
          "ip_is_private",
          "source_ip_cidr",
          "source_port",
          "process_name",
          "user",
          "user_id"
        ] | any(. as $key | $rule | has($key));
      ($configured_filters
        | split("\n")
        | map(gsub("\r"; "") | select(length > 0) | ascii_downcase)) as $filters
      | (.outbounds // []) as $outbounds
      | ($outbounds
          | map(select(
              (proxy_node
                and ((.tag // "" | ascii_downcase) as $tag
                  | $filters | any(. as $filter | $tag | contains($filter)))) | not
            ))
          | dedupe_proxy_nodes) as $deduped_outbounds
      | ([$deduped_outbounds[]
          | select(proxy_node)
          | .tag // empty]) as $node_tags
      | ($node_tags | prioritize_ai_tags) as $ai_tags
      | .outbounds = ($deduped_outbounds
          | map(select(.tag as $tag | [
              "proxy", "proxy-auto", "chain", "chain-hop1", "chain-exit", "chain-auto",
              "ai-proxy",
              "ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude",
              "ai-chatgpt-auto", "ai-gemini-auto", "ai-grok-auto", "ai-claude-auto"
            ] | index($tag) == null))
          | (proxy_outbounds($node_tags) + .)
          | if any(.tag == "dns-guard") then .
            else . + [{"type": "selector", "tag": "dns-guard", "outbounds": ["proxy", "block", "direct"], "default": "proxy"}]
            end
          | . + [ai_proxy_selector($ai_tags)]
          | . + ai_service_outbounds($ai_tags))
      | .route.rules = ((.route.rules // [])
        | map(select(((has("outbound") and (has_match(.) | not) and (has("action") | not)) | not))))
    ' "$_sanitize_config_file" >"$_sanitize_tmp_file"
    ) &&
        chmod 600 "$_sanitize_tmp_file" &&
        mv -f "$_sanitize_tmp_file" "$_sanitize_config_file" &&
        chmod 600 "$_sanitize_config_file"
    _sanitize_rc=$?
    [ "$_sanitize_rc" -eq 0 ] || rm -f "$_sanitize_tmp_file" 2>/dev/null || true
    if [ "$_sanitize_rc" -eq 0 ]; then
        unset _sanitize_config_file _sanitize_jq _sanitize_filter_file _sanitize_tmp_file _sanitize_rc _sanitize_return
        return 0
    fi
    unset _sanitize_config_file _sanitize_jq _sanitize_filter_file _sanitize_tmp_file _sanitize_rc _sanitize_return
    return 1
}

magicnet_singbox_update_config_with_nodes() (
    _config_file=$(magicnet_singbox_subscription_config_file)
    _outbounds_file="$1"
    _tmp_file="${_config_file}.new"
    trap 'rm -f "$_tmp_file"' 0 1 2 3 15

    _update_jq="$(command -v jq 2>/dev/null || true)"
    [ -n "$_update_jq" ] || return 1
    (
        umask 077
        "$_update_jq" --rawfile generated_outbounds "$_outbounds_file" '
      def decoded_outbounds:
        try ($generated_outbounds | fromjson)
        catch ($generated_outbounds
          | sub(",[[:space:]]*$"; "")
          | ("{" + . + "}")
          | fromjson
          | .outbounds);
      (decoded_outbounds) as $generated
      | if ($generated | type) == "array" then
          .outbounds = $generated
        else
          error("generated outbounds must be a JSON array")
        end
    ' "$_config_file" >"$_tmp_file"
    ) || return 1

    magicnet_singbox_sanitize_generated_config "$_tmp_file" || {
        error "Generated sing-box config failed sanitization"
        return 1
    }

    magicnet_singbox_chain_apply "$_tmp_file" || {
        error "Generated sing-box config failed proxy chain materialization"
        return 1
    }

    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "$_tmp_file" -D "${_config_file%/*}" >/dev/null || {
            error "Generated sing-box config failed validation"
            return 1
        }
    fi

    chmod 600 "$_tmp_file" &&
        mv -f "$_tmp_file" "$_config_file" &&
        chmod 600 "$_config_file" || return 1
    trap - 0 1 2 3 15
)

magicnet_singbox_replay_cached_outbounds() {
    _cached_outbounds="${MODDIR}/.state/sing-box/subscription-work/outbounds.json"
    [ -s "$_cached_outbounds" ] || {
        unset _cached_outbounds
        return 1
    }
    grep -Eq '"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks|anytls|tuic|socks)"' \
        "$_cached_outbounds" || {
        unset _cached_outbounds
        return 1
    }

    _config_file=$(magicnet_singbox_subscription_config_file)
    _previous_config="${_config_file}.cache-replay.previous"
    (
        umask 077
        cp -f "$_config_file" "$_previous_config"
    ) || {
        unset _cached_outbounds _config_file _previous_config
        return 1
    }
    if magicnet_singbox_update_config_with_nodes "$_cached_outbounds" &&
        magicnet_singbox_verify_subscription_ready; then
        rm -f "$_previous_config"
        unset _cached_outbounds _config_file _previous_config
        return 0
    fi

    chmod 600 "$_previous_config" 2>/dev/null &&
        mv -f "$_previous_config" "$_config_file" 2>/dev/null &&
        chmod 600 "$_config_file" 2>/dev/null || true
    unset _cached_outbounds _config_file _previous_config
    return 1
}

magicnet_singbox_config_has_clash_api() {
    _api_config="$1"
    [ -f "$_api_config" ] || {
        unset _api_config
        return 1
    }
    _api_jq="${MODDIR:-}/bin/jq"
    [ -x "$_api_jq" ] || _api_jq="$(command -v jq 2>/dev/null || true)"
    if [ -n "$_api_jq" ] &&
        "$_api_jq" -e '
            (.experimental.clash_api.external_controller // "")
            | type == "string" and length > 0
        ' "$_api_config" >/dev/null 2>&1; then
        unset _api_config _api_jq
        return 0
    fi
    if [ -z "$_api_jq" ] &&
        awk '
            /"clash_api"[[:space:]]*:[[:space:]]*\{/ { in_clash_api = 1; next }
            in_clash_api &&
                /"external_controller"[[:space:]]*:[[:space:]]*"[^"]+"/ {
                found_controller = 1
            }
            in_clash_api && /\}/ { in_clash_api = 0 }
            END { exit(found_controller ? 0 : 1) }
        ' "$_api_config"; then
        unset _api_config _api_jq
        return 0
    fi
    unset _api_config _api_jq
    return 1
}

# Process discovery uses a tri-state contract throughout this file:
#   0 = one or more matching processes were found
#   1 = the process set is authoritatively empty
#   2 = discovery or identity is indeterminate
# Callers must preserve 2 and must never interpret it as an empty process set.
magicnet_singbox_pid_live() (
    _live_pid="$1"
    case "$_live_pid" in
    '' | *[!0-9]* | 0) return 1 ;;
    esac
    _live_proc_root="$(magicnet_runtime_proc_root "" "${MAGICNET_SINGBOX_PROC_ROOT:-}")"
    _live_proc_dir="$_live_proc_root/$_live_pid"
    [ -d "$_live_proc_dir" ] || {
        unset _live_pid _live_proc_root _live_proc_dir
        return 1
    }
    _live_state="$(magicnet_proc_state "$_live_pid" "$_live_proc_root")" || {
        if [ -d "$_live_proc_dir" ]; then
            _live_rc=2
        else
            _live_rc=1
        fi
        unset _live_pid _live_proc_root _live_proc_dir _live_state
        return "$_live_rc"
    }
    [ -n "$_live_state" ] && [ "$_live_state" != Z ]
    _live_rc=$?
    unset _live_pid _live_proc_root _live_proc_dir _live_state
    return "$_live_rc"
)

magicnet_singbox_pids_to_file() (
    _singbox_output="$1"
    [ -f "$_singbox_output" ] && [ ! -L "$_singbox_output" ] || return 2
    chmod 600 "$_singbox_output" 2>/dev/null || return 2
    : >"$_singbox_output" || return 2
    _singbox_proc_root="$(magicnet_runtime_proc_root "" "${MAGICNET_SINGBOX_PROC_ROOT:-}")"
    _singbox_candidates=$(magicnet_proc_query_temp_create) || return 2
    _singbox_found=0

    if [ "$_singbox_proc_root" = /proc ] || command -v pidof >/dev/null 2>&1; then
        if magicnet_proc_named_pids_to_file sing-box "$_singbox_candidates"; then
            _singbox_lookup_rc=0
        else
            _singbox_lookup_rc=$?
        fi
        case "$_singbox_lookup_rc" in
        1)
            rm -f "$_singbox_candidates"
            return 1
            ;;
        0) ;;
        *)
            rm -f "$_singbox_candidates"
            return 2
            ;;
        esac
    else
        # Only custom test roots may use the bounded per-entry fallback.
        for _proc_comm in "$_singbox_proc_root"/[0-9]*/comm; do
            [ -r "$_proc_comm" ] || continue
            _pid=${_proc_comm#"$_singbox_proc_root"/}
            _pid=${_pid%/comm}
            _proc_name="$(magicnet_proc_comm "$_pid" "$_singbox_proc_root")" || {
                [ -d "$_singbox_proc_root/$_pid" ] || continue
                rm -f "$_singbox_candidates"
                unset _singbox_output _singbox_proc_root _singbox_candidates
                unset _singbox_found _proc_comm _proc_name _pid
                return 2
            }
            [ "$_proc_name" = sing-box ] || continue
            printf '%s\n' "$_pid" >>"$_singbox_candidates" || {
                rm -f "$_singbox_candidates"
                return 2
            }
        done
    fi

    _singbox_loop_rc=0
    while IFS= read -r _pid; do
        if magicnet_singbox_pid_live "$_pid"; then
            _singbox_live_rc=0
        else
            _singbox_live_rc=$?
        fi
        case "$_singbox_live_rc" in
        0)
            if printf '%s\n' "$_pid" >>"$_singbox_output"; then
                _singbox_found=1
            else
                _singbox_loop_rc=2
                break
            fi
            ;;
        1) ;;
        *)
            _singbox_loop_rc=2
            break
            ;;
        esac
    done <"$_singbox_candidates"
    rm -f "$_singbox_candidates"
    if [ "$_singbox_loop_rc" -eq 2 ]; then
        : >"$_singbox_output" 2>/dev/null || true
        return 2
    fi
    _singbox_rc=1
    [ "$_singbox_found" -eq 0 ] || _singbox_rc=0
    unset _singbox_output _singbox_proc_root _singbox_candidates
    unset _singbox_found _singbox_lookup_rc _singbox_live_rc _pid _proc_comm _proc_name
    return "$_singbox_rc"
)

# Compatibility emitter for diagnostics/tests. Lifecycle code must use the
# explicit *_to_file API so command substitution cannot erase the tri-state.
magicnet_singbox_pids() (
    _singbox_emit=$(magicnet_proc_query_temp_create) || return 2
    if magicnet_singbox_pids_to_file "$_singbox_emit"; then
        _singbox_emit_rc=0
    else
        _singbox_emit_rc=$?
    fi
    if [ "$_singbox_emit_rc" -eq 0 ]; then
        while IFS= read -r _singbox_emit_pid; do
            printf '%s\n' "$_singbox_emit_pid"
        done <"$_singbox_emit"
    fi
    rm -f "$_singbox_emit"
    unset _singbox_emit _singbox_emit_pid
    return "$_singbox_emit_rc"
)

magicnet_singbox_pid_owned() (
    _owned_pid="$1"
    _owned_config="$2"
    if magicnet_singbox_pid_live "$_owned_pid"; then
        _owned_live_rc=0
    else
        _owned_live_rc=$?
    fi
    [ "$_owned_live_rc" -ne 2 ] || return 2
    [ "$_owned_live_rc" -eq 0 ] || return 1
    [ -x "${MODDIR}/bin/sing-box" ] || return 2
    _owned_expected=$(readlink -f "${MODDIR}/bin/sing-box" 2>/dev/null) || return 2
    _owned_proc_root="$(magicnet_runtime_proc_root "" "${MAGICNET_SINGBOX_PROC_ROOT:-}")"
    _owned_proc_dir="$_owned_proc_root/$_owned_pid"
    _owned_comm="$(magicnet_proc_comm "$_owned_pid" "$_owned_proc_root")" || {
        [ -d "$_owned_proc_dir" ] && return 2
        return 1
    }
    [ "$_owned_comm" = sing-box ] || return 1
    _owned_exe_link=$(readlink "$_owned_proc_dir/exe" 2>/dev/null || true)
    _owned_exe_visible=0
    _owned_exe_match=0
    if [ -n "$_owned_exe_link" ]; then
        _owned_exe_path=${_owned_exe_link% (deleted)}
        _owned_exe_visible=1
        [ "$_owned_exe_path" = "$_owned_expected" ] && _owned_exe_match=1
    fi
    _owned_argv=$(magicnet_proc_query_temp_create) || return 2
    magicnet_proc_cmdline_lines "$_owned_pid" "$_owned_proc_root" >"$_owned_argv" 2>/dev/null
    _owned_argv_rc=$?
    if [ "$_owned_argv_rc" -ne 0 ]; then
        rm -f "$_owned_argv"
        [ -d "$_owned_proc_dir" ] && return 2
        return 1
    fi

    _argv_count=0
    _argv1=
    _argv2=
    _argv3=
    _argv4=
    _argv5=
    _argv6=
    _argv7=
    while IFS= read -r _argv_arg || [ -n "$_argv_arg" ]; do
        _argv_count=$((_argv_count + 1))
        case "$_argv_count" in
        1) _argv1="$_argv_arg" ;;
        2) _argv2="$_argv_arg" ;;
        3) _argv3="$_argv_arg" ;;
        4) _argv4="$_argv_arg" ;;
        5) _argv5="$_argv_arg" ;;
        6) _argv6="$_argv_arg" ;;
        7) _argv7="$_argv_arg" ;;
        *) _argv_count=8; break ;;
        esac
    done <"$_owned_argv"
    rm -f "$_owned_argv"

    _argv_direct=0
    if [ "$_argv_count" -eq 6 ] &&
        { [ "$_argv1" = "$_owned_expected" ] ||
            [ "$_argv1" = "${MODDIR}/bin/sing-box" ] ||
            [ "$_argv1" = sing-box ]; } &&
        [ "$_argv2" = run ] && [ "$_argv3" = -c ] &&
        [ "$_argv4" = "$_owned_config" ] && [ "$_argv5" = -D ] &&
        [ "$_argv6" = "${_owned_config%/*}" ]; then
        _argv_direct=1
    fi
    _argv_wrapper=0
    case "${_argv1##*/}" in
    sh | ash | dash | bash | ksh | mksh)
        if [ "$_argv_count" -eq 7 ] &&
            { [ "$_argv2" = "$_owned_expected" ] ||
                [ "$_argv2" = "${MODDIR}/bin/sing-box" ]; } &&
            [ "$_argv3" = run ] && [ "$_argv4" = -c ] &&
            [ "$_argv5" = "$_owned_config" ] && [ "$_argv6" = -D ] &&
            [ "$_argv7" = "${_owned_config%/*}" ]; then
            _argv_wrapper=1
        fi
        ;;
    esac
    # Some Android launchers publish argv as `sing-box sing-box run ...` while
    # hiding /proc/<pid>/exe. Accept only that complete, position-anchored form.
    _argv_compat=0
    if [ "$_argv_count" -eq 7 ] && [ "$_argv1" = sing-box ] &&
        [ "$_argv2" = sing-box ] && [ "$_argv3" = run ] &&
        [ "$_argv4" = -c ] && [ "$_argv5" = "$_owned_config" ] &&
        [ "$_argv6" = -D ] && [ "$_argv7" = "${_owned_config%/*}" ]; then
        _argv_compat=1
    fi
    _owned_rc=1
    if { [ "$_argv_direct" -eq 1 ] || [ "$_argv_wrapper" -eq 1 ] ||
        [ "$_argv_compat" -eq 1 ]; } && {
        [ "$_owned_exe_match" -eq 1 ] || [ "$_argv_wrapper" -eq 1 ] ||
            { [ "$_owned_exe_visible" -eq 0 ] &&
                { [ "$_argv_direct" -eq 1 ] || [ "$_argv_compat" -eq 1 ]; }; }
    }; then
        _owned_rc=0
    fi
    unset _owned_pid _owned_config _owned_live_rc _owned_expected _owned_proc_root
    unset _owned_proc_dir _owned_comm _owned_exe_link _owned_exe_visible
    unset _owned_exe_match _owned_exe_path _owned_argv _owned_argv_rc
    unset _argv_count _argv1 _argv2 _argv3 _argv4 _argv5 _argv6 _argv7
    unset _argv_arg _argv_direct _argv_wrapper _argv_compat
    return "$_owned_rc"
)

magicnet_singbox_owned_pids_to_file() (
    _owned_list_config="$1"
    _owned_list_output="$2"
    [ -f "$_owned_list_output" ] && [ ! -L "$_owned_list_output" ] || return 2
    chmod 600 "$_owned_list_output" 2>/dev/null || return 2
    : >"$_owned_list_output" || return 2
    _owned_list_candidates=$(magicnet_proc_query_temp_create) || return 2
    if magicnet_singbox_pids_to_file "$_owned_list_candidates"; then
        _owned_list_lookup_rc=0
    else
        _owned_list_lookup_rc=$?
    fi
    case "$_owned_list_lookup_rc" in
    1)
        rm -f "$_owned_list_candidates"
        return 1
        ;;
    0) ;;
    *)
        rm -f "$_owned_list_candidates"
        return 2
        ;;
    esac
    _owned_list_found=0
    _owned_list_loop_rc=0
    while IFS= read -r _owned_list_pid; do
        if magicnet_singbox_pid_owned "$_owned_list_pid" "$_owned_list_config"; then
            _owned_list_pid_rc=0
        else
            _owned_list_pid_rc=$?
        fi
        case "$_owned_list_pid_rc" in
        0)
            if printf '%s\n' "$_owned_list_pid" >>"$_owned_list_output"; then
                _owned_list_found=1
            else
                _owned_list_loop_rc=2
                break
            fi
            ;;
        1) ;;
        *)
            _owned_list_loop_rc=2
            break
            ;;
        esac
    done <"$_owned_list_candidates"
    rm -f "$_owned_list_candidates"
    if [ "$_owned_list_loop_rc" -eq 2 ]; then
        : >"$_owned_list_output" 2>/dev/null || true
        return 2
    fi
    _owned_list_rc=1
    [ "$_owned_list_found" -eq 0 ] || _owned_list_rc=0
    unset _owned_list_config _owned_list_output _owned_list_candidates
    unset _owned_list_lookup_rc _owned_list_found _owned_list_pid _owned_list_pid_rc
    return "$_owned_list_rc"
)

magicnet_singbox_owned_pids() (
    _owned_emit=$(magicnet_proc_query_temp_create) || return 2
    if magicnet_singbox_owned_pids_to_file "$1" "$_owned_emit"; then
        _owned_emit_rc=0
    else
        _owned_emit_rc=$?
    fi
    if [ "$_owned_emit_rc" -eq 0 ]; then
        while IFS= read -r _owned_emit_pid; do
            printf '%s\n' "$_owned_emit_pid"
        done <"$_owned_emit"
    fi
    rm -f "$_owned_emit"
    unset _owned_emit _owned_emit_pid
    return "$_owned_emit_rc"
)

magicnet_singbox_is_running() (
    _running_config="${1:-$(magicnet_singbox_subscription_config_file)}"
    _running_pids=$(magicnet_proc_query_temp_create) || return 2
    if magicnet_singbox_owned_pids_to_file "$_running_config" "$_running_pids"; then
        _running_rc=0
    else
        _running_rc=$?
    fi
    rm -f "$_running_pids"
    unset _running_config _running_pids
    return "$_running_rc"
)

magicnet_singbox_listener_owned() {
    _listener_pid="$1"
    ss -lntp 2>/dev/null | grep -E '127\.0\.0\.1:9090[[:space:]]' | grep -q "pid=${_listener_pid},"
}

magicnet_singbox_owned_ready() {
    _ready_owned_config="$1"
    _ready_owned_pids=$(magicnet_proc_query_temp_create) || return 2
    if magicnet_singbox_owned_pids_to_file "$_ready_owned_config" "$_ready_owned_pids"; then
        _ready_lookup_rc=0
    else
        _ready_lookup_rc=$?
    fi
    case "$_ready_lookup_rc" in
    1)
        rm -f "$_ready_owned_pids"
        return 1
        ;;
    0) ;;
    *)
        rm -f "$_ready_owned_pids"
        return 2
        ;;
    esac
    _ready_api_expected=0
    _ready_found=0
    magicnet_singbox_config_has_clash_api "$_ready_owned_config" && _ready_api_expected=1
    while IFS= read -r _ready_owned_pid; do
        if [ "$_ready_api_expected" -eq 0 ] || {
            magicnet_singbox_listener_owned "$_ready_owned_pid" &&
                curl -fsS --max-time 1 http://127.0.0.1:9090/version 2>/dev/null |
                grep -q '"version"'
        }; then
            _ready_found=1
            break
        fi
    done <"$_ready_owned_pids"
    rm -f "$_ready_owned_pids"
    _ready_rc=1
    [ "$_ready_found" -eq 0 ] || _ready_rc=0
    unset _ready_owned_config _ready_api_expected _ready_owned_pid _ready_found
    return "$_ready_rc"
}

magicnet_singbox_supervisor_restore() {
    _restore_fswatch_active="${1:-${_owned_fswatch_active:-0}}"
    [ "$_restore_fswatch_active" -eq 1 ] || {
        unset _restore_fswatch_active
        return 0
    }
    if ! magicnet_fswatch_start >/dev/null 2>&1; then
        unset _restore_fswatch_active
        return 1
    fi
    magicnet_fswatch_status >/dev/null 2>&1
    _restore_rc=$?
    unset _restore_fswatch_active
    return "$_restore_rc"
}

magicnet_singbox_ensure_start_owned() {
    _owned_config="$1"
    _owned_work="${_owned_config%/*}"
    _owned_binary="${MODDIR}/bin/sing-box"
    _owned_log="${MODDIR}/.log/sing-box.log"
    _owned_start_pids=$(magicnet_proc_query_temp_create) || return 2
    if magicnet_singbox_owned_pids_to_file "$_owned_config" "$_owned_start_pids"; then
        _owned_start_lookup_rc=0
    else
        _owned_start_lookup_rc=$?
    fi
    rm -f "$_owned_start_pids"
    case "$_owned_start_lookup_rc" in
    1) ;;
    0) return 1 ;;
    *) return 2 ;;
    esac
    _api_expected=0
    if magicnet_singbox_config_has_clash_api "$_owned_config"; then
        _api_expected=1
    fi
    [ -x "$_owned_binary" ] || return 1
    ss -lnt 2>/dev/null | grep -q '127\.0\.0\.1:9090[[:space:]]' && return 1
    mkdir -p "${MODDIR}/.log"
    nohup "$_owned_binary" run -c "$_owned_config" -D "$_owned_work" >"$_owned_log" 2>&1 </dev/null &
    _new_pid=$!
    _ready_deadline=$(($(date +%s) + ${MAGICNET_SUB_READY_TIMEOUT:-15}))
    while [ "$(date +%s)" -lt "$_ready_deadline" ]; do
        if kill -0 "$_new_pid" 2>/dev/null &&
            magicnet_singbox_pid_owned "$_new_pid" "$_owned_config" && {
            [ "$_api_expected" -eq 0 ] ||
                {
                    magicnet_singbox_listener_owned "$_new_pid" &&
                        curl -fsS --max-time 1 http://127.0.0.1:9090/version 2>/dev/null |
                        grep -q '"version"'
                }
        }; then
            unset _api_expected
            return 0
        fi
        sleep 1
    done
    kill "$_new_pid" 2>/dev/null || true
    unset _api_expected
    return 1
}

magicnet_singbox_signal_pids_file() {
    _signal_file="$1"
    _signal_number="$2"
    [ -f "$_signal_file" ] && [ ! -L "$_signal_file" ] || return 1
    while IFS= read -r _signal_pid; do
        case "$_signal_pid" in '' | *[!0-9]* | 0) return 1 ;; esac
        if [ "$_signal_number" = 9 ]; then
            kill -9 "$_signal_pid" 2>/dev/null || true
        else
            kill "$_signal_pid" 2>/dev/null || true
        fi
    done <"$_signal_file"
    unset _signal_file _signal_number _signal_pid
}

# Refresh the destination until the owned set is empty or the deadline passes.
# The return code remains tri-state: 0=still found at deadline, 1=empty,
# 2=indeterminate. A failed lookup is never accepted as successful shutdown.
magicnet_singbox_wait_owned_state() {
    _wait_config="$1"
    _wait_output="$2"
    _wait_deadline="$3"
    while :; do
        if magicnet_singbox_owned_pids_to_file "$_wait_config" "$_wait_output"; then
            _wait_rc=0
        else
            _wait_rc=$?
        fi
        case "$_wait_rc" in
        1) return 1 ;;
        0)
            [ "$(date +%s)" -lt "$_wait_deadline" ] || return 0
            sleep 1
            ;;
        *) return 2 ;;
        esac
    done
}

magicnet_singbox_stop_owned_after_failure() {
    _failure_config="$1"
    _failure_pids=$(magicnet_proc_query_temp_create) || return 2
    if magicnet_singbox_owned_pids_to_file "$_failure_config" "$_failure_pids"; then
        _failure_query_rc=0
    else
        _failure_query_rc=$?
    fi
    case "$_failure_query_rc" in
    0) magicnet_singbox_signal_pids_file "$_failure_pids" 15 || true ;;
    1)
        ip link delete magicnet0 2>/dev/null || true
        rm -f "$_failure_pids"
        return 0
        ;;
    *)
        rm -f "$_failure_pids"
        return 2
        ;;
    esac
    _failure_deadline=$(($(date +%s) + ${MAGICNET_SUB_STOP_TIMEOUT:-8}))
    if magicnet_singbox_wait_owned_state \
        "$_failure_config" "$_failure_pids" "$_failure_deadline"; then
        _failure_query_rc=0
    else
        _failure_query_rc=$?
    fi
    if [ "$_failure_query_rc" -eq 0 ]; then
        magicnet_singbox_signal_pids_file "$_failure_pids" 9 || true
        _failure_kill_deadline=$(($(date +%s) + ${MAGICNET_SUB_KILL_TIMEOUT:-3}))
        if magicnet_singbox_wait_owned_state \
            "$_failure_config" "$_failure_pids" "$_failure_kill_deadline"; then
            _failure_query_rc=0
        else
            _failure_query_rc=$?
        fi
    fi
    _failure_rc=1
    if [ "$_failure_query_rc" -eq 1 ]; then
        ip link delete magicnet0 2>/dev/null || true
        _failure_rc=0
    elif [ "$_failure_query_rc" -eq 2 ]; then
        _failure_rc=2
    fi
    rm -f "$_failure_pids"
    unset _failure_config _failure_pids _failure_query_rc _failure_deadline
    unset _failure_kill_deadline
    return "$_failure_rc"
}

magicnet_singbox_reset_bootstrap_cache() {
    _bootstrap_config="$1"
    _bootstrap_cache_path=$(jq -er '
      .experimental.cache_file
      | select(.enabled == true)
      | (.path // "cache.db")
    ' "$_bootstrap_config" 2>/dev/null) || return 0

    # Only the packaged cache basename belongs to MagicNet. Never follow a
    # custom path from a user-edited config.
    [ "$_bootstrap_cache_path" = cache.db ] || {
        unset _bootstrap_config _bootstrap_cache_path
        return 0
    }
    _bootstrap_cache_dir=${_bootstrap_config%/*}
    [ "$_bootstrap_cache_dir" != "$_bootstrap_config" ] || _bootstrap_cache_dir=.
    rm -f "$_bootstrap_cache_dir"/cache.db \
        "$_bootstrap_cache_dir"/cache.db-wal \
        "$_bootstrap_cache_dir"/cache.db-shm \
        "$_bootstrap_cache_dir"/cache.db-journal
    _bootstrap_cache_rc=$?
    unset _bootstrap_config _bootstrap_cache_path _bootstrap_cache_dir
    return "$_bootstrap_cache_rc"
}

magicnet_singbox_restart_owned() {
    _owned_config="$1"
    _owned_fswatch_active="${MAGICNET_SUB_FSWATCH_WAS_ACTIVE:-0}"
    if [ -z "${MAGICNET_SUB_FSWATCH_WAS_ACTIVE+x}" ]; then
        magicnet_fswatch_status >/dev/null 2>&1 && _owned_fswatch_active=1
    fi

    # Establish an authoritative owned-process set before touching DNS, TUN,
    # supervisors, or any process. An indeterminate lookup leaves the complete
    # running generation unchanged and must not be treated as an empty set.
    _owned_pids=$(magicnet_proc_query_temp_create) || return 2
    if magicnet_singbox_owned_pids_to_file "$_owned_config" "$_owned_pids"; then
        _owned_query_rc=0
    else
        _owned_query_rc=$?
    fi
    case "$_owned_query_rc" in
    0)
        magicnet_singbox_signal_pids_file "$_owned_pids" 15 || true
        _stop_deadline=$(($(date +%s) + ${MAGICNET_SUB_STOP_TIMEOUT:-8}))
        if magicnet_singbox_wait_owned_state \
            "$_owned_config" "$_owned_pids" "$_stop_deadline"; then
            _owned_query_rc=0
        else
            _owned_query_rc=$?
        fi
        if [ "$_owned_query_rc" -eq 0 ]; then
            magicnet_singbox_signal_pids_file "$_owned_pids" 9 || true
            _kill_deadline=$(($(date +%s) + ${MAGICNET_SUB_KILL_TIMEOUT:-3}))
            if magicnet_singbox_wait_owned_state \
                "$_owned_config" "$_owned_pids" "$_kill_deadline"; then
                _owned_query_rc=0
            else
                _owned_query_rc=$?
            fi
        fi
        ;;
    1) ;;
    *)
        warn "sing-box process discovery is indeterminate; restart aborted before runtime teardown"
        rm -f "$_owned_pids"
        return 2
        ;;
    esac

    case "$_owned_query_rc" in
    1) ;;
    2)
        warn "sing-box stop state is indeterminate; preserving TUN, DNS rules, and supervisors"
        rm -f "$_owned_pids"
        return 2
        ;;
    *)
        warn "sing-box did not stop before the bounded restart deadline"
        rm -f "$_owned_pids"
        return 1
        ;;
    esac
    rm -f "$_owned_pids"

    # A listener with no authoritatively owned process is not safe to replace.
    if ss -lnt 2>/dev/null | grep -q '127\.0\.0\.1:9090[[:space:]]'; then
        warn "sing-box API listener ownership is unknown; restart aborted"
        return 2
    fi

    # Only now is the old core definitely absent. Keep all network policy and
    # supervisor state intact throughout discovery and stop-wait uncertainty.
    magicnet_supervisors_stop >/dev/null 2>&1 || return 1
    magicnet_disable_dns_capture >/dev/null 2>&1 ||
        warn "Failed to clear DNS capture before subscription restart"
    magicnet_disable_dns_leak_guard >/dev/null 2>&1 ||
        warn "Failed to clear DNS leak guard before subscription restart"

    _restart_rc=0
    if [ "${MAGICNET_SUB_RESET_BOOTSTRAP_CACHE:-0}" = 1 ]; then
        magicnet_singbox_reset_bootstrap_cache "$_owned_config" || _restart_rc=1
    fi
    if [ "$_restart_rc" -eq 0 ]; then
        ip link delete magicnet0 2>/dev/null || true
        if magicnet_singbox_ensure_start_owned "$_owned_config"; then
            _restart_rc=0
        else
            _restart_rc=$?
        fi
        if [ "$_restart_rc" -eq 0 ]; then
            # The core is started outside magicnet_start_kernel, so its normal
            # post-start network phase does not run automatically here. DNS
            # interception and the TUN/app policy must be rebuilt while the
            # subscription transaction still owns the config lock.
            _post_start_rc=0
            magicnet_reapply_post_start_policy || _post_start_rc=1
            if [ "$_post_start_rc" -ne 0 ]; then
                magicnet_disable_dns_capture >/dev/null 2>&1 || true
                magicnet_disable_dns_leak_guard >/dev/null 2>&1 || true
                magicnet_singbox_stop_owned_after_failure "$_owned_config" || true
                _restart_rc=1
            else
                magicnet_singbox_record_runtime_fingerprint ||
                    warn "Failed to record the running sing-box configuration fingerprint"
            fi
        fi
        unset _post_start_rc
    fi
    if [ "${MAGICNET_SUB_DEFER_FSWATCH_RESTORE:-0}" -eq 1 ]; then
        # Read by the subscription update wrapper after it releases the config lock.
        # shellcheck disable=SC2034
        MAGICNET_SUB_FSWATCH_RESTORE_PENDING="$_owned_fswatch_active"
    else
        magicnet_singbox_supervisor_restore "$_owned_fswatch_active" || _restart_rc=1
    fi
    unset _owned_pids _owned_query_rc _stop_deadline _kill_deadline
    return "$_restart_rc"
}

magicnet_singbox_restart_if_running() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    magicnet_singbox_restart_owned "$_config_file"
}

magicnet_singbox_google_works() {
    curl -fsSI --max-time "${MAGICNET_GOOGLE_TEST_MAX_TIME:-15}" \
        -x http://127.0.0.1:7892 \
        https://www.google.com >/dev/null 2>&1
}

magicnet_singbox_verify_subscription_ready() {
    if magicnet_singbox_is_running; then
        _verify_running_rc=0
    else
        _verify_running_rc=$?
    fi
    if [ "$_verify_running_rc" -eq 0 ]; then
        magicnet_singbox_restart_if_running || {
            error "sing-box restart failed after subscription update"
            return 1
        }
        magicnet_singbox_api_has_nodes || {
            warn "sing-box API did not expose proxy nodes; generated config contains nodes"
        }
        magicnet_singbox_google_works || {
            warn "sing-box proxy test failed: https://www.google.com is not reachable"
        }
        return 0
    fi
    if [ "$_verify_running_rc" -eq 2 ]; then
        error "sing-box process state is indeterminate; subscription activation aborted"
        return 2
    fi

    magicnet_singbox_config_has_nodes || {
        error "sing-box generated config contains no proxy nodes"
        return 1
    }
}

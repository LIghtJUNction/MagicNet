magicnet_singbox_emitted_node_port_valid() {
    _emitted_port=$(printf '%s' "$1" |
        sed -n 's/.*"server_port":\([0-9][0-9]*\)[,}].*/\1/p')
    case "$_emitted_port" in
    '' | 0 | 0* | *[!0-9]*) return 1 ;;
    esac
    [ "$_emitted_port" -le 65535 ] 2>/dev/null
}

magicnet_singbox_build_outbounds_file() {
    _nodes_dir="$1"
    _out_file="$2"
    _tags_file="$3"
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
                magicnet_singbox_is_info_tag "$_tag"; then
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

    if magicnet_singbox_build_outbounds_file_with_jq "${_out_file}.nodes" "$_tags_file" "$_out_file"; then
        printf '%s %s\n' "$_imported" "$_skipped"
        return 0
    fi

    {
        printf '  "outbounds": [\n'
        magicnet_singbox_emit_selector_block "$_tags_file"
        _nodes=$(sed 's/^\[//; s/\]$//' "${_out_file}.nodes")
        if [ -n "$_nodes" ]; then
            printf ',\n    %s' "$_nodes"
        fi
        printf ',\n'
        printf '    {\n      "type": "direct",\n      "tag": "direct"\n    },\n'
        printf '    {\n      "type": "block",\n      "tag": "block"\n    }\n'
        printf '  ],'
    } >"$_out_file"

    printf '%s %s\n' "$_imported" "$_skipped"
}

magicnet_singbox_build_outbounds_file_with_jq() {
    _nodes_json="$1"
    _tags_file="$2"
    _out_file="$3"
    command -v jq >/dev/null 2>&1 || return 1
    _tags_json="${_out_file}.tags.json"
    jq -R -s 'split("\n") | map(select(length > 0))' "$_tags_file" >"$_tags_json" || return 1
    jq -n -r --slurpfile nodes "$_nodes_json" --slurpfile tags "$_tags_json" '
      def normalize_tag:
        if type == "string"
        then gsub("[\\r\\n\\t]"; " ") | gsub("[[:cntrl:]]"; "")
        else ""
        end;
      def reserved_tag:
        . as $tag
        | [
            "proxy-auto", "proxy", "select", "lan", "ad-block", "ad-allow", "cn-direct",
            "apple-cn", "microsoft-cn", "google-cn", "icloud", "bing", "dns-guard", "network-test",
            "ai-proxy", "ai-chatgpt", "ai-chatgpt-auto", "ai-gemini", "ai-gemini-auto",
            "ai-grok", "ai-grok-auto", "ai-claude", "ai-claude-auto", "proxy-rule", "dev-proxy",
            "social-proxy", "media-proxy", "game-proxy", "telegram-proxy", "download-direct",
            "final", "direct", "block", "warp"
          ]
        | index($tag) != null;
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
              "outbounds": (["proxy-auto"] + $tags + ["direct", "block"]),
              "default": "proxy-auto"}
        else {"type": "selector", "tag": "proxy", "outbounds": ["block"], "default": "block"}
        end;
    def mainland_node_tag:
      test("中国|大陆|内地|香港|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西|(^|[^A-Za-z0-9])(?:Hong[ _-]?Kong(?:[ _-]?[0-9]+)?|HKG?[ _-]?[0-9]+|China|Mainland|HK|HKG|CN|Beijing|Shanghai|Guangzhou|Shenzhen|Chongqing|Tianjin|Hebei|Shanxi|Liaoning|Jilin|Heilongjiang|Jiangsu|Zhejiang|Anhui|Fujian|Jiangxi|Shandong|Henan|Hubei|Hunan|Guangdong|Hainan|Sichuan|Guizhou|Yunnan|Shaanxi|Gansu|Qinghai|Inner[ _-]?Mongolia|Guangxi|Tibet|Ningxia|Xinjiang)([^A-Za-z0-9]|$)"; "i");
    def ai_proxy_selector($tags):
      if ($tags | length) > 0
        then {"type": "selector", "tag": "ai-proxy", "outbounds": $tags, "default": $tags[0]}
        else {"type": "selector", "tag": "ai-proxy", "outbounds": ["block"], "default": "block"}
        end;
    def ai_urltest($tag; $url; $tags):
      urltest(($tag + "-auto"); $url; "10m"; $tags);
    def pinned_ai_selector($tag; $tags):
      {"type": "selector", "tag": $tag,
       "outbounds": (if ($tags | length) > 0 then ["block", ($tag + "-auto")] else ["block"] end),
       "default": "block"};
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
      ($nodes[0] // []
        | map(.tag = ((.tag // "") | normalize_tag))
        | map(select(
            valid_proxy_node
            and (((.tag // "") | test("剩余流量|到期|过期|套餐|官网|订阅|Traffic|traffic|Expire|expire|Expired|expired|Subscription|subscription|官方网站|更新订阅")) | not)
          ))
        | reduce .[] as $node
            ([]; if (map(.tag) | index($node.tag)) != null then . else . + [$node] end)
      ) as $nodes
      | ([ $nodes[] | .tag ]) as $tags
      | ([ $tags[]? | select(mainland_node_tag | not) ]) as $ai_tags
      | (if ($tags | length) > 0
          then [urltest("proxy-auto"; "https://www.gstatic.com/generate_204"; "3m"; $tags)]
          else []
        end) + [
          proxy_selector($tags),
          selector("select"; ["proxy", "direct"]; "proxy"),
          selector("lan"; ["direct"]; "direct"),
          selector("ad-block"; ["block", "direct", "proxy"]; "block"),
          selector_exact("ad-allow"; ["final", "direct", "proxy"]; "final"),
          selector("cn-direct"; ["direct", "proxy"]; "direct"),
          selector("apple-cn"; ["direct", "proxy"]; "direct"),
          selector("microsoft-cn"; ["direct", "proxy"]; "direct"),
          selector("icloud"; ["direct", "proxy"]; "direct"),
          selector("bing"; ["proxy", "direct"]; "proxy"),
          selector("dns-guard"; ["proxy", "block", "direct"]; "proxy"),
          selector("network-test"; ["proxy", "direct"]; "proxy"),
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
      | "  \"outbounds\": " + tojson + ","
    ' >"$_out_file" || return 1
}

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
            "proxy-auto", "proxy", "select", "lan", "ad-block", "ad-allow", "cn-direct",
            "apple-cn", "microsoft-cn", "google-cn", "icloud", "bing", "dns-guard", "network-test",
            "ai-proxy", "ai-chatgpt", "ai-chatgpt-auto", "ai-gemini", "ai-gemini-auto",
            "ai-grok", "ai-grok-auto", "ai-claude", "ai-claude-auto", "proxy-rule", "dev-proxy",
            "social-proxy", "media-proxy", "game-proxy", "telegram-proxy", "download-direct",
            "final", "direct", "block", "warp"
          ]
        | index($tag) != null;
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

magicnet_singbox_emit_selector_block() {
    _tags_file="$1"
    _proxy_tags=$(awk 'NF && !seen[$0]++' "$_tags_file")
    if [ -n "$_proxy_tags" ]; then
        magicnet_singbox_emit_urltest \
            "proxy-auto" "https://www.gstatic.com/generate_204" "3m" "$_proxy_tags"
        printf ',\n'
        magicnet_emit_selector_json_exact "proxy" \
            "$(printf '%s\n%s\n%s\n%s\n' "proxy-auto" "$_proxy_tags" "direct" "block")" \
            "proxy-auto"
    else
        magicnet_emit_selector_json_exact "proxy" "block" "block"
    fi
    printf ',\n'
    magicnet_emit_selector_json "select" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    magicnet_singbox_emit_static_selectors
    unset _tags_file _proxy_tags
}

magicnet_singbox_emit_static_selectors() {
    for _pair in \
        "lan::direct" \
        "apple-cn::direct" "microsoft-cn::direct" "icloud::direct"; do
        _name=${_pair%%:*}
        _default=${_pair##*:}
        printf ',\n'
        magicnet_emit_selector_json "$_name" "" "$_default"
    done
    printf ',\n'
    magicnet_emit_selector_json_exact "cn-direct" "$(printf '%s\n%s\n%s\n' "direct" "proxy" "block")" "direct"
    printf ',\n'
    magicnet_emit_selector_json "ad-block" "$(printf '%s\n%s\n%s\n' "block" "direct" "proxy")" "block"
    printf ',\n'
    magicnet_emit_selector_json_exact "ad-allow" "$(printf '%s\n%s\n%s\n' "final" "direct" "proxy")" "final"
    printf ',\n'
    magicnet_emit_selector_json "bing" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    printf ',\n'
    magicnet_emit_selector_json "dns-guard" "$(printf '%s\n%s\n%s\n' "proxy" "block" "direct")" "proxy"
    printf ',\n'
    magicnet_emit_selector_json "network-test" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    printf ',\n'
    _pinned_ai_tags=$(magicnet_singbox_pinned_ai_tags "$_tags_file")
    _pinned_ai_default=$(printf '%s\n' "$_pinned_ai_tags" | sed -n '1p')
    if [ -n "$_pinned_ai_default" ]; then
        magicnet_emit_selector_json_exact "ai-proxy" "$_pinned_ai_tags" "$_pinned_ai_default"
    else
        magicnet_emit_selector_json_exact "ai-proxy" "block" "block"
    fi
    for _name in ai-chatgpt ai-gemini ai-grok ai-claude; do
        printf ',\n'
        if [ -n "$_pinned_ai_tags" ]; then
            magicnet_singbox_emit_ai_urltest "$_name" "$_pinned_ai_tags"
            printf ',\n'
        fi
        magicnet_singbox_emit_pinned_ai_selector "$_name" "$_pinned_ai_tags"
    done
    for _name in proxy-rule dev-proxy social-proxy media-proxy game-proxy telegram-proxy; do
        printf ',\n'
        magicnet_emit_selector_json "$_name" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    done
    printf ',\n'
    magicnet_emit_selector_json "download-direct" "$(printf '%s\n%s\n' "direct" "proxy")" "direct"
    printf ',\n'
    magicnet_emit_selector_json_exact "final" "$(printf '%s\n%s\n%s\n' "proxy" "direct" "block")" "proxy"
    unset _pair _name _default _pinned_ai_tags _pinned_ai_default
}

magicnet_singbox_ai_url() {
    case "$1" in
    ai-chatgpt) printf '%s\n' "https://chatgpt.com/" ;;
    ai-gemini) printf '%s\n' "https://gemini.google.com/" ;;
    ai-grok) printf '%s\n' "https://grok.com/" ;;
    ai-claude) printf '%s\n' "https://claude.ai/" ;;
    *) return 1 ;;
    esac
}

magicnet_singbox_emit_ai_urltest() {
    _ai_urltest_name="$1"
    _ai_urltest_tags="$2"
    magicnet_singbox_emit_urltest \
        "${_ai_urltest_name}-auto" "$(magicnet_singbox_ai_url "$_ai_urltest_name")" \
        "10m" "$_ai_urltest_tags"
    unset _ai_urltest_name _ai_urltest_tags
}

magicnet_singbox_emit_urltest() {
    _urltest_name="$1"
    _urltest_url="$2"
    _urltest_interval="$3"
    _urltest_tags="$4"
    _urltest_first=1
    printf '    {\n'
    printf '      "type": "urltest",\n'
    printf '      "tag": "%s",\n' "$(magicnet_json_escape "$_urltest_name")"
    printf '      "outbounds": ['
    while IFS= read -r _urltest_tag; do
        [ -n "$_urltest_tag" ] || continue
        [ "$_urltest_first" -eq 1 ] || printf ', '
        printf '"%s"' "$(magicnet_json_escape "$_urltest_tag")"
        _urltest_first=0
    done <<EOF
$_urltest_tags
EOF
    printf '],\n'
    printf '      "url": "%s",\n' "$(magicnet_json_escape "$_urltest_url")"
    printf '      "interval": "%s",\n' "$(magicnet_json_escape "$_urltest_interval")"
    printf '      "tolerance": 30,\n'
    printf '      "idle_timeout": "10m",\n'
    printf '      "interrupt_exist_connections": false\n'
    printf '    }'
    unset _urltest_name _urltest_url _urltest_interval _urltest_tags _urltest_first _urltest_tag
}

magicnet_singbox_emit_pinned_ai_selector() {
    _pinned_ai_name="$1"
    _pinned_ai_selector_tags="$2"
    printf '    {\n'
    printf '      "type": "selector",\n'
    printf '      "tag": "%s",\n' "$(magicnet_json_escape "$_pinned_ai_name")"
    printf '      "outbounds": ['
    printf '"block"'
    [ -z "$_pinned_ai_selector_tags" ] || printf ', "%s-auto"' "$(magicnet_json_escape "$_pinned_ai_name")"
    printf '],\n'
    printf '      "default": "block"\n'
    printf '    }'
    unset _pinned_ai_name _pinned_ai_selector_tags
}

magicnet_singbox_pinned_ai_tags() {
    _pinned_ai_tags_file="$1"
    awk 'BEGIN { IGNORECASE = 1 }
      !/中国|大陆|内地|香港|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西/ &&
      !/(^|[^[:alnum:]])(Hong[ _-]?Kong([ _-]?[0-9]+)?|HKG?[ _-]?[0-9]+|China|Mainland|HK|HKG|CN|Beijing|Shanghai|Guangzhou|Shenzhen|Chongqing|Tianjin|Hebei|Shanxi|Liaoning|Jilin|Heilongjiang|Jiangsu|Zhejiang|Anhui|Fujian|Jiangxi|Shandong|Henan|Hubei|Hunan|Guangdong|Hainan|Sichuan|Guizhou|Yunnan|Shaanxi|Gansu|Qinghai|Inner[ _-]?Mongolia|Guangxi|Tibet|Ningxia|Xinjiang)([^[:alnum:]]|$)/ { print }
    ' "$_pinned_ai_tags_file"
    unset _pinned_ai_tags_file
}

magicnet_singbox_sanitize_generated_config() {
    _sanitize_config_file="$1"
    _sanitize_jq="$(command -v jq 2>/dev/null || true)"
    [ -n "$_sanitize_jq" ] || {
        if magicnet_singbox_ai_selectors_canonical "$_sanitize_config_file"; then
            unset _sanitize_config_file _sanitize_jq _sanitize_tmp_file _sanitize_rc _sanitize_return
            return 0
        fi
        magicnet_singbox_ai_selectors_canonical \
            "$_sanitize_config_file" "https://www.google.com/generate_204" "10m" || {
            unset _sanitize_config_file _sanitize_jq _sanitize_tmp_file _sanitize_rc _sanitize_return
            return 1
        }

        _sanitize_tmp_file="${_sanitize_config_file}.sanitized"
        if awk '
          BEGIN {
            legacy_url_re = "https://www\\.google\\.com/generate_204"
            current_url = "https://www.gstatic.com/generate_204"
            pair_re = "\"url\"[[:space:]]*:[[:space:]]*\"" legacy_url_re \
              "\"[[:space:]]*,[[:space:]]*\"interval\"[[:space:]]*:[[:space:]]*\"10m\""
          }
          {
            text = text (NR == 1 ? "" : "\n") $0
          }
          END {
            scan = text
            scan_offset = 0
            pair_count = 0
            while (match(scan, pair_re)) {
              pair_count++
              pair_start = scan_offset + RSTART
              pair_length = RLENGTH
              scan_offset += RSTART + RLENGTH - 1
              scan = substr(scan, RSTART + RLENGTH)
            }
            if (pair_count != 1) exit 1
            pair = substr(text, pair_start, pair_length)
            if (sub(legacy_url_re, current_url, pair) != 1) exit 1
            if (sub(/"10m"$/, "\"3m\"", pair) != 1) exit 1
            printf "%s%s%s\n", substr(text, 1, pair_start - 1), pair, \
              substr(text, pair_start + pair_length)
          }
        ' "$_sanitize_config_file" >"$_sanitize_tmp_file" &&
            magicnet_singbox_ai_selectors_canonical "$_sanitize_tmp_file" &&
            mv -f "$_sanitize_tmp_file" "$_sanitize_config_file"; then
            _sanitize_rc=0
        else
            _sanitize_rc=1
            rm -f "$_sanitize_tmp_file" 2>/dev/null || true
        fi
        if [ "$_sanitize_rc" -eq 0 ]; then
            unset _sanitize_config_file _sanitize_jq _sanitize_tmp_file _sanitize_rc _sanitize_return
            return 0
        fi
        unset _sanitize_config_file _sanitize_jq _sanitize_tmp_file _sanitize_rc _sanitize_return
        return 1
    }

    _sanitize_tmp_file="${_sanitize_config_file}.sanitized"
    # shellcheck disable=SC2016
    "$_sanitize_jq" '
      def mainland_node_tag:
        test("中国|大陆|内地|香港|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西|(^|[^A-Za-z0-9])(?:Hong[ _-]?Kong(?:[ _-]?[0-9]+)?|HKG?[ _-]?[0-9]+|China|Mainland|HK|HKG|CN|Beijing|Shanghai|Guangzhou|Shenzhen|Chongqing|Tianjin|Hebei|Shanxi|Liaoning|Jilin|Heilongjiang|Jiangsu|Zhejiang|Anhui|Fujian|Jiangxi|Shandong|Henan|Hubei|Hunan|Guangdong|Hainan|Sichuan|Guizhou|Yunnan|Shaanxi|Gansu|Qinghai|Inner[ _-]?Mongolia|Guangxi|Tibet|Ningxia|Xinjiang)([^A-Za-z0-9]|$)"; "i");
      def proxy_node_type:
        .type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
          or .type == "hysteria2" or .type == "anytls" or .type == "tuic";
      def reserved_tag:
        . as $tag
        | [
            "proxy-auto", "proxy", "select", "lan", "ad-block", "ad-allow", "cn-direct",
            "apple-cn", "microsoft-cn", "google-cn", "icloud", "bing", "dns-guard", "network-test",
            "ai-proxy", "ai-chatgpt", "ai-chatgpt-auto", "ai-gemini", "ai-gemini-auto",
            "ai-grok", "ai-grok-auto", "ai-claude", "ai-claude-auto", "proxy-rule", "dev-proxy",
            "social-proxy", "media-proxy", "game-proxy", "telegram-proxy", "download-direct",
            "final", "direct", "block", "warp"
          ]
        | index($tag) != null;
      def proxy_node:
        proxy_node_type
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
              "outbounds": (["proxy-auto"] + $tags + ["direct", "block"]), "default": "proxy-auto"}
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
      def pinned_ai_selector($tag; $tags):
        {"type": "selector", "tag": $tag,
         "outbounds": (if ($tags | length) > 0 then ["block", ($tag + "-auto")] else ["block"] end),
         "default": "block"};
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
      (.outbounds // []) as $outbounds
      | ($outbounds | dedupe_proxy_nodes) as $deduped_outbounds
      | ([$deduped_outbounds[]
          | select(proxy_node)
          | .tag // empty]) as $node_tags
      | ([$node_tags[] | select(mainland_node_tag | not)]) as $ai_tags
      | .outbounds = ($deduped_outbounds
          | map(select(.tag as $tag | [
              "proxy", "proxy-auto",
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
    ' "$_sanitize_config_file" >"$_sanitize_tmp_file" && mv -f "$_sanitize_tmp_file" "$_sanitize_config_file"
    _sanitize_rc=$?
    [ "$_sanitize_rc" -eq 0 ] || rm -f "$_sanitize_tmp_file" 2>/dev/null || true
    if [ "$_sanitize_rc" -eq 0 ]; then
        unset _sanitize_config_file _sanitize_jq _sanitize_tmp_file _sanitize_rc _sanitize_return
        return 0
    fi
    unset _sanitize_config_file _sanitize_jq _sanitize_tmp_file _sanitize_rc _sanitize_return
    return 1
}

magicnet_singbox_update_config_with_nodes() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    _outbounds_file="$1"
    _tmp_file="${_config_file}.new"

    awk -v repl="$_outbounds_file" '
        function count_delta(s, i, c, d) {
            d = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "[") d++
                if (c == "]") d--
            }
            return d
        }
        BEGIN {
            while ((getline line < repl) > 0) {
                replacement = replacement line "\n"
            }
            close(repl)
            skipping = 0
            depth = 0
            found = 0
        }
        skipping == 0 && $0 ~ /^[[:space:]]*"outbounds"[[:space:]]*:/ {
            found = 1
            if (prev != "") {
                sub(/,[[:space:]]*$/, "", prev)
                sub(/[[:space:]]*$/, ",", prev)
                print prev
                prev = ""
            }
            printf "%s", replacement
            depth = count_delta($0)
            skipping = 1
            next
        }
        skipping == 1 {
            depth += count_delta($0)
            if (depth <= 0) {
                skipping = 0
            }
            next
        }
        skipping == 0 && found == 0 && $0 ~ /^  "(route|experimental)"[[:space:]]*:/ {
            if (prev != "") {
                sub(/,[[:space:]]*$/, "", prev)
                sub(/[[:space:]]*$/, ",", prev)
                print prev
                prev = ""
            }
            printf "%s", replacement
            found = 1
        }
        {
            if (prev != "") print prev
            prev = $0
        }
        END {
            if (prev != "") print prev
        }
    ' "$_config_file" >"$_tmp_file"

    magicnet_singbox_sanitize_generated_config "$_tmp_file" || {
        error "Generated sing-box config failed sanitization"
        return 1
    }

    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "$_tmp_file" -D "${_config_file%/*}" >/dev/null || {
            error "Generated sing-box config failed validation"
            return 1
        }
    fi

    mv -f "$_tmp_file" "$_config_file"
}

magicnet_singbox_replay_cached_outbounds() {
    _cached_outbounds="${MODDIR}/.state/sing-box/subscription-work/outbounds.json"
    [ -s "$_cached_outbounds" ] || {
        unset _cached_outbounds
        return 1
    }
    grep -Eq '"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks)"' \
        "$_cached_outbounds" || {
        unset _cached_outbounds
        return 1
    }

    _config_file=$(magicnet_singbox_subscription_config_file)
    _previous_config="${_config_file}.cache-replay.previous"
    cp -f "$_config_file" "$_previous_config" || {
        unset _cached_outbounds _config_file _previous_config
        return 1
    }
    if magicnet_singbox_update_config_with_nodes "$_cached_outbounds" &&
        magicnet_singbox_verify_subscription_ready; then
        rm -f "$_previous_config"
        unset _cached_outbounds _config_file _previous_config
        return 0
    fi

    mv -f "$_previous_config" "$_config_file" 2>/dev/null || true
    unset _cached_outbounds _config_file _previous_config
    return 1
}

magicnet_singbox_pids() {
    for _proc_comm in /proc/[0-9]*/comm; do
        [ -r "$_proc_comm" ] || continue
        if [ "$(cat "$_proc_comm" 2>/dev/null)" = "sing-box" ]; then
            _pid=${_proc_comm#/proc/}
            printf '%s\n' "${_pid%/comm}"
        fi
    done
}

magicnet_singbox_is_running() {
    [ -n "$(magicnet_singbox_pids)" ]
}

magicnet_singbox_pid_owned() {
    _owned_pid="$1"
    _owned_config="$2"
    _owned_expected=$(readlink -f "${MODDIR}/bin/sing-box" 2>/dev/null) || return 1
    _owned_exe_link=$(readlink "/proc/${_owned_pid}/exe" 2>/dev/null) || return 1
    _owned_exe_path=${_owned_exe_link% (deleted)}
    [ "$_owned_exe_path" = "$_owned_expected" ] || return 1
    (
        _argv_index=0
        _argv_run=0
        _argv_config_count=0
        _argv_config_ok=0
        _argv_work_count=0
        _argv_work_ok=0
        _argv_pending=
        # Android sh and the host-side Bash fixture use an empty read delimiter for NUL.
        # shellcheck disable=SC3045
        while IFS= read -r -d '' _argv_arg; do
            _argv_index=$((_argv_index + 1))
            [ "$_argv_index" -ne 2 ] || [ "$_argv_arg" != "run" ] || _argv_run=1
            case "$_argv_pending" in
                config)
                    [ "$_argv_arg" != "$_owned_config" ] || _argv_config_ok=1
                    _argv_pending=
                    continue
                    ;;
                work)
                    [ "$_argv_arg" != "${_owned_config%/*}" ] || _argv_work_ok=1
                    _argv_pending=
                    continue
                    ;;
            esac
            case "$_argv_arg" in
                -c)
                    _argv_config_count=$((_argv_config_count + 1))
                    _argv_pending=config
                    ;;
                -D)
                    _argv_work_count=$((_argv_work_count + 1))
                    _argv_pending=work
                    ;;
            esac
        done <"/proc/${_owned_pid}/cmdline"
        [ "$_argv_run" -eq 1 ] &&
            [ "$_argv_config_count" -eq 1 ] && [ "$_argv_config_ok" -eq 1 ] &&
            [ "$_argv_work_count" -eq 1 ] && [ "$_argv_work_ok" -eq 1 ] &&
            [ -z "$_argv_pending" ]
    ) 2>/dev/null
}

magicnet_singbox_owned_pids() {
    _owned_config="$1"
    for _pid in $(magicnet_singbox_pids); do
        magicnet_singbox_pid_owned "$_pid" "$_owned_config" && printf '%s\n' "$_pid"
    done
}

magicnet_singbox_listener_owned() {
    _listener_pid="$1"
    ss -lntp 2>/dev/null | grep -E '127\.0\.0\.1:9090[[:space:]]' | grep -q "pid=${_listener_pid},"
}

magicnet_singbox_supervisor_restore() {
    [ "${_owned_fswatch_active:-0}" -eq 1 ] || return 0
    magicnet_fswatch_start >/dev/null 2>&1 || return 1
    magicnet_fswatch_status >/dev/null 2>&1
}

magicnet_singbox_ensure_start_owned() {
    _owned_config="$1"
    _owned_work="${_owned_config%/*}"
    _owned_binary="${MODDIR}/bin/sing-box"
    _owned_log="${MODDIR}/.log/sing-box.log"
    [ -x "$_owned_binary" ] || return 1
    ss -lnt 2>/dev/null | grep -q '127\.0\.0\.1:9090[[:space:]]' && return 1
    mkdir -p "${MODDIR}/.log"
    nohup "$_owned_binary" run -c "$_owned_config" -D "$_owned_work" >"$_owned_log" 2>&1 </dev/null &
    _new_pid=$!
    _ready_deadline=$(($(date +%s) + ${MAGICNET_SUB_READY_TIMEOUT:-15}))
    while [ "$(date +%s)" -lt "$_ready_deadline" ]; do
        if kill -0 "$_new_pid" 2>/dev/null &&
            magicnet_singbox_pid_owned "$_new_pid" "$_owned_config" &&
            magicnet_singbox_listener_owned "$_new_pid" &&
            curl -fsS --max-time 1 http://127.0.0.1:9090/version 2>/dev/null | grep -q '"version"'; then
            return 0
        fi
        sleep 1
    done
    kill "$_new_pid" 2>/dev/null || true
    return 1
}

magicnet_singbox_restart_owned() {
    _owned_config="$1"
    _owned_fswatch_active="${MAGICNET_SUB_FSWATCH_WAS_ACTIVE:-0}"
    if [ -z "${MAGICNET_SUB_FSWATCH_WAS_ACTIVE+x}" ]; then
        magicnet_fswatch_status >/dev/null 2>&1 && _owned_fswatch_active=1
    fi
    magicnet_supervisors_stop >/dev/null 2>&1 || return 1
    for _pid in $(magicnet_singbox_owned_pids "$_owned_config"); do
        kill "$_pid" 2>/dev/null || true
    done
    _stop_deadline=$(($(date +%s) + ${MAGICNET_SUB_STOP_TIMEOUT:-8}))
    while [ -n "$(magicnet_singbox_owned_pids "$_owned_config")" ] && [ "$(date +%s)" -lt "$_stop_deadline" ]; do
        sleep 1
    done
    if [ -n "$(magicnet_singbox_owned_pids "$_owned_config")" ]; then
        for _pid in $(magicnet_singbox_owned_pids "$_owned_config"); do
            kill -9 "$_pid" 2>/dev/null || true
        done
        _kill_deadline=$(($(date +%s) + ${MAGICNET_SUB_KILL_TIMEOUT:-3}))
        while [ -n "$(magicnet_singbox_owned_pids "$_owned_config")" ] && [ "$(date +%s)" -lt "$_kill_deadline" ]; do sleep 1; done
    fi
    _restart_rc=0
    [ -z "$(magicnet_singbox_owned_pids "$_owned_config")" ] || _restart_rc=1
    if [ "$_restart_rc" -eq 0 ] && ss -lnt 2>/dev/null | grep -q '127\.0\.0\.1:9090[[:space:]]'; then
        _restart_rc=1
    fi
    if [ "$_restart_rc" -eq 0 ]; then
        ip link delete magicnet0 2>/dev/null || true
        ip link delete tun0 2>/dev/null || true
        magicnet_singbox_ensure_start_owned "$_owned_config" || _restart_rc=1
    fi
    magicnet_singbox_supervisor_restore || _restart_rc=1
    return "$_restart_rc"
}

magicnet_singbox_restart_if_running() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    magicnet_singbox_restart_owned "$_config_file"
}

magicnet_singbox_api_has_nodes() {
    _api=$(curl -sS --max-time 5 http://127.0.0.1:9090/proxies 2>/dev/null || curl -sS --max-time 5 http://127.0.0.1:9090/providers/proxies 2>/dev/null || true)
    [ -n "$_api" ] || return 1
    printf '%s' "$_api" | grep -Eq '"type":"(VLESS|Hysteria2|Trojan|VMess|Shadowsocks|Selector)"'
}

magicnet_singbox_config_has_nodes() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    grep -Eq '"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks)"' "$_config_file"
}

magicnet_singbox_google_works() {
    curl -fsSI --max-time "${MAGICNET_GOOGLE_TEST_MAX_TIME:-15}" \
        -x http://127.0.0.1:7892 \
        https://www.google.com >/dev/null 2>&1
}

magicnet_singbox_verify_subscription_ready() {
    if magicnet_singbox_is_running; then
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

    magicnet_singbox_config_has_nodes || {
        error "sing-box generated config contains no proxy nodes"
        return 1
    }
}

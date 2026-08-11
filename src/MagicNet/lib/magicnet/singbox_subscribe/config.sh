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
    _filter_file=$(magicnet_singbox_subscription_filter_file)
    [ -f "$_filter_file" ] || _filter_file=/dev/null
    jq -R -s 'split("\n") | map(select(length > 0))' "$_tags_file" >"$_tags_json" || return 1
    jq -n -r --slurpfile nodes "$_nodes_json" --slurpfile tags "$_tags_json" \
      --rawfile configured_filters "$_filter_file" '
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
    def blocked_ai_node_tag:
      test("中国|大陆|内地|香港|台湾|臺灣|台北|臺北|台中|臺中|台南|臺南|高雄|新竹|🇭🇰|🇹🇼|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西|(^|[^A-Za-z0-9])(?:Hong[ _-]?Kong(?:[ _-]?[0-9]+)?|HKG?[ _-]?[0-9]+|Taiwan|Taipei|Taichung|Tainan|Kaohsiung|Hsinchu|TW|TWN|China|Mainland|HK|HKG|CN|Beijing|Shanghai|Guangzhou|Shenzhen|Chongqing|Tianjin|Hebei|Shanxi|Liaoning|Jilin|Heilongjiang|Jiangsu|Zhejiang|Anhui|Fujian|Jiangxi|Shandong|Henan|Hubei|Hunan|Guangdong|Hainan|Sichuan|Guizhou|Yunnan|Shaanxi|Gansu|Qinghai|Inner[ _-]?Mongolia|Guangxi|Tibet|Ningxia|Xinjiang)([^A-Za-z0-9]|$)"; "i");
    def us_node_tag:
      test("美国|美國|美西|美东|美東|洛杉矶|洛杉磯|圣何塞|聖何塞|西雅图|西雅圖|达拉斯|達拉斯|纽约|紐約|芝加哥|迈阿密|邁阿密|凤凰城|鳳凰城|亚特兰大|亞特蘭大|波特兰|波特蘭|丹佛|拉斯维加斯|拉斯維加斯|硅谷|🇺🇸|(^|[^A-Za-z0-9])(?:US|USA|United[ _-]?States|America|Los[ _-]?Angeles|San[ _-]?Jose|Seattle|Dallas|New[ _-]?York|Chicago|Washington|Miami|Phoenix|Atlanta|Portland|Denver|Las[ _-]?Vegas|Silicon[ _-]?Valley)([^A-Za-z0-9]|$)"; "i");
    def japan_node_tag:
      test("日本|东京|東京|大阪|埼玉|名古屋|🇯🇵|(^|[^A-Za-z0-9])(?:JP|JPN|Japan|Tokyo|Osaka|Saitama|Nagoya)([^A-Za-z0-9]|$)"; "i");
    def prioritize_ai_tags:
      . as $tags
      | ([$tags[]? | select(blocked_ai_node_tag | not)]) as $eligible
      | ([$eligible[] | select(us_node_tag)])
        + ([$eligible[] | select((us_node_tag | not) and japan_node_tag)])
        + ([$eligible[] | select((us_node_tag | not) and (japan_node_tag | not))]);
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

magicnet_singbox_emit_selector_block() {
    _tags_file="$1"
    _proxy_tags=$(awk 'NF && !seen[$0]++' "$_tags_file")
    if [ -n "$_proxy_tags" ]; then
        _proxy_default=$(printf '%s\n' "$_proxy_tags" | sed -n '1p')
        magicnet_singbox_emit_urltest \
            "proxy-auto" "https://www.gstatic.com/generate_204" "3m" "$_proxy_tags"
        printf ',\n'
        magicnet_emit_selector_json_exact "proxy" \
            "$(printf '%s\n%s\n%s\n%s\n' "$_proxy_tags" "proxy-auto" "direct" "block")" \
            "$_proxy_default"
    else
        magicnet_emit_selector_json_exact "proxy" "block" "block"
    fi
    printf ',\n'
    magicnet_emit_selector_json "select" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    magicnet_singbox_emit_static_selectors
    unset _tags_file _proxy_tags _proxy_default
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
    magicnet_emit_selector_json_exact "hotspot" "$(printf '%s\n%s\n' "direct" "proxy")" "direct"
    printf ',\n'
    magicnet_emit_selector_json "ad-block" "$(printf '%s\n%s\n%s\n' "block" "direct" "proxy")" "block"
    printf ',\n'
    magicnet_emit_selector_json_exact "ad-allow" "$(printf '%s\n%s\n%s\n' "final" "direct" "proxy")" "final"
    printf ',\n'
    magicnet_emit_selector_json "bing" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    printf ',\n'
    magicnet_emit_selector_json "dns-guard" "$(printf '%s\n%s\n%s\n' "proxy" "block" "direct")" "proxy"
    printf ',\n'
    if [ -n "$_proxy_tags" ]; then
        magicnet_emit_selector_json_exact \
            "network-test" \
            "$(printf '%s\n%s\n%s\n%s\n' "proxy-auto" "proxy" "direct" "block")" \
            "proxy-auto"
    else
        magicnet_emit_selector_json_exact "network-test" "block" "block"
    fi
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

# Manual node selection by default.
# outbounds = [first-node, ...other-nodes, block, name-auto]
# default   = first-node
magicnet_singbox_emit_pinned_ai_selector() {
    _pinned_ai_name="$1"
    _pinned_ai_selector_tags="$2"
    _pinned_ai_first=$(printf '%s\n' "$_pinned_ai_selector_tags" | sed -n '1p')
    printf '    {\n'
    printf '      "type": "selector",\n'
    printf '      "tag": "%s",\n' "$(magicnet_json_escape "$_pinned_ai_name")"
    printf '      "outbounds": ['
    if [ -n "$_pinned_ai_first" ]; then
        _first_out=1
        while IFS= read -r _tag; do
            [ -n "$_tag" ] || continue
            [ "$_first_out" -eq 1 ] || printf ', '
            printf '"%s"' "$(magicnet_json_escape "$_tag")"
            _first_out=0
        done <<EOF
$_pinned_ai_selector_tags
EOF
        printf ', "block", "%s-auto"' "$(magicnet_json_escape "$_pinned_ai_name")"
        printf '],\n'
        printf '      "default": "%s"\n' "$(magicnet_json_escape "$_pinned_ai_first")"
    else
        printf '"block"],\n'
        printf '      "default": "block"\n'
    fi
    printf '    }'
    unset _pinned_ai_name _pinned_ai_selector_tags _pinned_ai_first _first_out _tag
}

magicnet_singbox_pinned_ai_tags() {
    _pinned_ai_tags_file="$1"
    awk '
      function blocked_ai(value, folded) {
        folded = tolower(value)
        return value ~ /中国|大陆|内地|香港|台湾|臺灣|台北|臺北|台中|臺中|台南|臺南|高雄|新竹|🇭🇰|🇹🇼|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西/ ||
          folded ~ /(^|[^[:alnum:]])(hong[ _-]?kong([ _-]?[0-9]+)?|hkg?[ _-]?[0-9]+|taiwan|taipei|taichung|tainan|kaohsiung|hsinchu|tw|twn|china|mainland|hk|hkg|cn|beijing|shanghai|guangzhou|shenzhen|chongqing|tianjin|hebei|shanxi|liaoning|jilin|heilongjiang|jiangsu|zhejiang|anhui|fujian|jiangxi|shandong|henan|hubei|hunan|guangdong|hainan|sichuan|guizhou|yunnan|shaanxi|gansu|qinghai|inner[ _-]?mongolia|guangxi|tibet|ningxia|xinjiang)([^[:alnum:]]|$)/
      }
      function us_node(value, folded) {
        folded = tolower(value)
        return value ~ /美国|美國|美西|美东|美東|洛杉矶|洛杉磯|圣何塞|聖何塞|西雅图|西雅圖|达拉斯|達拉斯|纽约|紐約|芝加哥|迈阿密|邁阿密|凤凰城|鳳凰城|亚特兰大|亞特蘭大|波特兰|波特蘭|丹佛|拉斯维加斯|拉斯維加斯|硅谷|🇺🇸/ ||
          folded ~ /(^|[^[:alnum:]])(us|usa|united[ _-]?states|america|los[ _-]?angeles|san[ _-]?jose|seattle|dallas|new[ _-]?york|chicago|washington|miami|phoenix|atlanta|portland|denver|las[ _-]?vegas|silicon[ _-]?valley)([^[:alnum:]]|$)/
      }
      function japan_node(value, folded) {
        folded = tolower(value)
        return value ~ /日本|东京|東京|大阪|埼玉|名古屋|🇯🇵/ ||
          folded ~ /(^|[^[:alnum:]])(jp|jpn|japan|tokyo|osaka|saitama|nagoya)([^[:alnum:]]|$)/
      }
      {
        if (blocked_ai($0)) next
        tag[++count] = $0
        priority[count] = us_node($0) ? 1 : (japan_node($0) ? 2 : 3)
      }
      END {
        for (wanted = 1; wanted <= 3; wanted++)
          for (item = 1; item <= count; item++)
            if (priority[item] == wanted) print tag[item]
      }
    ' "$_pinned_ai_tags_file"
    unset _pinned_ai_tags_file
}

magicnet_singbox_sanitize_generated_config() {
    _sanitize_config_file="$1"
    _sanitize_jq="$(command -v jq 2>/dev/null || true)"
    _sanitize_filter_file=$(magicnet_singbox_subscription_filter_file)
    [ -f "$_sanitize_filter_file" ] || _sanitize_filter_file=/dev/null
    [ -n "$_sanitize_jq" ] || {
        if magicnet_singbox_ai_selectors_canonical "$_sanitize_config_file"; then
            unset _sanitize_config_file _sanitize_jq _sanitize_filter_file _sanitize_tmp_file _sanitize_rc _sanitize_return
            return 0
        fi
        magicnet_singbox_ai_selectors_canonical \
            "$_sanitize_config_file" "https://www.google.com/generate_204" "10m" || {
            unset _sanitize_config_file _sanitize_jq _sanitize_filter_file _sanitize_tmp_file _sanitize_rc _sanitize_return
            return 1
        }

        _sanitize_tmp_file="${_sanitize_config_file}.sanitized"
        if (umask 077; awk '
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
        ' "$_sanitize_config_file" >"$_sanitize_tmp_file") &&
            magicnet_singbox_ai_selectors_canonical "$_sanitize_tmp_file" &&
            chmod 600 "$_sanitize_tmp_file" &&
            mv -f "$_sanitize_tmp_file" "$_sanitize_config_file" &&
            chmod 600 "$_sanitize_config_file"; then
            _sanitize_rc=0
        else
            _sanitize_rc=1
            rm -f "$_sanitize_tmp_file" 2>/dev/null || true
        fi
        if [ "$_sanitize_rc" -eq 0 ]; then
            unset _sanitize_config_file _sanitize_jq _sanitize_filter_file _sanitize_tmp_file _sanitize_rc _sanitize_return
            return 0
        fi
        unset _sanitize_config_file _sanitize_jq _sanitize_filter_file _sanitize_tmp_file _sanitize_rc _sanitize_return
        return 1
    }

    _sanitize_tmp_file="${_sanitize_config_file}.sanitized"
    # shellcheck disable=SC2016
    (umask 077; "$_sanitize_jq" --rawfile configured_filters "$_sanitize_filter_file" '
      def blocked_ai_node_tag:
        test("中国|大陆|内地|香港|台湾|臺灣|台北|臺北|台中|臺中|台南|臺南|高雄|新竹|🇭🇰|🇹🇼|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西|(^|[^A-Za-z0-9])(?:Hong[ _-]?Kong(?:[ _-]?[0-9]+)?|HKG?[ _-]?[0-9]+|Taiwan|Taipei|Taichung|Tainan|Kaohsiung|Hsinchu|TW|TWN|China|Mainland|HK|HKG|CN|Beijing|Shanghai|Guangzhou|Shenzhen|Chongqing|Tianjin|Hebei|Shanxi|Liaoning|Jilin|Heilongjiang|Jiangsu|Zhejiang|Anhui|Fujian|Jiangxi|Shandong|Henan|Hubei|Hunan|Guangdong|Hainan|Sichuan|Guizhou|Yunnan|Shaanxi|Gansu|Qinghai|Inner[ _-]?Mongolia|Guangxi|Tibet|Ningxia|Xinjiang)([^A-Za-z0-9]|$)"; "i");
      def us_node_tag:
        test("美国|美國|美西|美东|美東|洛杉矶|洛杉磯|圣何塞|聖何塞|西雅图|西雅圖|达拉斯|達拉斯|纽约|紐約|芝加哥|迈阿密|邁阿密|凤凰城|鳳凰城|亚特兰大|亞特蘭大|波特兰|波特蘭|丹佛|拉斯维加斯|拉斯維加斯|硅谷|🇺🇸|(^|[^A-Za-z0-9])(?:US|USA|United[ _-]?States|America|Los[ _-]?Angeles|San[ _-]?Jose|Seattle|Dallas|New[ _-]?York|Chicago|Washington|Miami|Phoenix|Atlanta|Portland|Denver|Las[ _-]?Vegas|Silicon[ _-]?Valley)([^A-Za-z0-9]|$)"; "i");
      def japan_node_tag:
        test("日本|东京|東京|大阪|埼玉|名古屋|🇯🇵|(^|[^A-Za-z0-9])(?:JP|JPN|Japan|Tokyo|Osaka|Saitama|Nagoya)([^A-Za-z0-9]|$)"; "i");
      def prioritize_ai_tags:
        . as $tags
        | ([$tags[]? | select(blocked_ai_node_tag | not)]) as $eligible
        | ([$eligible[] | select(us_node_tag)])
          + ([$eligible[] | select((us_node_tag | not) and japan_node_tag)])
          + ([$eligible[] | select((us_node_tag | not) and (japan_node_tag | not))]);
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
    ' "$_sanitize_config_file" >"$_sanitize_tmp_file") &&
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

magicnet_singbox_update_config_with_nodes() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    _outbounds_file="$1"
    _tmp_file="${_config_file}.new"

    (umask 077; awk -v repl="$_outbounds_file" '
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
    ' "$_config_file" >"$_tmp_file")

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
        chmod 600 "$_config_file"
}

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
    (umask 077; cp -f "$_config_file" "$_previous_config") || {
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

magicnet_singbox_pid_live() {
    _live_pid="$1"
    case "$_live_pid" in
        '' | *[!0-9]*) return 1 ;;
    esac
    _live_stat="${MAGICNET_SINGBOX_PROC_ROOT:-/proc}/${_live_pid}/stat"
    [ -r "$_live_stat" ] || {
        unset _live_pid _live_stat
        return 1
    }
    _live_state="$(sed -n 's/^.*) \([^ ]\) .*$/\1/p' "$_live_stat" 2>/dev/null)"
    [ -n "$_live_state" ] && [ "$_live_state" != "Z" ] || {
        unset _live_pid _live_stat _live_state
        return 1
    }
    unset _live_pid _live_stat _live_state
    return 0
}

magicnet_singbox_pids() {
    if command -v pidof >/dev/null 2>&1; then
        _singbox_pid_list=$(pidof sing-box 2>/dev/null) || _singbox_pid_list=
        # shellcheck disable=SC2086 # pidof returns a whitespace-separated PID list.
        for _pid in $_singbox_pid_list; do
            case "$_pid" in
                *[!0-9]* | '') continue ;;
            esac
            magicnet_singbox_pid_live "$_pid" || continue
            printf '%s\n' "$_pid"
        done
        unset _singbox_pid_list _pid
        return 0
    fi

    _singbox_proc_root="${MAGICNET_SINGBOX_PROC_ROOT:-/proc}"
    for _proc_comm in "$_singbox_proc_root"/[0-9]*/comm; do
        [ -r "$_proc_comm" ] || continue
        if IFS= read -r _proc_name <"$_proc_comm" 2>/dev/null &&
            [ "$_proc_name" = "sing-box" ]; then
            _pid=${_proc_comm#"$_singbox_proc_root"/}
            magicnet_singbox_pid_live "${_pid%/comm}" || continue
            printf '%s\n' "${_pid%/comm}"
        fi
    done
    unset _singbox_proc_root _proc_comm _proc_name _pid
}

magicnet_singbox_is_running() {
    _running_config="${1:-$(magicnet_singbox_subscription_config_file)}"
    [ -n "$(magicnet_singbox_owned_pids "$_running_config")" ]
}

magicnet_singbox_pid_owned() {
    _owned_pid="$1"
    _owned_config="$2"
    magicnet_singbox_pid_live "$_owned_pid" || return 1
    _owned_expected=$(readlink -f "${MODDIR}/bin/sing-box" 2>/dev/null) || return 1
    [ -x "${MODDIR}/bin/sing-box" ] || return 1
    _owned_proc_root="${MAGICNET_SINGBOX_PROC_ROOT:-/proc}"
    _owned_proc_dir="$_owned_proc_root/$_owned_pid"
    _owned_comm=$(tr -d '\r\n' <"$_owned_proc_dir/comm" 2>/dev/null) || return 1
    [ "$_owned_comm" = "sing-box" ] || return 1
    _owned_exe_link=$(readlink "$_owned_proc_dir/exe" 2>/dev/null || true)
    _owned_exe_visible=0
    _owned_exe_match=0
    if [ -n "$_owned_exe_link" ]; then
        _owned_exe_path=${_owned_exe_link% (deleted)}
        _owned_exe_visible=1
        [ "$_owned_exe_path" = "$_owned_expected" ] && _owned_exe_match=1
    fi
    (
        _argv_index=0
        _argv_run=0
        _argv_after_run=0
        _argv0=
        _argv_wrapper=0
        _argv_config_count=0
        _argv_config_ok=0
        _argv_work_count=0
        _argv_work_ok=0
        _argv_pending=
        _argv_cmdline_file="$_owned_proc_dir/cmdline"
        # Normalize proc's NUL-delimited argv before reading it.  Android ash
        # and Debian dash do not agree on `read -d`, while newline preserves
        # the argument boundaries needed by this exact ownership tuple.  A
        # literal newline inside one argv would otherwise be mistaken for a
        # second argument, so reject it before normalization.
        _argv_bytes_with_newline=$(tr -d '\000' <"$_argv_cmdline_file" 2>/dev/null | wc -c)
        _argv_bytes_without_newline=$(tr -d '\000\n' <"$_argv_cmdline_file" 2>/dev/null | wc -c)
        [ "$_argv_bytes_with_newline" = "$_argv_bytes_without_newline" ] || return 1
        _argv_cmdline=$(tr '\000' '\n' <"$_argv_cmdline_file" 2>/dev/null) || return 1
        while IFS= read -r _argv_arg || [ -n "$_argv_arg" ]; do
            _argv_index=$((_argv_index + 1))
            [ "$_argv_index" -ne 1 ] || _argv0="$_argv_arg"
            if [ "$_argv_after_run" -eq 0 ]; then
                if [ "$_argv_arg" = "$_owned_expected" ] ||
                    [ "$_argv_arg" = "${MODDIR}/bin/sing-box" ]; then
                    _argv_wrapper=1
                fi
                if [ "$_argv_arg" = "run" ]; then
                    _argv_run=1
                    _argv_after_run=1
                fi
                continue
            fi
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
        done <<EOF
$_argv_cmdline
EOF
        [ "$_argv_run" -eq 1 ] &&
            [ "$_argv_config_count" -eq 1 ] && [ "$_argv_config_ok" -eq 1 ] &&
            [ "$_argv_work_count" -eq 1 ] && [ "$_argv_work_ok" -eq 1 ] &&
            [ -z "$_argv_pending" ] &&
            {
                [ "$_owned_exe_match" -eq 1 ] ||
                    [ "$_argv_wrapper" -eq 1 ] ||
                    { [ "$_owned_exe_visible" -eq 0 ] && [ "$_argv0" = "sing-box" ]; }
            }
    ) 2>/dev/null
    _owned_rc=$?
    unset _owned_pid _owned_config _owned_expected _owned_proc_root _owned_proc_dir \
        _owned_comm _owned_exe_link _owned_exe_visible _owned_exe_match _owned_exe_path
    return "$_owned_rc"
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

magicnet_singbox_stop_owned_after_failure() {
    _failure_config="$1"
    for _failure_pid in $(magicnet_singbox_owned_pids "$_failure_config"); do
        kill "$_failure_pid" 2>/dev/null || true
    done
    _failure_deadline=$(($(date +%s) + ${MAGICNET_SUB_STOP_TIMEOUT:-8}))
    while [ -n "$(magicnet_singbox_owned_pids "$_failure_config")" ] &&
        [ "$(date +%s)" -lt "$_failure_deadline" ]; do
        sleep 1
    done
    if [ -n "$(magicnet_singbox_owned_pids "$_failure_config")" ]; then
        for _failure_pid in $(magicnet_singbox_owned_pids "$_failure_config"); do
            kill -9 "$_failure_pid" 2>/dev/null || true
        done
        _failure_kill_deadline=$(($(date +%s) + ${MAGICNET_SUB_KILL_TIMEOUT:-3}))
        while [ -n "$(magicnet_singbox_owned_pids "$_failure_config")" ] &&
            [ "$(date +%s)" -lt "$_failure_kill_deadline" ]; do
            sleep 1
        done
    fi
    ip link delete magicnet0 2>/dev/null || true
    _failure_rc=0
    [ -z "$(magicnet_singbox_owned_pids "$_failure_config")" ] || _failure_rc=1
    unset _failure_config _failure_pid _failure_deadline _failure_kill_deadline
    return "$_failure_rc"
}

magicnet_singbox_restart_owned() {
    _owned_config="$1"
    _owned_fswatch_active="${MAGICNET_SUB_FSWATCH_WAS_ACTIVE:-0}"
    if [ -z "${MAGICNET_SUB_FSWATCH_WAS_ACTIVE+x}" ]; then
        magicnet_fswatch_status >/dev/null 2>&1 && _owned_fswatch_active=1
    fi
    # Remove host-side DNS interception before stopping the core.  Leaving a
    # REDIRECT to 127.0.0.1:1053 in place while sing-box is down turns the
    # bounded restart window into an avoidable DNS outage for every app.
    magicnet_disable_dns_capture >/dev/null 2>&1 ||
        warn "Failed to clear DNS capture before subscription restart"
    magicnet_disable_dns_leak_guard >/dev/null 2>&1 ||
        warn "Failed to clear DNS leak guard before subscription restart"
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
        magicnet_singbox_ensure_start_owned "$_owned_config" || _restart_rc=1
        if [ "$_restart_rc" -eq 0 ]; then
            # The core is started outside magicnet_start_kernel, so its normal
            # post-start network phase does not run automatically here. DNS
            # interception and the TUN/app policy must be rebuilt after the
            # pre-stop cleanup above, while the subscription transaction still
            # owns the config lock.
            _post_start_rc=0
            if command -v magicnet_after_kernel_start_unlocked >/dev/null 2>&1; then
                magicnet_after_kernel_start_unlocked || _post_start_rc=1
            else
                magicnet_enable_dns_capture || _post_start_rc=1
                magicnet_enable_dns_leak_guard || _post_start_rc=1
            fi
            if [ "$_post_start_rc" -ne 0 ]; then
                # Do not leave a live core behind when the network phase did
                # not finish.  A running process without its TUN/DNS policy
                # is a half-initialized generation that can black-hole apps.
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
    return "$_restart_rc"
}

magicnet_singbox_restart_if_running() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    magicnet_singbox_restart_owned "$_config_file"
}

magicnet_singbox_api_has_nodes() {
    _api=$(curl -sS --max-time 5 http://127.0.0.1:9090/proxies 2>/dev/null || curl -sS --max-time 5 http://127.0.0.1:9090/providers/proxies 2>/dev/null || true)
    [ -n "$_api" ] || return 1
    printf '%s' "$_api" | grep -Eq '"type":"(VLESS|Hysteria2|Trojan|VMess|Shadowsocks|AnyTLS|TUIC|Socks|SOCKS|Selector)"'
}

magicnet_singbox_config_has_nodes() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    grep -Eq '"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks|anytls|tuic|socks)"' "$_config_file"
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

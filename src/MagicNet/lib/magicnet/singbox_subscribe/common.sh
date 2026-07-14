# shellcheck shell=ash
#
# Import common Clash-style subscription nodes into the bundled sing-box config.

magicnet_json_escape() {
    printf '%s' "$1" |
        tr '\r\n\t' '   ' |
        sed 's/[[:cntrl:]]//g; s/\\/\\\\/g; s/"/\\"/g'
}

magicnet_singbox_ai_selectors_canonical() {
    _ai_config="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -e '
          def mainland_node_tag:
            test("中国|大陆|内地|香港|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西|(^|[^A-Za-z0-9])(?:Hong[ _-]?Kong(?:[ _-]?[0-9]+)?|HKG?[ _-]?[0-9]+|China|Mainland|HK|HKG|CN|Beijing|Shanghai|Guangzhou|Shenzhen|Chongqing|Tianjin|Hebei|Shanxi|Liaoning|Jilin|Heilongjiang|Jiangsu|Zhejiang|Anhui|Fujian|Jiangxi|Shandong|Henan|Hubei|Hunan|Guangdong|Hainan|Sichuan|Guizhou|Yunnan|Shaanxi|Gansu|Qinghai|Inner[ _-]?Mongolia|Guangxi|Tibet|Ningxia|Xinjiang)([^A-Za-z0-9]|$)"; "i");
          ["ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude"] as $names
          | [.outbounds[]? | select(.tag as $tag | $names | index($tag))] as $groups
          | ([.outbounds[]? | select(.tag == "ai-proxy")]) as $ai_proxies
          | [.outbounds[]?
              | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan" or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
              | .tag] as $node_tags
          | ([.outbounds[]?.tag] | unique) as $tags
          | ($groups | length) == 4
            and ($ai_proxies | length) == 1
            and ($ai_proxies[0].type == "selector")
            and (($ai_proxies[0].outbounds == ["block"] and $ai_proxies[0].default == "block" and ($node_tags | length) == 0)
              or (($ai_proxies[0].outbounds | length) > 0
                and $ai_proxies[0].default == $ai_proxies[0].outbounds[0]
                and ($ai_proxies[0].outbounds | all(. as $member | ($node_tags | index($member) != null) and ($member | mainland_node_tag | not)))))
            and ($groups | all(
              .type == "selector" and .default == "block"
              and .outbounds == ["block", "ai-proxy"]
              and (.outbounds | all(. as $member | $tags | index($member) != null))))
        ' "$_ai_config" >/dev/null 2>&1
        _ai_rc=$?
    else
        awk '
          BEGIN {
            IGNORECASE = 1
            split("ai-chatgpt ai-gemini ai-grok ai-claude", names)
            for (i in names) wanted[names[i]] = 1
          }
          /^[[:space:]]*\{/ { object = $0 "\n"; next }
          object != "" { object = object $0 "\n" }
          object != "" && /^[[:space:]]*\}[,]?[[:space:]]*$/ {
            objects[++object_count] = object
            object = ""
          }
          END {
            for (i = 1; i <= object_count; i++) {
              tag = objects[i]
              if (tag !~ /"tag"[[:space:]]*:/) continue
              sub(/^.*"tag"[[:space:]]*:[[:space:]]*"/, "", tag)
              sub(/".*/, "", tag)
              tags[tag] = 1
              type = objects[i]
              if (type !~ /"type"[[:space:]]*:/) continue
              sub(/^.*"type"[[:space:]]*:[[:space:]]*"/, "", type)
              sub(/".*/, "", type)
              if (type ~ /^(shadowsocks|vmess|vless|trojan|hysteria2|anytls|tuic)$/) {
                node_tags[tag] = 1
                node_count++
              }
            }
            for (i = 1; i <= object_count; i++) {
              object = objects[i]
              tag = object
              if (tag !~ /"tag"[[:space:]]*:/) continue
              sub(/^.*"tag"[[:space:]]*:[[:space:]]*"/, "", tag)
              sub(/".*/, "", tag)
              if (tag == "ai-proxy") {
                ai_proxy_count++
                if (object !~ /"type"[[:space:]]*:[[:space:]]*"selector"/) bad = 1
                if (object ~ /中国|大陆|内地|香港|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西/ ||
                    object ~ /(^|[^[:alnum:]])(Hong[ _-]?Kong([ _-]?[0-9]+)?|HKG?[ _-]?[0-9]+|China|Mainland|HK|HKG|CN|Beijing|Shanghai|Guangzhou|Shenzhen|Chongqing|Tianjin|Hebei|Shanxi|Liaoning|Jilin|Heilongjiang|Jiangsu|Zhejiang|Anhui|Fujian|Jiangxi|Shandong|Henan|Hubei|Hunan|Guangdong|Hainan|Sichuan|Guizhou|Yunnan|Shaanxi|Gansu|Qinghai|Inner[ _-]?Mongolia|Guangxi|Tibet|Ningxia|Xinjiang)([^[:alnum:]]|$)/) bad = 1
                members = object
                sub(/^.*"outbounds"[[:space:]]*:[[:space:]]*\[/, "", members)
                sub(/\].*/, "", members)
                member_count = split(members, member, ",")
                default_member = object
                sub(/^.*"default"[[:space:]]*:[[:space:]]*"/, "", default_member)
                sub(/".*/, "", default_member)
                for (j = 1; j <= member_count; j++) {
                  gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", member[j])
                }
                if (member_count == 1 && member[1] == "block") {
                  if (default_member != "block" || node_count != 0) bad = 1
                } else {
                  if (member_count < 1 || default_member != member[1]) bad = 1
                  for (j = 1; j <= member_count; j++) if (!(member[j] in node_tags)) bad = 1
                }
                continue
              }
              if (!(tag in wanted)) continue
              count[tag]++
              if (object !~ /"type"[[:space:]]*:[[:space:]]*"selector"/ ||
                  object !~ /"default"[[:space:]]*:[[:space:]]*"block"/ ||
                  object !~ /"outbounds"[[:space:]]*:[[:space:]]*\[[[:space:]]*"block"[[:space:]]*,[[:space:]]*"ai-proxy"[[:space:]]*\]/) bad = 1
            }
            for (name in wanted) if (count[name] != 1) bad = 1
            if (ai_proxy_count != 1) bad = 1
            exit bad ? 1 : 0
          }
        ' "$_ai_config"
        _ai_rc=$?
    fi
    unset _ai_config
    return "$_ai_rc"
}

magicnet_json_array_csv() {
    _values="$1"
    _first=1
    printf '['
    _old_ifs=$IFS
    IFS=,
    for _value in $_values; do
        _value=$(printf '%s' "$_value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$_value" ] || continue
        [ "$_first" -eq 1 ] || printf ','
        printf '"%s"' "$(magicnet_json_escape "$_value")"
        _first=0
    done
    IFS=$_old_ifs
    printf ']'
}

magicnet_selector_tags_json() {
    _tags="$1"
    _fallback="$2"
    _seen=""
    _first=1
    printf '['
    while IFS= read -r _tag; do
        [ -n "$_tag" ] || continue
        [ "$_first" -eq 1 ] || printf ', '
        printf '"%s"' "$(magicnet_json_escape "$_tag")"
        _first=0
    done <<EOF
$_tags
EOF
    _seen=$(printf '%s\n%s\n%s\n' "$_tags" direct block)
    if [ -n "$_fallback" ] && ! printf '%s\n' "$_seen" | grep -F -x "$_fallback" >/dev/null 2>&1; then
        [ "$_first" -eq 1 ] || printf ', '
        printf '"%s"' "$(magicnet_json_escape "$_fallback")"
        _first=0
    fi
    [ "$_first" -eq 1 ] || printf ', '
    printf '"direct", "block"]'
}

magicnet_selector_default_tag() {
    _tags="$1"
    _fallback="$2"
    _first=$(printf '%s\n' "$_tags" | awk 'NF{print; exit}')
    printf '%s\n' "${_first:-$_fallback}"
}

magicnet_emit_selector_json() {
    _tag="$1"
    _tags="$2"
    _fallback="${3:-direct}"
    printf '    {\n'
    printf '      "type": "selector",\n'
    printf '      "tag": "%s",\n' "$(magicnet_json_escape "$_tag")"
    printf '      "outbounds": '
    magicnet_selector_tags_json "$_tags" "$_fallback"
    printf ',\n'
    printf '      "default": "%s"\n' "$(magicnet_json_escape "$(magicnet_selector_default_tag "$_tags" "$_fallback")")"
    printf '    }'
}

magicnet_emit_selector_json_exact() {
    _exact_tag="$1"
    _exact_tags="$2"
    _exact_fallback="$3"
    _exact_items=$(printf '%s\n%s\n' "$_exact_fallback" "$_exact_tags" | awk 'NF && !seen[$0]++')
    _exact_first=1
    printf '    {\n'
    printf '      "type": "selector",\n'
    printf '      "tag": "%s",\n' "$(magicnet_json_escape "$_exact_tag")"
    printf '      "outbounds": ['
    while IFS= read -r _exact_item; do
        [ -n "$_exact_item" ] || continue
        [ "$_exact_first" -eq 1 ] || printf ', '
        printf '"%s"' "$(magicnet_json_escape "$_exact_item")"
        _exact_first=0
    done <<EOF
$_exact_items
EOF
    printf '],\n'
    printf '      "default": "%s"\n' "$(magicnet_json_escape "$_exact_fallback")"
    printf '    }'
    unset _exact_tag _exact_tags _exact_fallback _exact_items _exact_first _exact_item
}

magicnet_uri_query_value() {
    _key="$1"
    _query="$2"
    printf '%s' "$_query" | tr '&' '\n' |
        sed -n "s/^${_key}=//p" | tail -n 1
}

magicnet_b64_decode() {
    _value=$(printf '%s' "$1" | tr '_-' '/+')
    _pad=$(((${#_value} + 3) % 4))
    case "$_pad" in
    2) _value="${_value}==" ;;
    3) _value="${_value}=" ;;
    esac
    printf '%s' "$_value" | base64 -d 2>/dev/null
}

magicnet_percent_decode() {
    _value="$1"
    _out=""
    while [ -n "$_value" ]; do
        case "$_value" in
        %??*)
            _hex=${_value#%}
            _hex=${_hex%"${_hex#??}"}
            case "$_hex" in
            *[!0-9A-Fa-f]*)
                _out="${_out}%"
                _value=${_value#%}
                ;;
            *)
                _out="${_out}\\x${_hex}"
                _value=${_value#???}
                ;;
            esac
            ;;
        +*)
            _out="${_out} "
            _value=${_value#?}
            ;;
        *)
            _out="${_out}${_value%"${_value#?}"}"
            _value=${_value#?}
            ;;
        esac
    done
    printf '%b\n' "$_out"
}

magicnet_share_link_tag() {
    _link="$1"
    _fallback="$2"
    _tag=$(printf '%s' "$_link" | sed -n 's/.*#//p')
    [ "$_tag" != "$_link" ] && [ -n "$_tag" ] || _tag="$_fallback"
    _tag=$(magicnet_percent_decode "$_tag")
    printf '%s\n' "$_tag"
}

magicnet_tag_matches_any() {
    _tag="$1"
    shift
    for _needle in "$@"; do
        printf '%s' "$_tag" | grep -F "$_needle" >/dev/null 2>&1 && return 0
    done
    return 1
}

magicnet_singbox_is_info_tag() {
    _tag="$1"
    magicnet_tag_matches_any "$_tag" \
        "剩余流量" "到期" "过期" "过期时间" "套餐" "官网" "订阅" \
        "Traffic" "traffic" "Expire" "expire" "Expired" "expired" \
        "Subscription" "subscription" "官网地址" "官方网站" "更新订阅" &&
        return 0
    return 1
}

if ! command -v error >/dev/null 2>&1; then
    error() { printf '%s\n' "ERROR: $1"; }
fi

if ! command -v warn >/dev/null 2>&1; then
    warn() { printf '%s\n' "WARN: $1"; }
fi

if ! command -v success >/dev/null 2>&1; then
    success() { printf '%s\n' "$1"; }
fi

magicnet_yaml_value() {
    _key="$1"
    _value=$(
        sed -n "s/^[[:space:]]*${_key}:[[:space:]]*//p" "$_node_file" | tail -n 1
    )
    if [ -z "$_value" ]; then
        _value=$(
            sed -n "s/.*[{,][[:space:]]*${_key}:[[:space:]]*\\([^,}]*\\).*/\\1/p" "$_node_file" |
                tail -n 1
        )
    fi
    printf '%s\n' "$_value" |
        tr -d '\r' |
        sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//'
    unset _value
}

magicnet_truthy() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
    esac
}

magicnet_singbox_subscription_url_file() {
    printf '%s\n' "${MODDIR}/.config/sing-box/subscription.url"
}

magicnet_singbox_subscription_source_file() {
    printf '%s\n' "${MODDIR}/.config/sing-box/subscription.yaml"
}

magicnet_singbox_subscription_source_dir() {
    printf '%s\n' "${MODDIR}/.config/sing-box"
}

magicnet_singbox_subscription_config_file() {
    printf '%s\n' "${MODDIR}/.config/sing-box/config.json"
}

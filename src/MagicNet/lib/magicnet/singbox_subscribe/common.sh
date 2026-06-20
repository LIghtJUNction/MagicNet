# shellcheck shell=ash
#
# Import common Clash-style subscription nodes into the bundled sing-box config.

magicnet_json_escape() {
    printf '%s' "$1" |
        tr '\r\n\t' '   ' |
        sed 's/[[:cntrl:]]//g; s/\\/\\\\/g; s/"/\\"/g'
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

magicnet_append_group_tag() {
    _var="$1"
    _tag="$2"
    eval "_old=\${$_var:-}"
    if [ -n "$_old" ]; then
        printf '%s\n' "$_old" | grep -F -x "$_tag" >/dev/null 2>&1 && return 0
        eval "$_var=\$(printf '%s\n%s' \"\$_old\" \"\$_tag\")"
    else
        eval "$_var=\$_tag"
    fi
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

magicnet_singbox_build_region_groups() {
    _tags_file="$1"
    _all=""
    _hk=""
    _jp=""
    _us=""
    _sg=""
    _tw=""
    _uk=""
    _free=""
    _download=""
    _iepl=""

    while IFS= read -r _tag || [ -n "$_tag" ]; do
        [ -n "$_tag" ] || continue
        magicnet_append_group_tag _all "$_tag"
        magicnet_tag_matches_any "$_tag" "香港" "港" "HK" "Hong" "hong" && magicnet_append_group_tag _hk "$_tag"
        magicnet_tag_matches_any "$_tag" "日本" "日" "JP" "Japan" "japan" && magicnet_append_group_tag _jp "$_tag"
        magicnet_tag_matches_any "$_tag" "美国" "美" "US" "USA" "United States" "America" && magicnet_append_group_tag _us "$_tag"
        magicnet_tag_matches_any "$_tag" "新加坡" "狮城" "SG" "Singapore" "singapore" && magicnet_append_group_tag _sg "$_tag"
        magicnet_tag_matches_any "$_tag" "台湾" "台灣" "TW" "Taiwan" "taiwan" && magicnet_append_group_tag _tw "$_tag"
        magicnet_tag_matches_any "$_tag" "英国" "英國" "UK" "GB" "Britain" "London" && magicnet_append_group_tag _uk "$_tag"
        magicnet_tag_matches_any "$_tag" "免费" "Free" "free" && magicnet_append_group_tag _free "$_tag"
        magicnet_tag_matches_any "$_tag" "下载" "download" "Download" "x0.01" && magicnet_append_group_tag _download "$_tag"
        magicnet_tag_matches_any "$_tag" "IEPL" "iepl" && magicnet_append_group_tag _iepl "$_tag"
    done <"$_tags_file"
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

# shellcheck shell=ash
#
# Import common Clash-style subscription nodes into the bundled sing-box config.

magicnet_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
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
    sed -n "s/^[[:space:]]*${_key}:[[:space:]]*//p" "$_node_file" | tail -n 1 |
        sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//'
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

magicnet_singbox_download_proxy_args() {
    _proxy="${MAGICNET_SUB_PROXY:-}"
    if [ -z "$_proxy" ] && command -v curl >/dev/null 2>&1; then
        curl -sS --max-time 2 http://127.0.0.1:9090/proxies >/dev/null 2>&1 &&
            _proxy="http://127.0.0.1:7892"
    fi
    [ -n "$_proxy" ] && printf '%s\n%s\n' "--proxy" "$_proxy"
}

magicnet_singbox_fetch_one_subscription() {
    _url="$1"
    _source_file="$2"
    _fallback_file="$3"
    _label="$4"
    _url_file=$(magicnet_singbox_subscription_url_file)
    _download_file="${_source_file}.download"

    if [ -z "$_url" ]; then
        error "Subscription URL is empty in $_url_file"
        return 1
    fi

    mkdir -p "${_source_file%/*}"
    rm -f "$_download_file"

    _connect_timeout="${MAGICNET_SUB_CONNECT_TIMEOUT:-10}"
    _max_time="${MAGICNET_SUB_MAX_TIME:-45}"

    if command -v curl >/dev/null 2>&1; then
        # shellcheck disable=SC2046
        curl -fsSL $(magicnet_singbox_download_proxy_args) --connect-timeout "$_connect_timeout" --max-time "$_max_time" "$_url" -o "$_download_file" || {
            error "Failed to download subscription ${_label} with curl"
            [ -s "$_source_file" ] && {
                warn "Using cached subscription: $_source_file"
                return 0
            }
            [ -n "$_fallback_file" ] && [ -s "$_fallback_file" ] && {
                warn "Using legacy cached subscription: $_fallback_file"
                cp "$_fallback_file" "$_source_file"
                return 0
            }
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -T "$_max_time" -qO "$_download_file" "$_url" || {
            error "Failed to download subscription ${_label} with wget"
            [ -s "$_source_file" ] && {
                warn "Using cached subscription: $_source_file"
                return 0
            }
            [ -n "$_fallback_file" ] && [ -s "$_fallback_file" ] && {
                warn "Using legacy cached subscription: $_fallback_file"
                cp "$_fallback_file" "$_source_file"
                return 0
            }
            return 1
        }
    elif command -v sing-box >/dev/null 2>&1; then
        sing-box tools fetch "$_url" >"$_download_file" || {
            error "Failed to download subscription ${_label} with sing-box"
            [ -s "$_source_file" ] && {
                warn "Using cached subscription: $_source_file"
                return 0
            }
            [ -n "$_fallback_file" ] && [ -s "$_fallback_file" ] && {
                warn "Using legacy cached subscription: $_fallback_file"
                cp "$_fallback_file" "$_source_file"
                return 0
            }
            return 1
        }
    else
        error "No downloader found: curl, wget or sing-box tools fetch"
        return 1
    fi

    [ -s "$_download_file" ] || {
        error "Downloaded subscription ${_label} is empty"
        [ -s "$_source_file" ] && {
            warn "Using cached subscription: $_source_file"
            return 0
        }
        [ -n "$_fallback_file" ] && [ -s "$_fallback_file" ] && {
            warn "Using legacy cached subscription: $_fallback_file"
            cp "$_fallback_file" "$_source_file"
            return 0
        }
        return 1
    }

    mv -f "$_download_file" "$_source_file"
}

magicnet_singbox_fetch_subscription() {
    _url_file=$(magicnet_singbox_subscription_url_file)
    _source_dir=$(magicnet_singbox_subscription_source_dir)
    _legacy_source_file=$(magicnet_singbox_subscription_source_file)
    _sources_file="$1"

    if [ ! -s "$_url_file" ]; then
        error "Missing subscription URL file: $_url_file"
        return 1
    fi

    mkdir -p "$_source_dir"
    : >"$_sources_file"

    _index=0
    _ok=0
    while IFS= read -r _url || [ -n "$_url" ]; do
        _url=$(printf '%s' "$_url" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$_url" ] || continue

        _index=$((_index + 1))
        _source_file="${_source_dir}/subscription-${_index}.yaml"
        _fallback_file=""
        [ "$_index" -eq 1 ] && _fallback_file="$_legacy_source_file"

        if magicnet_singbox_fetch_one_subscription "$_url" "$_source_file" "$_fallback_file" "#${_index}"; then
            printf '%s\n' "$_source_file" >>"$_sources_file"
            _ok=$((_ok + 1))
        else
            warn "Skipping subscription #${_index}"
        fi
    done <"$_url_file"

    if [ "$_index" -eq 0 ]; then
        error "Subscription URL file is empty: $_url_file"
        return 1
    fi
    if [ "$_ok" -le 0 ]; then
        error "No subscription source is available"
        return 1
    fi
}

magicnet_singbox_extract_clash_nodes() {
    _source_file="$1"
    _nodes_dir="$2"
    mkdir -p "$_nodes_dir"
    _start_index=$(find "$_nodes_dir" -maxdepth 1 -type f \( -name 'node-*.yaml' -o -name 'node-*.link' \) 2>/dev/null | wc -l)

    awk -v outdir="$_nodes_dir" -v start="$_start_index" '
        BEGIN { in_proxies = 0; idx = 0; file = "" }
        /^[^[:space:]-][^:]*:/ {
            if ($0 ~ /^proxies:[[:space:]]*$/) {
                in_proxies = 1
                next
            }
            if (in_proxies) {
                in_proxies = 0
            }
        }
        in_proxies && /^[[:space:]]*-[[:space:]]+/ {
            idx++
            file = outdir "/node-" (start + idx) ".yaml"
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            print line > file
            next
        }
        in_proxies && file != "" && /^[[:space:]]+[[:alnum:]_-]+:/ {
            print $0 >> file
        }
        END { print idx }
    ' "$_source_file"
}

magicnet_singbox_extract_share_links() {
    _source_file="$1"
    _nodes_dir="$2"
    mkdir -p "$_nodes_dir"
    _start_index=$(find "$_nodes_dir" -maxdepth 1 -type f \( -name 'node-*.yaml' -o -name 'node-*.link' \) 2>/dev/null | wc -l)

    _links_file="${_nodes_dir}/links.txt"
    _first_line=$(sed -n '1{s/^[[:space:]]*//;p;}' "$_source_file")
    case "$_first_line" in
    vless://* | hysteria2://* | hy2://* | trojan://* | vmess://* | ss://*)
        grep -E '^[[:space:]]*(vless|hysteria2|hy2|trojan|vmess|ss)://' "$_source_file" |
            sed 's/^[[:space:]]*//' >"$_links_file"
        ;;
    *)
        if command -v base64 >/dev/null 2>&1; then
            base64 -d "$_source_file" 2>/dev/null |
                grep -E '^[[:space:]]*(vless|hysteria2|hy2|trojan|vmess|ss)://' |
                sed 's/^[[:space:]]*//' >"$_links_file"
            if [ ! -s "$_links_file" ]; then
                tr '_-' '/+' <"$_source_file" 2>/dev/null |
                    base64 -d 2>/dev/null |
                    grep -E '^[[:space:]]*(vless|hysteria2|hy2|trojan|vmess|ss)://' |
                    sed 's/^[[:space:]]*//' >"$_links_file"
            fi
        else
            : >"$_links_file"
        fi
        ;;
    esac

    _idx=0
    while IFS= read -r _link || [ -n "$_link" ]; do
        [ -n "$_link" ] || continue
        _idx=$((_idx + 1))
        printf '%s\n' "$_link" >"${_nodes_dir}/node-$((_start_index + _idx)).link"
    done <"$_links_file"

    printf '%s\n' "$_idx"
}

magicnet_singbox_emit_node_json() {
    _node_file="$1"
    _name=$(magicnet_yaml_value name)
    _type=$(magicnet_yaml_value type)
    _server=$(magicnet_yaml_value server)
    _port=$(magicnet_yaml_value port)

    [ -n "$_name" ] || return 1
    [ -n "$_type" ] || return 1
    [ -n "$_server" ] || return 1
    [ -n "$_port" ] || return 1

    _name=$(magicnet_percent_decode "$_name")
    _name=$(magicnet_json_escape "$_name")
    _server=$(magicnet_json_escape "$_server")

    case "$_type" in
    ss | shadowsocks)
        _cipher=$(magicnet_json_escape "$(magicnet_yaml_value cipher)")
        _password=$(magicnet_json_escape "$(magicnet_yaml_value password)")
        [ -n "$_cipher" ] || return 1
        [ -n "$_password" ] || return 1
        printf '{"type":"shadowsocks","tag":"%s","server":"%s","server_port":%s,"method":"%s","password":"%s"}' \
            "$_name" "$_server" "$_port" "$_cipher" "$_password"
        ;;
    vmess)
        _uuid=$(magicnet_json_escape "$(magicnet_yaml_value uuid)")
        _alter_id=$(magicnet_yaml_value alterId)
        _network=$(magicnet_yaml_value network)
        _tls=$(magicnet_yaml_value tls)
        [ -n "$_uuid" ] || return 1
        [ -n "$_alter_id" ] || _alter_id=0
        [ -n "$_network" ] || _network=tcp
        printf '{"type":"vmess","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","alter_id":%s' \
            "$_name" "$_server" "$_port" "$_uuid" "$_alter_id"
        [ "$_network" != "tcp" ] && printf ',"transport":{"type":"%s"}' "$_network"
        if magicnet_truthy "$_tls"; then
            _sni=$(magicnet_yaml_value servername)
            [ -n "$_sni" ] || _sni=$(magicnet_yaml_value sni)
            [ -n "$_sni" ] || _sni="$_server"
            _sni=$(magicnet_json_escape "$_sni")
            printf ',"tls":{"enabled":true,"server_name":"%s"}' "$_sni"
        fi
        printf '}'
        ;;
    vless)
        _uuid=$(magicnet_json_escape "$(magicnet_yaml_value uuid)")
        _flow=$(magicnet_json_escape "$(magicnet_yaml_value flow)")
        _network=$(magicnet_yaml_value network)
        _tls=$(magicnet_yaml_value tls)
        [ -n "$_uuid" ] || return 1
        [ -n "$_network" ] || _network=tcp
        printf '{"type":"vless","tag":"%s","server":"%s","server_port":%s,"uuid":"%s"' \
            "$_name" "$_server" "$_port" "$_uuid"
        [ "$_network" != "tcp" ] && printf ',"transport":{"type":"%s"}' "$_network"
        [ -n "$_flow" ] && printf ',"flow":"%s"' "$_flow"
        if magicnet_truthy "$_tls"; then
            _sni=$(magicnet_yaml_value servername)
            [ -n "$_sni" ] || _sni=$(magicnet_yaml_value sni)
            [ -n "$_sni" ] || _sni="$_server"
            _sni=$(magicnet_json_escape "$_sni")
            printf ',"tls":{"enabled":true,"server_name":"%s"}' "$_sni"
        fi
        printf '}'
        ;;
    trojan)
        _password=$(magicnet_json_escape "$(magicnet_yaml_value password)")
        [ -n "$_password" ] || return 1
        _sni=$(magicnet_yaml_value sni)
        [ -n "$_sni" ] || _sni=$(magicnet_yaml_value servername)
        [ -n "$_sni" ] || _sni="$_server"
        _sni=$(magicnet_json_escape "$_sni")
        printf '{"type":"trojan","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s"}}' \
            "$_name" "$_server" "$_port" "$_password" "$_sni"
        ;;
    hysteria2 | hy2)
        _password=$(magicnet_json_escape "$(magicnet_yaml_value password)")
        [ -n "$_password" ] || return 1
        _sni=$(magicnet_yaml_value sni)
        [ -n "$_sni" ] || _sni=$(magicnet_yaml_value servername)
        [ -n "$_sni" ] || _sni="$_server"
        _sni=$(magicnet_json_escape "$_sni")
        printf '{"type":"hysteria2","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s"}}' \
            "$_name" "$_server" "$_port" "$_password" "$_sni"
        ;;
    *)
        return 1
        ;;
    esac
}

magicnet_singbox_emit_share_link_json() {
    _node_file="$1"
    _link=$(sed -n '1p' "$_node_file")
    _scheme=${_link%%://*}
    _rest=${_link#*://}
    _body=${_rest%%\#*}
    _base=${_body%%\?*}
    _query=""
    [ "$_body" != "$_base" ] && _query=${_body#*\?}
    _userinfo=${_base%@*}
    _hostport=${_base#*@}
    _server=${_hostport%:*}
    _port=${_hostport##*:}
    _tag=$(magicnet_share_link_tag "$_link" "${_scheme}-${_server}-${_port}")

    [ -n "$_scheme" ] || return 1
    [ -n "$_userinfo" ] || return 1
    [ -n "$_server" ] || return 1
    [ -n "$_port" ] || return 1

    _tag=$(magicnet_json_escape "$_tag")
    _server=$(magicnet_json_escape "$_server")

    case "$_scheme" in
    ss)
        if printf '%s' "$_base" | grep -q '@'; then
            _method_password=$(magicnet_b64_decode "$_userinfo")
            [ -n "$_method_password" ] || _method_password="$_userinfo"
            _method=${_method_password%%:*}
            _password=${_method_password#*:}
        else
            _decoded=$(magicnet_b64_decode "$_base")
            _method_password=${_decoded%@*}
            _hostport=${_decoded#*@}
            _server=${_hostport%:*}
            _port=${_hostport##*:}
            _method=${_method_password%%:*}
            _password=${_method_password#*:}
        fi
        [ -n "$_method" ] || return 1
        [ -n "$_password" ] || return 1
        [ -n "$_server" ] || return 1
        [ -n "$_port" ] || return 1
        printf '{"type":"shadowsocks","tag":"%s","server":"%s","server_port":%s,"method":"%s","password":"%s"}' \
            "$_tag" "$(magicnet_json_escape "$_server")" "$_port" \
            "$(magicnet_json_escape "$_method")" "$(magicnet_json_escape "$_password")"
        ;;
    vmess)
        _decoded=$(magicnet_b64_decode "$_body")
        [ -n "$_decoded" ] || return 1
        _name=$(printf '%s' "$_decoded" | sed -n 's/.*"ps"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        _server=$(printf '%s' "$_decoded" | sed -n 's/.*"add"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        _port=$(printf '%s' "$_decoded" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p')
        _uuid=$(printf '%s' "$_decoded" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        _alter_id=$(printf '%s' "$_decoded" | sed -n 's/.*"aid"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p')
        _network=$(printf '%s' "$_decoded" | sed -n 's/.*"net"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        _tls=$(printf '%s' "$_decoded" | sed -n 's/.*"tls"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        _sni=$(printf '%s' "$_decoded" | sed -n 's/.*"sni"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        [ -n "$_name" ] && _tag=$(magicnet_json_escape "$_name")
        [ -n "$_server" ] || return 1
        [ -n "$_port" ] || return 1
        [ -n "$_uuid" ] || return 1
        [ -n "$_alter_id" ] || _alter_id=0
        [ -n "$_network" ] || _network=tcp
        printf '{"type":"vmess","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","alter_id":%s' \
            "$_tag" "$(magicnet_json_escape "$_server")" "$_port" "$(magicnet_json_escape "$_uuid")" "$_alter_id"
        [ "$_network" != "tcp" ] && printf ',"transport":{"type":"%s"}' "$(magicnet_json_escape "$_network")"
        if [ "$_tls" = "tls" ]; then
            [ -n "$_sni" ] || _sni="$_server"
            printf ',"tls":{"enabled":true,"server_name":"%s"}' "$(magicnet_json_escape "$_sni")"
        fi
        printf '}'
        ;;
    vless)
        _flow=$(magicnet_uri_query_value flow "$_query")
        _security=$(magicnet_uri_query_value security "$_query")
        _sni=$(magicnet_uri_query_value sni "$_query")
        [ -n "$_sni" ] || _sni=$(magicnet_uri_query_value servername "$_query")
        _fp=$(magicnet_uri_query_value fp "$_query")
        _pbk=$(magicnet_uri_query_value pbk "$_query")
        _sid=$(magicnet_uri_query_value sid "$_query")

        printf '{"type":"vless","tag":"%s","server":"%s","server_port":%s,"uuid":"%s"' \
            "$_tag" "$_server" "$_port" "$(magicnet_json_escape "$_userinfo")"
        [ -n "$_flow" ] && printf ',"flow":"%s"' "$(magicnet_json_escape "$_flow")"
        if [ "$_security" = "reality" ]; then
            [ -n "$_sni" ] || return 1
            printf ',"tls":{"enabled":true,"server_name":"%s"' "$(magicnet_json_escape "$_sni")"
            [ -n "$_fp" ] && printf ',"utls":{"enabled":true,"fingerprint":"%s"}' "$(magicnet_json_escape "$_fp")"
            printf ',"reality":{"enabled":true,"public_key":"%s"' "$(magicnet_json_escape "$_pbk")"
            [ -n "$_sid" ] && printf ',"short_id":"%s"' "$(magicnet_json_escape "$_sid")"
            printf '}}'
        elif [ "$_security" = "tls" ]; then
            [ -n "$_sni" ] || _sni="$_server"
            printf ',"tls":{"enabled":true,"server_name":"%s"' "$(magicnet_json_escape "$_sni")"
            [ -n "$_fp" ] && printf ',"utls":{"enabled":true,"fingerprint":"%s"}' "$(magicnet_json_escape "$_fp")"
            printf '}'
        fi
        printf '}'
        ;;
    hysteria2 | hy2)
        _sni=$(magicnet_uri_query_value sni "$_query")
        [ -n "$_sni" ] || _sni=$(magicnet_uri_query_value servername "$_query")
        [ -n "$_sni" ] || _sni="$_server"
        _fp=$(magicnet_uri_query_value fp "$_query")
        _alpn=$(magicnet_uri_query_value alpn "$_query")
        printf '{"type":"hysteria2","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s"' \
            "$_tag" "$_server" "$_port" "$(magicnet_json_escape "$_userinfo")" "$(magicnet_json_escape "$_sni")"
        [ -n "$_fp" ] && printf ',"utls":{"enabled":true,"fingerprint":"%s"}' "$(magicnet_json_escape "$_fp")"
        [ -n "$_alpn" ] && printf ',"alpn":%s' "$(magicnet_json_array_csv "$_alpn")"
        printf '}}'
        ;;
    *)
        return 1
        ;;
    esac
}

magicnet_singbox_build_outbounds_file() {
    _nodes_dir="$1"
    _out_file="$2"
    _tags_file="$3"
    _first=1
    _imported=0
    _skipped=0

    _first_tag=""
    : >"$_tags_file"
    printf '[' >"${_out_file}.nodes"
    for _node_file in "$_nodes_dir"/node-*.yaml "$_nodes_dir"/node-*.link; do
        [ -f "$_node_file" ] || continue
        case "$_node_file" in
        *.link) _json=$(magicnet_singbox_emit_share_link_json "$_node_file" 2>/dev/null) ;;
        *) _json=$(magicnet_singbox_emit_node_json "$_node_file" 2>/dev/null) ;;
        esac
        if [ -n "$_json" ]; then
            _tag=$(printf '%s' "$_json" | sed -n 's/.*"tag":"\([^"]*\)".*/\1/p')
            if magicnet_singbox_is_info_tag "$_tag"; then
                _skipped=$((_skipped + 1))
                continue
            fi
            [ "$_first" -eq 1 ] || printf ',' >>"${_out_file}.nodes"
            printf '%s' "$_json" >>"${_out_file}.nodes"
            printf '%s\n' "$_tag" >>"$_tags_file"
            [ -n "$_first_tag" ] || _first_tag="$_tag"
            _first=0
            _imported=$((_imported + 1))
        else
            _skipped=$((_skipped + 1))
        fi
    done
    printf ']' >>"${_out_file}.nodes"
    magicnet_singbox_build_region_groups "$_tags_file"

    {
        printf '  "outbounds": [\n'
        magicnet_emit_selector_json "proxy" "$_all" "$_first_tag"
        printf ',\n'
        magicnet_emit_selector_json "select" "$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "proxy" "hk" "jp" "us" "sg" "tw" "uk" "iepl" "free" "download" "direct")" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "hk" "$_hk" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "jp" "$_jp" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "us" "$_us" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "sg" "$_sg" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "tw" "$_tw" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "uk" "$_uk" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "iepl" "$_iepl" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "free" "$_free" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "download" "$_download" "direct"
        printf ',\n'
        magicnet_emit_selector_json "lan" "" "direct"
        printf ',\n'
        magicnet_emit_selector_json "ad-block" "" "block"
        printf ',\n'
        magicnet_emit_selector_json "cn-direct" "" "direct"
        printf ',\n'
        magicnet_emit_selector_json "apple-cn" "" "direct"
        printf ',\n'
        magicnet_emit_selector_json "microsoft-cn" "" "direct"
        printf ',\n'
        magicnet_emit_selector_json "google-cn" "" "direct"
        printf ',\n'
        magicnet_emit_selector_json "icloud" "" "direct"
        printf ',\n'
        magicnet_emit_selector_json "bing" "$(printf '%s\n%s\n%s\n%s\n' "proxy" "direct" "hk" "us")" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "network-test" "" "direct"
        printf ',\n'
        magicnet_emit_selector_json "ai-proxy" "$(printf '%s\n%s\n%s\n%s\n%s\n' "us" "sg" "jp" "proxy" "direct")" "us"
        printf ',\n'
        magicnet_emit_selector_json "proxy-rule" "$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' "proxy" "hk" "jp" "us" "sg" "direct")" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "dev-proxy" "$(printf '%s\n%s\n%s\n%s\n%s\n' "proxy" "hk" "jp" "us" "direct")" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "social-proxy" "$(printf '%s\n%s\n%s\n%s\n%s\n' "proxy" "hk" "jp" "us" "direct")" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "download-direct" "$_download" "direct"
        printf ',\n'
        magicnet_emit_selector_json "media-proxy" "$(printf '%s\n%s\n%s\n%s\n%s\n' "proxy" "hk" "jp" "us" "direct")" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "game-proxy" "$(printf '%s\n%s\n%s\n%s\n%s\n' "proxy" "hk" "jp" "us" "direct")" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "telegram-proxy" "$(printf '%s\n%s\n%s\n%s\n%s\n' "proxy" "hk" "jp" "sg" "direct")" "proxy"
        printf ',\n'
        magicnet_emit_selector_json "final" "$(printf '%s\n%s\n%s\n' "proxy" "direct" "block")" "proxy"
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
        }
        skipping == 0 && $0 ~ /^[[:space:]]*"outbounds"[[:space:]]*:/ {
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
        {
            if (prev != "") print prev
            prev = $0
        }
        END {
            if (prev != "") print prev
        }
    ' "$_config_file" >"$_tmp_file"

    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "$_tmp_file" -D "${_config_file%/*}" >/dev/null || {
            error "Generated sing-box config failed validation"
            return 1
        }
    fi

    mv -f "$_tmp_file" "$_config_file"
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

magicnet_singbox_restart_if_running() {
    magicnet_singbox_is_running || return 0

    for _pid in $(magicnet_singbox_pids); do
        kill "$_pid" 2>/dev/null || true
    done
    sleep 1
    if magicnet_singbox_is_running; then
        for _pid in $(magicnet_singbox_pids); do
            kill -9 "$_pid" 2>/dev/null || true
        done
        sleep 1
    fi
    ip link delete tun0 2>/dev/null || true

    _config_file=$(magicnet_singbox_subscription_config_file)
    _work_dir="${_config_file%/*}"
    _log_file="${MODDIR}/.log/sing-box.log"
    mkdir -p "${MODDIR}/.log"
    nohup sing-box run -c "$_config_file" -D "$_work_dir" >"$_log_file" 2>&1 &
    sleep 2
    magicnet_singbox_is_running
}

magicnet_singbox_api_has_nodes() {
    _api=$(curl -sS --max-time 5 http://127.0.0.1:9090/proxies 2>/dev/null || true)
    [ -n "$_api" ] || return 1
    printf '%s' "$_api" | grep -Eq '"type":"(VLESS|Hysteria2|Trojan|VMess|Shadowsocks)"'
}

magicnet_singbox_config_has_nodes() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    grep -Eq '"type":"(vless|hysteria2|trojan|vmess|shadowsocks)"' "$_config_file"
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
            error "sing-box subscription loaded no proxy nodes"
            return 1
        }
        magicnet_singbox_google_works || {
            error "sing-box proxy test failed: https://www.google.com is not reachable"
            return 1
        }
        return 0
    fi

    magicnet_singbox_config_has_nodes || {
        error "sing-box generated config contains no proxy nodes"
        return 1
    }
}

magicnet_singbox_update_subscription() {
    _work_dir="${MODDIR}/.config/sing-box/.subscription-work"
    _nodes_dir="${_work_dir}/nodes"
    _outbounds_file="${_work_dir}/outbounds.json"
    _tags_file="${_work_dir}/tags.txt"
    _sources_file="${_work_dir}/sources.txt"

    rm -rf "$_work_dir"
    mkdir -p "$_nodes_dir"

    magicnet_singbox_fetch_subscription "$_sources_file" || return 1

    _node_total=0
    while IFS= read -r _source_file || [ -n "$_source_file" ]; do
        [ -s "$_source_file" ] || continue
        if grep -Eq '^proxies:[[:space:]]*$' "$_source_file"; then
            _node_count=$(magicnet_singbox_extract_clash_nodes "$_source_file" "$_nodes_dir")
        else
            _node_count=$(magicnet_singbox_extract_share_links "$_source_file" "$_nodes_dir")
        fi
        _node_total=$((_node_total + ${_node_count:-0}))
    done <"$_sources_file"

    if [ "${_node_total:-0}" -le 0 ]; then
        error "No supported subscription nodes found"
        return 1
    fi

    # shellcheck disable=SC2046
    set -- $(magicnet_singbox_build_outbounds_file "$_nodes_dir" "$_outbounds_file" "$_tags_file")
    _imported="$1"
    _skipped="$2"

    if [ "${_imported:-0}" -le 0 ]; then
        error "No supported nodes imported. Supported: Clash ss/vmess/vless/trojan/hysteria2, share-link vless/hysteria2"
        return 1
    fi

    magicnet_singbox_update_config_with_nodes "$_outbounds_file" || return 1
    magicnet_singbox_verify_subscription_ready || return 1
    success "sing-box nodes updated: imported ${_imported}, skipped ${_skipped}"
}

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

magicnet_uri_query_value() {
    _key="$1"
    _query="$2"
    printf '%s' "$_query" | tr '&' '\n' |
        sed -n "s/^${_key}=//p" | tail -n 1
}

magicnet_share_link_tag() {
    _link="$1"
    _fallback="$2"
    _tag=$(printf '%s' "$_link" | sed -n 's/.*#//p')
    [ "$_tag" != "$_link" ] && [ -n "$_tag" ] || _tag="$_fallback"
    printf '%s\n' "$_tag"
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

magicnet_singbox_subscription_config_file() {
    printf '%s\n' "${MODDIR}/.config/sing-box/config.json"
}

magicnet_singbox_fetch_subscription() {
    _url_file=$(magicnet_singbox_subscription_url_file)
    _source_file=$(magicnet_singbox_subscription_source_file)
    _download_file="${_source_file}.download"

    if [ ! -s "$_url_file" ]; then
        error "Missing subscription URL file: $_url_file"
        return 1
    fi

    _url=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$_url_file")
    if [ -z "$_url" ]; then
        error "Subscription URL file is empty: $_url_file"
        return 1
    fi

    mkdir -p "${_source_file%/*}"
    rm -f "$_download_file"

    _connect_timeout="${MAGICNET_SUB_CONNECT_TIMEOUT:-10}"
    _max_time="${MAGICNET_SUB_MAX_TIME:-45}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$_connect_timeout" --max-time "$_max_time" "$_url" -o "$_download_file" || {
            error "Failed to download subscription with curl"
            [ -s "$_source_file" ] && {
                warn "Using cached subscription: $_source_file"
                return 0
            }
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -T "$_max_time" -qO "$_download_file" "$_url" || {
            error "Failed to download subscription with wget"
            [ -s "$_source_file" ] && {
                warn "Using cached subscription: $_source_file"
                return 0
            }
            return 1
        }
    elif command -v sing-box >/dev/null 2>&1; then
        sing-box tools fetch "$_url" >"$_download_file" || {
            error "Failed to download subscription with sing-box"
            [ -s "$_source_file" ] && {
                warn "Using cached subscription: $_source_file"
                return 0
            }
            return 1
        }
    else
        error "No downloader found: curl, wget or sing-box tools fetch"
        return 1
    fi

    [ -s "$_download_file" ] || {
        error "Downloaded subscription is empty"
        [ -s "$_source_file" ] && {
            warn "Using cached subscription: $_source_file"
            return 0
        }
        return 1
    }

    mv -f "$_download_file" "$_source_file"
}

magicnet_singbox_extract_clash_nodes() {
    _source_file="$1"
    _nodes_dir="$2"
    mkdir -p "$_nodes_dir"

    awk -v outdir="$_nodes_dir" '
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
            file = outdir "/node-" idx ".yaml"
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
        else
            : >"$_links_file"
        fi
        ;;
    esac

    _idx=0
    while IFS= read -r _link || [ -n "$_link" ]; do
        [ -n "$_link" ] || continue
        _idx=$((_idx + 1))
        printf '%s\n' "$_link" >"${_nodes_dir}/node-${_idx}.link"
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
            [ "$_first" -eq 1 ] || printf ',' >>"${_out_file}.nodes"
            printf '%s' "$_json" >>"${_out_file}.nodes"
            case "$_node_file" in
            *.link) _tag=$(magicnet_share_link_tag "$(sed -n '1p' "$_node_file")" "node-${_imported}") ;;
            *) _tag=$(magicnet_yaml_value name) ;;
            esac
            printf '%s\n' "$_tag" >>"$_tags_file"
            [ -n "$_first_tag" ] || _first_tag="$_tag"
            _first=0
            _imported=$((_imported + 1))
        else
            _skipped=$((_skipped + 1))
        fi
    done
    printf ']' >>"${_out_file}.nodes"

    {
        printf '  "outbounds": [\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "proxy",\n'
        printf '      "outbounds": ['
        _first=1
        while IFS= read -r _tag; do
            [ -n "$_tag" ] || continue
            [ "$_first" -eq 1 ] || printf ', '
            printf '"%s"' "$(magicnet_json_escape "$_tag")"
            _first=0
        done <"$_tags_file"
        [ "$_first" -eq 1 ] || printf ', '
        printf '"direct", "block"],\n'
        printf '      "default": "%s"\n' "$(magicnet_json_escape "${_first_tag:-direct}")"
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "select",\n'
        printf '      "outbounds": ["proxy", "direct", "block"],\n'
        printf '      "default": "proxy"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "lan",\n'
        printf '      "outbounds": ["direct", "proxy", "block"],\n'
        printf '      "default": "direct"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "ad-block",\n'
        printf '      "outbounds": ["block", "direct", "proxy"],\n'
        printf '      "default": "block"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "cn-direct",\n'
        printf '      "outbounds": ["direct", "proxy", "block"],\n'
        printf '      "default": "direct"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "apple-cn",\n'
        printf '      "outbounds": ["direct", "proxy", "block"],\n'
        printf '      "default": "direct"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "microsoft-cn",\n'
        printf '      "outbounds": ["direct", "proxy", "block"],\n'
        printf '      "default": "direct"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "google-cn",\n'
        printf '      "outbounds": ["direct", "proxy", "block"],\n'
        printf '      "default": "direct"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "icloud",\n'
        printf '      "outbounds": ["direct", "proxy", "block"],\n'
        printf '      "default": "direct"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "bing",\n'
        printf '      "outbounds": ["proxy", "direct", "block"],\n'
        printf '      "default": "proxy"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "network-test",\n'
        printf '      "outbounds": ["direct", "proxy", "block"],\n'
        printf '      "default": "direct"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "ai-proxy",\n'
        printf '      "outbounds": ["proxy", "direct", "block"],\n'
        printf '      "default": "proxy"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "proxy-rule",\n'
        printf '      "outbounds": ["proxy", "direct", "block"],\n'
        printf '      "default": "proxy"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "dev-proxy",\n'
        printf '      "outbounds": ["proxy", "direct", "block"],\n'
        printf '      "default": "proxy"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "social-proxy",\n'
        printf '      "outbounds": ["proxy", "direct", "block"],\n'
        printf '      "default": "proxy"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "download-direct",\n'
        printf '      "outbounds": ["direct", "proxy", "block"],\n'
        printf '      "default": "direct"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "media-proxy",\n'
        printf '      "outbounds": ["proxy", "direct", "block"],\n'
        printf '      "default": "proxy"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "game-proxy",\n'
        printf '      "outbounds": ["proxy", "direct", "block"],\n'
        printf '      "default": "proxy"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "telegram-proxy",\n'
        printf '      "outbounds": ["proxy", "direct", "block"],\n'
        printf '      "default": "proxy"\n'
        printf '    },\n'
        printf '    {\n'
        printf '      "type": "selector",\n'
        printf '      "tag": "final",\n'
        printf '      "outbounds": ["direct", "proxy", "block"],\n'
        printf '      "default": "direct"\n'
        printf '    }'
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

magicnet_singbox_update_subscription() {
    _source_file=$(magicnet_singbox_subscription_source_file)
    _work_dir="${MODDIR}/.config/sing-box/.subscription-work"
    _nodes_dir="${_work_dir}/nodes"
    _outbounds_file="${_work_dir}/outbounds.json"
    _tags_file="${_work_dir}/tags.txt"

    rm -rf "$_work_dir"
    mkdir -p "$_nodes_dir"

    magicnet_singbox_fetch_subscription || return 1
    if grep -Eq '^proxies:[[:space:]]*$' "$_source_file"; then
        _node_count=$(magicnet_singbox_extract_clash_nodes "$_source_file" "$_nodes_dir")
    else
        _node_count=$(magicnet_singbox_extract_share_links "$_source_file" "$_nodes_dir")
    fi
    if [ "${_node_count:-0}" -le 0 ]; then
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
    success "sing-box nodes updated: imported ${_imported}, skipped ${_skipped}"
}

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
        _alpn=$(magicnet_uri_query_value alpn "$_query")
        printf '{"type":"hysteria2","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s"' \
            "$_tag" "$_server" "$_port" "$(magicnet_json_escape "$_userinfo")" "$(magicnet_json_escape "$_sni")"
        [ -n "$_alpn" ] && printf ',"alpn":%s' "$(magicnet_json_array_csv "$_alpn")"
        printf '}}'
        ;;
    *)
        return 1
        ;;
    esac
}


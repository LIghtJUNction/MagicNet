magicnet_singbox_extract_clash_nodes() {
    _source_file="$1"
    _nodes_dir="$2"
    mkdir -p "$_nodes_dir"
    _start_index=$(find "$_nodes_dir" -maxdepth 1 -type f \( -name 'node-*.yaml' -o -name 'node-*.link' \) 2>/dev/null | wc -l)

    awk -v outdir="$_nodes_dir" -v start="$_start_index" '
        { gsub(/\r/, "") }
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
    _current_links_file=$(mktemp "${_nodes_dir}/links.current.XXXXXX") || return 1
    _first_line=$(awk '
        {
            sub(/\r$/, "")
            sub(/^[[:space:]]+/, "")
            if ($0 != "" && $0 !~ /^#/) {
                print
                exit
            }
        }
    ' "$_source_file")
    _first_line_lc=$(printf '%s' "$_first_line" | tr '[:upper:]' '[:lower:]')
    case "$_first_line_lc" in
    vless://* | anytls://* | tuic://* | hysteria2://* | hy2://* | trojan://* | vmess://* | ss://* | socks://* | socks5://*)
        tr -d '\r' <"$_source_file" |
            grep -E -i '^[[:space:]]*(vless|anytls|tuic|hysteria2|hy2|trojan|vmess|ss|socks|socks5)://' |
            sed 's/^[[:space:]]*//' >"$_current_links_file"
        ;;
    *)
        if command -v base64 >/dev/null 2>&1; then
            base64 -d "$_source_file" 2>/dev/null |
                tr -d '\r' |
                grep -E -i '^[[:space:]]*(vless|anytls|tuic|hysteria2|hy2|trojan|vmess|ss|socks|socks5)://' |
                sed 's/^[[:space:]]*//' >"$_current_links_file"
            if [ ! -s "$_current_links_file" ]; then
                tr '_-' '/+' <"$_source_file" 2>/dev/null |
                    base64 -d 2>/dev/null |
                    tr -d '\r' |
                    grep -E -i '^[[:space:]]*(vless|anytls|tuic|hysteria2|hy2|trojan|vmess|ss|socks|socks5)://' |
                    sed 's/^[[:space:]]*//' >"$_current_links_file"
            fi
        else
            : >"$_current_links_file"
        fi
        ;;
    esac

    cat "$_current_links_file" >>"$_links_file" || {
        rm -f "$_current_links_file"
        return 1
    }

    _idx=0
    while IFS= read -r _link || [ -n "$_link" ]; do
        [ -n "$_link" ] || continue
        _idx=$((_idx + 1))
        printf '%s\n' "$_link" >"${_nodes_dir}/node-$((_start_index + _idx)).link"
    done <"$_current_links_file"

    rm -f "$_current_links_file"

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
    _port=$(magicnet_singbox_normalize_port "$_port") || return 1

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
    socks | socks5)
        _version=$(magicnet_yaml_value version)
        [ -n "$_version" ] || _version=5
        case "$_version" in
        4 | 4a | 5) ;;
        *) return 1 ;;
        esac
        _username=$(magicnet_yaml_value username)
        _password=$(magicnet_yaml_value password)
        if { [ -n "$_username" ] && [ -z "$_password" ]; } ||
            { [ -z "$_username" ] && [ -n "$_password" ]; }; then
            return 1
        fi
        printf '{"type":"socks","tag":"%s","server":"%s","server_port":%s,"version":"%s"' \
            "$_name" "$_server" "$_port" "$_version"
        if [ -n "$_username" ]; then
            printf ',"username":"%s","password":"%s"' \
                "$(magicnet_json_escape "$_username")" "$(magicnet_json_escape "$_password")"
        fi
        printf '}'
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
    anytls)
        _password=$(magicnet_json_escape "$(magicnet_yaml_value password)")
        [ -n "$_password" ] || return 1
        _sni=$(magicnet_yaml_value sni)
        [ -n "$_sni" ] || _sni=$(magicnet_yaml_value servername)
        [ -n "$_sni" ] || _sni="$_server"
        _sni=$(magicnet_json_escape "$_sni")
        _fp=$(magicnet_yaml_value client-fingerprint)
        [ -n "$_fp" ] || _fp=$(magicnet_yaml_value fingerprint)
        _fp=$(magicnet_json_escape "$_fp")
        _skip=$(magicnet_yaml_value skip-cert-verify)
        [ -n "$_skip" ] || _skip=$(magicnet_yaml_value insecure)
        _alpn=$(magicnet_yaml_value alpn)
        # Clash may store alpn as a YAML list; flatten common one-line forms.
        _alpn=$(printf '%s' "$_alpn" | tr -d '[]"' | tr ' ' ',')
        printf '{"type":"anytls","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s"' \
            "$_name" "$_server" "$_port" "$_password" "$_sni"
        if magicnet_truthy "$_skip"; then
            printf ',"insecure":true'
        fi
        [ -n "$_fp" ] && printf ',"utls":{"enabled":true,"fingerprint":"%s"}' "$_fp"
        [ -n "$_alpn" ] && printf ',"alpn":%s' "$(magicnet_json_array_csv "$_alpn")"
        printf '}}'
        ;;
    tuic)
        # Clash: uuid + password (+ optional sni / congestion-controller / alpn / skip-cert-verify)
        _uuid=$(magicnet_json_escape "$(magicnet_yaml_value uuid)")
        _password=$(magicnet_json_escape "$(magicnet_yaml_value password)")
        [ -n "$_uuid" ] || return 1
        [ -n "$_password" ] || return 1
        _sni=$(magicnet_yaml_value sni)
        [ -n "$_sni" ] || _sni=$(magicnet_yaml_value servername)
        [ -n "$_sni" ] || _sni="$_server"
        _sni=$(magicnet_json_escape "$_sni")
        _cc=$(magicnet_yaml_value congestion-controller)
        [ -n "$_cc" ] || _cc=$(magicnet_yaml_value congestion_control)
        [ -n "$_cc" ] || _cc="cubic"
        _cc=$(magicnet_json_escape "$_cc")
        _udp_relay=$(magicnet_yaml_value udp-relay-mode)
        [ -n "$_udp_relay" ] || _udp_relay=$(magicnet_yaml_value udp_relay_mode)
        _skip=$(magicnet_yaml_value skip-cert-verify)
        [ -n "$_skip" ] || _skip=$(magicnet_yaml_value insecure)
        _alpn=$(magicnet_yaml_value alpn)
        _alpn=$(printf '%s' "$_alpn" | tr -d '[]"' | tr ' ' ',')
        printf '{"type":"tuic","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","password":"%s","congestion_control":"%s"' \
            "$_name" "$_server" "$_port" "$_uuid" "$_password" "$_cc"
        [ -n "$_udp_relay" ] && printf ',"udp_relay_mode":"%s"' "$(magicnet_json_escape "$_udp_relay")"
        printf ',"tls":{"enabled":true,"server_name":"%s"' "$_sni"
        if magicnet_truthy "$_skip"; then
            printf ',"insecure":true'
        fi
        [ -n "$_alpn" ] && printf ',"alpn":%s' "$(magicnet_json_array_csv "$_alpn")"
        printf '}}'
        ;;
    *)
        return 1
        ;;
    esac
}

magicnet_singbox_emit_share_link_json() {
    _node_file="$1"
    _link=$(sed -n '1p' "$_node_file" | tr -d '\r')
    _scheme=${_link%%://*}
    _scheme=$(printf '%s' "$_scheme" | tr '[:upper:]' '[:lower:]')
    _rest=${_link#*://}
    _body=${_rest%%\#*}
    _base=${_body%%\?*}
    _query=""
    [ "$_body" != "$_base" ] && _query=${_body#*\?}
    _userinfo=${_base%@*}
    _hostport=${_base#*@}
    _hostport=${_hostport%/}
    case "$_hostport" in
    \[*\]:*)
        # Share links bracket IPv6 literals.  The brackets delimit the
        # authority and must not become part of sing-box's server value.
        _server=${_hostport#\[}
        _server=${_server%%\]*}
        _port=${_hostport#*\]:}
        ;;
    *)
        _server=${_hostport%:*}
        _port=${_hostport##*:}
        ;;
    esac
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
        _port=$(magicnet_singbox_normalize_port "$_port") || return 1
        printf '{"type":"shadowsocks","tag":"%s","server":"%s","server_port":%s,"method":"%s","password":"%s"}' \
            "$_tag" "$(magicnet_json_escape "$_server")" "$_port" \
            "$(magicnet_json_escape "$_method")" "$(magicnet_json_escape "$_password")"
        ;;
    vmess)
        _decoded=$(magicnet_b64_decode "$_body")
        [ -n "$_decoded" ] || return 1
        if command -v jq >/dev/null 2>&1; then
            _vmess_json_raw=0
            _name=$(printf '%s' "$_decoded" | jq -r '.ps // empty | tostring' 2>/dev/null)
            _server=$(printf '%s' "$_decoded" | jq -r '.add // empty | tostring' 2>/dev/null)
            _port=$(printf '%s' "$_decoded" | jq -r '.port // empty | tostring' 2>/dev/null)
            _uuid=$(printf '%s' "$_decoded" | jq -r '.id // empty | tostring' 2>/dev/null)
            _alter_id=$(printf '%s' "$_decoded" | jq -r '.aid // empty | tostring' 2>/dev/null)
            _network=$(printf '%s' "$_decoded" | jq -r '.net // empty | tostring' 2>/dev/null)
            _path=$(printf '%s' "$_decoded" | jq -r '.path // empty | tostring' 2>/dev/null)
            _host=$(printf '%s' "$_decoded" | jq -r '.host // empty | tostring' 2>/dev/null)
            _tls=$(printf '%s' "$_decoded" | jq -r '.tls // empty | tostring' 2>/dev/null)
            _sni=$(printf '%s' "$_decoded" | jq -r '.sni // empty | tostring' 2>/dev/null)
        else
            _vmess_json_raw=1
            _name=$(magicnet_json_field_raw ps "$_decoded") || _name=
            _server=$(magicnet_json_field_raw add "$_decoded") || return 1
            _port=$(printf '%s' "$_decoded" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p')
            _uuid=$(magicnet_json_field_raw id "$_decoded") || return 1
            _alter_id=$(printf '%s' "$_decoded" | sed -n 's/.*"aid"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p')
            _network=$(magicnet_json_field_raw net "$_decoded") || _network=
            _path=$(magicnet_json_field_raw path "$_decoded") || _path=
            _host=$(magicnet_json_field_raw host "$_decoded") || _host=
            _tls=$(magicnet_json_field_raw tls "$_decoded") || _tls=
            _sni=$(magicnet_json_field_raw sni "$_decoded") || _sni=
        fi
        if [ "${_vmess_json_raw:-0}" = 1 ]; then
            [ -n "$_name" ] && _tag="$_name"
            _server_json=$_server
            _uuid_json=$_uuid
            _path_json=$_path
            _host_json=$_host
            _sni_json=$_sni
        else
            [ -n "$_name" ] && _tag=$(magicnet_json_escape "$_name")
            _server_json=$(magicnet_json_escape "$_server")
            _uuid_json=$(magicnet_json_escape "$_uuid")
            _path_json=$(magicnet_json_escape "$_path")
            _host_json=$(magicnet_json_escape "$_host")
            _sni_json=$(magicnet_json_escape "$_sni")
        fi
        [ -n "$_server" ] || return 1
        [ -n "$_port" ] || return 1
        [ -n "$_uuid" ] || return 1
        _port=$(magicnet_singbox_normalize_port "$_port") || return 1
        [ -n "$_alter_id" ] || _alter_id=0
        [ -n "$_network" ] || _network=tcp
        printf '{"type":"vmess","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","alter_id":%s' \
            "$_tag" "$_server_json" "$_port" "$_uuid_json" "$_alter_id"
        if [ "$_network" = "ws" ]; then
            printf ',"transport":{"type":"ws"'
            [ -n "$_path" ] && printf ',"path":"%s"' "$_path_json"
            [ -n "$_host" ] && printf ',"headers":{"Host":"%s"}' "$_host_json"
            printf '}'
        elif [ "$_network" != "tcp" ]; then
            printf ',"transport":{"type":"%s"}' "$(magicnet_json_escape "$_network")"
        fi
        if [ "$_tls" = "tls" ]; then
            [ -n "$_sni" ] || _sni="$_server"
            if [ "${_vmess_json_raw:-0}" = 1 ]; then
                [ -n "$_sni_json" ] || _sni_json=$_server_json
            else
                _sni_json=$(magicnet_json_escape "$_sni")
            fi
            printf ',"tls":{"enabled":true,"server_name":"%s"}' "$_sni_json"
        fi
        printf '}'
        ;;
    socks | socks5)
        _port=$(magicnet_singbox_normalize_port "$_port") || return 1
        _username=""
        _password=""
        case "$_base" in
        *@*)
            [ -n "$_userinfo" ] || return 1
            case "$_userinfo" in
            *:*) _credentials="$_userinfo" ;;
            *)
                _credentials=$(magicnet_b64_decode "$_userinfo")
                [ -n "$_credentials" ] || return 1
                case "$_credentials" in
                *:*) ;;
                *) return 1 ;;
                esac
                ;;
            esac
            _username=${_credentials%%:*}
            _password=${_credentials#*:}
            [ -n "$_username" ] || return 1
            [ -n "$_password" ] || return 1
            _username=$(magicnet_percent_decode "$_username")
            _password=$(magicnet_percent_decode "$_password")
            [ -n "$_username" ] || return 1
            [ -n "$_password" ] || return 1
            ;;
        esac

        printf '{"type":"socks","tag":"%s","server":"%s","server_port":%s,"version":"5"' \
            "$_tag" "$_server" "$_port"
        if [ -n "$_username" ]; then
            printf ',"username":"%s","password":"%s"' \
                "$(magicnet_json_escape "$_username")" "$(magicnet_json_escape "$_password")"
        fi
        printf '}'
        ;;
    vless)
        _port=$(magicnet_singbox_normalize_port "$_port") || return 1
        _userinfo=$(magicnet_percent_decode "$_userinfo") || return 1
        [ -n "$_userinfo" ] || return 1
        _flow=$(magicnet_uri_query_value flow "$_query")
        _security=$(magicnet_uri_query_value security "$_query")
        _security=$(printf '%s' "$_security" | tr '[:upper:]' '[:lower:]')
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
            [ -n "$_pbk" ] || return 1
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
        _port=$(magicnet_singbox_normalize_port "$_port") || return 1
        _password=$(magicnet_percent_decode "$_userinfo")
        [ -n "$_password" ] || return 1
        _sni=$(magicnet_uri_query_value sni "$_query")
        [ -n "$_sni" ] || _sni=$(magicnet_uri_query_value servername "$_query")
        [ -n "$_sni" ] || _sni="$_server"
        _alpn=$(magicnet_uri_query_value alpn "$_query")
        printf '{"type":"hysteria2","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s"' \
            "$_tag" "$_server" "$_port" "$(magicnet_json_escape "$_password")" "$(magicnet_json_escape "$_sni")"
        [ -n "$_alpn" ] && printf ',"alpn":%s' "$(magicnet_json_array_csv "$_alpn")"
        printf '}}'
        ;;
    trojan)
        _port=$(magicnet_singbox_normalize_port "$_port") || return 1
        _password=$(magicnet_percent_decode "$_userinfo")
        [ -n "$_password" ] || return 1
        _sni=$(magicnet_uri_query_value sni "$_query")
        [ -n "$_sni" ] || _sni=$(magicnet_uri_query_value servername "$_query")
        [ -n "$_sni" ] || _sni=$(magicnet_uri_query_value peer "$_query")
        [ -n "$_sni" ] || _sni="$_server"
        _insecure=$(magicnet_uri_query_value insecure "$_query")
        [ -n "$_insecure" ] || _insecure=$(magicnet_uri_query_value allowInsecure "$_query")
        [ -n "$_insecure" ] || _insecure=$(magicnet_uri_query_value skip-cert-verify "$_query")
        _alpn=$(magicnet_uri_query_value alpn "$_query")
        printf '{"type":"trojan","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s"' \
            "$_tag" "$_server" "$_port" "$(magicnet_json_escape "$_password")" "$(magicnet_json_escape "$_sni")"
        if magicnet_truthy "$_insecure"; then
            printf ',"insecure":true'
        fi
        [ -n "$_alpn" ] && printf ',"alpn":%s' "$(magicnet_json_array_csv "$_alpn")"
        printf '}}'
        ;;
    anytls)
        # anytls://password@host:port?sni=&insecure=&fp=&alpn=#tag
        _port=$(magicnet_singbox_normalize_port "$_port") || return 1
        _password=$(magicnet_percent_decode "$_userinfo")
        [ -n "$_password" ] || return 1
        _sni=$(magicnet_uri_query_value sni "$_query")
        [ -n "$_sni" ] || _sni=$(magicnet_uri_query_value servername "$_query")
        [ -n "$_sni" ] || _sni=$(magicnet_uri_query_value peer "$_query")
        [ -n "$_sni" ] || _sni="$_server"
        _fp=$(magicnet_uri_query_value fp "$_query")
        [ -n "$_fp" ] || _fp=$(magicnet_uri_query_value fingerprint "$_query")
        _insecure=$(magicnet_uri_query_value insecure "$_query")
        [ -n "$_insecure" ] || _insecure=$(magicnet_uri_query_value allowInsecure "$_query")
        _alpn=$(magicnet_uri_query_value alpn "$_query")
        printf '{"type":"anytls","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s"' \
            "$_tag" "$_server" "$_port" "$(magicnet_json_escape "$_password")" "$(magicnet_json_escape "$_sni")"
        if magicnet_truthy "$_insecure"; then
            printf ',"insecure":true'
        fi
        [ -n "$_fp" ] && printf ',"utls":{"enabled":true,"fingerprint":"%s"}' "$(magicnet_json_escape "$_fp")"
        [ -n "$_alpn" ] && printf ',"alpn":%s' "$(magicnet_json_array_csv "$_alpn")"
        printf '}}'
        ;;
    tuic)
        # tuic://uuid:password@host:port?sni=&congestion_control=&alpn=&udp_relay_mode=#tag
        _port=$(magicnet_singbox_normalize_port "$_port") || return 1
        _uuid=${_userinfo%%:*}
        _password=${_userinfo#*:}
        [ -n "$_uuid" ] || return 1
        [ "$_password" != "$_userinfo" ] || return 1
        [ -n "$_password" ] || return 1
        _uuid=$(magicnet_percent_decode "$_uuid")
        _password=$(magicnet_percent_decode "$_password")
        _sni=$(magicnet_uri_query_value sni "$_query")
        [ -n "$_sni" ] || _sni=$(magicnet_uri_query_value servername "$_query")
        [ -n "$_sni" ] || _sni="$_server"
        _cc=$(magicnet_uri_query_value congestion_control "$_query")
        [ -n "$_cc" ] || _cc=$(magicnet_uri_query_value congestion-controller "$_query")
        [ -n "$_cc" ] || _cc="cubic"
        _udp_relay=$(magicnet_uri_query_value udp_relay_mode "$_query")
        [ -n "$_udp_relay" ] || _udp_relay=$(magicnet_uri_query_value udp-relay-mode "$_query")
        _insecure=$(magicnet_uri_query_value insecure "$_query")
        [ -n "$_insecure" ] || _insecure=$(magicnet_uri_query_value allowInsecure "$_query")
        _alpn=$(magicnet_uri_query_value alpn "$_query")
        printf '{"type":"tuic","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","password":"%s","congestion_control":"%s"' \
            "$_tag" "$_server" "$_port" "$(magicnet_json_escape "$_uuid")" "$(magicnet_json_escape "$_password")" "$(magicnet_json_escape "$_cc")"
        [ -n "$_udp_relay" ] && printf ',"udp_relay_mode":"%s"' "$(magicnet_json_escape "$_udp_relay")"
        printf ',"tls":{"enabled":true,"server_name":"%s"' "$(magicnet_json_escape "$_sni")"
        if magicnet_truthy "$_insecure"; then
            printf ',"insecure":true'
        fi
        [ -n "$_alpn" ] && printf ',"alpn":%s' "$(magicnet_json_array_csv "$_alpn")"
        printf '}}'
        ;;
    *)
        return 1
        ;;
    esac
}

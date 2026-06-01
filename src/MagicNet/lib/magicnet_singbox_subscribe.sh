# shellcheck shell=ash
#
# Import common Clash-style subscription nodes into the bundled sing-box config.

magicnet_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if ! command -v error >/dev/null 2>&1; then
    error() { printf '%s\n' "ERROR: $1"; }
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

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$_url" -o "$_source_file" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$_source_file" "$_url" || return 1
    elif command -v sing-box >/dev/null 2>&1; then
        sing-box tools fetch "$_url" >"$_source_file" || return 1
    else
        error "No downloader found: curl, wget or sing-box tools fetch"
        return 1
    fi

    [ -s "$_source_file" ] || {
        error "Downloaded subscription is empty"
        return 1
    }
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
    for _node_file in "$_nodes_dir"/node-*.yaml; do
        [ -f "$_node_file" ] || continue
        _json=$(magicnet_singbox_emit_node_json "$_node_file" 2>/dev/null)
        if [ -n "$_json" ]; then
            [ "$_first" -eq 1 ] || printf ',' >>"${_out_file}.nodes"
            printf '%s' "$_json" >>"${_out_file}.nodes"
            _tag=$(magicnet_yaml_value name)
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
    _node_count=$(magicnet_singbox_extract_clash_nodes "$_source_file" "$_nodes_dir")
    if [ "${_node_count:-0}" -le 0 ]; then
        error "No Clash proxies found in subscription"
        return 1
    fi

    # shellcheck disable=SC2046
    set -- $(magicnet_singbox_build_outbounds_file "$_nodes_dir" "$_outbounds_file" "$_tags_file")
    _imported="$1"
    _skipped="$2"

    if [ "${_imported:-0}" -le 0 ]; then
        error "No supported nodes imported. Supported: ss, vmess, vless, trojan, hysteria2"
        return 1
    fi

    magicnet_singbox_update_config_with_nodes "$_outbounds_file" || return 1
    success "sing-box nodes updated: imported ${_imported}, skipped ${_skipped}"
}

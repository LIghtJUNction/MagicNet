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
        magicnet_singbox_emit_selector_block "$_tags_file" "$_first_tag"
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

magicnet_singbox_emit_selector_block() {
    _tags_file="$1"
    _first_tag="$2"
    magicnet_emit_selector_json "proxy" "$(cat "$_tags_file")" "$_first_tag"
    printf ',\n'
    magicnet_emit_selector_json "select" "$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "proxy" "hk" "jp" "us" "sg" "tw" "uk" "iepl" "free" "download" "direct")" "proxy"
    for _pair in \
        "hk:$_hk:proxy" "jp:$_jp:proxy" "us:$_us:proxy" "sg:$_sg:proxy" \
        "tw:$_tw:proxy" "uk:$_uk:proxy" "iepl:$_iepl:proxy" \
        "free:$_free:proxy" "download:$_download:direct"; do
        _name=${_pair%%:*}
        _rest=${_pair#*:}
        _items=${_rest%:*}
        _default=${_pair##*:}
        printf ',\n'
        magicnet_emit_selector_json "$_name" "$_items" "$_default"
    done
    magicnet_singbox_emit_static_selectors
    unset _tags_file _first_tag _pair _name _rest _items _default
}

magicnet_singbox_emit_static_selectors() {
    for _pair in \
        "lan::direct" "ad-block::block" "cn-direct::direct" \
        "apple-cn::direct" "microsoft-cn::direct" "google-cn::direct" "icloud::direct"; do
        _name=${_pair%%:*}
        _default=${_pair##*:}
        printf ',\n'
        magicnet_emit_selector_json "$_name" "" "$_default"
    done
    printf ',\n'
    magicnet_emit_selector_json "bing" "$(printf '%s\n%s\n%s\n%s\n' "proxy" "direct" "hk" "us")" "proxy"
    printf ',\n'
    magicnet_emit_selector_json "network-test" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    for _name in ai-proxy proxy-rule dev-proxy social-proxy media-proxy game-proxy telegram-proxy; do
        printf ',\n'
        magicnet_emit_selector_json "$_name" "$(printf '%s\n%s\n%s\n%s\n%s\n' "proxy" "hk" "jp" "us" "direct")" "proxy"
    done
    printf ',\n'
    magicnet_emit_selector_json "download-direct" "$_download" "direct"
    printf ',\n'
    magicnet_emit_selector_json "final" "$(printf '%s\n%s\n%s\n' "proxy" "direct" "block")" "proxy"
    unset _pair _name _default
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
    ip link delete magicnet0 2>/dev/null || true
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
    _api=$(curl -sS --max-time 5 http://127.0.0.1:9090/proxies 2>/dev/null || curl -sS --max-time 5 http://127.0.0.1:9090/providers/proxies 2>/dev/null || true)
    [ -n "$_api" ] || return 1
    printf '%s' "$_api" | grep -Eq '"type":"(VLESS|Hysteria2|Trojan|VMess|Shadowsocks|Selector)"'
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
            warn "sing-box API did not expose proxy nodes; generated config contains nodes"
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

magicnet_mihomo_apply_transparent_mode() {
    _config="${MODDIR}/.config/mihomo/config.yaml"
    [ -f "$_config" ] || return 0
    _mode="$(magicnet_transparent_mode)"
    _tmp="${_config}.transparent-mode.new"
    if awk -v mode="$_mode" '
        BEGIN {
            in_tun = 0
        }
        {
            if ($0 ~ /^tun:[[:space:]]*$/) {
                in_tun = 1
                print
                next
            }
            if (in_tun && $0 ~ /^[^[:space:]-]/) {
                in_tun = 0
            }
            if (in_tun && $0 ~ /^  enable[[:space:]]*:/) {
                print "  enable: " (mode == "tun" ? "true" : "false")
                next
            }
            print
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        unset _mode
        return 1
    fi
    unset _mode
}

magicnet_singbox_apply_transparent_mode() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _mode="$(magicnet_transparent_mode)"
    _tmp="${_config}.transparent-mode.new"
    if awk -v mode="$_mode" '
        function emit_tun(comma) {
            print "    {"
            print "      \"type\": \"tun\","
            print "      \"tag\": \"tun-in\","
            print "      \"interface_name\": \"magicnet0\","
            print "      \"address\": \"172.19.0.1/30\","
            print "      \"auto_route\": true,"
            print "      \"auto_redirect\": true,"
            print "      \"strict_route\": true,"
            print "      \"route_exclude_address\": ["
            print "        \"192.168.0.0/16\","
            print "        \"10.0.0.0/8\","
            print "        \"172.16.0.0/12\","
            print "        \"100.64.0.0/10\","
            print "        \"127.0.0.0/8\","
            print "        \"169.254.0.0/16\","
            print "        \"224.0.0.0/4\","
            print "        \"::1/128\","
            print "        \"fc00::/7\","
            print "        \"fe80::/10\","
            print "        \"ff00::/8\","
            print "        \"fd7a:115c:a1e0::/48\""
            print "      ],"
            print "      \"exclude_package\": ["
            print "        \"com.tailscale.ipn\","
            print "        \"com.wireguard.android\","
            print "        \"net.openvpn.openvpn\","
            print "        \"de.blinkt.openvpn\","
            print "        \"com.zerotier.one\","
            print "        \"com.cloudflare.onedotonedotonedotone\","
            print "        \"io.nekohasekai.sfa\","
            print "        \"moe.nb4a\","
            print "        \"com.v2ray.ang\","
            print "        \"com.github.kr328.clash\","
            print "        \"com.github.metacubex.clash.meta\""
            print "      ],"
            print "      \"stack\": \"gvisor\""
            printf "    }%s\n", comma
        }
        function emit_tproxy(comma) {
            print "    {"
            print "      \"type\": \"tproxy\","
            print "      \"tag\": \"tproxy-in\","
            print "      \"listen\": \"::\","
            print "      \"listen_port\": 9898,"
            print "      \"sniff\": true"
            printf "    }%s\n", comma
        }
        function emit_selected(comma) {
            if (mode == "tproxy") {
                emit_tproxy(comma)
            } else {
                emit_tun(comma)
            }
        }
        BEGIN {
            in_inbounds = 0
            buffering = 0
            depth = 0
            emitted = 0
            prev = ""
        }
        function count_delta(line, i, c, delta) {
            delta = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c == "{") delta++
                if (c == "}") delta--
            }
            return delta
        }
        {
            if (!in_inbounds && $0 ~ /^  "inbounds"[[:space:]]*:[[:space:]]*\[/) {
                in_inbounds = 1
                print
                next
            }
            if (in_inbounds && !buffering && $0 ~ /^  ][,]?[[:space:]]*$/) {
                if (!emitted) {
                    emit_selected("")
                    emitted = 1
                }
                print
                in_inbounds = 0
                next
            }
            if (in_inbounds && !buffering && $0 ~ /^    \{[[:space:]]*$/) {
                buffering = 1
                depth = 1
                buffer = $0 "\n"
                is_transparent = 0
                next
            }
            if (buffering) {
                buffer = buffer $0 "\n"
                depth += count_delta($0)
                if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"(tun|tproxy)"/) {
                    is_transparent = 1
                }
                if (depth <= 0) {
                    buffering = 0
                    if (is_transparent) {
                        if (!emitted) {
                            comma = ($0 ~ /,[[:space:]]*$/) ? "," : ""
                            emit_selected(comma)
                            emitted = 1
                        }
                    } else {
                        printf "%s", buffer
                    }
                    buffer = ""
                }
                next
            }
            print
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        unset _mode
        return 1
    fi
    unset _mode
}

magicnet_transparent_apply_unlocked() {
    _transparent_rc=0
    magicnet_mihomo_apply_transparent_mode || _transparent_rc=1
    magicnet_singbox_apply_transparent_mode || _transparent_rc=1
    magicnet_enable_tproxy || true
    return "$_transparent_rc"
}

magicnet_transparent_apply() {
    magicnet_with_config_lock magicnet_transparent_apply_unlocked
}


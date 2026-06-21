magicnet_singbox_apply_transparent_mode() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _mode="$(magicnet_transparent_mode)"
    _ebpf_profile="$(magicnet_ebpf_profile)"
    _dns_strategy="$(magicnet_singbox_dns_strategy_for_mode "$_config" "$_mode")"
    _dns_port="${MAGICNET_EBPF_DNS_PORT:-1053}"
    case "$_dns_port" in
        *[!0-9]*|"")
            unset _mode _ebpf_profile _dns_strategy _dns_port
            return 1
            ;;
    esac
    _jq="${MODDIR}/bin/jq"
    if [ ! -x "$_jq" ]; then
        _jq="$(command -v jq 2>/dev/null || true)"
    fi
    _tmp="${_config}.transparent-mode.new"
    if [ -n "$_jq" ]; then
        if "$_jq" --arg mode "$_mode" --arg ebpf_profile "$_ebpf_profile" --arg dns_strategy "$_dns_strategy" --argjson dns_port "$_dns_port" '
            def tun_in:
              {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "magicnet0",
                "address": [
                  "172.19.0.1/30",
                  "fdfe:dcba:9876::1/126"
                ],
                "auto_route": true,
                "auto_redirect": true,
                "strict_route": true,
                "exclude_uid": [
                  0
                ],
                "route_exclude_address": [
                  "192.168.0.0/16",
                  "10.0.0.0/8",
                  "172.16.0.0/12",
                  "127.0.0.0/8",
                  "169.254.0.0/16",
                  "224.0.0.0/4",
                  "::1/128",
                  "fc00::/7",
                  "fe80::/10",
                  "ff00::/8"
                ],
                "stack": "gvisor"
              };
            def ebpf_dns4_in:
              {
                "type": "direct",
                "tag": "magicnet-ebpf-dns4-in",
                "listen": "127.0.0.1",
                "listen_port": $dns_port
              };
            def ebpf_dns6_in:
              {
                "type": "direct",
                "tag": "magicnet-ebpf-dns6-in",
                "listen": "::1",
                "listen_port": $dns_port
              };
            def without_ebpf_dns_hijack:
              map(
                select(
                  ((
                    (
                      (((.inbound // []) | index("magicnet-ebpf-dns4-in")) != null)
                      or (((.inbound // []) | index("magicnet-ebpf-dns6-in")) != null)
                    )
                    and (((.action // "") == "hijack-dns") or ((.protocol // "") == "dns"))
                  ) | not)
                )
              );
            def ebpf_quic_block:
              {
                "network": "udp",
                "port": 443,
                "outbound": "block"
              };
            def without_ebpf_quic_block:
              map(select((((.network // "") == "udp") and ((.port // "") == 443) and ((.outbound // "") == "block")) | not));
            .inbounds = (
              ((.inbounds // [])
                | map(select((.type // "") as $type | ($type != "tun" and $type != "tproxy" and $type != "redirect")))
                | map(select((.tag // "") as $tag | ($tag != "magicnet-ebpf-dns4-in" and $tag != "magicnet-ebpf-dns6-in"))))
              + (if $mode == "auto" or $mode == "tun" or $mode == "ebpf" then [tun_in] else [] end)
              + (if $mode == "auto" or $mode == "ebpf" then [ebpf_dns4_in, ebpf_dns6_in] else [] end)
            )
            | .route.rules = (
              ((.route.rules // []) | without_ebpf_dns_hijack | without_ebpf_quic_block) as $rules
              | $rules
            )
            | if $dns_strategy != "" then .dns.strategy = $dns_strategy else . end
        ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
            :
        else
            rm -f "$_tmp" 2>/dev/null || true
            unset _mode _ebpf_profile _dns_strategy _dns_port _jq
            return 1
        fi
    elif awk -v mode="$_mode" -v ebpf_profile="$_ebpf_profile" -v dns_port="$_dns_port" '
        function emit_tun(comma) {
            print "    {"
            print "      \"type\": \"tun\","
            print "      \"tag\": \"tun-in\","
            print "      \"interface_name\": \"magicnet0\","
            print "      \"address\": ["
            print "        \"172.19.0.1/30\","
            print "        \"fdfe:dcba:9876::1/126\""
            print "      ],"
            print "      \"auto_route\": true,"
            print "      \"auto_redirect\": true,"
            print "      \"strict_route\": true,"
            print "      \"exclude_uid\": ["
            print "        0"
            print "      ],"
            print "      \"route_exclude_address\": ["
            print "        \"192.168.0.0/16\","
            print "        \"10.0.0.0/8\","
            print "        \"172.16.0.0/12\","
            print "        \"127.0.0.0/8\","
            print "        \"169.254.0.0/16\","
            print "        \"224.0.0.0/4\","
            print "        \"::1/128\","
            print "        \"fc00::/7\","
            print "        \"fe80::/10\","
            print "        \"ff00::/8\""
            print "      ],"
            print "      \"stack\": \"gvisor\""
            printf "    }%s\n", comma
        }
        function emit_dns4(comma) {
            print "    {"
            print "      \"type\": \"direct\","
            print "      \"tag\": \"magicnet-ebpf-dns4-in\","
            print "      \"listen\": \"127.0.0.1\","
            print "      \"listen_port\": " dns_port
            printf "    }%s\n", comma
        }
        function emit_dns6(comma) {
            print "    {"
            print "      \"type\": \"direct\","
            print "      \"tag\": \"magicnet-ebpf-dns6-in\","
            print "      \"listen\": \"::1\","
            print "      \"listen_port\": " dns_port
            printf "    }%s\n", comma
        }
        function emit_selected(comma) {
            if (mode == "ebpf") {
                emit_tun(",")
                emit_dns4(",")
                emit_dns6(comma)
            } else if (mode == "auto") {
                emit_tun(",")
                emit_dns4(",")
                emit_dns6(comma)
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
                if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"(tun|tproxy|redirect)"/) {
                    is_transparent = 1
                }
                if ($0 ~ /"tag"[[:space:]]*:[[:space:]]*"magicnet-ebpf-dns[46]-in"/) {
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
        unset _mode _ebpf_profile _dns_strategy _dns_port _jq
        return 1
    fi
    if [ -n "$_dns_strategy" ] && [ -z "$_jq" ]; then
        if awk -v strategy="$_dns_strategy" '
            {
                if ($0 ~ /"dns"[[:space:]]*:[[:space:]]*\{/) {
                    in_dns = 1
                }
                if (in_dns && $0 ~ /"strategy"[[:space:]]*:/) {
                    sub("\"strategy\"[[:space:]]*:[[:space:]]*\"[^\"]*\"", "\"strategy\": \"" strategy "\"")
                    in_dns = 0
                }
                print
            }
        ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
            :
        else
            rm -f "$_tmp" 2>/dev/null || true
            unset _mode _ebpf_profile _dns_strategy _dns_port _jq
            return 1
        fi
    fi
    if awk -v mode="$_mode" -v ebpf_profile="$_ebpf_profile" '
        function count_delta(line, i, c, delta) {
            delta = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c == "{") delta++
                if (c == "}") delta--
            }
            return delta
        }
        function emit_sniff_inbounds() {
            if (mode == "ebpf") {
                print "          \"mixed-in\","
                print "          \"tun-in\","
                print "          \"magicnet-ebpf-dns4-in\","
                print "          \"magicnet-ebpf-dns6-in\""
            } else if (mode == "auto") {
                print "          \"mixed-in\","
                print "          \"tun-in\","
                print "          \"magicnet-ebpf-dns4-in\","
                print "          \"magicnet-ebpf-dns6-in\""
            } else {
                print "          \"mixed-in\","
                print "          \"tun-in\""
            }
        }
        function print_sniff_rule(buf, n, i, line, lines, in_sniff_inbounds) {
            n = split(buf, lines, "\n")
            in_sniff_inbounds = 0
            for (i = 1; i <= n; i++) {
                line = lines[i]
                if (i == n && line == "") {
                    continue
                }
                if (!in_sniff_inbounds && line ~ /^        "inbound"[[:space:]]*:[[:space:]]*\[/) {
                    in_sniff_inbounds = 1
                    print line
                    continue
                }
                if (in_sniff_inbounds && line ~ /^        ][,]?[[:space:]]*$/) {
                    emit_sniff_inbounds()
                    print line
                    in_sniff_inbounds = 0
                    continue
                }
                if (in_sniff_inbounds) {
                    continue
                }
                print line
            }
        }
        function flush_rule() {
            if (buffer ~ /"action"[[:space:]]*:[[:space:]]*"sniff"/ && buffer ~ /"inbound"[[:space:]]*:[[:space:]]*\[/) {
                print_sniff_rule(buffer)
            } else {
                printf "%s", buffer
            }
            buffer = ""
        }
        BEGIN {
            buffering = 0
            depth = 0
            buffer = ""
        }
        {
            if (!buffering && $0 ~ /^      \{[[:space:]]*$/) {
                buffering = 1
                depth = 1
                buffer = $0 "\n"
                next
            }
            if (buffering) {
                buffer = buffer $0 "\n"
                depth += count_delta($0)
                if (depth <= 0) {
                    buffering = 0
                    flush_rule()
                }
                next
            }
            print
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        unset _mode _ebpf_profile _dns_strategy _dns_port _jq
        return 1
    fi
    import __singbox__
    singbox_prepare_route_config "$_config" || true
    unset _mode _ebpf_profile _dns_strategy _dns_port _jq
}

magicnet_transparent_apply_unlocked() {
    _transparent_rc=0
    magicnet_singbox_apply_transparent_mode || _transparent_rc=1
    if magicnet_enable_ebpf; then
        magicnet_tproxy_udp_cleanup || true
    else
        magicnet_tproxy_udp_cleanup || true
        _transparent_rc=1
    fi
    return "$_transparent_rc"
}

magicnet_transparent_apply() {
    magicnet_with_config_lock magicnet_transparent_apply_unlocked
}

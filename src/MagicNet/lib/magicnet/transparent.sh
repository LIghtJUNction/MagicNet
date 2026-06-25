magicnet_singbox_apply_transparent_mode() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _mode="$(magicnet_transparent_mode)"
    _dns_strategy="$(magicnet_singbox_dns_strategy_for_mode "$_config" "tun")"
    _jq="${MODDIR}/bin/jq"
    if [ ! -x "$_jq" ]; then
        _jq="$(command -v jq 2>/dev/null || true)"
    fi
    _tmp="${_config}.transparent-mode.new"
    if [ -n "$_jq" ]; then
        if "$_jq" --arg dns_strategy "$_dns_strategy" --arg mode "$_mode" '
            def mixed_in:
              {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": 7892,
                "sniff": true
              };
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
            def managed_inbound:
              ((.type // "") as $type | ($type == "tun" or $type == "tproxy" or $type == "redirect"))
              or ((.tag // "") | startswith("magicnet-"));
            def references_managed_inbound:
              ((.inbound // []) | map(select(startswith("magicnet-"))) | length) > 0;
            def normalize_sniff_rule:
              if (.action // "") == "sniff" then
                .inbound = (if $mode == "proxy" or $mode == "external-tun" then ["mixed-in"] else ["mixed-in", "tun-in"] end)
              else
                .
              end;
            .inbounds = (
              ((.inbounds // [])
                | map(select(managed_inbound | not)))
              + [mixed_in]
              + (if $mode == "proxy" or $mode == "external-tun" then [] else [tun_in] end)
            )
            | .route.rules = (
              ((.route.rules // [])
                | map(normalize_sniff_rule)
                | map(select(references_managed_inbound | not))) as $rules
              | $rules
            )
            | if $dns_strategy != "" then .dns.strategy = $dns_strategy else . end
        ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
            :
        else
            rm -f "$_tmp" 2>/dev/null || true
            unset _dns_strategy _jq
            return 1
        fi
    elif [ "$_mode" != "tun" ] && [ "$_mode" != "hybrid" ]; then
        magicnet_warn "jq not found; transparent mode $_mode requires jq to remove managed TUN inbounds"
        rm -f "$_tmp" 2>/dev/null || true
        unset _dns_strategy _jq _mode
        return 1
    elif awk '
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
        function emit_selected(comma) {
            emit_tun(comma)
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
                if ($0 ~ /"tag"[[:space:]]*:[[:space:]]*"magicnet-[^"]+"/) {
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
        unset _dns_strategy _jq
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
            unset _dns_strategy _jq
            return 1
        fi
    fi
    if [ -z "$_jq" ] && awk '
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
            print "          \"mixed-in\","
            print "          \"tun-in\""
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
    elif [ -z "$_jq" ]; then
        rm -f "$_tmp" 2>/dev/null || true
        unset _dns_strategy _jq _mode
        return 1
    fi
    import __singbox__
    singbox_prepare_route_config "$_config" || true
    unset _dns_strategy _jq _mode
}

magicnet_transparent_apply_unlocked() {
    _transparent_rc=0
    magicnet_singbox_apply_transparent_mode || _transparent_rc=1
    return "$_transparent_rc"
}

magicnet_transparent_apply() {
    magicnet_with_config_lock magicnet_transparent_apply_unlocked
}

magicnet_singbox_apply_transparent_mode() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _mode="$(magicnet_transparent_mode)"
    _dns_strategy="$(magicnet_singbox_dns_strategy_for_mode "$_config" "tun")"
    _tun_mtu="$(magicnet_tun_mtu)"
    _udp_timeout="$(magicnet_udp_timeout)"
    _jq="${MODDIR}/bin/jq"
    if [ ! -x "$_jq" ]; then
        _jq="$(command -v jq 2>/dev/null || true)"
    fi
    _tmp="${_config}.transparent-mode.new"
    if [ -n "$_jq" ]; then
        # shellcheck disable=SC2016
        if (umask 077; "$_jq" \
            --arg dns_strategy "$_dns_strategy" \
            --argjson tun_mtu "$_tun_mtu" \
            --arg udp_timeout "$_udp_timeout" '
            def mixed_in:
              {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": 7892
              };
            def dns_in:
              {
                "type": "direct",
                "tag": "magicnet-dns-in",
                "listen": "127.0.0.1",
                "listen_port": 1053
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
                  "100.64.0.0/10",
                  "127.0.0.0/8",
                  "169.254.0.0/16",
                  "224.0.0.0/4",
                  "::1/128",
                  "fc00::/7",
                  "fe80::/10",
                  "ff00::/8",
                  "fd7a:115c:a1e0::/48"
                ],
                "stack": "mixed",
                "mtu": $tun_mtu,
                "udp_timeout": $udp_timeout
              };
            def managed_inbound:
              ((.type // "") as $type | ($type == "tun" or $type == "tproxy" or $type == "redirect"))
              or ((.tag // "") == "mixed-in")
              or ((.tag // "") | startswith("magicnet-"));
            def references_managed_inbound:
              (.inbound // []) as $inbound
              | (if ($inbound | type) == "array" then $inbound else [$inbound] end)
              | map(select(type == "string" and startswith("magicnet-")))
              | length > 0;
            def dns_hijack_rule:
              {"inbound": ["magicnet-dns-in"], "action": "hijack-dns"};
            def ipv6_reject_rule:
              {"ip_version": 6, "action": "reject", "method": "default", "no_drop": true};
            def legacy_ipv6_block_rule:
              {"ip_version": 6, "outbound": "block"};
            def normalized_ipv6_reject_rule:
              {"ip_version": 6, "action": "reject", "no_drop": true};
            def is_managed_ipv6_guard:
              . == legacy_ipv6_block_rule or . == normalized_ipv6_reject_rule or . == ipv6_reject_rule;
            def is_dns_hijack_rule:
              (.action // "") == "hijack-dns";
            def is_icmp_block_rule:
              (.protocol // "") == "icmp" and (.outbound // "") == "block";
            def is_sniff_rule:
              (.action // "") == "sniff";
            def normalize_sniff_rule:
              if (.action // "") == "sniff" then
                .inbound = ["mixed-in", "tun-in"]
              else
                .
              end;
            def sniff_rule:
              {"inbound": ["mixed-in", "tun-in"], "action": "sniff"};
            .inbounds = (
              ((.inbounds // [])
                | map(select(managed_inbound | not)))
              + [mixed_in]
              + [dns_in]
              + [tun_in]
            )
            | .route.rules = (
              ((.route.rules // [])
                | map(select(references_managed_inbound | not))
                | map(select(is_managed_ipv6_guard | not))
                | map(normalize_sniff_rule)) as $rules
              | ([dns_hijack_rule] + (if any($rules[]?; is_sniff_rule) then $rules else [sniff_rule] + $rules end)) as $managed_rules
              | if $dns_strategy == "ipv4_only" then
                  [$managed_rules[] | select(is_sniff_rule)]
                  + [dns_hijack_rule]
                  + [$managed_rules[] | select(is_icmp_block_rule)]
                  + [ipv6_reject_rule]
                  + [$managed_rules[] | select((is_sniff_rule or is_dns_hijack_rule or is_icmp_block_rule or is_managed_ipv6_guard) | not)]
                else
                  $managed_rules
                end
            )
            | if $dns_strategy != "" then .dns.strategy = $dns_strategy else . end
        ' "$_config" >"$_tmp") && chmod 600 "$_tmp" && mv -f "$_tmp" "$_config" && chmod 600 "$_config"; then
            :
        else
            rm -f "$_tmp" 2>/dev/null || true
            unset _dns_strategy _tun_mtu _udp_timeout _jq _mode
            return 1
        fi
    else
        _singbox="$(command -v sing-box 2>/dev/null || true)"
        _stage="${_config}.transparent-mode.stage.$$"
        _next="${_config}.transparent-mode.tmp.$$"
        if [ -z "$_singbox" ]; then
            magicnet_warn "sing-box not found; cannot safely normalize config without jq"
            rm -f "$_tmp" "$_stage" "$_next" 2>/dev/null || true
            unset _dns_strategy _tun_mtu _udp_timeout _jq _mode _singbox _stage _next
            return 1
        fi
        if (umask 077; "$_singbox" format -c "$_config" -D "${_config%/*}" >"$_stage"); then
            :
        else
            magicnet_warn "sing-box format failed; refusing unsafe no-jq config rewrite"
            rm -f "$_tmp" "$_stage" "$_next" 2>/dev/null || true
            unset _dns_strategy _tun_mtu _udp_timeout _jq _mode _singbox _stage _next
            return 1
        fi
        if (umask 077; awk -v dns_strategy="$_dns_strategy" '
            {
                lines[NR] = $0
                if ($0 ~ /^  "dns": \{/) {
                    has_dns = 1
                    dns_open = NR
                }
                if ($0 ~ /^    "strategy": /) has_dns_strategy = 1
                if ($0 ~ /^  "inbounds": \[/) has_inbounds = 1
                if ($0 ~ /^  "route": \{/) {
                    has_route = 1
                    route_open = NR
                }
                if ($0 ~ /^    "rules": \[/) has_rules = 1
                if ($0 == "}") root_close = NR
            }
            END {
                empty_root = (lines[1] == "{}")
                for (i = 2; i <= NR; i++) {
                    if (lines[i] != "") empty_root = 0
                }
                if (empty_root) {
                    print "{"
                    print "  \"dns\": {"
                    print "    \"strategy\": \"" dns_strategy "\""
                    print "  },"
                    print "  \"inbounds\": [],"
                    print "  \"route\": {"
                    print "    \"rules\": []"
                    print "  }"
                    print "}"
                    print ""
                    exit
                }
                dns_at = root_close
                inbounds_at = root_close
                route_at = root_close
                for (i = 1; i <= NR; i++) {
                    if (!has_dns && lines[i] ~ /^  "(ntp|certificate|endpoints|inbounds|outbounds|route|services|experimental)":/) {
                        dns_at = i
                        break
                    }
                }
                for (i = 1; i <= NR; i++) {
                    if (!has_inbounds && lines[i] ~ /^  "(outbounds|route|services|experimental)":/) {
                        inbounds_at = i
                        break
                    }
                }
                for (i = 1; i <= NR; i++) {
                    if (!has_route && lines[i] ~ /^  "(services|experimental)":/) {
                        route_at = i
                        break
                    }
                }
                if ((!has_dns && dns_at == root_close) ||
                    (!has_inbounds && inbounds_at == root_close) ||
                    (!has_route && route_at == root_close)) {
                    previous = root_close - 1
                    while (previous > 0 && lines[previous] == "") previous--
                    if (lines[previous] !~ /,[[:space:]]*$/) lines[previous] = lines[previous] ","
                }
                for (i = 1; i <= NR; i++) {
                    if (!has_dns && i == dns_at) {
                        print "  \"dns\": {"
                        print "    \"strategy\": \"" dns_strategy "\""
                        print "  },"
                    }
                    if (!has_inbounds && i == inbounds_at) {
                        print "  \"inbounds\": [],"
                    }
                    if (!has_route && i == route_at) {
                        print "  \"route\": {"
                        print "    \"rules\": []"
                        print (route_at < root_close ? "  }," : "  }")
                    }
                    print lines[i]
                    if (has_dns && !has_dns_strategy && i == dns_open) {
                        print "    \"strategy\": \"" dns_strategy "\","
                    }
                    if (has_route && !has_rules && i == route_open) {
                        print "    \"rules\": [],"
                    }
                }
            }
        ' "$_stage" >"$_next") && mv -f "$_next" "$_stage"; then
            :
        else
            rm -f "$_tmp" "$_stage" "$_next" 2>/dev/null || true
            unset _dns_strategy _tun_mtu _udp_timeout _jq _mode _singbox _stage _next
            return 1
        fi
        if awk -v tun_mtu="$_tun_mtu" -v udp_timeout="$_udp_timeout" '
        function emit_mixed(comma) {
            print "    {"
            print "      \"type\": \"mixed\","
            print "      \"tag\": \"mixed-in\","
            print "      \"listen\": \"127.0.0.1\","
            print "      \"listen_port\": 7892"
            printf "    }%s\n", comma
        }
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
            print "      \"stack\": \"mixed\","
            print "      \"mtu\": " tun_mtu ","
            print "      \"udp_timeout\": \"" udp_timeout "\""
            printf "    }%s\n", comma
        }
        function emit_dns(comma) {
            print "    {"
            print "      \"type\": \"direct\","
            print "      \"tag\": \"magicnet-dns-in\","
            print "      \"listen\": \"127.0.0.1\","
            print "      \"listen_port\": 1053"
            printf "    }%s\n", comma
        }
        function emit_selected(comma) {
            emit_mixed(",")
            emit_dns(",")
            emit_tun(comma)
        }
        function count_delta(line, i, c, delta, in_string, escaped) {
            delta = 0
            in_string = 0
            escaped = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (in_string) {
                    if (escaped) escaped = 0
                    else if (c == "\\") escaped = 1
                    else if (c == "\"") in_string = 0
                    continue
                }
                if (c == "\"") in_string = 1
                else if (c == "{") delta++
                else if (c == "}") delta--
            }
            return delta
        }
        function strip_trailing_comma(buf, n, i, lines, last) {
            n = split(buf, lines, "\n")
            last = n
            while (last > 0 && lines[last] == "") last--
            sub(/,[[:space:]]*$/, "", lines[last])
            buf = ""
            for (i = 1; i <= last; i++) buf = buf lines[i] "\n"
            return buf
        }
        function emit_object(buf, comma, n, i, lines, last, line) {
            n = split(buf, lines, "\n")
            last = n
            while (last > 0 && lines[last] == "") last--
            for (i = 1; i <= last; i++) {
                line = lines[i]
                if (i == last && comma) sub(/[[:space:]]*$/, ",", line)
                print line
            }
        }
        function finish_inbound() {
            if (!is_transparent) {
                kept_inbounds[++kept_count] = strip_trailing_comma(buffer)
            }
            buffer = ""
        }
        function emit_inbounds(i) {
            for (i = 1; i <= kept_count; i++) emit_object(kept_inbounds[i], 1)
            emit_selected("")
        }
        BEGIN {
            in_inbounds = 0
            buffering = 0
            depth = 0
            buffer = ""
        }
        NR == FNR {
            if ($0 ~ /^  "inbounds": \[/) has_inbounds = 1
            next
        }
        {
            if (!has_inbounds && !emitted_inbounds &&
                $0 ~ /^  "(outbounds|route|services|experimental)":/) {
                print "  \"inbounds\": ["
                emit_inbounds()
                print "  ],"
                emitted_inbounds = 1
            }
            if (!in_inbounds && $0 ~ /^  "inbounds"[[:space:]]*:[[:space:]]*\[[[:space:]]*\][,]?[[:space:]]*$/) {
                comma = ($0 ~ /,[[:space:]]*$/) ? "," : ""
                print "  \"inbounds\": ["
                emit_inbounds()
                print "  ]" comma
                next
            }
            if (!in_inbounds && $0 ~ /^  "inbounds"[[:space:]]*:[[:space:]]*\[/) {
                in_inbounds = 1
                print
                next
            }
            if (in_inbounds && !buffering && $0 ~ /^  ][,]?[[:space:]]*$/) {
                emit_inbounds()
                print
                in_inbounds = 0
                next
            }
            if (in_inbounds && !buffering && $0 ~ /^    \{/) {
                buffering = 1
                depth = count_delta($0)
                buffer = $0 "\n"
                is_transparent = 0
                if (depth <= 0) {
                    buffering = 0
                    finish_inbound()
                }
                next
            }
            if (buffering) {
                buffer = buffer $0 "\n"
                depth += count_delta($0)
                if ($0 ~ /^      "type": "(tun|tproxy|redirect)",?[[:space:]]*$/) {
                    is_transparent = 1
                }
                if ($0 ~ /^      "tag": "mixed-in",?[[:space:]]*$/) {
                    is_transparent = 1
                }
                if ($0 ~ /^      "tag": "magicnet-[^"]+",?[[:space:]]*$/) {
                    is_transparent = 1
                }
                if (depth <= 0) {
                    buffering = 0
                    finish_inbound()
                }
                next
            }
            print
        }
        ' "$_stage" "$_stage" >"$_next" && mv -f "$_next" "$_stage"; then
            :
        else
            rm -f "$_tmp" "$_stage" "$_next" 2>/dev/null || true
            unset _dns_strategy _tun_mtu _udp_timeout _jq _mode _singbox _stage _next
            return 1
        fi
    fi
    if [ -n "$_dns_strategy" ] && [ -z "$_jq" ]; then
        if awk -v strategy="$_dns_strategy" '
            {
                if ($0 ~ /^  "dns": \{[[:space:]]*$/) {
                    in_dns = 1
                }
                if (in_dns && $0 ~ /^    "strategy": /) {
                    sub("\"strategy\"[[:space:]]*:[[:space:]]*\"[^\"]*\"", "\"strategy\": \"" strategy "\"")
                    in_dns = 0
                }
                print
            }
        ' "$_stage" >"$_next" && mv -f "$_next" "$_stage"; then
            :
        else
            rm -f "$_tmp" "$_stage" "$_next" 2>/dev/null || true
            unset _dns_strategy _tun_mtu _udp_timeout _jq _mode _singbox _stage _next
            return 1
        fi
    fi
    if [ -z "$_jq" ] && awk -v dns_strategy="$_dns_strategy" '
        function count_delta(line, i, c, delta, in_string, escaped) {
            delta = 0
            in_string = 0
            escaped = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (in_string) {
                    if (escaped) escaped = 0
                    else if (c == "\\") escaped = 1
                    else if (c == "\"") in_string = 0
                    continue
                }
                if (c == "\"") in_string = 1
                else if (c == "{") delta++
                else if (c == "}") delta--
            }
            return delta
        }
        function reset_rule_fields() {
            rule_field_count = 0
            rule_ip_version_6 = 0
            rule_outbound_block = 0
            rule_action_reject = 0
            rule_method_default = 0
            rule_no_drop_true = 0
            rule_action_sniff = 0
            rule_action_hijack = 0
            rule_protocol_icmp = 0
            rule_has_inbound = 0
            rule_inbound_array = 0
            rule_references_managed_inbound = 0
        }
        function capture_rule_field(line) {
            if (rule_inbound_array) {
                if (line ~ /^        ],?[[:space:]]*$/) {
                    rule_inbound_array = 0
                } else if (line ~ /^          "magicnet-[^"]+",?[[:space:]]*$/) {
                    rule_references_managed_inbound = 1
                }
                return
            }
            if (line !~ /^        "[^"]+":/) return
            rule_field_count++
            if (line ~ /^        "ip_version": 6,?[[:space:]]*$/) rule_ip_version_6++
            else if (line ~ /^        "outbound": "block",?[[:space:]]*$/) rule_outbound_block++
            else if (line ~ /^        "action": "reject",?[[:space:]]*$/) rule_action_reject++
            else if (line ~ /^        "method": "default",?[[:space:]]*$/) rule_method_default++
            else if (line ~ /^        "no_drop": true,?[[:space:]]*$/) rule_no_drop_true++
            else if (line ~ /^        "action": "sniff",?[[:space:]]*$/) rule_action_sniff++
            else if (line ~ /^        "action": "hijack-dns",?[[:space:]]*$/) rule_action_hijack++
            else if (line ~ /^        "protocol": "icmp",?[[:space:]]*$/) rule_protocol_icmp++
            if (line ~ /^        "inbound":/) {
                rule_has_inbound++
                if (line ~ /^        "inbound": "magicnet-[^"]+",?[[:space:]]*$/) {
                    rule_references_managed_inbound = 1
                } else if (line ~ /^        "inbound": \[[[:space:]]*$/) {
                    rule_inbound_array = 1
                }
            }
        }
        function normalize_sniff_rule(buf, n, i, j, lines, line, comma, out) {
            n = split(buf, lines, "\n")
            for (i = 1; i <= n; i++) {
                line = lines[i]
                if (!rule_has_inbound && line ~ /^      \{[[:space:]]*$/) {
                    out = out line "\n"
                    out = out "        \"inbound\": [\n"
                    out = out "          \"mixed-in\",\n"
                    out = out "          \"tun-in\"\n"
                    out = out "        ],\n"
                } else if (line ~ /^        "inbound":/) {
                    comma = (line ~ /,[[:space:]]*$/) ? "," : ""
                    if (line ~ /^        "inbound": \[[[:space:]]*$/) {
                        for (j = i + 1; j <= n; j++) {
                            if (lines[j] ~ /^        ],?[[:space:]]*$/) {
                                comma = (lines[j] ~ /,[[:space:]]*$/) ? "," : ""
                                i = j
                                break
                            }
                        }
                    }
                    out = out "        \"inbound\": [\n"
                    out = out "          \"mixed-in\",\n"
                    out = out "          \"tun-in\"\n"
                    out = out "        ]" comma "\n"
                } else if (i < n || line != "") {
                    out = out line "\n"
                }
            }
            return out
        }
        function strip_trailing_comma(buf, n, i, lines, last) {
            n = split(buf, lines, "\n")
            last = n
            while (last > 0 && lines[last] == "") last--
            sub(/,[[:space:]]*$/, "", lines[last])
            buf = ""
            for (i = 1; i <= last; i++) buf = buf lines[i] "\n"
            return buf
        }
        function is_managed_ipv6_guard() {
            return (rule_field_count == 2 && rule_ip_version_6 == 1 && rule_outbound_block == 1) ||
                (rule_field_count == 3 && rule_ip_version_6 == 1 && rule_action_reject == 1 &&
                 rule_no_drop_true == 1) ||
                (rule_field_count == 4 && rule_ip_version_6 == 1 && rule_action_reject == 1 &&
                 rule_method_default == 1 && rule_no_drop_true == 1)
        }
        function add_rule(buf, normalized) {
            normalized = strip_trailing_comma(buf)
            if (rule_references_managed_inbound == 1) return
            if (rule_action_sniff == 1) {
                normalized = normalize_sniff_rule(normalized)
            }
            if (is_managed_ipv6_guard()) return
            if (rule_action_sniff == 1) {
                sniff_rules[++sniff_count] = normalized
            } else if (rule_action_hijack == 1) {
                return
            } else if (rule_protocol_icmp == 1 && rule_outbound_block == 1) {
                priority_rules[++priority_count] = normalized
            } else {
                ordinary_rules[++ordinary_count] = normalized
            }
        }
        function emit_rule(buf, comma, n, i, lines, last, line) {
            n = split(buf, lines, "\n")
            last = n
            while (last > 0 && lines[last] == "") last--
            for (i = 1; i <= last; i++) {
                line = lines[i]
                if (i == last && comma) sub(/[[:space:]]*$/, ",", line)
                print line
            }
        }
        function emit_managed_ipv6(comma) {
            print "      {"
            print "        \"ip_version\": 6,"
            print "        \"action\": \"reject\","
            print "        \"method\": \"default\","
            print "        \"no_drop\": true"
            if (comma) print "      },"
            else print "      }"
        }
        function emit_managed_sniff(comma) {
            print "      {"
            print "        \"inbound\": ["
            print "          \"mixed-in\","
            print "          \"tun-in\""
            print "        ],"
            print "        \"action\": \"sniff\""
            if (comma) print "      },"
            else print "      }"
        }
        function emit_managed_dns_hijack(comma) {
            print "      {"
            print "        \"inbound\": ["
            print "          \"magicnet-dns-in\""
            print "        ],"
            print "        \"action\": \"hijack-dns\""
            if (comma) print "      },"
            else print "      }"
        }
        function flush_rules(total, emitted, i, emitted_sniff) {
            total = (sniff_count > 0 ? sniff_count : 1) + 1 + priority_count + ordinary_count
            if (dns_strategy == "ipv4_only") total++
            emitted = 0
            if (sniff_count > 0) {
                for (i = 1; i <= sniff_count; i++) emit_rule(sniff_rules[i], ++emitted < total)
            } else {
                emit_managed_sniff(++emitted < total)
            }
            emit_managed_dns_hijack(++emitted < total)
            for (i = 1; i <= priority_count; i++) emit_rule(priority_rules[i], ++emitted < total)
            if (dns_strategy == "ipv4_only") emit_managed_ipv6(++emitted < total)
            for (i = 1; i <= ordinary_count; i++) emit_rule(ordinary_rules[i], ++emitted < total)
        }
        function emit_managed_route(comma) {
            print "  \"route\": {"
            print "    \"rules\": ["
            flush_rules()
            print "    ]"
            if (comma) print "  },"
            else print "  }"
        }
        BEGIN {
            in_route = 0
            route_depth = 0
            in_rules = 0
            buffering = 0
            depth = 0
            buffer = ""
        }
        NR == FNR {
            if ($0 ~ /^  "route": \{/) has_route = 1
            if ($0 ~ /^    "rules": \[/) has_route_rules = 1
            next
        }
        {
            if (!has_route && !in_outbounds && $0 ~ /^  "outbounds": \[/) {
                in_outbounds = 1
                print
                next
            }
            if (!in_route && $0 ~ /^  "route"[[:space:]]*:[[:space:]]*\{/) {
                in_route = 1
                route_depth = count_delta($0)
                print
                if (!has_route_rules) {
                    print "    \"rules\": ["
                    flush_rules()
                    print "    ],"
                }
                next
            }
            if (in_route && route_depth == 1 && !in_rules && $0 ~ /^    "rules"[[:space:]]*:[[:space:]]*\[[[:space:]]*\][,]?[[:space:]]*$/) {
                comma = ($0 ~ /,[[:space:]]*$/) ? "," : ""
                print "    \"rules\": ["
                flush_rules()
                print "    ]" comma
                next
            }
            if (in_route && route_depth == 1 && !in_rules && $0 ~ /^    "rules"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
                in_rules = 1
                print
                next
            }
            if (in_rules && !buffering && $0 ~ /^    ][,]?[[:space:]]*$/) {
                flush_rules()
                print
                in_rules = 0
                next
            }
            if (in_rules && !buffering && $0 ~ /^      \{/) {
                buffering = 1
                depth = count_delta($0)
                buffer = $0 "\n"
                reset_rule_fields()
                if (depth <= 0) {
                    buffering = 0
                    add_rule(buffer)
                    buffer = ""
                }
                next
            }
            if (buffering) {
                buffer = buffer $0 "\n"
                depth += count_delta($0)
                capture_rule_field($0)
                if (depth <= 0) {
                    buffering = 0
                    add_rule(buffer)
                    buffer = ""
                }
                next
            }
            if (in_route) {
                route_depth += count_delta($0)
                print
                if (route_depth <= 0) {
                    in_route = 0
                    route_depth = 0
                }
                next
            }
            if (!has_route && in_outbounds && !emitted_route && $0 ~ /^  ][,]?[[:space:]]*$/) {
                route_comma = ($0 ~ /,[[:space:]]*$/)
                if (!route_comma) sub(/[[:space:]]*$/, ",")
                print
                emit_managed_route(route_comma)
                emitted_route = 1
                in_outbounds = 0
                next
            }
            print
        }
    ' "$_stage" "$_stage" >"$_next" && mv -f "$_next" "$_stage"; then
        :
    elif [ -z "$_jq" ]; then
        rm -f "$_tmp" "$_stage" "$_next" 2>/dev/null || true
        unset _dns_strategy _tun_mtu _udp_timeout _jq _mode _singbox _stage _next
        return 1
    fi
    if [ -z "$_jq" ]; then
        if chmod 600 "$_stage" && mv -f "$_stage" "$_config" && chmod 600 "$_config"; then
            rm -f "$_next" 2>/dev/null || true
        else
            rm -f "$_stage" "$_next" 2>/dev/null || true
            unset _dns_strategy _tun_mtu _udp_timeout _jq _mode _singbox _stage _next
            return 1
        fi
    fi
    import __singbox__
    singbox_prepare_route_config "$_config" || true
    unset _dns_strategy _tun_mtu _udp_timeout _jq _mode _singbox _stage _next
}

magicnet_transparent_apply_unlocked() {
    _transparent_rc=0
    magicnet_singbox_apply_transparent_mode || _transparent_rc=1
    return "$_transparent_rc"
}

magicnet_transparent_apply() {
    magicnet_with_config_lock magicnet_transparent_apply_unlocked
}

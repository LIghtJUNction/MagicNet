magicnet_capture_apply_singbox() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    magicnet_capture_conf
    _tmp="${_config}.capture.new"
    _route_rules_file="${MODDIR}/.tmp/magicnet-capture-singbox.rules"
    mkdir -p "${_route_rules_file%/*}"
    magicnet_capture_singbox_rule_block "magicnet-capture" >"$_route_rules_file" || true
    if awk \
        -v enabled="$MAGICNET_CAPTURE_ENABLED" \
        -v host="$MAGICNET_CAPTURE_HOST" \
        -v port="$MAGICNET_CAPTURE_PORT" \
        -v route_rules_file="$_route_rules_file" '
        BEGIN {
            in_outbounds = 0
            in_route = 0
            in_route_rules = 0
            buffering = 0
            mode = ""
            buffer = ""
            is_direct = 0
            is_capture = 0
            inserted_outbound = 0
            inserted_rules = 0
        }
        function reset_buffer() {
            buffer = ""
            is_direct = 0
            is_capture = 0
            buffering = 0
            mode = ""
        }
        function flush_outbound_object() {
            if (!is_capture) {
                if (enabled == "1" && !inserted_outbound && is_direct) {
                    print "    {"
                    print "      \"type\": \"http\","
                    print "      \"tag\": \"magicnet-capture\","
                    print "      \"server\": \"" host "\","
                    print "      \"server_port\": " port
                    print "    },"
                    inserted_outbound = 1
                }
                printf "%s", buffer
            }
            reset_buffer()
        }
        function flush_route_rule_object() {
            if (!is_capture) {
                printf "%s", buffer
                if (enabled == "1" && !inserted_rules && buffer ~ /"action"[[:space:]]*:[[:space:]]*"sniff"/) {
                    while ((getline rule_line < route_rules_file) > 0) {
                        print rule_line
                    }
                    close(route_rules_file)
                    inserted_rules = 1
                }
            }
            reset_buffer()
        }
        {
            if (buffering && mode == "outbound") {
                buffer = buffer $0 "\n"
                if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"direct"/) {
                    is_direct = 1
                }
                if ($0 ~ /"tag"[[:space:]]*:[[:space:]]*"magicnet-capture"/) {
                    is_capture = 1
                }
                if ($0 ~ /^    }[,]?[[:space:]]*$/) {
                    flush_outbound_object()
                }
                next
            }
            if (buffering && mode == "route_rule") {
                buffer = buffer $0 "\n"
                if ($0 ~ /"outbound"[[:space:]]*:[[:space:]]*"magicnet-capture"/) {
                    is_capture = 1
                }
                if ($0 ~ /^      }[,]?[[:space:]]*$/) {
                    flush_route_rule_object()
                }
                next
            }
            if ($0 ~ /^  "outbounds"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
                in_outbounds = 1
                print
                next
            }
            if (in_outbounds && $0 ~ /^  ][,]?[[:space:]]*$/) {
                in_outbounds = 0
                print
                next
            }
            if (in_outbounds && $0 ~ /^    \{[[:space:]]*$/) {
                buffering = 1
                mode = "outbound"
                buffer = $0 "\n"
                is_direct = 0
                is_capture = 0
                next
            }
            if ($0 ~ /^  "route"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/) {
                in_route = 1
                print
                next
            }
            if (in_route && $0 ~ /^  }[,]?[[:space:]]*$/) {
                in_route = 0
                print
                next
            }
            if (in_route && $0 ~ /^    "rules"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
                in_route_rules = 1
                print
                next
            }
            if (in_route_rules && $0 ~ /^    ][,]?[[:space:]]*$/) {
                in_route_rules = 0
                print
                next
            }
            if (in_route_rules && $0 ~ /^      \{[[:space:]]*$/) {
                buffering = 1
                mode = "route_rule"
                buffer = $0 "\n"
                is_capture = 0
                next
            }
            print
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
}

magicnet_capture_apply() {
    magicnet_capture_apply_mihomo
    magicnet_capture_apply_singbox
}


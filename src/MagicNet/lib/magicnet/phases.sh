set_i18n "MAGICNET_MCP_CLI_NOT_EXECUTABLE" \
    "zh" "MCP 已启用，但 cli 入口不可执行" \
    "en" "MCP is enabled, but the cli entry is not executable"
set_i18n "MAGICNET_MCP_START_FAILED" \
    "zh" "MCP 服务器启动失败；请查看 \$_1" \
    "en" "MCP server failed to start; see \$_1"

kamfw_phase_boot_completed() {
    if magicnet_module_disabled; then
        magicnet_supervisors_stop >/dev/null 2>&1 || true
        magicnet_disable_dns_capture >/dev/null 2>&1 || true
        magicnet_disable_dns_leak_guard >/dev/null 2>&1 || true
        return 0
    fi
    wait_boot
    sleep 3
    magicnet_mcp_start_if_enabled || true
    magicnet_start_kernel || true
    "${MODDIR}/cli" supervisor start all >/dev/null 2>&1 &
    return 0
}

kamfw_phase_service() {
    kamfw_phase_boot_completed "$@"
}

kamfw_phase_action() {
    magicnet_action
}

magicnet_mcp_start_if_enabled() {
    _mmsie_conf="${MODDIR}/.config/magicnet/mcp.conf"
    [ -f "$_mmsie_conf" ] || {
        unset _mmsie_conf
        return 0
    }

    # mcp.conf is written by the CLI, but it can also be a legacy or manually
    # edited file. Never source it. Parse the complete canonical schema as
    # data, so a valid enabled flag cannot make an injected extra line run.
    # The secret line is optional only for older configs; the Rust CLI creates
    # one before it starts the server.
    _mmsie_enabled=
    if _mmsie_enabled="$(
        awk '
            function valid_ipv4(value,    parts, count, part_index, part) {
                if (value ~ /^\./ || value ~ /\.$/ || value ~ /\.\./) return 0
                count = split(value, parts, /\./)
                if (count != 4) return 0
                for (part_index = 1; part_index <= count; part_index++) {
                    part = parts[part_index]
                    if (part !~ /^[0-9]+$/ || length(part) > 3) return 0
                    if (length(part) > 1 && substr(part, 1, 1) == "0") return 0
                    if ((part + 0) > 255) return 0
                }
                return 1
            }

            function valid_ipv6(value,    compressed_at, compressed, left, right, values, parts, count, part_index, part, units, ipv4_seen, after) {
                if (value !~ /^[0-9A-Fa-f:.]+$/ || index(value, ":") == 0) return 0
                compressed_at = index(value, "::")
                compressed = compressed_at > 0
                if (compressed) {
                    after = substr(value, compressed_at + 2)
                    if (index(after, "::") > 0) return 0
                    left = substr(value, 1, compressed_at - 1)
                    right = after
                    if (left != "" && (substr(left, 1, 1) == ":" || substr(left, length(left), 1) == ":")) return 0
                    if (right != "" && (substr(right, 1, 1) == ":" || substr(right, length(right), 1) == ":")) return 0
                    if (left != "" && right != "") values = left ":" right
                    else values = left right
                } else {
                    if (substr(value, 1, 1) == ":" || substr(value, length(value), 1) == ":") return 0
                    values = value
                }
                units = 0
                ipv4_seen = 0
                if (values != "") {
                    count = split(values, parts, ":")
                    for (part_index = 1; part_index <= count; part_index++) {
                        part = parts[part_index]
                        if (part == "") return 0
                        if (index(part, ".") > 0) {
                            if (part_index != count || !valid_ipv4(part)) return 0
                            ipv4_seen = 1
                            units += 2
                        } else {
                            if (part !~ /^[0-9A-Fa-f]+$/ || length(part) > 4) return 0
                            units++
                        }
                    }
                }
                if (ipv4_seen && substr(value, length(value), 1) == ":") return 0
                return compressed ? units < 8 : units == 8
            }

            function valid_bind(value) {
                return valid_ipv4(value) || valid_ipv6(value)
            }

            function valid_port(value) {
                if (value !~ /^[0-9]+$/ || length(value) > 5) return 0
                if (length(value) > 1 && substr(value, 1, 1) == "0") return 0
                return (value + 0) >= 1 && (value + 0) <= 65535
            }

            function valid_secret(value) {
                return length(value) <= 256 && value ~ /^[A-Za-z0-9._:\/?=%+@,-]*$/
            }

            BEGIN { valid = 1 }

            /^MAGICNET_MCP_ENABLED=/ {
                if (++enabled_seen != 1 || $0 !~ /^MAGICNET_MCP_ENABLED=[01]$/) valid = 0
                else enabled = substr($0, length("MAGICNET_MCP_ENABLED=") + 1)
                next
            }
            /^MAGICNET_MCP_BIND=/ {
                if (++bind_seen != 1 || !valid_bind(substr($0, length("MAGICNET_MCP_BIND=") + 1))) valid = 0
                next
            }
            /^MAGICNET_MCP_PORT=/ {
                if (++port_seen != 1 || !valid_port(substr($0, length("MAGICNET_MCP_PORT=") + 1))) valid = 0
                next
            }
            /^MAGICNET_MCP_SECRET=/ {
                if (++secret_seen != 1 || !valid_secret(substr($0, length("MAGICNET_MCP_SECRET=") + 1))) valid = 0
                next
            }
            { valid = 0 }

            END {
                if (valid && enabled_seen == 1 && bind_seen == 1 && port_seen == 1 && secret_seen <= 1) print enabled
            }
        ' "$_mmsie_conf" 2>/dev/null
    )"; then
        :
    else
        _mmsie_enabled=
    fi
    if [ "$_mmsie_enabled" != "1" ]; then
        unset _mmsie_conf _mmsie_enabled
        return 0
    fi
    if [ ! -x "${MODDIR}/cli" ]; then
        magicnet_warn "$(i18n "MAGICNET_MCP_CLI_NOT_EXECUTABLE")"
        unset _mmsie_conf _mmsie_enabled
        return 1
    fi
    "${MODDIR}/cli" mcp start >/dev/null 2>&1 || {
        magicnet_warn "$(i18n "MAGICNET_MCP_START_FAILED" | t "${MODDIR}/.log/mcp-server.log")"
        unset _mmsie_conf _mmsie_enabled
        return 1
    }
    unset _mmsie_conf _mmsie_enabled
}

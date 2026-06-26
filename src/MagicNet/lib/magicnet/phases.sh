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
    wait_boot_if_magisk
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
    MAGICNET_MCP_ENABLED=0
    # shellcheck disable=SC1090
    . "$_mmsie_conf"
    if [ "${MAGICNET_MCP_ENABLED:-0}" != "1" ]; then
        unset _mmsie_conf
        return 0
    fi
    if [ ! -x "${MODDIR}/cli" ]; then
        magicnet_warn "$(i18n "MAGICNET_MCP_CLI_NOT_EXECUTABLE")"
        unset _mmsie_conf
        return 1
    fi
    "${MODDIR}/cli" mcp start >/dev/null 2>&1 || {
        magicnet_warn "$(i18n "MAGICNET_MCP_START_FAILED" | t "${MODDIR}/.log/mcp-server.log")"
        unset _mmsie_conf
        return 1
    }
    unset _mmsie_conf
}

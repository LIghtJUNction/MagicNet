set_i18n "MAGICNET_MCP_CLI_NOT_EXECUTABLE" \
    "zh" "MCP 已启用，但 cli 入口不可执行" \
    "en" "MCP is enabled, but the cli entry is not executable" \
    "ru" "MCP включён, но файл cli недоступен для выполнения"
set_i18n "MAGICNET_MCP_START_FAILED" \
    "zh" "MCP 服务器启动失败；请查看 \$_1" \
    "en" "MCP server failed to start; see \$_1" \
    "ru" "Не удалось запустить сервер MCP; см. \$_1"

kamfw_phase_boot_completed() {
    magicnet_detach_pid_from_app_cgroup "$$" ||
        magicnet_warn "Failed to detach the service launcher from the caller cgroup."
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
    _mcp_cli="${MODDIR}/cli"
    if [ ! -x "$_mcp_cli" ]; then
        _mcp_enabled="$(magicnet_conf_value \
            "${MODDIR}/.config/magicnet/mcp.conf" \
            MAGICNET_MCP_ENABLED 2>/dev/null || true)"
        if [ "$_mcp_enabled" = "1" ]; then
            magicnet_warn "$(i18n "MAGICNET_MCP_CLI_NOT_EXECUTABLE")"
            unset _mcp_cli _mcp_enabled
            return 1
        fi
        unset _mcp_cli _mcp_enabled
        return 0
    fi
    if ! "$_mcp_cli" mcp start-if-enabled >/dev/null 2>&1; then
        magicnet_warn "$(i18n "MAGICNET_MCP_START_FAILED" | t "${MODDIR}/.log/mcp-server.log")"
        unset _mcp_cli
        return 1
    fi
    unset _mcp_cli
}

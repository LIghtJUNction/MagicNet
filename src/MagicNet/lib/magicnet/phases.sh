set_i18n "MAGICNET_MCP_CLI_NOT_EXECUTABLE" \
    "zh" "MCP 已启用，但 cli 入口不可执行" \
    "en" "MCP is enabled, but the cli entry is not executable"
set_i18n "MAGICNET_MCP_START_FAILED" \
    "zh" "MCP 服务器启动失败；请查看 \$_1" \
    "en" "MCP server failed to start; see \$_1"

magicnet_disabled_runtime_cleanup() {
    [ ! -x "${MODDIR}/cli" ] || "${MODDIR}/cli" mcp stop >/dev/null 2>&1 || true
    magicnet_supervisors_stop >/dev/null 2>&1 || true
    magicnet_disable_dns_capture >/dev/null 2>&1 || true
    magicnet_disable_dns_leak_guard >/dev/null 2>&1 || true
}

kamfw_phase_boot_completed() {
    magicnet_detach_pid_from_app_cgroup "$$" ||
        magicnet_warn "Failed to detach the service launcher from the caller cgroup."
    if magicnet_module_disabled; then
        magicnet_disabled_runtime_cleanup
        return 0
    fi
    wait_boot
    sleep 3
    # The module can be disabled while Android is still booting. Re-check at
    # every daemon boundary so a late disable cannot start MCP, sing-box, or
    # maintenance supervisors after the user turned MagicNet off.
    if magicnet_module_disabled; then
        magicnet_disabled_runtime_cleanup
        return 0
    fi
    if [ -x "${MODDIR}/cli" ]; then
        "${MODDIR}/cli" service start >/dev/null 2>&1 ||
            magicnet_warn "MagicNet service failed to start during boot completion."
    else
        magicnet_start_kernel || true
        magicnet_supervisors_start_detached || true
    fi
    if magicnet_module_disabled; then
        magicnet_disabled_runtime_cleanup
        return 0
    fi
    magicnet_mcp_start_if_enabled || true
    if magicnet_module_disabled; then
        magicnet_disabled_runtime_cleanup
        return 0
    fi
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

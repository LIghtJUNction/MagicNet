magicnet_apply_runtime_config_unlocked() {
    if magicnet_module_disabled; then
        magicnet_supervisors_stop >/dev/null 2>&1 || true
        magicnet_ebpf_cleanup >/dev/null 2>&1 || true
        magicnet_disable_dns_leak_guard >/dev/null 2>&1 || true
        return 0
    fi
    _runtime_rc=0
    magicnet_ipset_lkm_prepare || true
    magicnet_singbox_apply_zashboard
    magicnet_transparent_apply_unlocked || _runtime_rc=1
    magicnet_app_policy_apply_unlocked || _runtime_rc=1
    magicnet_route_apply_unlocked || _runtime_rc=1
    magicnet_block_apply_unlocked || _runtime_rc=1
    magicnet_enable_dns_leak_guard || true
    return "$_runtime_rc"
}

magicnet_apply_runtime_config() {
    magicnet_with_config_lock magicnet_apply_runtime_config_unlocked
}

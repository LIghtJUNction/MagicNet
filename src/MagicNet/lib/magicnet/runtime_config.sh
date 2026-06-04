magicnet_apply_runtime_config_unlocked() {
    _runtime_rc=0
    magicnet_ipset_lkm_prepare || true
    magicnet_singbox_apply_zashboard
    magicnet_transparent_apply_unlocked || _runtime_rc=1
    magicnet_app_policy_apply_unlocked || _runtime_rc=1
    magicnet_route_apply_unlocked || _runtime_rc=1
    magicnet_block_apply_unlocked || _runtime_rc=1
    magicnet_capture_apply || _runtime_rc=1
    magicnet_enable_hotspot_forward || true
    magicnet_enable_vpn_coexist || true
    return "$_runtime_rc"
}

magicnet_apply_runtime_config() {
    magicnet_with_config_lock magicnet_apply_runtime_config_unlocked
}

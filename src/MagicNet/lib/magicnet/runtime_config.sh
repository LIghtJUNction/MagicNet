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

magicnet_singbox_disabled() {
    [ -f "${MODDIR}/.disable_sing_box" ]
}

magicnet_singbox_disable() {
    mkdir -p "$MODDIR"
    touch "${MODDIR}/.disable_sing_box"
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        singbox_stop || true
    fi
    magicnet_refresh_status
}

magicnet_singbox_enable() {
    rm -f "${MODDIR}/.disable_sing_box" 2>/dev/null || true
    magicnet_refresh_status
}

magicnet_singbox_toggle_disabled() {
    if magicnet_singbox_disabled; then
        magicnet_singbox_enable
        magicnet_log "sing-box enabled"
    else
        magicnet_singbox_disable
        magicnet_log "sing-box disabled by ${MODDIR}/.disable_sing_box"
    fi
}

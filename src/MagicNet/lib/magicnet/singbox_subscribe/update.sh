magicnet_singbox_update_lock_active() {
    _update_lock="${MODDIR}/.state/sing-box/subscription-update.lock"
    [ -d "$_update_lock" ] || return 1
    _update_owner=$(sed -n '1p' "$_update_lock/owner" 2>/dev/null)
    _update_pid=${_update_owner%%:*}
    _update_rest=${_update_owner#*:}
    _update_start=${_update_rest%%:*}
    _update_live_start=$(awk '{print $22}' "/proc/${_update_pid}/stat" 2>/dev/null || true)
    if [ -n "$_update_pid" ] && kill -0 "$_update_pid" 2>/dev/null &&
        [ -n "$_update_start" ] && [ "$_update_start" = "$_update_live_start" ]; then
        return 0
    fi
    _update_current=$(sed -n '1p' "$_update_lock/owner" 2>/dev/null)
    [ "$_update_current" = "$_update_owner" ] && rm -rf "$_update_lock" 2>/dev/null || true
    return 1
}

magicnet_singbox_update_lock_acquire() {
    _update_lock="${MODDIR}/.state/sing-box/subscription-update.lock"
    mkdir -p "${_update_lock%/*}"
    if ! mkdir "$_update_lock" 2>/dev/null; then
        if magicnet_singbox_update_lock_active; then
            error "Subscription update already running"
            return 1
        fi
        mkdir "$_update_lock" 2>/dev/null || return 1
    fi
    _update_start=$(awk '{print $22}' "/proc/$$/stat" 2>/dev/null || true)
    _update_nonce=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s)
    _update_token="$$:${_update_start:-unknown}:${_update_nonce}"
    printf '%s\n' "$_update_token" >"$_update_lock/owner"
}

magicnet_singbox_update_lock_release() {
    _update_lock="${MODDIR}/.state/sing-box/subscription-update.lock"
    _update_owner=$(sed -n '1p' "$_update_lock/owner" 2>/dev/null)
    [ -n "${_update_token:-}" ] && [ "$_update_owner" = "$_update_token" ] &&
        rm -rf "$_update_lock" 2>/dev/null || true
}

magicnet_singbox_update_subscription() {
    magicnet_singbox_update_lock_acquire || return 1
    trap 'magicnet_singbox_update_lock_release' EXIT HUP INT TERM
    magicnet_with_config_lock magicnet_singbox_update_subscription_unlocked
    _update_rc=$?
    trap - EXIT HUP INT TERM
    magicnet_singbox_update_lock_release
    return "$_update_rc"
}

magicnet_singbox_update_subscription_unlocked() {
    _work_dir="${MODDIR}/.state/sing-box/subscription-work"
    _nodes_dir="${_work_dir}/nodes"
    _outbounds_file="${_work_dir}/outbounds.json"
    _tags_file="${_work_dir}/tags.txt"
    _sources_file="${_work_dir}/sources.txt"
    _counts_file="${_work_dir}/counts.txt"

    rm -rf "$_work_dir"
    mkdir -p "$_nodes_dir"

    info "Subscription update stage: fetch"
    magicnet_singbox_fetch_subscription "$_sources_file" || return 1

    _node_total=0
    while IFS= read -r _source_file || [ -n "$_source_file" ]; do
        [ -s "$_source_file" ] || continue
        if grep -Eq '^proxies:[[:space:]]*$' "$_source_file"; then
            _node_count=$(magicnet_singbox_extract_clash_nodes "$_source_file" "$_nodes_dir")
        else
            _node_count=$(magicnet_singbox_extract_share_links "$_source_file" "$_nodes_dir")
        fi
        _node_total=$((_node_total + ${_node_count:-0}))
    done <"$_sources_file"

    if [ "${_node_total:-0}" -le 0 ]; then
        error "No supported subscription nodes found"
        return 1
    fi

    info "Subscription update stage: convert"
    if [ "${MAGICNET_PROXYLINK_ENABLED:-1}" = "1" ] &&
        magicnet_singbox_proxylink_bin >/dev/null 2>&1 &&
        magicnet_singbox_build_outbounds_with_proxylink "$_sources_file" "$_outbounds_file" "$_node_total" >"${_work_dir}/proxylink-counts.txt" 2>/dev/null; then
        # shellcheck disable=SC2046
        set -- $(cat "${_work_dir}/proxylink-counts.txt")
        _imported="$1"
        _skipped="$2"
    else
        magicnet_singbox_build_outbounds_file "$_nodes_dir" "$_outbounds_file" "$_tags_file" >"$_counts_file" ||
            return 1
        # shellcheck disable=SC2046
        set -- $(cat "$_counts_file")
        _imported="$1"
        _skipped="$2"
    fi

    if [ "${_imported:-0}" -le 0 ]; then
        error "No supported nodes imported. Supported: Clash ss/vmess/vless/trojan/hysteria2, share-link vless/hysteria2; Proxylink adds AnyTLS/TUIC when available"
        return 1
    fi

    info "Subscription update stage: validate"
    _active_config=$(magicnet_singbox_subscription_config_file)
    _previous_config="${_work_dir}/previous-config.json"
    cp -f "$_active_config" "$_previous_config" || return 1
    magicnet_singbox_update_config_with_nodes "$_outbounds_file" || return 1
    info "Subscription update stage: activate"
    _update_fswatch_active=0
    magicnet_fswatch_status >/dev/null 2>&1 && _update_fswatch_active=1
    # Read by magicnet_singbox_restart_owned in config.sh.
    # shellcheck disable=SC2034
    MAGICNET_SUB_FSWATCH_WAS_ACTIVE="$_update_fswatch_active"
    if ! magicnet_singbox_verify_subscription_ready; then
        mv -f "$_previous_config" "$_active_config" 2>/dev/null || true
        if ! magicnet_singbox_restart_owned "$_active_config" >/dev/null 2>&1; then
            unset MAGICNET_SUB_FSWATCH_WAS_ACTIVE
            error "Subscription activation and previous core recovery both failed"
            return 1
        fi
        unset MAGICNET_SUB_FSWATCH_WAS_ACTIVE
        error "Subscription activation failed; previous config and core restored"
        return 1
    fi
    unset MAGICNET_SUB_FSWATCH_WAS_ACTIVE
    rm -f "$_previous_config"
    success "sing-box nodes updated: imported ${_imported}, skipped ${_skipped}"
}

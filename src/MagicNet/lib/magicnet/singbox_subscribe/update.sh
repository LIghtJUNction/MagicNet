magicnet_singbox_update_subscription() {
    _work_dir="${MODDIR}/.config/sing-box/.subscription-work"
    _nodes_dir="${_work_dir}/nodes"
    _outbounds_file="${_work_dir}/outbounds.json"
    _tags_file="${_work_dir}/tags.txt"
    _sources_file="${_work_dir}/sources.txt"

    rm -rf "$_work_dir"
    mkdir -p "$_nodes_dir"

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

    if magicnet_singbox_proxylink_bin >/dev/null 2>&1 &&
        magicnet_singbox_build_outbounds_with_proxylink "$_sources_file" "$_outbounds_file" >"${_work_dir}/proxylink-counts.txt" 2>/dev/null; then
        # shellcheck disable=SC2046
        set -- $(cat "${_work_dir}/proxylink-counts.txt")
        _imported="$1"
        _skipped="$2"
    else
        # shellcheck disable=SC2046
        set -- $(magicnet_singbox_build_outbounds_file "$_nodes_dir" "$_outbounds_file" "$_tags_file")
        _imported="$1"
        _skipped="$2"
    fi

    if [ "${_imported:-0}" -le 0 ]; then
        error "No supported nodes imported. Supported: Clash ss/vmess/vless/trojan/hysteria2, share-link vless/hysteria2; Proxylink adds WireGuard/AnyTLS/TUIC when available"
        return 1
    fi

    magicnet_singbox_update_config_with_nodes "$_outbounds_file" || return 1
    magicnet_singbox_verify_subscription_ready || return 1
    success "sing-box nodes updated: imported ${_imported}, skipped ${_skipped}"
}

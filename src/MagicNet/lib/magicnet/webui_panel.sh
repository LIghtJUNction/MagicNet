magicnet_singbox_apply_zashboard() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0

    _tmp="${_config}.zashboard.new"
    if awk '
        /"external_ui"[[:space:]]*:/ {
            sub(/"external_ui"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"external_ui\": \"zashboard\"")
        }
        /"external_ui_download_url"[[:space:]]*:/ {
            sub(/"external_ui_download_url"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"external_ui_download_url\": \"https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip\"")
        }
        { print }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
}

magicnet_mihomo_apply_zashboard() {
    _target="${MODDIR}/.config/mihomo/ui/cubex"
    _index="${_target}/index.html"
    mkdir -p "${_target%/*}" || return 1

    if [ -f "$_index" ] && grep -qi '<title>zashboard</title>' "$_index" 2>/dev/null; then
        rm -rf "$_target" 2>/dev/null || true
        magicnet_log "Removed zashboard from mihomo cubex path; mihomo will fetch MetaCubeX"
    fi
    unset _target _index
}

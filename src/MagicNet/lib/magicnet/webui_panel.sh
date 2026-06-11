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
    _config="${MODDIR}/.config/mihomo/config.yaml"
    [ -f "$_config" ] || return 0

    _ui_dir="${MODDIR}/.config/sing-box/zashboard"
    _tmp="${_config}.zashboard.new"
    if awk -v ui_dir="$_ui_dir" '
        BEGIN {
            has_ui = 0
            has_ui_name = 0
            has_ui_url = 0
        }
        /^external-ui[[:space:]]*:/ {
            print "external-ui: " ui_dir
            has_ui = 1
            next
        }
        /^external-ui-name[[:space:]]*:/ {
            print "external-ui-name: zashboard"
            has_ui_name = 1
            next
        }
        /^external-ui-url[[:space:]]*:/ {
            print "external-ui-url: \"\""
            has_ui_url = 1
            next
        }
        { print }
        END {
            if (!has_ui) {
                print "external-ui: " ui_dir
            }
            if (!has_ui_name) {
                print "external-ui-name: zashboard"
            }
            if (!has_ui_url) {
                print "external-ui-url: \"\""
            }
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
    unset _config _ui_dir _tmp
}

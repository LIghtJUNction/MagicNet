magicnet_singbox_apply_zashboard() (
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || return 1
    _tmp="${_config}.zashboard.new"
    trap 'rm -f "$_tmp"' 0 1 2 3 15
    if ! (umask 077; "$_jq" '
        .experimental = (.experimental // {})
        | .experimental.clash_api = ((.experimental.clash_api // {})
            | .external_ui = "zashboard"
            | del(.external_ui_download_url, .external_ui_download_detour))
      ' "$_config" >"$_tmp"); then
        return 1
    fi
    chmod 600 "$_tmp" || return 1
    mv -f "$_tmp" "$_config" || return 1
    trap - 0 1 2 3 15
)

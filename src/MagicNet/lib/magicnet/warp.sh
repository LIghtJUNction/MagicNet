magicnet_warp_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/warp.conf"
}

magicnet_warp_endpoint_file() {
    printf '%s\n' "${MODDIR}/.config/magicnet/warp-endpoint.json"
}

magicnet_warp_enabled() {
    _enabled="${MAGICNET_WARP_ENABLED:-}"
    if [ -z "$_enabled" ]; then
        _enabled="$(magicnet_conf_value "$(magicnet_warp_conf)" MAGICNET_WARP_ENABLED 2>/dev/null || true)"
    fi
    case "$_enabled" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

magicnet_warp_configured() {
    [ -s "$(magicnet_warp_endpoint_file)" ]
}

magicnet_warp_apply_singbox() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || {
        unset _config
        return 0
    }
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || {
        magicnet_warn "packaged jq is unavailable; WARP apply rejected"
        unset _config _jq
        return 1
    }
    _endpoint="$(magicnet_warp_endpoint_file)"
    _tmp="${_config}.magicnet-warp.new"
    if magicnet_warp_enabled && magicnet_warp_configured; then
        (umask 077; "$_jq" --slurpfile warp "$_endpoint" '
          def with_warp($items):
            reduce (($items // []) + ["warp"])[] as $item ([]; if ($item == "" or index($item)) then . else . + [$item] end);
          .endpoints = ((.endpoints // []) | map(select((.tag // "") != "warp")) + [$warp[0]])
          | .outbounds = ((.outbounds // []) | map(
              if (.type == "selector" and ((.tag // "") | IN("select", "proxy-rule", "final"))) then
                .outbounds = with_warp(.outbounds)
              else .
              end
            ))
        ' "$_config" >"$_tmp") && chmod 600 "$_tmp" && mv -f "$_tmp" "$_config" && chmod 600 "$_config"
    else
        (umask 077; "$_jq" '
          def without_warp($items): ($items // []) | map(select(. != "warp"));
          .endpoints = ((.endpoints // []) | map(select((.tag // "") != "warp")))
          | if (.endpoints | length) == 0 then del(.endpoints) else . end
          | .outbounds = ((.outbounds // []) | map(
              if (.type == "selector") then
                (.outbounds = without_warp(.outbounds))
                | if (.default // "") == "warp" then .default = ((.outbounds // ["direct"])[0] // "direct") else . end
              else .
              end
            ))
        ' "$_config" >"$_tmp") && chmod 600 "$_tmp" && mv -f "$_tmp" "$_config" && chmod 600 "$_config"
    fi
    _rc=$?
    [ "$_rc" -eq 0 ] || rm -f "$_tmp" 2>/dev/null || true
    unset _config _jq _endpoint _tmp
    return "$_rc"
}

magicnet_warp_apply_unlocked() {
    magicnet_warp_apply_singbox
}

magicnet_warp_apply() {
    magicnet_with_config_lock magicnet_warp_apply_unlocked
}

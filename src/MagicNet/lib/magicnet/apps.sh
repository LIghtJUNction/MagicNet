magicnet_app_policy_dir() {
    printf '%s\n' "${MODDIR}/.config/magicnet"
}

magicnet_app_policy_mode() {
    _mode_file="$(magicnet_app_policy_dir)/app-mode.conf"
    if [ -f "$_mode_file" ]; then
        . "$_mode_file"
    fi
    case "${MAGICNET_APP_MODE:-blacklist}" in
        whitelist) printf '%s\n' "whitelist" ;;
        *) printf '%s\n' "blacklist" ;;
    esac
}


magicnet_package_array_block() {
    _key="$1"
    _file="$2"
    _comma="${3:-,}"
    _force_empty="${4:-0}"
    if [ ! -s "$_file" ]; then
        [ "$_force_empty" = "1" ] || return 0
        printf '      "%s": []%s\n' "$_key" "$_comma"
        unset _key _file _comma _force_empty
        return 0
    fi

    _items=$(sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++')
    if [ -z "$_items" ]; then
        [ "$_force_empty" = "1" ] || return 0
        printf '      "%s": []%s\n' "$_key" "$_comma"
        unset _key _file _comma _force_empty _items
        return 0
    fi

    printf '      "%s": [\n' "$_key"
    _count=$(printf '%s\n' "$_items" | wc -l | tr -d ' ')
    _idx=0
    printf '%s\n' "$_items" | while read -r _pkg; do
        [ -n "$_pkg" ] || continue
        _idx=$((_idx + 1))
        _line_comma=","
        [ "$_idx" -eq "$_count" ] && _line_comma=""
        printf '        "%s"%s\n' "$(magicnet_json_escape "$_pkg")" "$_line_comma"
    done
    printf '      ]%s\n' "$_comma"
    unset _key _file _comma _force_empty _items _count _idx _line_comma _pkg
}

magicnet_yaml_package_block() {
    _key="$1"
    _file="$2"
    _force_empty="${3:-0}"
    if [ ! -s "$_file" ]; then
        [ "$_force_empty" = "1" ] || return 0
        printf '  %s: []\n' "$_key"
        unset _key _file _force_empty
        return 0
    fi

    _items=$(sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++')
    if [ -z "$_items" ]; then
        [ "$_force_empty" = "1" ] || return 0
        printf '  %s: []\n' "$_key"
        unset _key _file _force_empty _items
        return 0
    fi

    printf '  %s:\n' "$_key"
    printf '%s\n' "$_items" | while read -r _pkg; do
        [ -n "$_pkg" ] || continue
        printf '    - %s\n' "$_pkg"
    done
    unset _key _file _items _pkg _force_empty
}

magicnet_mihomo_apply_app_policy() {
    _config="${MODDIR}/.config/mihomo/config.yaml"
    [ -f "$_config" ] || return 0

    _dir="$(magicnet_app_policy_dir)"
    _mode="$(magicnet_app_policy_mode)"
    _proxy_file="${_dir}/app-proxy.list"
    _bypass_file="${_dir}/app-bypass.list"

    _include_block=""
    _exclude_block=""
    if [ "$_mode" = "whitelist" ]; then
        _include_block="$(magicnet_yaml_package_block include-package "$_proxy_file" 1)"
    else
        _exclude_block="$(magicnet_yaml_package_block exclude-package "$_bypass_file")"
    fi

    _tmp="${_config}.app-policy.new"
    _include_tmp="${_config}.include-package.tmp"
    _exclude_tmp="${_config}.exclude-package.tmp"
    if [ -n "$_include_block" ]; then
        printf '%s\n' "$_include_block" >"$_include_tmp"
    else
        rm -f "$_include_tmp" 2>/dev/null || true
        _include_tmp=""
    fi
    if [ -n "$_exclude_block" ]; then
        printf '%s\n' "$_exclude_block" >"$_exclude_tmp"
    else
        rm -f "$_exclude_tmp" 2>/dev/null || true
        _exclude_tmp=""
    fi

    if awk -v include_file="$_include_tmp" -v exclude_file="$_exclude_tmp" '
        function emit_file(path, line) {
            if (path == "") {
                return
            }
            while ((getline line < path) > 0) {
                print line
            }
            close(path)
        }
        BEGIN {
            in_tun = 0
            skip_package_array = 0
        }
        skip_package_array {
            if ($0 ~ /^[^[:space:]-]/ || $0 ~ /^  [A-Za-z0-9_-]+[[:space:]]*:/) {
                skip_package_array = 0
            } else {
                next
            }
        }
        {
            if ($0 ~ /^tun:[[:space:]]*$/) {
                in_tun = 1
                print
                next
            }
            if (in_tun && $0 ~ /^[^[:space:]-]/) {
                emit_file(include_file)
                emit_file(exclude_file)
                in_tun = 0
            }
            if (in_tun && $0 ~ /^  (include-package|exclude-package)[[:space:]]*:/) {
                skip_package_array = 1
                next
            }
            print
        }
        END {
            if (in_tun) {
                emit_file(include_file)
                emit_file(exclude_file)
            }
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        rm -f "$_include_tmp" "$_exclude_tmp" 2>/dev/null || true
        return 1
    fi
    rm -f "$_include_tmp" "$_exclude_tmp" 2>/dev/null || true
}

magicnet_singbox_apply_app_policy() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0

    _dir="$(magicnet_app_policy_dir)"
    _mode="$(magicnet_app_policy_mode)"
    _proxy_file="${_dir}/app-proxy.list"
    _bypass_file="${_dir}/app-bypass.list"

    _include_block=""
    _exclude_block=""
    if [ "$_mode" = "whitelist" ]; then
        _include_block="$(magicnet_package_array_block include_package "$_proxy_file" "," 1)"
    else
        _exclude_block="$(magicnet_package_array_block exclude_package "$_bypass_file" ",")"
    fi

    _tmp="${_config}.app-policy.new"
    _include_tmp="${_config}.include-package.tmp"
    _exclude_tmp="${_config}.exclude-package.tmp"
    if [ -n "$_include_block" ]; then
        printf '%s\n' "$_include_block" >"$_include_tmp"
    else
        rm -f "$_include_tmp" 2>/dev/null || true
        _include_tmp=""
    fi
    if [ -n "$_exclude_block" ]; then
        printf '%s\n' "$_exclude_block" >"$_exclude_tmp"
    else
        rm -f "$_exclude_tmp" 2>/dev/null || true
        _exclude_tmp=""
    fi

    if awk -v include_file="$_include_tmp" -v exclude_file="$_exclude_tmp" '
        function emit_file(path, line) {
            if (path == "") {
                return
            }
            while ((getline line < path) > 0) {
                print line
            }
            close(path)
        }
        BEGIN {
            in_tun = 0
            skip_package_array = 0
        }
        skip_package_array {
            if ($0 ~ /^[[:space:]]*][[:space:]]*,?[[:space:]]*$/) {
                skip_package_array = 0
            }
            next
        }
        {
            if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"tun"/) {
                in_tun = 1
            }
            if (in_tun && $0 ~ /^[[:space:]]*"(include_package|exclude_package)"[[:space:]]*:/) {
                skip_package_array = 1
                next
            }
            if (in_tun && $0 ~ /^[[:space:]]*"stack"[[:space:]]*:/) {
                emit_file(include_file)
                emit_file(exclude_file)
            }
            print
            if (in_tun && $0 ~ /^    }[,]?[[:space:]]*$/) {
                in_tun = 0
            }
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        rm -f "$_include_tmp" "$_exclude_tmp" 2>/dev/null || true
        return 1
    fi
    rm -f "$_include_tmp" "$_exclude_tmp" 2>/dev/null || true
}

magicnet_app_policy_apply_unlocked() {
    _app_rc=0
    magicnet_mihomo_apply_app_policy || _app_rc=1
    magicnet_singbox_apply_app_policy || _app_rc=1
    if [ "$(magicnet_transparent_mode)" = "ebpf" ]; then
        magicnet_enable_ebpf || _app_rc=1
    fi
    return "$_app_rc"
}

magicnet_app_policy_apply() {
    magicnet_with_config_lock magicnet_app_policy_apply_unlocked
}

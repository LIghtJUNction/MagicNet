magicnet_capture_dir() {
    printf '%s\n' "${MODDIR}/.config/magicnet"
}

magicnet_capture_conf() {
    _conf="$(magicnet_capture_dir)/capture.conf"
    if [ -f "$_conf" ]; then
        . "$_conf"
    fi
    MAGICNET_CAPTURE_ENABLED="${MAGICNET_CAPTURE_ENABLED:-0}"
    MAGICNET_CAPTURE_HOST="${MAGICNET_CAPTURE_HOST:-192.168.1.100}"
    MAGICNET_CAPTURE_PORT="${MAGICNET_CAPTURE_PORT:-8888}"
    MAGICNET_CAPTURE_NAME="${MAGICNET_CAPTURE_NAME:-MagicNet-Capture}"
}

magicnet_capture_list_values() {
    _file="$1"
    [ -f "$_file" ] || return 0
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++'
}

magicnet_capture_yaml_rules() {
    _apps_file="$(magicnet_capture_dir)/capture-app.list"
    _domains_file="$(magicnet_capture_dir)/capture-domain-suffix.list"
    _name="$1"
    magicnet_capture_list_values "$_apps_file" | while read -r _pkg; do
        [ -n "$_pkg" ] && printf '  - PROCESS-NAME,%s,%s\n' "$_pkg" "$_name"
    done
    magicnet_capture_list_values "$_domains_file" | while read -r _domain; do
        [ -n "$_domain" ] && printf '  - DOMAIN-SUFFIX,%s,%s\n' "$_domain" "$_name"
    done
}

magicnet_capture_singbox_rule_block() {
    _apps_file="$(magicnet_capture_dir)/capture-app.list"
    _domains_file="$(magicnet_capture_dir)/capture-domain-suffix.list"
    _outbound="$1"
    _has_any=0

    _apps="$(magicnet_capture_list_values "$_apps_file")"
    if [ -n "$_apps" ]; then
        _has_any=1
        printf '      {\n'
        printf '        "package_name": [\n'
        _count=$(printf '%s\n' "$_apps" | wc -l | tr -d ' ')
        _idx=0
        printf '%s\n' "$_apps" | while read -r _pkg; do
            [ -n "$_pkg" ] || continue
            _idx=$((_idx + 1))
            _comma=","
            [ "$_idx" -eq "$_count" ] && _comma=""
            printf '          "%s"%s\n' "$(magicnet_json_escape "$_pkg")" "$_comma"
        done
        printf '        ],\n'
        printf '        "outbound": "%s"\n' "$_outbound"
        printf '      },\n'
    fi

    _domains="$(magicnet_capture_list_values "$_domains_file")"
    if [ -n "$_domains" ]; then
        _has_any=1
        printf '      {\n'
        printf '        "domain_suffix": [\n'
        _count=$(printf '%s\n' "$_domains" | wc -l | tr -d ' ')
        _idx=0
        printf '%s\n' "$_domains" | while read -r _domain; do
            [ -n "$_domain" ] || continue
            _idx=$((_idx + 1))
            _comma=","
            [ "$_idx" -eq "$_count" ] && _comma=""
            printf '          "%s"%s\n' "$(magicnet_json_escape "$_domain")" "$_comma"
        done
        printf '        ],\n'
        printf '        "outbound": "%s"\n' "$_outbound"
        printf '      },\n'
    fi

    [ "$_has_any" -eq 1 ]
}


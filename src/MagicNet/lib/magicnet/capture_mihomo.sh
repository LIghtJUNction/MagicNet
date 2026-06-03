magicnet_capture_apply_mihomo() {
    _config="${MODDIR}/.config/mihomo/config.yaml"
    [ -f "$_config" ] || return 0
    magicnet_capture_conf
    _tmp="${_config}.capture.new"
    _rules_file="${MODDIR}/.tmp/magicnet-capture-mihomo.rules"
    mkdir -p "${_rules_file%/*}"
    magicnet_capture_yaml_rules "$MAGICNET_CAPTURE_NAME" >"$_rules_file"
    if awk \
        -v enabled="$MAGICNET_CAPTURE_ENABLED" \
        -v name="$MAGICNET_CAPTURE_NAME" \
        -v host="$MAGICNET_CAPTURE_HOST" \
        -v port="$MAGICNET_CAPTURE_PORT" \
        -v rules_file="$_rules_file" '
        BEGIN {
            skip_capture_proxy = 0
            skip_capture_rules = 0
            inserted_proxy = 0
            inserted_rules = 0
        }
        skip_capture_proxy {
            if ($0 ~ /^  # MAGICNET_CAPTURE_PROXY_END/) {
                skip_capture_proxy = 0
            }
            next
        }
        skip_capture_rules {
            if ($0 ~ /^  # MAGICNET_CAPTURE_END/) {
                skip_capture_rules = 0
            }
            next
        }
        $0 ~ /^  # MAGICNET_CAPTURE_PROXY_START/ {
            skip_capture_proxy = 1
            next
        }
        $0 ~ /^  # MAGICNET_CAPTURE_START/ {
            skip_capture_rules = 1
            next
        }
        {
            if (enabled == "1" && !inserted_proxy && $0 ~ /^proxies:[[:space:]]*\[\][[:space:]]*$/) {
                print "proxies:"
                print "  # MAGICNET_CAPTURE_PROXY_START"
                print "  - name: \"" name "\""
                print "    type: http"
                print "    server: " host
                print "    port: " port
                print "  # MAGICNET_CAPTURE_PROXY_END"
                inserted_proxy = 1
                next
            }
            print
            if (enabled == "1" && !inserted_proxy && $0 ~ /^proxies:[[:space:]]*$/) {
                print "  # MAGICNET_CAPTURE_PROXY_START"
                print "  - name: \"" name "\""
                print "    type: http"
                print "    server: " host
                print "    port: " port
                print "  # MAGICNET_CAPTURE_PROXY_END"
                inserted_proxy = 1
            }
            if (enabled == "1" && !inserted_rules && $0 ~ /^rules:[[:space:]]*$/) {
                print "  # MAGICNET_CAPTURE_START"
                while ((getline rule_line < rules_file) > 0) {
                    print rule_line
                }
                close(rules_file)
                print "  # MAGICNET_CAPTURE_END"
                inserted_rules = 1
            }
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
}


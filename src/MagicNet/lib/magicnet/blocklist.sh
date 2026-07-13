magicnet_block_dir() {
    printf '%s\n' "${MODDIR}/.config/magicnet"
}

magicnet_block_conf() {
    printf '%s\n' "$(magicnet_block_dir)/block.conf"
}

magicnet_block_manual_file() {
    printf '%s\n' "$(magicnet_block_dir)/block-domain-suffix.list"
}

magicnet_block_community_file() {
    printf '%s\n' "$(magicnet_block_dir)/community-ban-domain-suffix.list"
}

magicnet_block_community_rules_file() {
    printf '%s\n' "$(magicnet_block_dir)/community-ban-rules.list"
}

magicnet_block_allow_file() {
    printf '%s\n' "$(magicnet_block_dir)/block-allow-rules.list"
}

magicnet_block_load_conf() {
    _conf="$(magicnet_block_conf)"
    if [ -f "$_conf" ]; then
        . "$_conf"
    fi
    MAGICNET_BLOCK_ENABLED="${MAGICNET_BLOCK_ENABLED:-1}"
    MAGICNET_BLOCK_COMMUNITY_ENABLED="${MAGICNET_BLOCK_COMMUNITY_ENABLED:-1}"
    MAGICNET_BLOCK_URL="${MAGICNET_BLOCK_URL:-https://raw.githubusercontent.com/LIghtJUNction/MagicNet/main/src/MagicNet/.config/magicnet/community-ban.yaml}"
    unset _conf
}

magicnet_block_list_values() {
    _file="$1"
    [ -f "$_file" ] || return 0
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++'
}

magicnet_block_manual_suffixes() {
    magicnet_block_list_values "$(magicnet_block_manual_file)" | awk '{ print "DOMAIN-SUFFIX," $0 }'
}

magicnet_block_community_rules() {
    _allow_file="$(magicnet_block_allow_file)"
    if [ -s "$(magicnet_block_community_rules_file)" ]; then
        if [ -s "$_allow_file" ]; then
            magicnet_block_list_values "$(magicnet_block_community_rules_file)" | grep -Fvx -f "$_allow_file"
        else
            magicnet_block_list_values "$(magicnet_block_community_rules_file)"
        fi
    else
        if [ -s "$_allow_file" ]; then
            magicnet_block_list_values "$(magicnet_block_community_file)" | awk '{ print "DOMAIN-SUFFIX," $0 }' | grep -Fvx -f "$_allow_file"
        else
            magicnet_block_list_values "$(magicnet_block_community_file)" | awk '{ print "DOMAIN-SUFFIX," $0 }'
        fi
    fi
    unset _allow_file
}

magicnet_block_all_rules() {
    magicnet_block_load_conf
    [ "$MAGICNET_BLOCK_ENABLED" = "1" ] || return 0
    magicnet_block_manual_suffixes
    if [ "$MAGICNET_BLOCK_COMMUNITY_ENABLED" = "1" ]; then
        magicnet_block_community_rules
    fi
}

magicnet_block_has_domains() {
    magicnet_block_all_rules | grep -q .
}

magicnet_block_emit_match_array() {
    _emit_key="$1"
    _emit_values="$2"
    [ -n "$_emit_values" ] || return 0
    printf ',\n        "%s": [\n' "$_emit_key"
    _emit_count=$(printf '%s\n' "$_emit_values" | awk 'NF' | wc -l | tr -d ' ')
    _emit_idx=0
    printf '%s\n' "$_emit_values" | while read -r _emit_value; do
        [ -n "$_emit_value" ] || continue
        _emit_idx=$((_emit_idx + 1))
        _emit_comma=","; [ "$_emit_idx" -eq "$_emit_count" ] && _emit_comma=""
        printf '          "%s"%s\n' "$(magicnet_json_escape "$_emit_value")" "$_emit_comma"
    done
    printf '        ]'
    unset _emit_key _emit_values _emit_count _emit_idx _emit_value _emit_comma
}

magicnet_block_allow_singbox_rules() {
    _rules="$(magicnet_block_list_values "$(magicnet_block_allow_file)")"
    [ -n "$_rules" ] || return 0
    _domains="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN" { print $2 }' | awk 'NF && !seen[$0]++')"
    _suffixes="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN-SUFFIX" { print $2 }' | awk 'NF && !seen[$0]++')"
    _keywords="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN-KEYWORD" { print $2 }' | awk 'NF && !seen[$0]++')"
    printf '      {\n'
    printf '        "domain": ["__magicnet_ad_allow__"'
    if [ -n "$_domains" ]; then
        printf '%s\n' "$_domains" | while read -r _domain; do
            [ -n "$_domain" ] || continue
            printf ', "%s"' "$(magicnet_json_escape "$_domain")"
        done
    fi
    printf ']'
    magicnet_block_emit_match_array "domain_suffix" "$_suffixes"
    magicnet_block_emit_match_array "domain_keyword" "$_keywords"
    printf ',\n        "outbound": "ad-allow"\n'
    printf '      },\n'
    unset _rules _domains _suffixes _keywords _domain
}

magicnet_block_singbox_rules() {
    _rules="$(magicnet_block_all_rules)"
    [ -n "$_rules" ] || return 0
    _domains="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN" { print $2 }' | awk 'NF && !seen[$0]++')"
    _suffixes="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN-SUFFIX" { print $2 }' | awk 'NF && !seen[$0]++')"
    _keywords="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN-KEYWORD" { print $2 }' | awk 'NF && !seen[$0]++')"
    printf '      {\n'
    printf '        "domain": [\n'
    printf '          "__magicnet_block__"'
    if [ -n "$_domains" ]; then
        printf ',\n'
        _count=$(printf '%s\n' "$_domains" | awk 'NF' | wc -l | tr -d ' ')
        _idx=0
        printf '%s\n' "$_domains" | while read -r _domain; do
            [ -n "$_domain" ] || continue
            _idx=$((_idx + 1))
            _comma=","
            [ "$_idx" -eq "$_count" ] && _comma=""
            printf '          "%s"%s\n' "$(magicnet_json_escape "$_domain")" "$_comma"
        done
    else
        printf '\n'
    fi
    printf '        ]'
    if [ -n "$_suffixes" ]; then
        printf ',\n        "domain_suffix": [\n'
        _count=$(printf '%s\n' "$_suffixes" | awk 'NF' | wc -l | tr -d ' ')
        _idx=0
        printf '%s\n' "$_suffixes" | while read -r _domain; do
            [ -n "$_domain" ] || continue
            _idx=$((_idx + 1))
            _comma=","
            [ "$_idx" -eq "$_count" ] && _comma=""
            printf '          "%s"%s\n' "$(magicnet_json_escape "$_domain")" "$_comma"
        done
        printf '        ]'
    fi
    if [ -n "$_keywords" ]; then
        printf ',\n        "domain_keyword": [\n'
        _count=$(printf '%s\n' "$_keywords" | awk 'NF' | wc -l | tr -d ' ')
        _idx=0
        printf '%s\n' "$_keywords" | while read -r _domain; do
            [ -n "$_domain" ] || continue
            _idx=$((_idx + 1))
            _comma=","
            [ "$_idx" -eq "$_count" ] && _comma=""
            printf '          "%s"%s\n' "$(magicnet_json_escape "$_domain")" "$_comma"
        done
        printf '        ]'
    fi
    printf ',\n'
    printf '        "outbound": "ad-block"\n'
    printf '      },\n'
    unset _rules _domains _suffixes _keywords _count _idx _comma _domain
}

magicnet_block_ensure_ad_selectors() {
    _selector_config="$1"
    _selector_tmp="${_selector_config}.magicnet-selectors.new"
    _selector_has_allow=0
    grep -q '"tag"[[:space:]]*:[[:space:]]*"ad-allow"' "$_selector_config" && _selector_has_allow=1
    awk -v has_allow="$_selector_has_allow" '
        function emit_block(comma) {
            print "    {"
            print "      \"type\": \"selector\","
            print "      \"tag\": \"ad-block\","
            print "      \"outbounds\": [\"block\", \"direct\", \"proxy\"],"
            print "      \"default\": \"block\""
            print "    }" comma
        }
        function emit_allow(comma) {
            print "    {"
            print "      \"type\": \"selector\","
            print "      \"tag\": \"ad-allow\","
            print "      \"outbounds\": [\"final\", \"direct\", \"proxy\"],"
            print "      \"default\": \"final\""
            print "    }" comma
        }
        function brace_delta(s, i, c, d) {
            d = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "{") d++
                if (c == "}") d--
            }
            return d
        }
        BEGIN { in_outbounds = 0; buffering = 0; depth = 0; buffer = ""; found_block = 0 }
        {
            if (buffering) {
                buffer = buffer $0 "\n"
                depth += brace_delta($0)
                if ($0 ~ /"tag"[[:space:]]*:[[:space:]]*"ad-block"/) tag = "block"
                if ($0 ~ /"tag"[[:space:]]*:[[:space:]]*"ad-allow"/) tag = "allow"
                if (depth <= 0) {
                    comma = ($0 ~ /},[[:space:]]*$/) ? "," : ""
                    if (tag == "block") {
                        emit_block(has_allow ? comma : ",")
                        found_block = 1
                        if (!has_allow) emit_allow(comma)
                    } else if (tag == "allow") {
                        emit_allow(comma)
                    } else {
                        printf "%s", buffer
                    }
                    buffering = 0; buffer = ""; tag = ""
                }
                next
            }
            if ($0 ~ /^  "outbounds"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
                in_outbounds = 1
                print
                next
            }
            if (in_outbounds && $0 ~ /^    \{[[:space:]]*$/) {
                buffering = 1; buffer = $0 "\n"; depth = 1; tag = ""
                next
            }
            if (in_outbounds && $0 ~ /^  ][,]?[[:space:]]*$/) {
                if (!found_block) exit 42
                in_outbounds = 0
            }
            print
        }
    ' "$_selector_config" >"$_selector_tmp" || {
        _selector_rc=$?
        rm -f "$_selector_tmp"
        unset _selector_config _selector_tmp _selector_has_allow _selector_rc
        return 1
    }
    mv -f "$_selector_tmp" "$_selector_config"
    unset _selector_config _selector_tmp _selector_has_allow
}

magicnet_block_apply_singbox() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    magicnet_block_ensure_ad_selectors "$_config" || return 1
    _tmp="${_config}.magicnet-block.new"
    _rules_file="${MODDIR}/.tmp/magicnet-block-singbox.rules"
    mkdir -p "${_rules_file%/*}"
    {
        magicnet_block_allow_singbox_rules
        magicnet_block_singbox_rules
    } >"$_rules_file"
    if awk -v rules_file="$_rules_file" '
        BEGIN {
            in_route = 0
            in_rules = 0
            buffering = 0
            buffer = ""
            skip_custom = 0
            inserted = 0
        }
        function reset_buffer() {
            buffer = ""
            buffering = 0
            skip_custom = 0
        }
        function route_rule_precedes_ads(rule) {
            return rule ~ /"action"[[:space:]]*:/ ||
                (rule ~ /"protocol"[[:space:]]*:[[:space:]]*"icmp"/ &&
                 rule ~ /"outbound"[[:space:]]*:[[:space:]]*"block"/) ||
                rule ~ /"__magicnet_app_proxy__"/
        }
        function flush_rule() {
            if (!skip_custom) {
                if (!inserted && !route_rule_precedes_ads(buffer)) {
                    while ((getline rule_line < rules_file) > 0) {
                        print rule_line
                    }
                    close(rules_file)
                    inserted = 1
                }
                printf "%s", buffer
            }
            reset_buffer()
        }
        {
            if (buffering) {
                buffer = buffer $0 "\n"
                if ($0 ~ /"__magicnet_(ad_allow|block)__"/) {
                    skip_custom = 1
                }
                if ($0 ~ /^      }[,]?[[:space:]]*$/) {
                    flush_rule()
                }
                next
            }
            if ($0 ~ /^  "route"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/) {
                in_route = 1
                print
                next
            }
            if (in_route && $0 ~ /^  }[,]?[[:space:]]*$/) {
                in_route = 0
                print
                next
            }
            if (in_route && $0 ~ /^    "rules"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
                in_rules = 1
                print
                next
            }
            if (in_rules && $0 ~ /^    ][,]?[[:space:]]*$/) {
                if (!inserted) {
                    while ((getline rule_line < rules_file) > 0) {
                        print rule_line
                    }
                    close(rules_file)
                    inserted = 1
                }
                in_rules = 0
                print
                next
            }
            if (in_rules && $0 ~ /^      \{[[:space:]]*$/) {
                buffering = 1
                buffer = $0 "\n"
                skip_custom = 0
                next
            }
            print
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
}

magicnet_block_apply_unlocked() {
    _block_rc=0
    magicnet_block_apply_singbox || _block_rc=1
    return "$_block_rc"
}

magicnet_block_apply() {
    magicnet_with_config_lock magicnet_block_apply_unlocked
}

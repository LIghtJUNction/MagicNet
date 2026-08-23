# shellcheck shell=ash
#
# Shared sing-box route.rules helpers.

magicnet_singbox_insert_route_rules() {
    _insert_config="$1"
    _insert_tmp="$2"
    _insert_rules_file="$3"
    _insert_mode="$4"
    case "$_insert_mode" in
        block | route) ;;
        *)
            unset _insert_config _insert_tmp _insert_rules_file _insert_mode
            return 1
            ;;
    esac
    (umask 077; awk -v rules_file="$_insert_rules_file" -v mode="$_insert_mode" '
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
        function should_insert(rule) {
            if (mode == "block") {
                return rule ~ /"action"[[:space:]]*:/ ||
                    (rule ~ /"protocol"[[:space:]]*:[[:space:]]*"icmp"/ &&
                     rule ~ /"outbound"[[:space:]]*:[[:space:]]*"block"/) ||
                    rule ~ /"__magicnet_app_proxy__"/
            }
            return rule ~ /"action"[[:space:]]*:[[:space:]]*"sniff"/
        }
        function insert_rules() {
            while ((getline rule_line < rules_file) > 0) {
                print rule_line
            }
            close(rules_file)
            inserted = 1
        }
        function flush_rule() {
            if (!skip_custom) {
                if (!inserted && should_insert(buffer)) {
                    insert_rules()
                }
                printf "%s", buffer
            }
            reset_buffer()
        }
        function note_skip_marker() {
            if (mode == "block") {
                if ($0 ~ /"__magicnet_(ad_allow|block)__"/) {
                    skip_custom = 1
                }
                return
            }
            if ($0 ~ /"domain_suffix"[[:space:]]*:/) {
                getline next_line
                buffer = buffer next_line "\n"
                if (next_line ~ /"__magicnet_route__"/) {
                    skip_custom = 1
                }
            }
        }
        {
            if (buffering) {
                buffer = buffer $0 "\n"
                note_skip_marker()
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
                if (mode == "block" && !inserted) {
                    insert_rules()
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
    ' "$_insert_config" >"$_insert_tmp")
    _insert_rc=$?
    unset _insert_config _insert_tmp _insert_rules_file _insert_mode
    return "$_insert_rc"
}

magicnet_singbox_validate_managed_marker() {
    _validate_file="$1"
    _validate_marker="$2"
    _validate_required="$3"
    _validate_warn="$4"
    case "$_validate_required" in
        0 | 1) ;;
        *)
            unset _validate_file _validate_marker _validate_required _validate_warn
            return 1
            ;;
    esac
    if [ "$_validate_required" -eq 1 ]; then
        grep -q "$_validate_marker" "$_validate_file" || {
            magicnet_warn "$_validate_warn"
            unset _validate_file _validate_marker _validate_required _validate_warn
            return 1
        }
    elif grep -q "$_validate_marker" "$_validate_file"; then
        magicnet_warn "$_validate_warn"
        unset _validate_file _validate_marker _validate_required _validate_warn
        return 1
    fi
    unset _validate_file _validate_marker _validate_required _validate_warn
    return 0
}

magicnet_singbox_publish_config() {
    _publish_config="$1"
    _publish_tmp="$2"
    chmod 600 "$_publish_tmp" && mv -f "$_publish_tmp" "$_publish_config" && chmod 600 "$_publish_config"
    _publish_rc=$?
    [ "$_publish_rc" -eq 0 ] || rm -f "$_publish_tmp" 2>/dev/null || true
    unset _publish_config _publish_tmp
    return "$_publish_rc"
}

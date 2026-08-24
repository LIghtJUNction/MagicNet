# shellcheck shell=ash
#
# Shared awk helper for inserting managed sing-box route.rules entries.

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

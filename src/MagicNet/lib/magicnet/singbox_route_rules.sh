# shellcheck shell=ash
#
# Shared structural helper for inserting managed sing-box route.rules entries.

magicnet_singbox_insert_route_rules() (
    _insert_config="$1"
    _insert_tmp="$2"
    _insert_rules_file="$3"
    _insert_mode="$4"
    case "$_insert_mode" in
        block | route) ;;
        *) return 1 ;;
    esac

    _insert_jq=$(magicnet_require_jq "packaged jq is unavailable; route-rule apply rejected") || return 1
    _insert_rules_json=$(mktemp "${_insert_tmp}.rules.XXXXXX") || return 1
    trap 'rm -f "$_insert_rules_json" 2>/dev/null || true' EXIT HUP INT TERM
    if ! {
        printf '[\n'
        awk '
            { lines[NR] = $0; if ($0 ~ /[^[:space:]]/) last = NR }
            END {
                for (i = 1; i <= NR; i++) {
                    if (i == last) sub(/,[[:space:]]*$/, "", lines[i])
                    print lines[i]
                }
            }
        ' "$_insert_rules_file"
        printf ']\n'
    } >"$_insert_rules_json" ||
        ! "$_insert_jq" -e 'type == "array" and all(.[]; type == "object")' \
            "$_insert_rules_json" >/dev/null; then
        return 1
    fi

    magicnet_jq_install_config "$_insert_tmp" "${_insert_tmp}.magicnet-route-rules.new" \
        "$_insert_jq" --slurpfile managed "$_insert_rules_json" --arg mode "$_insert_mode" -e '
        def has_value($key; $value):
          .[$key]? as $candidate
          | if ($candidate | type) == "array" then
              ($candidate | index($value)) != null
            else
              $candidate == $value
            end;
        def is_managed:
          if $mode == "block" then
            has_value("domain"; "__magicnet_ad_allow__")
              or has_value("domain"; "__magicnet_block__")
          else
            has_value("domain_suffix"; "__magicnet_route__")
          end;
        def is_block_precedence_rule:
          has("action")
            or ((has_value("protocol"; "icmp")) and ((.outbound? // "") == "block"))
            or has_value("package_name"; "__magicnet_app_proxy__")
            or has_value("domain"; "__magicnet_app_proxy__");
        def is_insertion_point:
          if $mode == "block" then
            (is_block_precedence_rule | not)
          else
            (.action? // "") == "sniff"
          end;
        if (.route | type) != "object" or (.route.rules | type) != "array" then
          error("sing-box route.rules must be an array")
        else
          ($managed[0] // []) as $new
          | (.route.rules | map(select(is_managed | not))) as $clean
          | ([range(0; ($clean | length)) as $index
              | select($clean[$index] | is_insertion_point)
              | $index][0] // ($clean | length)) as $position
          | .route.rules = (
              $clean[0:$position] + $new + $clean[$position:]
            )
        end
        ' "$_insert_config"
)

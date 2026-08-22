magicnet_singbox_proxylink_bin() {
    _bin="${MODDIR}/bin/proxylink"
    [ -x "$_bin" ] || {
        unset _bin
        return 1
    }
    printf '%s\n' "$_bin"
    unset _bin
}

magicnet_singbox_run_proxylink() (
    _proxylink_timeout="${MAGICNET_PROXYLINK_TIMEOUT:-12}"
    case "$_proxylink_timeout" in
        '' | *[!0-9]*) _proxylink_timeout=12 ;;
        *)
            if [ "$_proxylink_timeout" -lt 1 ] || [ "$_proxylink_timeout" -gt 60 ]; then
                _proxylink_timeout=12
            fi
            ;;
    esac
    "$@" &
    _proxylink_pid=$!
    _proxylink_wait=0
    while kill -0 "$_proxylink_pid" 2>/dev/null; do
        if [ "$_proxylink_wait" -ge "$_proxylink_timeout" ]; then
            kill "$_proxylink_pid" 2>/dev/null || true
            sleep 1
            kill -9 "$_proxylink_pid" 2>/dev/null || true
            wait "$_proxylink_pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        _proxylink_wait=$((_proxylink_wait + 1))
    done
    wait "$_proxylink_pid"
    return $?
)

magicnet_singbox_proxylink_source_is_singbox_json() (
    _proxylink_detect_source_file="$1"
    _proxylink_detect_jq="$(command -v jq 2>/dev/null || true)"
    [ -n "$_proxylink_detect_jq" ] || return 1
    "$_proxylink_detect_jq" -e 'type == "object" and (((.outbounds | type == "array") or (.endpoints | type == "array")) or ((.type | type == "string" and length > 0) and (.server | type == "string" and length > 0)))' \
        "$_proxylink_detect_source_file" >/dev/null 2>&1
)

magicnet_singbox_proxylink_decode_source() {
    _proxylink_decode_source_file="$1"
    _proxylink_decode_file="$2"
    command -v base64 >/dev/null 2>&1 || {
        unset _proxylink_decode_source_file _proxylink_decode_file
        return 1
    }

    if base64 -d "$_proxylink_decode_source_file" >"$_proxylink_decode_file" 2>/dev/null &&
        [ -s "$_proxylink_decode_file" ]; then
        unset _proxylink_decode_source_file _proxylink_decode_file
        return 0
    fi

    : >"$_proxylink_decode_file" || {
        unset _proxylink_decode_source_file _proxylink_decode_file
        return 1
    }
    if tr -d '\r\n' <"$_proxylink_decode_source_file" | tr '_-' '/+' |
        awk '{ value = value $0 }
            END {
                remainder = length(value) % 4
                if (remainder == 1) exit 1
                if (remainder == 2) value = value "=="
                else if (remainder == 3) value = value "="
                print value
            }' |
        base64 -d >"$_proxylink_decode_file" 2>/dev/null && [ -s "$_proxylink_decode_file" ]; then
        unset _proxylink_decode_source_file _proxylink_decode_file
        return 0
    fi

    unset _proxylink_decode_source_file _proxylink_decode_file
    return 1
}

magicnet_singbox_run_proxylink_source() {
    _proxylink_source_bin="$1"
    _proxylink_source_file="$2"
    _proxylink_output_file="$3"
    _proxylink_source_for="$_proxylink_source_file"
    _proxylink_decoded_file="${_proxylink_source_file}.proxylink-decoded.$$"

    if ! magicnet_singbox_proxylink_source_is_singbox_json "$_proxylink_source_file" &&
        magicnet_singbox_proxylink_decode_source "$_proxylink_source_file" "$_proxylink_decoded_file" &&
        { magicnet_singbox_proxylink_source_is_singbox_json "$_proxylink_decoded_file" ||
            grep -Eq '^[[:space:]]*proxies:[[:space:]]*$|^[[:space:]]*[[:alpha:]][[:alnum:]+.-]*://' \
                "$_proxylink_decoded_file"; }; then
        _proxylink_source_for="$_proxylink_decoded_file"
    fi

    if magicnet_singbox_proxylink_source_is_singbox_json "$_proxylink_source_for"; then
        MAGICNET_SUB_CONVERTER_FORMAT=singbox
        if magicnet_singbox_run_proxylink "$_proxylink_source_bin" -singbox "$_proxylink_source_for" \
            -format singbox -o "$_proxylink_output_file"; then
            _proxylink_source_rc=0
        else
            _proxylink_source_rc=$?
        fi
    else
        # shellcheck disable=SC2034,SC2209 # consumed by update.sh status metadata
        MAGICNET_SUB_CONVERTER_FORMAT="file"
        if magicnet_singbox_run_proxylink "$_proxylink_source_bin" -file "$_proxylink_source_for" \
            -format singbox -o "$_proxylink_output_file"; then
            _proxylink_source_rc=0
        else
            _proxylink_source_rc=$?
        fi
    fi
    rm -f "$_proxylink_decoded_file" 2>/dev/null || true
    unset _proxylink_source_bin _proxylink_source_file _proxylink_output_file
    unset _proxylink_source_for _proxylink_decoded_file
    return "$_proxylink_source_rc"
}

magicnet_singbox_build_outbounds_with_proxylink() {
    _sources_file="$1"
    _out_file="$2"
    _expected_count="${3:-0}"
    _proxylink=$(magicnet_singbox_proxylink_bin) || return 1
    _tmp_config="${_out_file}.proxylink-config.json"
    _tmp_outbounds="${_out_file}.proxylink-outbounds.json"
    _filtered_outbounds="${_out_file}.proxylink-filtered.json"
    _links_file="${_sources_file%/*}/nodes/links.txt"
    MAGICNET_SUB_CONVERTER_FORMAT=none

    : >"$_tmp_config"
    if [ -s "$_links_file" ]; then
        # shellcheck disable=SC2034,SC2209 # consumed by update.sh status metadata
        MAGICNET_SUB_CONVERTER_FORMAT="file"
        magicnet_singbox_run_proxylink "$_proxylink" -file "$_links_file" -format singbox -o "$_tmp_config" >/dev/null 2>&1 ||
            return 1
    else
        _first=1
        while IFS= read -r _source_file || [ -n "$_source_file" ]; do
            [ -s "$_source_file" ] || continue
            [ "$_first" -eq 1 ] || return 1
            magicnet_singbox_run_proxylink_source "$_proxylink" "$_source_file" "$_tmp_config" >/dev/null 2>&1 ||
                return 1
            _first=0
        done <"$_sources_file"
    fi

    [ -s "$_tmp_config" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -c '.outbounds // []' "$_tmp_config" >"$_tmp_outbounds" || return 1
    _raw_count=$(jq 'length' "$_tmp_outbounds" 2>/dev/null || printf '0')
    [ "${_raw_count:-0}" -gt 0 ] || return 1
    _pre_filter_valid_count=$(magicnet_singbox_count_valid_outbounds_nodes "$_tmp_outbounds") || return 1
    if [ "${_expected_count:-0}" -gt 0 ] &&
        [ "${_pre_filter_valid_count:-0}" -lt "${_expected_count:-0}" ]; then
        return 1
    fi

    _filter_file=$(magicnet_singbox_subscription_filter_file)
    [ -f "$_filter_file" ] || _filter_file=/dev/null
    jq --rawfile configured_filters "$_filter_file" '
      ($configured_filters
        | split("\n")
        | map(gsub("\r"; "") | select(length > 0) | ascii_downcase)) as $filters
      | map(select((.tag // "" | ascii_downcase) as $tag
          | ($filters | any(. as $filter | $tag | contains($filter))) | not))
    ' "$_tmp_outbounds" >"$_filtered_outbounds" || return 1

    _valid_count=$(magicnet_singbox_count_valid_outbounds_nodes "$_filtered_outbounds") || return 1
    [ "${_valid_count:-0}" -gt 0 ] || return 1

    magicnet_singbox_write_outbounds_from_json "$_filtered_outbounds" "$_out_file" || return 1
    _skipped=$((_raw_count - _valid_count))
    printf '%s %s\n' "$_valid_count" "$_skipped"
}

magicnet_singbox_write_outbounds_from_json() {
    _nodes_json="$1"
    _out_file="$2"
    _tags_file="${_out_file}.proxylink-tags"
    jq -r '.[].tag // empty' "$_nodes_json" >"$_tags_file" || return 1
    magicnet_singbox_build_outbounds_file_with_jq "$_nodes_json" "$_tags_file" "$_out_file" || return 1
}

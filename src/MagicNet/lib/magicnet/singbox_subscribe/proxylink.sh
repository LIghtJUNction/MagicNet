magicnet_singbox_proxylink_bin() {
    for _bin in "${MODDIR}/bin/proxylink" proxylink; do
        if command -v "$_bin" >/dev/null 2>&1; then
            command -v "$_bin"
            unset _bin
            return 0
        fi
        [ -x "$_bin" ] && {
            printf '%s\n' "$_bin"
            unset _bin
            return 0
        }
    done
    unset _bin
    return 1
}

magicnet_singbox_run_proxylink() {
    _proxylink_timeout="${MAGICNET_PROXYLINK_TIMEOUT:-12}"
    "$@" &
    _proxylink_pid=$!
    _proxylink_wait=0
    while kill -0 "$_proxylink_pid" 2>/dev/null; do
        if [ "$_proxylink_wait" -ge "$_proxylink_timeout" ]; then
            kill "$_proxylink_pid" 2>/dev/null || true
            sleep 1
            kill -9 "$_proxylink_pid" 2>/dev/null || true
            wait "$_proxylink_pid" 2>/dev/null || true
            unset _proxylink_timeout _proxylink_pid _proxylink_wait
            return 124
        fi
        sleep 1
        _proxylink_wait=$((_proxylink_wait + 1))
    done
    wait "$_proxylink_pid"
    _proxylink_rc=$?
    unset _proxylink_timeout _proxylink_pid _proxylink_wait
    return "$_proxylink_rc"
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

    : >"$_tmp_config"
    if [ -s "$_links_file" ]; then
        magicnet_singbox_run_proxylink "$_proxylink" -file "$_links_file" -format singbox -o "$_tmp_config" >/dev/null 2>&1 ||
            return 1
    else
        _first=1
        while IFS= read -r _source_file || [ -n "$_source_file" ]; do
            [ -s "$_source_file" ] || continue
            [ "$_first" -eq 1 ] || return 1
            magicnet_singbox_run_proxylink "$_proxylink" -file "$_source_file" -format singbox -o "$_tmp_config" >/dev/null 2>&1 ||
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

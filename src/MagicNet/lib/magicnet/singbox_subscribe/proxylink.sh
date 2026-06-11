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

magicnet_singbox_build_outbounds_with_proxylink() {
    _sources_file="$1"
    _out_file="$2"
    _proxylink=$(magicnet_singbox_proxylink_bin) || return 1
    _tmp_config="${_out_file}.proxylink-config.json"
    _tmp_outbounds="${_out_file}.proxylink-outbounds.json"

    : >"$_tmp_config"
    _first=1
    while IFS= read -r _source_file || [ -n "$_source_file" ]; do
        [ -s "$_source_file" ] || continue
        [ "$_first" -eq 1 ] || return 1
        "$_proxylink" -file "$_source_file" -format singbox -o "$_tmp_config" >/dev/null 2>&1 ||
            return 1
        _first=0
    done <"$_sources_file"

    [ -s "$_tmp_config" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -c '.outbounds // []' "$_tmp_config" >"$_tmp_outbounds" || return 1
    _count=$(jq 'length' "$_tmp_outbounds" 2>/dev/null || printf '0')
    [ "${_count:-0}" -gt 0 ] || return 1

    magicnet_singbox_write_outbounds_from_json "$_tmp_outbounds" "$_out_file" || return 1
    printf '%s %s\n' "$_count" "0"
}

magicnet_singbox_write_outbounds_from_json() {
    _nodes_json="$1"
    _out_file="$2"
    _tags_file="${_out_file}.proxylink-tags"
    jq -r '.[].tag // empty' "$_nodes_json" >"$_tags_file" || return 1
    magicnet_singbox_build_region_groups "$_tags_file"
    _first_tag=$(sed -n '1p' "$_tags_file")

    {
        printf '  "outbounds": [\n'
        magicnet_singbox_emit_selector_block "$_tags_file" "$_first_tag"
        jq -c '.[]' "$_nodes_json" | while IFS= read -r _node; do
            printf ',\n    %s' "$_node"
        done
        printf ',\n'
        printf '    {\n      "type": "direct",\n      "tag": "direct"\n    },\n'
        printf '    {\n      "type": "block",\n      "tag": "block"\n    }\n'
        printf '  ],'
    } >"$_out_file"
}

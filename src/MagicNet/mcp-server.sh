#!/system/bin/sh
# shellcheck shell=ash

case "$0" in
    */*) MODDIR=${0%/*} ;;
    *) MODDIR=${MODDIR:-$(pwd)} ;;
esac

MCP_BIND="${MAGICNET_MCP_BIND:-127.0.0.1}"
MCP_PORT="${MAGICNET_MCP_PORT:-8765}"
CLI="${MODDIR}/cli"

mcp_json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/$/\\n/' | tr -d '\n' | sed 's/\\n$//'
}

mcp_response() {
    _id="$1"
    _body="$2"
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Type: application/json\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$_id" "$_body"
}

mcp_error() {
    _id="${1:-null}"
    _code="$2"
    _message="$3"
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Type: application/json\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}\n' "$_id" "$_code" "$_message"
}

mcp_http_error() {
    _status="$1"
    _message="$2"
    printf 'HTTP/1.1 %s\r\n' "$_status"
    printf 'Content-Type: text/plain\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    printf '%s\n' "$_message"
}

mcp_field() {
    _key="$1"
    sed -n "s/.*\"${_key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

mcp_id() {
    _id="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    [ -n "$_id" ] || _id="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\("[^"]*"\).*/\1/p')"
    [ -n "$_id" ] || _id="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\(null\).*/\1/p')"
    [ -n "$_id" ] && printf '%s\n' "$_id" || printf 'null\n'
}

mcp_tool_name() {
    sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

mcp_arg() {
    _key="$1"
    sed -n "s/.*\"arguments\"[[:space:]]*:[[:space:]]*{.*\"${_key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
    unset _key
}

mcp_path_safe() {
    _path="$1"
    case "$_path" in
        ""|/*|*../*|../*|*"/.."|*".."*) return 1 ;;
    esac
    return 0
}

mcp_module_path() {
    _rel="$1"
    mcp_path_safe "$_rel" || return 1
    printf '%s/%s\n' "$MODDIR" "$_rel"
    unset _rel
}

mcp_cli_text() {
    _command="$1"
    _text="$("$CLI" $_command 2>&1)"
    _rc=$?
    _escaped="$(printf '%s\nrc=%s\n' "$_text" "$_rc" | mcp_json_escape)"
    printf '{"content":[{"type":"text","text":"%s"}]}' "$_escaped"
}

mcp_file_text() {
    _text="$1"
    _escaped="$(printf '%s\n' "$_text" | mcp_json_escape)"
    printf '{"content":[{"type":"text","text":"%s"}]}' "$_escaped"
    unset _text _escaped
}

mcp_file_list() {
    _path="$(printf '%s\n' "$1" | sed 's#^/*##')"
    [ -n "$_path" ] || _path="."
    _full="$(mcp_module_path "$_path")" || { mcp_file_text "invalid path"; return; }
    if [ -d "$_full" ]; then
        mcp_file_text "$(find "$_full" -maxdepth 2 -mindepth 1 2>/dev/null | sed "s#^${MODDIR}/##" | head -200)"
    else
        mcp_file_text "not a directory: $_path"
    fi
    unset _path _full
}

mcp_file_read() {
    _path="$(printf '%s\n' "$1" | sed 's#^/*##')"
    _full="$(mcp_module_path "$_path")" || { mcp_file_text "invalid path"; return; }
    if [ -f "$_full" ]; then
        mcp_file_text "$(sed -n '1,240p' "$_full" 2>&1)"
    else
        mcp_file_text "not a file: $_path"
    fi
    unset _path _full
}

mcp_file_write() {
    _path="$(printf '%s\n' "$1" | sed 's#^/*##')"
    _content="$2"
    _full="$(mcp_module_path "$_path")" || { mcp_file_text "invalid path"; return; }
    mkdir -p "${_full%/*}" || { mcp_file_text "mkdir failed: ${_full%/*}"; return; }
    printf '%s' "$_content" >"$_full" || { mcp_file_text "write failed: $_path"; return; }
    chmod 0644 "$_full" 2>/dev/null || true
    mcp_file_text "wrote $_path"
    unset _path _content _full
}

mcp_dir_make() {
    _path="$(printf '%s\n' "$1" | sed 's#^/*##')"
    _full="$(mcp_module_path "$_path")" || { mcp_file_text "invalid path"; return; }
    mkdir -p "$_full" || { mcp_file_text "mkdir failed: $_path"; return; }
    mcp_file_text "created $_path"
    unset _path _full
}

mcp_tools() {
    cat <<'EOF'
{"tools":[
{"name":"magicnet_status","description":"Show MagicNet service status","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_health","description":"Run MagicNet health diagnostics","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_list","description":"Show MagicNet community and manual blocklist state","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_update","description":"Download and apply the community blocklist","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_pingtest","description":"Run MagicNet domestic and global connectivity checks","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_topology","description":"Show Android network interfaces, routes, forwarding and MagicNet topology","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_file_list","description":"List files under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"magicnet_file_read","description":"Read a text file under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"magicnet_file_write","description":"Hot-update a text file under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},
{"name":"magicnet_dir_make","description":"Create a directory under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}
]}
EOF
}

mcp_handle_jsonrpc() {
    _payload="$1"
    _id="$(printf '%s\n' "$_payload" | mcp_id)"
    _method="$(printf '%s\n' "$_payload" | mcp_field method)"
    case "$_method" in
        initialize)
            mcp_response "$_id" '{"protocolVersion":"2025-03-26","serverInfo":{"name":"magicnet","version":"1.0.0"},"capabilities":{"tools":{}}}'
            ;;
        tools/list)
            mcp_response "$_id" "$(mcp_tools)"
            ;;
        tools/call)
            _tool="$(printf '%s\n' "$_payload" | mcp_tool_name)"
            case "$_tool" in
                magicnet_status) mcp_response "$_id" "$(mcp_cli_text "service status")" ;;
                magicnet_health) mcp_response "$_id" "$(mcp_cli_text "health")" ;;
                magicnet_block_list) mcp_response "$_id" "$(mcp_cli_text "block list")" ;;
                magicnet_block_update) mcp_response "$_id" "$(mcp_cli_text "block update")" ;;
                magicnet_pingtest) mcp_response "$_id" "$(mcp_cli_text "pingtest")" ;;
                magicnet_topology) mcp_response "$_id" "$(mcp_cli_text "topology")" ;;
                magicnet_file_list) mcp_response "$_id" "$(mcp_file_list "$(printf '%s\n' "$_payload" | mcp_arg path)")" ;;
                magicnet_file_read) mcp_response "$_id" "$(mcp_file_read "$(printf '%s\n' "$_payload" | mcp_arg path)")" ;;
                magicnet_file_write) mcp_response "$_id" "$(mcp_file_write "$(printf '%s\n' "$_payload" | mcp_arg path)" "$(printf '%s\n' "$_payload" | mcp_arg content)")" ;;
                magicnet_dir_make) mcp_response "$_id" "$(mcp_dir_make "$(printf '%s\n' "$_payload" | mcp_arg path)")" ;;
                *) mcp_error "$_id" -32602 "unknown tool" ;;
            esac
            ;;
        notifications/initialized)
            mcp_response "$_id" '{}'
            ;;
        *)
            mcp_error "$_id" -32601 "method not found"
            ;;
    esac
}

mcp_handle_connection() {
    _headers=""
    _content_length=0
    IFS= read -r _request || exit 0
    _method=${_request%% *}
    while IFS= read -r _line; do
        _line=${_line%$(printf '\r')}
        [ -z "$_line" ] && break
        _headers="${_headers}
$_line"
        case "$_line" in
            [Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ll][Ee][Nn][Gg][Tt][Hh]:*)
                _content_length="$(printf '%s\n' "$_line" | sed 's/^[^:]*:[[:space:]]*//')"
                ;;
        esac
    done
    case "$_method" in
        POST)
            _payload="$(dd bs=1 count="$_content_length" 2>/dev/null)"
            mcp_handle_jsonrpc "$_payload"
            ;;
        GET)
            mcp_http_error "405 Method Not Allowed" "MagicNet MCP uses Streamable HTTP JSON-RPC POST at /mcp."
            ;;
        *)
            mcp_http_error "405 Method Not Allowed" "method not allowed"
            ;;
    esac
}

case "${1:-serve}" in
    serve|'')
        exec nc -s "$MCP_BIND" -p "$MCP_PORT" -L "$0" handle
        ;;
    handle)
        mcp_handle_connection
        ;;
    *)
        printf 'Usage: mcp-server.sh [serve]\n' >&2
        exit 1
        ;;
esac

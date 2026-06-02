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

mcp_cli_text() {
    _command="$1"
    _text="$("$CLI" $_command 2>&1)"
    _rc=$?
    _escaped="$(printf '%s\nrc=%s\n' "$_text" "$_rc" | mcp_json_escape)"
    printf '{"content":[{"type":"text","text":"%s"}]}' "$_escaped"
}

mcp_tools() {
    cat <<'EOF'
{"tools":[
{"name":"magicnet_status","description":"Show MagicNet service status","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_health","description":"Run MagicNet health diagnostics","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_list","description":"Show MagicNet community and manual blocklist state","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_update","description":"Download and apply the community blocklist","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_pingtest","description":"Run MagicNet domestic and global connectivity checks","inputSchema":{"type":"object","properties":{}}}
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

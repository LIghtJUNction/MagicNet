magicnet_ebpf_mixed_port() {
    if [ -n "${MAGICNET_EBPF_MIXED_PORT:-}" ]; then
        case "$MAGICNET_EBPF_MIXED_PORT" in
            *[!0-9]*|"") return 1 ;;
            *) printf '%s\n' "$MAGICNET_EBPF_MIXED_PORT"; return 0 ;;
        esac
    fi

    _ebpf_config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_ebpf_config" ] || return 1

    _ebpf_jq="${MODDIR}/bin/jq"
    if [ ! -x "$_ebpf_jq" ]; then
        _ebpf_jq="$(command -v jq 2>/dev/null || true)"
    fi
    [ -n "$_ebpf_jq" ] || return 1

    _ebpf_port=$(
        "$_ebpf_jq" -r '
            [
              .inbounds[]?
              | select((.type // "") == "mixed")
              | select((.tag // "") == "mixed-in" or (.listen // "") == "127.0.0.1" or (.listen // "") == "::1")
              | .listen_port
              | select(type == "number")
            ][0] // empty
        ' "$_ebpf_config" 2>/dev/null
    )
    case "$_ebpf_port" in
        *[!0-9]*|"")
            unset _ebpf_config _ebpf_jq _ebpf_port
            return 1
            ;;
        *) printf '%s\n' "$_ebpf_port" ;;
    esac
    unset _ebpf_config _ebpf_jq _ebpf_port
}

magicnet_ebpf_dns_port() {
    if [ -n "${MAGICNET_EBPF_DNS_PORT:-}" ]; then
        case "$MAGICNET_EBPF_DNS_PORT" in
            *[!0-9]*|"") return 1 ;;
            *) printf '%s\n' "$MAGICNET_EBPF_DNS_PORT"; return 0 ;;
        esac
    fi

    _ebpf_config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_ebpf_config" ] || return 1

    _ebpf_jq="${MODDIR}/bin/jq"
    if [ ! -x "$_ebpf_jq" ]; then
        _ebpf_jq="$(command -v jq 2>/dev/null || true)"
    fi
    [ -n "$_ebpf_jq" ] || return 1

    _ebpf_port=$(
        "$_ebpf_jq" -r '
            [
              .inbounds[]?
              | select((.tag // "") == "magicnet-ebpf-dns4-in" or (.tag // "") == "magicnet-ebpf-dns6-in")
              | .listen_port
              | select(type == "number")
            ][0] // empty
        ' "$_ebpf_config" 2>/dev/null
    )
    case "$_ebpf_port" in
        *[!0-9]*|"") printf '%s\n' "1053" ;;
        *) printf '%s\n' "$_ebpf_port" ;;
    esac
    unset _ebpf_config _ebpf_jq _ebpf_port
}

magicnet_ebpf_mixed_inbound_ready() {
    _ebpf_ready_port="$1"
    case "$_ebpf_ready_port" in
        *[!0-9]*|"")
            unset _ebpf_ready_port
            return 1
            ;;
    esac
    if magicnet_cmd_exists ss; then
        ss -lnt 2>/dev/null |
            awk -v port=":${_ebpf_ready_port}" '$0 ~ port { found = 1 } END { exit found ? 0 : 1 }'
        _ebpf_ready_rc=$?
        unset _ebpf_ready_port
        return "$_ebpf_ready_rc"
    fi
    if [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then
        _ebpf_ready_hex="$(printf '%04X' "$_ebpf_ready_port" 2>/dev/null)"
        { [ -r /proc/net/tcp ] && cat /proc/net/tcp; [ -r /proc/net/tcp6 ] && cat /proc/net/tcp6; } 2>/dev/null |
            awk -v port=":${_ebpf_ready_hex}" '$2 ~ port && $4 == "0A" { found = 1 } END { exit found ? 0 : 1 }'
        _ebpf_ready_rc=$?
        unset _ebpf_ready_port _ebpf_ready_hex
        return "$_ebpf_ready_rc"
    fi
    unset _ebpf_ready_port
    return 1
}

magicnet_ebpf_socket_listening() {
    _ebpf_socket_proto="$1"
    _ebpf_socket_port="$2"
    case "$_ebpf_socket_port" in
        *[!0-9]*|"")
            unset _ebpf_socket_proto _ebpf_socket_port
            return 1
            ;;
    esac
    case "$_ebpf_socket_proto" in
        tcp|udp) ;;
        *)
            unset _ebpf_socket_proto _ebpf_socket_port
            return 1
            ;;
    esac

    if magicnet_cmd_exists ss; then
        case "$_ebpf_socket_proto" in
            tcp) _ebpf_socket_ss_args="-lnt" ;;
            udp) _ebpf_socket_ss_args="-lnu" ;;
        esac
        # shellcheck disable=SC2086
        ss $_ebpf_socket_ss_args 2>/dev/null |
            awk -v port=":${_ebpf_socket_port}" '$0 ~ port { found = 1 } END { exit found ? 0 : 1 }'
        _ebpf_socket_rc=$?
        unset _ebpf_socket_proto _ebpf_socket_port _ebpf_socket_ss_args
        return "$_ebpf_socket_rc"
    fi

    _ebpf_socket_hex="$(printf '%04X' "$_ebpf_socket_port" 2>/dev/null)"
    case "$_ebpf_socket_proto" in
        tcp)
            { [ -r /proc/net/tcp ] && cat /proc/net/tcp; [ -r /proc/net/tcp6 ] && cat /proc/net/tcp6; } 2>/dev/null |
                awk -v port=":${_ebpf_socket_hex}" '$2 ~ port && $4 == "0A" { found = 1 } END { exit found ? 0 : 1 }'
            ;;
        udp)
            { [ -r /proc/net/udp ] && cat /proc/net/udp; [ -r /proc/net/udp6 ] && cat /proc/net/udp6; } 2>/dev/null |
                awk -v port=":${_ebpf_socket_hex}" '$2 ~ port { found = 1 } END { exit found ? 0 : 1 }'
            ;;
    esac
    _ebpf_socket_rc=$?
    unset _ebpf_socket_proto _ebpf_socket_port _ebpf_socket_hex
    return "$_ebpf_socket_rc"
}

magicnet_ebpf_dns_inbound_ready() {
    _ebpf_ready_port="$1"
    magicnet_ebpf_socket_listening tcp "$_ebpf_ready_port" &&
        magicnet_ebpf_socket_listening udp "$_ebpf_ready_port"
    _ebpf_ready_rc=$?
    unset _ebpf_ready_port
    return "$_ebpf_ready_rc"
}

magicnet_ebpf_wait_for_singbox_inbounds() {
    _ebpf_wait_mixed_port="$1"
    _ebpf_wait_dns_port="$2"
    _ebpf_wait=0
    while [ "$_ebpf_wait" -lt "${MAGICNET_EBPF_INBOUND_TIMEOUT:-8}" ]; do
        if magicnet_ebpf_dns_inbound_ready "$_ebpf_wait_dns_port" &&
            magicnet_ebpf_mixed_inbound_ready "$_ebpf_wait_mixed_port"; then
            unset _ebpf_wait_mixed_port _ebpf_wait_dns_port _ebpf_wait
            return 0
        fi
        _ebpf_wait=$((_ebpf_wait + 1))
        sleep 1
    done
    unset _ebpf_wait_mixed_port _ebpf_wait_dns_port _ebpf_wait
    return 1
}

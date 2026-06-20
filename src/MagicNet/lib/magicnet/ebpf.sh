# shellcheck shell=ash

magicnet_ebpf_state_dir() {
    printf '%s\n' "${MODDIR}/.state/ebpf"
}

magicnet_ebpf_guard_pid_file() {
    printf '%s\n' "$(magicnet_ebpf_state_dir)/guard.pid"
}

magicnet_ebpf_loader() {
    printf '%s\n' "${MODDIR}/bin/magicnet-ebpf"
}

magicnet_ebpf_cgroup_path() {
    if [ -n "${MAGICNET_EBPF_CGROUP:-}" ] && [ -d "$MAGICNET_EBPF_CGROUP" ]; then
        printf '%s\n' "$MAGICNET_EBPF_CGROUP"
        return 0
    fi
    if [ -d /sys/fs/cgroup/apps ]; then
        printf '%s\n' "/sys/fs/cgroup/apps"
    else
        printf '%s\n' "/sys/fs/cgroup"
    fi
}

magicnet_ebpf_dns_cgroup_path() {
    if [ -n "${MAGICNET_EBPF_DNS_CGROUP:-}" ] && [ -d "$MAGICNET_EBPF_DNS_CGROUP" ]; then
        printf '%s\n' "$MAGICNET_EBPF_DNS_CGROUP"
        return 0
    fi
    printf '%s\n' "/sys/fs/cgroup"
}

magicnet_ebpf_bpffs_ready() {
    [ -d /sys/fs/bpf ] || return 1
    mount 2>/dev/null | grep -q ' on /sys/fs/bpf type bpf '
}

magicnet_ebpf_cgroup_ready() {
    [ -d "$(magicnet_ebpf_cgroup_path)" ] || return 1
    [ -d "$(magicnet_ebpf_dns_cgroup_path)" ] || return 1
    if [ -r /proc/config.gz ]; then
        zcat /proc/config.gz 2>/dev/null | grep -qx 'CONFIG_CGROUP_BPF=y' || return 1
        zcat /proc/config.gz 2>/dev/null | grep -qx 'CONFIG_BPF_SYSCALL=y' || return 1
    fi
    return 0
}

magicnet_ebpf_loader_ready() {
    [ -x "$(magicnet_ebpf_loader)" ]
}

magicnet_ebpf_redirect_ready() {
    magicnet_ebpf_loader_ready || return 1
    "$(magicnet_ebpf_loader)" supports-redirect >/dev/null 2>&1
}

magicnet_ebpf_probe_ready() {
    magicnet_ebpf_loader_ready || return 1
    "$(magicnet_ebpf_loader)" probe \
        --cgroup "$(magicnet_ebpf_cgroup_path)" \
        --dns-cgroup "$(magicnet_ebpf_dns_cgroup_path)" >/dev/null 2>&1
}

magicnet_ebpf_promote_netd() {
    magicnet_ebpf_loader_ready || return 1
    "$(magicnet_ebpf_loader)" promote-netd --cgroup /sys/fs/cgroup >/dev/null 2>&1
}

magicnet_ebpf_demote_netd() {
    magicnet_ebpf_loader_ready || return 1
    "$(magicnet_ebpf_loader)" demote-netd --cgroup /sys/fs/cgroup >/dev/null 2>&1
}

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
        *[!0-9]*|"")
            printf '%s\n' "1053"
            ;;
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
    _ebpf_ready_proto="$1"
    _ebpf_ready_port="$2"
    case "$_ebpf_ready_port" in
        *[!0-9]*|"")
            unset _ebpf_ready_proto _ebpf_ready_port
            return 1
            ;;
    esac
    case "$_ebpf_ready_proto" in
        tcp|udp) ;;
        *)
            unset _ebpf_ready_proto _ebpf_ready_port
            return 1
            ;;
    esac

    if magicnet_cmd_exists ss; then
        case "$_ebpf_ready_proto" in
            tcp) _ebpf_ss_args="-lnt" ;;
            udp) _ebpf_ss_args="-lnu" ;;
        esac
        # shellcheck disable=SC2086
        ss $_ebpf_ss_args 2>/dev/null |
            awk -v port=":${_ebpf_ready_port}" '$0 ~ port { found = 1 } END { exit found ? 0 : 1 }'
        _ebpf_ready_rc=$?
        unset _ebpf_ready_proto _ebpf_ready_port _ebpf_ss_args
        return "$_ebpf_ready_rc"
    fi

    _ebpf_ready_hex="$(printf '%04X' "$_ebpf_ready_port" 2>/dev/null)"
    case "$_ebpf_ready_proto" in
        tcp)
            { [ -r /proc/net/tcp ] && cat /proc/net/tcp; [ -r /proc/net/tcp6 ] && cat /proc/net/tcp6; } 2>/dev/null |
                awk -v port=":${_ebpf_ready_hex}" '$2 ~ port && $4 == "0A" { found = 1 } END { exit found ? 0 : 1 }'
            ;;
        udp)
            { [ -r /proc/net/udp ] && cat /proc/net/udp; [ -r /proc/net/udp6 ] && cat /proc/net/udp6; } 2>/dev/null |
                awk -v port=":${_ebpf_ready_hex}" '$2 ~ port { found = 1 } END { exit found ? 0 : 1 }'
            ;;
    esac
    _ebpf_ready_rc=$?
    unset _ebpf_ready_proto _ebpf_ready_port _ebpf_ready_hex
    return "$_ebpf_ready_rc"
}

magicnet_ebpf_dns_inbound_ready() {
    _ebpf_ready_port="$1"
    magicnet_ebpf_socket_listening tcp "$_ebpf_ready_port" &&
        magicnet_ebpf_socket_listening udp "$_ebpf_ready_port"
    _ebpf_ready_rc=$?
    unset _ebpf_ready_port
    return "$_ebpf_ready_rc"
}

magicnet_ebpf_supported() {
    magicnet_ebpf_bpffs_ready &&
        magicnet_ebpf_cgroup_ready &&
        magicnet_ebpf_loader_ready &&
        magicnet_ebpf_probe_ready
}

magicnet_ebpf_strict_mode() {
    [ "$(magicnet_transparent_mode)" = "ebpf" ]
}

magicnet_ebpf_daemon_running() {
    _ebpf_expected_port="$1"
    _ebpf_expected_dns_port="$2"
    _ebpf_guard_pid_file="$(magicnet_ebpf_guard_pid_file)"
    _ebpf_state_file="$(magicnet_ebpf_state_dir)/magicnet-ebpf.state"
    [ -f "$_ebpf_guard_pid_file" ] && [ -f "$_ebpf_state_file" ] || {
        unset _ebpf_expected_port _ebpf_expected_dns_port _ebpf_guard_pid_file _ebpf_state_file
        return 1
    }
    _ebpf_pid="$(sed -n '1p' "$_ebpf_guard_pid_file" 2>/dev/null)"
    case "$_ebpf_pid" in
        *[!0-9]*|"")
            unset _ebpf_expected_port _ebpf_expected_dns_port _ebpf_guard_pid_file _ebpf_state_file _ebpf_pid
            return 1
            ;;
    esac
    kill -0 "$_ebpf_pid" >/dev/null 2>&1 || {
        unset _ebpf_expected_port _ebpf_expected_dns_port _ebpf_guard_pid_file _ebpf_state_file _ebpf_pid
        return 1
    }
    grep -q '^mode=tcp-bridge$' "$_ebpf_state_file" 2>/dev/null || {
        unset _ebpf_expected_port _ebpf_expected_dns_port _ebpf_guard_pid_file _ebpf_state_file _ebpf_pid
        return 1
    }
    grep -q "^mixed_port=${_ebpf_expected_port}$" "$_ebpf_state_file" 2>/dev/null || {
        unset _ebpf_expected_port _ebpf_expected_dns_port _ebpf_guard_pid_file _ebpf_state_file _ebpf_pid
        return 1
    }
    grep -q "^dns_port=${_ebpf_expected_dns_port}$" "$_ebpf_state_file" 2>/dev/null || {
        unset _ebpf_expected_port _ebpf_expected_dns_port _ebpf_guard_pid_file _ebpf_state_file _ebpf_pid
        return 1
    }
    unset _ebpf_expected_port _ebpf_expected_dns_port _ebpf_guard_pid_file _ebpf_state_file _ebpf_pid
    return 0
}

magicnet_ebpf_dns_redirect_running() {
    _ebpf_state_file="$(magicnet_ebpf_state_dir)/magicnet-ebpf.state"
    [ -f "$_ebpf_state_file" ] || {
        unset _ebpf_state_file
        return 1
    }
    grep -Eq '^(dns_udp4|dns_udp6|root_dns_tcp4|root_dns_tcp6|root_dns_udp4|root_dns_udp6)=attached$' "$_ebpf_state_file" 2>/dev/null
    _ebpf_dns_rc=$?
    unset _ebpf_state_file
    return "$_ebpf_dns_rc"
}

magicnet_ebpf_guard_stop() {
    _ebpf_guard_pid_file="$(magicnet_ebpf_guard_pid_file)"
    if [ -f "$_ebpf_guard_pid_file" ]; then
        _ebpf_guard_pid="$(sed -n '1p' "$_ebpf_guard_pid_file" 2>/dev/null)"
        case "$_ebpf_guard_pid" in
            *[!0-9]*|"") ;;
            *)
                kill "$_ebpf_guard_pid" >/dev/null 2>&1 || true
                _ebpf_guard_wait=0
                while [ "$_ebpf_guard_wait" -lt 3 ]; do
                    kill -0 "$_ebpf_guard_pid" >/dev/null 2>&1 || break
                    _ebpf_guard_wait=$((_ebpf_guard_wait + 1))
                    sleep 1
                done
                kill -0 "$_ebpf_guard_pid" >/dev/null 2>&1 &&
                    kill -9 "$_ebpf_guard_pid" >/dev/null 2>&1 || true
                ;;
        esac
        rm -f "$_ebpf_guard_pid_file" 2>/dev/null || true
    fi
    unset _ebpf_guard_pid_file _ebpf_guard_pid _ebpf_guard_wait
}

magicnet_ebpf_kill_orphans() {
    for _ebpf_proc in /proc/[0-9]*; do
        [ -r "${_ebpf_proc}/comm" ] || continue
        _ebpf_comm="$(cat "${_ebpf_proc}/comm" 2>/dev/null)"
        [ "$_ebpf_comm" = "magicnet-ebpf" ] || continue
        _ebpf_pid="${_ebpf_proc#/proc/}"
        kill "$_ebpf_pid" >/dev/null 2>&1 || true
    done
    sleep 1
    for _ebpf_proc in /proc/[0-9]*; do
        [ -r "${_ebpf_proc}/comm" ] || continue
        _ebpf_comm="$(cat "${_ebpf_proc}/comm" 2>/dev/null)"
        [ "$_ebpf_comm" = "magicnet-ebpf" ] || continue
        _ebpf_pid="${_ebpf_proc#/proc/}"
        kill -9 "$_ebpf_pid" >/dev/null 2>&1 || true
    done
    unset _ebpf_proc _ebpf_comm _ebpf_pid
}

magicnet_ebpf_cleanup() {
    if magicnet_ebpf_loader_ready; then
        "$(magicnet_ebpf_loader)" detach \
            --cgroup "$(magicnet_ebpf_cgroup_path)" \
            --dns-cgroup "$(magicnet_ebpf_dns_cgroup_path)" >/dev/null 2>&1 || true
        magicnet_ebpf_demote_netd >/dev/null 2>&1 || true
    fi
    magicnet_ebpf_guard_stop
    magicnet_ebpf_kill_orphans
    rm -rf "$(magicnet_ebpf_state_dir)" 2>/dev/null || true
}

magicnet_ebpf_start_daemon() {
    _ebpf_mixed_port="$1"
    _ebpf_dns_port="$2"
    mkdir -p "$(magicnet_ebpf_state_dir)" || return 1
    magicnet_ebpf_guard_stop
    rm -f "$(magicnet_ebpf_state_dir)/magicnet-ebpf.state" 2>/dev/null || true
    "$(magicnet_ebpf_loader)" attach \
        --mixed-port "$_ebpf_mixed_port" \
        --dns-port "$_ebpf_dns_port" \
        --dns-redirect \
        --cgroup "$(magicnet_ebpf_cgroup_path)" \
        --dns-cgroup "$(magicnet_ebpf_dns_cgroup_path)" \
        --state "$(magicnet_ebpf_state_dir)" \
        >"$(magicnet_ebpf_state_dir)/daemon.log" 2>&1 &
    printf '%s\n' "$!" >"$(magicnet_ebpf_guard_pid_file)"
    _ebpf_wait=0
    while [ "$_ebpf_wait" -lt "${MAGICNET_EBPF_START_TIMEOUT:-5}" ]; do
        if [ -f "$(magicnet_ebpf_state_dir)/magicnet-ebpf.state" ] &&
            grep -q '^mode=tcp-bridge$' "$(magicnet_ebpf_state_dir)/magicnet-ebpf.state" 2>/dev/null; then
            unset _ebpf_mixed_port _ebpf_dns_port _ebpf_wait
            return 0
        fi
        _ebpf_pid="$(sed -n '1p' "$(magicnet_ebpf_guard_pid_file)" 2>/dev/null)"
        if [ -n "$_ebpf_pid" ] && ! kill -0 "$_ebpf_pid" >/dev/null 2>&1; then
            unset _ebpf_mixed_port _ebpf_dns_port _ebpf_wait _ebpf_pid
            return 1
        fi
        _ebpf_wait=$((_ebpf_wait + 1))
        sleep 1
    done
    unset _ebpf_mixed_port _ebpf_dns_port _ebpf_wait _ebpf_pid
    return 1
}

magicnet_enable_ebpf() {
    _ebpf_mode="$(magicnet_transparent_mode)"
    case "$_ebpf_mode" in
        auto|ebpf) ;;
        *)
            magicnet_ebpf_cleanup
            unset _ebpf_mode
            return 0
            ;;
    esac

    _ebpf_strict=0
    [ "$_ebpf_mode" = "ebpf" ] && _ebpf_strict=1

    magicnet_ebpf_fail() {
        _msg="$1"
        magicnet_warn "$_msg"
        magicnet_ebpf_cleanup
        if [ "$_ebpf_strict" = "1" ]; then
            unset _msg
            return 1
        fi
        magicnet_warn "auto transparent mode falls back to TUN"
        unset _msg
        return 0
    }

    magicnet_ebpf_bpffs_ready || {
        magicnet_ebpf_fail "eBPF bpffs is not mounted"
        return $?
    }
    magicnet_ebpf_cgroup_ready || {
        magicnet_ebpf_fail "CONFIG_CGROUP_BPF or CONFIG_BPF_SYSCALL is unavailable"
        return $?
    }
    magicnet_ebpf_loader_ready || {
        magicnet_ebpf_fail "magicnet-ebpf loader is not bundled yet"
        return $?
    }
    magicnet_ebpf_redirect_ready || {
        magicnet_ebpf_fail "eBPF TCP bridge data plane is unavailable"
        return $?
    }
    _ebpf_mixed_port="$(magicnet_ebpf_mixed_port)" || {
        magicnet_ebpf_fail "cannot resolve sing-box mixed inbound port"
        return $?
    }
    _ebpf_dns_port="$(magicnet_ebpf_dns_port)" || {
        magicnet_ebpf_fail "cannot resolve sing-box MagicNet DNS inbound port"
        return $?
    }
    magicnet_ebpf_dns_inbound_ready "$_ebpf_dns_port" || {
        magicnet_ebpf_fail "sing-box eBPF DNS inbound is not listening on tcp/udp 127.0.0.1:${_ebpf_dns_port}"
        return $?
    }
    magicnet_ebpf_mixed_inbound_ready "$_ebpf_mixed_port" || {
        magicnet_ebpf_fail "sing-box mixed inbound is not listening on 127.0.0.1:${_ebpf_mixed_port}"
        return $?
    }
    if magicnet_ebpf_daemon_running "$_ebpf_mixed_port" "$_ebpf_dns_port"; then
        magicnet_log "eBPF transparent TCP bridge already attached"
        unset _ebpf_mixed_port _ebpf_dns_port _ebpf_mode _ebpf_strict
        return 0
    fi
    magicnet_ebpf_probe_ready || {
        if [ "$_ebpf_strict" = "1" ]; then
            magicnet_ebpf_fail "eBPF cgroup/connect attach probe failed"
            return $?
        else
            magicnet_ebpf_fail "eBPF cgroup/connect attach probe failed"
            return $?
        fi
    }

    magicnet_ebpf_start_daemon "$_ebpf_mixed_port" "$_ebpf_dns_port" || {
        magicnet_ebpf_fail "eBPF cgroup/connect TCP bridge attach failed"
        return $?
    }
    if ! magicnet_ebpf_dns_redirect_running; then
        magicnet_ebpf_fail "eBPF DNS redirect is unavailable; refusing TCP-only transparent mode"
        return $?
    fi
    magicnet_log "eBPF transparent TCP bridge attached through cgroup hooks"
    unset _ebpf_mixed_port _ebpf_dns_port _ebpf_mode _ebpf_strict
}

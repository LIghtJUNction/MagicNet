#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=src/MagicNet/lib/magicnet/network.sh
. "${NETWORK_SOURCE:-$ROOT/src/MagicNet/lib/magicnet/network.sh}"
magicnet_warn() { printf '%s\n' "$*"; }
magicnet_log() { :; }
magicnet_cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# Exercise the executable path, not the function-double fast path.
(
    mkdir -p "$WORK/bin"
    cat >"$WORK/bin/iptables" <<'STUB'
#!/bin/sh
[ "$1 $2" = '-w 1' ] || exit 4
exit 0
STUB
    cp "$WORK/bin/iptables" "$WORK/bin/ip6tables"
    chmod +x "$WORK/bin/iptables" "$WORK/bin/ip6tables"
    export PATH="$WORK/bin:$PATH"
    magicnet_iptables_cmd -t nat -L
    magicnet_ip6tables_cmd -L
)

# Empty, successfully inspected rulesets outrank a stale saved interface set.
(
    MODDIR="$WORK/empty"
    mkdir -p "$MODDIR/.state"
    printf '%s\n' wlan0 >"$(magicnet_dns_leak_guard_state_file)"
    iptables() {
        case "$1" in
        -S) printf '%s\n' '-P OUTPUT ACCEPT' ;;
        -D | -C) printf '%s\n' 'missing REJECT extension' >&2; return 2 ;;
        esac
    }
    ip6tables() { iptables "$@"; }
    MAGIC_DNS_LEAK_GUARD=0
    magicnet_enable_dns_leak_guard
    [ ! -f "$(magicnet_dns_leak_guard_state_file)" ]
)

# An unsuccessful inspection must still use saved interfaces and fail closed.
(
    MODDIR="$WORK/blocked"
    mkdir -p "$MODDIR/.state"
    printf '%s\n' oldwlan0 >"$(magicnet_dns_leak_guard_state_file)"
    iptables() { return 4; }
    ip6tables() { return 4; }
    magicnet_collect_physical_egress_ifaces() { printf '%s\n' wlan0; }
    if magicnet_disable_dns_leak_guard; then
        printf '%s\n' 'inaccessible saved guard rules were treated as removed' >&2
        exit 1
    fi
    [ -f "$(magicnet_dns_leak_guard_state_file)" ]
)

# A real installation failure must retain its exit code and kernel diagnostic.
(
    iptables() {
        case "$*" in *' -C '*) return 1 ;; esac
        printf '%s\n' 'Permission denied' >&2
        return 4
    }
    rc=0
    magicnet_iptables_ensure -t nat magicnet-dns-output -p udp --dport 53 -j REDIRECT \
        >"$WORK/diagnostic" || rc=$?
    [ "$rc" -eq 4 ]
    grep -Fq 'Permission denied' "$WORK/diagnostic"
    grep -Fq 'exit 4' "$WORK/diagnostic"
)

# IPv4-first tolerates missing IPv6 NAT, never a required IPv4 rule failure.
(
    MODDIR="$WORK/capture"
    mkdir -p "$MODDIR"
    magicnet_transparent_mode() { printf '%s\n' tun; }
    magicnet_dns_profile() { printf '%s\n' default; }
    magicnet_dns_capture_singbox_mark() { printf '%s\n' 255; }
    magicnet_dns_capture_singbox_udp_marked() { return 1; }
    magicnet_ipv6_mode() { printf '%s\n' prefer_ipv4; }
    magicnet_hotspot_reconcile() { :; }
    magicnet_disable_dns_capture() { :; }
    magicnet_disable_dns_leak_guard() { :; }
    iptables() {
        case "$*" in
        *' -C '*) return 1 ;;
        *' -A '*) return "${install_rc:-0}" ;;
        esac
        return 0
    }
    ip6tables() { return 3; }
    MAGIC_DNS_LEAK_GUARD=0
    magicnet_after_kernel_start_deferred_unlocked >"$WORK/ipv4-first"
    grep -Fq 'IPv6 DNS capture unavailable' "$WORK/ipv4-first"
    install_rc=4
    if magicnet_after_kernel_start_deferred_unlocked >"$WORK/ipv4-failure"; then
        printf '%s\n' 'required IPv4 capture failure was ignored' >&2
        exit 1
    fi
    grep -Fq 'Post-start network controls failed: dns-capture' "$WORK/ipv4-failure"
)

# Verify actual lifecycle wrappers, including their rollback and status result.
(
    # shellcheck disable=SC1091
    . "$ROOT/src/MagicNet/lib/magicnet/core.sh"
    magicnet_detach_pid_from_app_cgroup() { :; }
    magicnet_kernel_start_preamble() { :; }
    magicnet_kernel_running() { return 1; }
    magicnet_disable_dns_capture() { :; }
    magicnet_disable_dns_leak_guard() { :; }
    magicnet_require_subscription_or_stop() { :; }
    magicnet_with_sub_config_lock() { "$@"; }
    magicnet_start_singbox_unlocked() { return "${start_rc:-0}"; }
    magicnet_after_kernel_start_unlocked() { return 1; }
    import() { :; }
    singbox_stop() { touch "$WORK/stopped"; }
    rc=0
    magicnet_start_kernel >"$WORK/startup-log" || rc=$?
    [ "$rc" -eq 1 ] && [ -f "$WORK/stopped" ]
    grep -Fq 'post-start network initialization failed' "$WORK/startup-log"
    if grep -Fq 'No supported sing-box core found' "$WORK/startup-log"; then
        printf '%s\n' 'network failure was mislabeled as a missing core' >&2
        exit 1
    fi
    start_rc=2
    rc=0
    magicnet_start_kernel >"$WORK/unknown-log" || rc=$?
    [ "$rc" -eq 2 ]
)
printf '%s\n' 'DNS startup compatibility regressions passed'

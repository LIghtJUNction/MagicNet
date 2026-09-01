#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-ebpf-mode.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 127
  }
}
need jq
need sha256sum

HOST_JQ="$(command -v jq)"
MODDIR="$WORK/module"
MOCK_BIN="$WORK/bin"
MOCK_LOG="$WORK/mock.log"
export MODDIR MODPATH="$MODDIR" MAGICNET_TEST_EBPF_LOG="$MOCK_LOG"
cp -a "$ROOT/src/MagicNet" "$MODDIR"
mkdir -p "$MOCK_BIN" "$MODDIR/bin" "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box"
ln -sf "$HOST_JQ" "$MODDIR/bin/jq"
: >"$MOCK_LOG"

cat >"$MOCK_BIN/sing-box" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'sing-box %s\n' "$*" >>"${MAGICNET_TEST_EBPF_LOG:?}"
case "${1:-} ${2:-} ${3:-}" in
    "tools ebpf status")
        [ "${MAGICNET_TEST_EBPF_PROBE_FAIL:-0}" != 1 ]
        printf '%s\n' '{"result":"supported","active_programs":[]}'
        ;;
    "check "*)
        [ "${MAGICNET_TEST_SINGBOX_CHECK_FAIL:-0}" != 1 ]
        ;;
esac
exit 0
SH
chmod +x "$MOCK_BIN/sing-box"
cp "$MOCK_BIN/sing-box" "$MODDIR/bin/sing-box"
export PATH="$MOCK_BIN:$MODDIR/bin:$PATH"

# Load the same aggregate shell surface used by the installed module. Device
# primitives are overridden below; no command is allowed to touch a real link.
set +u
# shellcheck disable=SC1091
. "$MODDIR/lib/kamfw/.kamfwrc"
import __runtime__
# shellcheck disable=SC1091
. "$MODDIR/lib/magicnet.sh"
set -u

magicnet_warn() { :; }
magicnet_info() { :; }
magicnet_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
magicnet_tun_mtu() { printf '%s\n' 1420; }
magicnet_udp_timeout() { printf '%s\n' 7m; }
magicnet_ipv6_mode() { printf '%s\n' "${MAGICNET_TEST_IPV6_MODE:-prefer_ipv4}"; }
magicnet_singbox_dns_strategy_for_mode() { printf '%s\n' "${MAGICNET_TEST_IPV6_MODE:-prefer_ipv4}"; }
magicnet_hotspot_proxy_enabled() { [ "${MAGICNET_TEST_HOTSPOT_PROXY:-0}" = 1 ]; }
magicnet_hotspot_active_networks() { printf '%s' "${MAGICNET_TEST_HOTSPOT_NETWORKS:-}"; }
magicnet_iface_exists() {
  case "$1" in
  wlan2) [[ "${MAGICNET_TEST_HOTSPOT_NETWORKS:-}" == *'wlan2|'* ]] ;;
  usb0) [[ "${MAGICNET_TEST_HOTSPOT_NETWORKS:-}" == *'usb0|'* ]] ;;
  magicnet0) return 1 ;;
  *) return 1 ;;
  esac
}

write_base_config() {
  cat >"$MODDIR/.config/sing-box/config.json" <<'JSON'
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7892},
    {"type": "tun", "tag": "tun-in", "interface_name": "magicnet0", "address": ["172.19.0.1/30"], "auto_route": true, "gso": true},
    {"type": "direct", "tag": "magicnet-dns-in", "listen": "127.0.0.1", "listen_port": 1053}
  ],
  "route": {"rules": [
    {"inbound": ["mixed-in", "tun-in"], "action": "sniff"},
    {"inbound": ["magicnet-dns-in"], "action": "hijack-dns"},
    {"domain_suffix": ["example.org"], "outbound": "direct"}
  ]}
}
JSON
  chmod 600 "$MODDIR/.config/sing-box/config.json"
}

set_mode_file() {
  printf 'MAGICNET_TRANSPARENT_MODE=%s\n' "$1" >"$MODDIR/.config/magicnet/transparent-mode.conf"
  chmod 600 "$MODDIR/.config/magicnet/transparent-mode.conf"
}

apply_transparent() {
  magicnet_singbox_apply_transparent_mode
}

validate_transparent() {
  magicnet_validate_singbox_transparent_config
}

assert_managed_ebpf() {
  local expected_mode="$1"
  local expected_interface="${2:-}"
  local expected_cidr="${3:-}"
  local expected_ipv6="$4"
  # The jq program is intentionally single-quoted; all shell values enter as args.
  # shellcheck disable=SC2016
  "$HOST_JQ" -e \
    --arg mode "$expected_mode" \
    --arg iface "$expected_interface" \
    --arg cidr "$expected_cidr" \
    --argjson ipv6 "$expected_ipv6" '
      ([.inbounds[] | select(.tag == "tun-in")] | length) == 1
      and ([.inbounds[] | select(.type == "ebpf")] | length) == 1
      and (.inbounds[] | select(.tag == "tun-in")
        | .type == "ebpf"
          and .mode == $mode
          and .network == ["tcp", "udp"]
          and .udp_timeout == "7m"
          and .local.dns_mode == "hijack"
          and .local.ipv6 == $ipv6
          and .shared.dns_mode == "respect_policy"
          and .shared.interface == (if $iface == "" then [] else [$iface] end)
          and .shared.include_source_cidr == (if $cidr == "" then [] else [$cidr] end)
          and .shared.ipv6 == $ipv6
          and .shared.advanced.tc_priority == 1)
      and ([.route.rules[] | select(
        .inbound == ["tun-in"] and .port == 53 and .action == "hijack-dns"
      )] | length) == 1
      and ([.route.rules[] | select(.action == "sniff")][0].inbound == ["mixed-in", "tun-in"])
    ' "$MODDIR/.config/sing-box/config.json" >/dev/null
}

write_base_config
set_mode_file ebpf
export MAGICNET_TEST_IPV6_MODE=prefer_ipv4
export MAGICNET_TEST_HOTSPOT_PROXY=0
export MAGICNET_TEST_HOTSPOT_NETWORKS=''
: >"$MOCK_LOG"
apply_transparent
assert_managed_ebpf hybrid '' '' true
validate_transparent
rg -q '^sing-box tools ebpf status ' "$MOCK_LOG"
rg -q '^sing-box check ' "$MOCK_LOG"

# Reapplying the same effective mode is byte-idempotent and never duplicates
# the stable managed tag.
first_sum="$(sha256sum "$MODDIR/.config/sing-box/config.json")"
apply_transparent
second_sum="$(sha256sum "$MODDIR/.config/sing-box/config.json")"
[[ "$first_sum" == "$second_sum" ]]

# Switching back restores the previous TUN-specific inbound instead of
# replacing it with a newly generated object. Canonical fields remain owned by
# MagicNet while supported user tuning survives the round trip.
set_mode_file tun
apply_transparent
"$HOST_JQ" -e '
  .inbounds[] | select(.tag == "tun-in")
  | .type == "tun" and .interface_name == "magicnet0" and .gso == true
' "$MODDIR/.config/sing-box/config.json" >/dev/null
set_mode_file ebpf
apply_transparent
assert_managed_ebpf hybrid '' '' true

# A real hotspot tuple populates the default hybrid shared path. The interface
# and source CIDR must come from the same fixture; wlan0 is deliberately absent
# and must never be guessed.
export MAGICNET_TEST_HOTSPOT_PROXY=1
export MAGICNET_TEST_HOTSPOT_NETWORKS=$'wlan2|192.168.43.0/24\n'
apply_transparent
assert_managed_ebpf hybrid wlan2 192.168.43.0/24 true
if rg -q 'wlan0' "$MODDIR/.config/sing-box/config.json" "$MOCK_LOG"; then
  printf '%s\n' 'eBPF hotspot mode guessed wlan0' >&2
  exit 1
fi

# Interface loss keeps hybrid/local cgroup active while clearing the shared
# selection. The durable pending marker prevents status from claiming that
# shared TC is already active.
export MAGICNET_TEST_HOTSPOT_NETWORKS=''
apply_transparent
assert_managed_ebpf hybrid '' '' true
[[ "$(<"$MODDIR/.state/transparent-ebpf/shared.pending")" == pending ]]
[[ ! -s "$MODDIR/.state/transparent-ebpf/shared-interfaces.list" ]]

# Recovery on a different real downstream link switches the shared attachment;
# the stale wlan2 tuple must not survive.
export MAGICNET_TEST_HOTSPOT_NETWORKS=$'usb0|192.168.44.0/24\n'
apply_transparent
assert_managed_ebpf hybrid usb0 192.168.44.0/24 true
[[ "$(<"$MODDIR/.state/transparent-ebpf/shared-interfaces.list")" == usb0 ]]
[[ ! -e "$MODDIR/.state/transparent-ebpf/shared.pending" ]]
if rg -q 'wlan2|192\.168\.43\.0/24|wlan0' "$MODDIR/.config/sing-box/config.json"; then
  printf '%s\n' 'hybrid recovery retained a stale or guessed interface' >&2
  exit 1
fi

# IPv4-only applies equally to both eBPF paths.
export MAGICNET_TEST_IPV6_MODE=ipv4_only
apply_transparent
assert_managed_ebpf hybrid usb0 192.168.44.0/24 false

# Probe and candidate validation failures are visible. Exact rollback of the
# active mode/config is exercised through the lifecycle transaction below in
# fake-magisk-smoke.sh, where the old generation is available to restart.
export MAGICNET_TEST_EBPF_PROBE_FAIL=1
if validate_transparent; then
  printf '%s\n' 'eBPF validation ignored a failed tools ebpf status probe' >&2
  exit 1
fi
unset MAGICNET_TEST_EBPF_PROBE_FAIL
export MAGICNET_TEST_SINGBOX_CHECK_FAIL=1
if validate_transparent; then
  printf '%s\n' 'eBPF validation ignored sing-box check failure' >&2
  exit 1
fi
unset MAGICNET_TEST_SINGBOX_CHECK_FAIL

# Status refresh publishes only current attachment evidence and removes stale
# evidence if the bounded probe fails.
magicnet_ebpf_refresh_active_report
"$HOST_JQ" -e '
  .active_programs == []
  and .active_state_error == ""
  and .result == "supported"
  and ((keys | sort) == ["active_programs", "active_state_error", "result"])
' "$MODDIR/.state/transparent-ebpf/probe.json" >/dev/null
export MAGICNET_TEST_EBPF_PROBE_FAIL=1
if magicnet_ebpf_refresh_active_report; then
  printf '%s\n' 'eBPF active attachment refresh ignored a failed bounded probe' >&2
  exit 1
fi
[[ ! -e "$MODDIR/.state/transparent-ebpf/probe.json" ]]
unset MAGICNET_TEST_EBPF_PROBE_FAIL

# Interrupted/preflight rollback restores the eBPF runtime evidence together
# with mode/config. Target TUN rendering clears these files before the old core
# is stopped, so omitting them from the journal makes a failed switch appear
# degraded even though the old eBPF generation is still running.
STATE_DIR="$MODDIR/.state/transparent-ebpf"
JOURNAL="$MODDIR/.state/transparent-state-test-journal"
mkdir -p "$STATE_DIR" "$JOURNAL"
printf '%s\n' 1 >"$JOURNAL/old-ebpf-state-version"
printf '%s\n' ok >"$JOURNAL/old-ebpf-capability"
printf '%s\n' 1 >"$JOURNAL/old-ebpf-capability-present"
printf '%s\n' '{"active_programs":[{"name":"sb_ebpf_conn4"}]}' >"$JOURNAL/old-ebpf-probe"
printf '%s\n' 1 >"$JOURNAL/old-ebpf-probe-present"
printf '%s\n' pending >"$JOURNAL/old-ebpf-shared-pending"
printf '%s\n' 1 >"$JOURNAL/old-ebpf-shared-pending-present"
printf '%s\n' wlan2 >"$JOURNAL/old-ebpf-shared-interfaces"
printf '%s\n' 1 >"$JOURNAL/old-ebpf-shared-interfaces-present"
rm -f "$STATE_DIR/capability" "$STATE_DIR/probe.json" "$STATE_DIR/shared.pending"
: >"$STATE_DIR/shared-interfaces.list"
magicnet_restore_transparent_state_snapshot "$JOURNAL"
[[ "$(<"$STATE_DIR/capability")" == ok ]]
"$HOST_JQ" -e '.active_programs[0].name == "sb_ebpf_conn4"' "$STATE_DIR/probe.json" >/dev/null
[[ "$(<"$STATE_DIR/shared.pending")" == pending ]]
[[ "$(<"$STATE_DIR/shared-interfaces.list")" == wlan2 ]]
rm -rf "$JOURNAL"

# eBPF post-start does not depend on magicnet0 and must not add the TUN-only
# table-2022 or DNS REDIRECT controls. Cleanup/deletion commands remain allowed.
POST_LOG="$WORK/post-start.log"
: >"$POST_LOG"
ip() {
  printf 'ip %s\n' "$*" >>"$POST_LOG"
  return 0
}
iptables() {
  printf 'iptables %s\n' "$*" >>"$POST_LOG"
  case " $* " in *' -C '* | *' -L '*) return 1 ;; *) return 0 ;; esac
}
ip6tables() {
  printf 'ip6tables %s\n' "$*" >>"$POST_LOG"
  case " $* " in *' -C '* | *' -L '*) return 1 ;; *) return 0 ;; esac
}
magicnet_cmd_exists() {
  case "$1" in ip | iptables | ip6tables | sing-box | jq) return 0 ;; *) return 1 ;; esac
}
magicnet_singbox_update_status() { :; }
if ! magicnet_after_kernel_start_unlocked; then
  printf '%s\n' 'eBPF post-start incorrectly required magicnet0/TUN controls' >&2
  exit 1
fi
if grep -Eq '^ip .* (route|rule) add .*2022|^iptables .* (-A|-I) .*REDIRECT|^ip6tables .* (-A|-I) .*REDIRECT' "$POST_LOG"; then
  printf '%s\n' 'eBPF post-start installed TUN-only kernel controls' >&2
  cat "$POST_LOG" >&2
  exit 1
fi

printf '%s\n' 'eBPF transparent mode contract passed'

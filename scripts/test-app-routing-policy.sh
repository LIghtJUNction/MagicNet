#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

JQ_BIN=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ_BIN" ]; then
  printf '%s\n' 'jq is required for app routing policy assertions' >&2
  exit 1
fi

MODDIR="$WORK/bootstrap"
export MODDIR
import() { :; }
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/apps.sh"
# network.sh reconciles the hotspot policy provided by routes.sh.
. "$ROOT/src/MagicNet/lib/magicnet/routes.sh"
# core.sh materializes the optional proxy chain during config startup.
. "$ROOT/src/MagicNet/lib/magicnet/chain.sh"
. "$ROOT/src/MagicNet/lib/magicnet/core.sh"
. "$ROOT/src/MagicNet/lib/magicnet/network.sh"
. "$ROOT/src/MagicNet/lib/magicnet/runtime_config.sh"

magicnet_warn() { :; }

REAL_MV=$(command -v mv)
FAIL_MV_BIN="$WORK/fail-mv-bin"
mkdir -p "$FAIL_MV_BIN"
cat >"$FAIL_MV_BIN/mv" <<EOF
#!/bin/sh
case "\${3:-}" in
  *.include-uids.tmp|*.exclude-uids.tmp)
    exit 1
    ;;
  *)
    exec "$REAL_MV" "\$@"
    ;;
esac
EOF
chmod +x "$FAIL_MV_BIN/mv"

MOCK_BIN="$WORK/mock-bin"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/cmd" <<'EOF'
#!/bin/sh
case "${1:-} ${2:-}" in
  "user list")
    printf '%s\n' 'Users:' '  UserInfo{0:Owner:13} running' '  UserInfo{10:Work:30} running'
    ;;
  "package list")
    package=""
    user=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --user) user="${2:-}"; shift 2 ;;
        -U) shift ;;
        package|list|packages) shift ;;
        *) package="$1"; shift ;;
      esac
    done
    case "$user:$package" in
      0:com.example.bypass) printf '%s\n' 'package:com.example.bypass uid:11001' ;;
      10:com.example.bypass) printf '%s\n' 'package:com.example.bypass uid:1011001' ;;
      0:com.example.directforce) printf '%s\n' 'package:com.example.directforce uid:11002' ;;
      0:com.example.proxy) printf '%s\n' 'package:com.example.proxy uid:11003' ;;
    esac
    ;;
esac
EOF
chmod +x "$MOCK_BIN/cmd"
write_base_config() {
  cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "exclude_uid": [0, 42],
      "include_package": ["stale.include"],
      "exclude_package": ["stale.exclude"],
      "stack": "system"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["tun-in"],
        "action": "sniff"
      },
      {
        "package_name": ["com.example.direct"],
        "outbound": "direct"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "protocol": "icmp",
        "outbound": "block"
      },
      {
        "domain_suffix": ["example.org"],
        "outbound": "direct"
      },
      {
        "domain_suffix": ["local", "home.arpa", "lan"],
        "outbound": "lan"
      },
      {
        "domain_keyword": ["adservice", "analytics", "tracking", "tracker"],
        "outbound": "ad-block"
      }
    ]
  }
}
EOF
}

assert_proxy_rule_and_order() {
  # shellcheck disable=SC2016
  "$JQ_BIN" -e '
    ([.route.rules | to_entries[]
       | select((.value.package_name // []) | index("__magicnet_app_proxy__"))] | length) == 1
    and ([.route.rules[]
          | select((.package_name // []) | index("__magicnet_app_proxy__"))][0]
         | .package_name == ["__magicnet_app_proxy__", "com.example.proxy"]
           and .outbound == "proxy")
    and ([.route.rules[]
          | select((.package_name // []) | index("__magicnet_app_direct__"))][0]
         | .package_name == ["__magicnet_app_direct__", "com.example.directforce"]
           and .outbound == "direct")
    and (([.route.rules | to_entries[]
            | select(.value | (has("action") or (.protocol == "icmp" and .outbound == "block")))
            | .key] | max) as $guard
         | ([.route.rules | to_entries[]
              | select((.value.package_name // []) | index("__magicnet_app_direct__"))
              | .key][0]) as $direct
         | ([.route.rules | to_entries[]
              | select((.value.package_name // []) | index("__magicnet_app_proxy__"))
              | .key][0]) as $proxy
         | ([.route.rules | to_entries[]
              | select(
                  .value.outbound == "direct"
                  and ((.value.package_name // []) | index("__magicnet_app_direct__")) == null
                  and ((.value.package_name // .value.domain_suffix // []) | length) > 0
                )
              | .key] | min) as $business
         | $guard < $direct and $direct < $proxy and $proxy < $business)
    and (([.route.rules | to_entries[]
            | select(.value == {"domain_suffix": ["local", "home.arpa", "lan"], "outbound": "lan"})
            | .key]) as $lan
         | ([.route.rules | to_entries[]
              | select(.value == {"domain_keyword": ["adservice", "analytics", "tracking", "tracker"], "outbound": "ad-block"})
              | .key]) as $ad
         | ($lan | length) == 1 and ($ad | length) == 1 and $lan[0] < $ad[0])
  ' "$MODDIR/.config/sing-box/config.json" >/dev/null
}

assert_blacklist() {
  "$JQ_BIN" -e '
    (.inbounds[] | select(.type == "tun")
      | (.exclude_uid | sort) == [0, 42, 11001, 1011001]
        and (has("include_uid") | not)
        and (has("include_package") | not)
        and (has("exclude_package") | not))
  ' "$MODDIR/.config/sing-box/config.json" >/dev/null
  assert_proxy_rule_and_order
}

assert_whitelist() {
  "$JQ_BIN" -e '
    (.inbounds[] | select(.type == "tun")
      | (.include_uid | sort) == [11002, 11003]
        and (.exclude_uid | sort) == [0, 42]
        and (has("include_package") | not)
        and (has("exclude_package") | not))
  ' "$MODDIR/.config/sing-box/config.json" >/dev/null
  assert_proxy_rule_and_order
}

apply_policy() {
  PATH="$MOCK_BIN:$PATH" magicnet_singbox_apply_app_policy
}

run_case() {
  implementation="$1"
  MODDIR="$WORK/$implementation/module"
  export MODDIR
  mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box"
  mkdir -p "$MODDIR/bin"
  ln -sf "$JQ_BIN" "$MODDIR/bin/jq"
  write_base_config

  printf '%s\n' 'MAGICNET_APP_MODE=blacklist' >"$MODDIR/.config/magicnet/app-mode.conf"
  cat >"$MODDIR/.config/magicnet/app-proxy.list" <<'EOF'
com.example.proxy
com.example.proxy
EOF
  cat >"$MODDIR/.config/magicnet/app-direct.list" <<'EOF'
	com.example.directforce
	com.example.directforce
EOF
  cat >"$MODDIR/.config/magicnet/app-bypass.list" <<'EOF'
com.example.bypass
com.example.bypass
EOF
  apply_policy "$implementation"
  apply_policy "$implementation"
  if ! "$JQ_BIN" empty "$MODDIR/.config/sing-box/config.json" >/dev/null 2>&1; then
    printf '%s\n' "$implementation generated invalid JSON" >&2
    awk '{ printf "%4d %s\n", NR, $0 }' "$MODDIR/.config/sing-box/config.json" >&2
    exit 1
  fi
  assert_blacklist

  : >"$MODDIR/.config/magicnet/app-proxy.list"
  apply_policy "$implementation"
  apply_policy "$implementation"
  "$JQ_BIN" -e '
    ([.route.rules[] | select((.package_name // []) | index("__magicnet_app_proxy__"))] | length) == 0
    and ([.route.rules[] | select((.package_name // []) | index("__magicnet_app_direct__"))] | length) == 1
  ' "$MODDIR/.config/sing-box/config.json" >/dev/null

  printf '%s\n' 'MAGICNET_APP_MODE=whitelist' >"$MODDIR/.config/magicnet/app-mode.conf"
  printf '%s\n' 'com.example.proxy' 'com.example.proxy' >"$MODDIR/.config/magicnet/app-proxy.list"
  apply_policy "$implementation"
  apply_policy "$implementation"
  assert_whitelist

  : >"$MODDIR/.config/magicnet/app-proxy.list"
  : >"$MODDIR/.config/magicnet/app-direct.list"
  apply_policy "$implementation"
  "$JQ_BIN" -e '
    (.inbounds[] | select(.type == "tun")
      | .include_uid == [4294967294]
        and (.exclude_uid | sort) == [0, 42]
        and (has("include_package") | not)
        and (has("exclude_package") | not))
  ' "$MODDIR/.config/sing-box/config.json" >/dev/null
}

run_case jq

assert_publish_failure_is_visible() (
  MODDIR="$WORK/publish-failure/module"
  export MODDIR
  mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box" "$MODDIR/bin"
  ln -sf "$JQ_BIN" "$MODDIR/bin/jq"
  write_base_config
  printf '%s\n' 'MAGICNET_APP_MODE=blacklist' >"$MODDIR/.config/magicnet/app-mode.conf"
  printf '%s\n' 'com.example.bypass' >"$MODDIR/.config/magicnet/app-bypass.list"
  original_hash=$($JQ_BIN -c . "$MODDIR/.config/sing-box/config.json" | sha256sum)
  if PATH="$MOCK_BIN:$FAIL_MV_BIN:$PATH" magicnet_singbox_apply_app_policy; then
    printf '%s\n' 'app policy must report temporary UID publish failure' >&2
    exit 1
  fi
  current_hash=$($JQ_BIN -c . "$MODDIR/.config/sing-box/config.json" | sha256sum)
  if [ "$current_hash" != "$original_hash" ]; then
    printf '%s\n' 'app policy publish failure must not replace the active config' >&2
    exit 1
  fi
)

assert_publish_failure_is_visible

assert_jq_removes_legacy_dns_package_rules() {
  MODDIR="$WORK/jq-dns/module"
  export MODDIR
  mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box" "$MODDIR/bin"
  ln -sf "$JQ_BIN" "$MODDIR/bin/jq"
  write_base_config
  printf '%s\n' 'MAGICNET_APP_MODE=blacklist' >"$MODDIR/.config/magicnet/app-mode.conf"
  printf '%s\n' 'com.example.proxy' >"$MODDIR/.config/magicnet/app-proxy.list"
  printf '%s\n' 'com.example.directforce' >"$MODDIR/.config/magicnet/app-direct.list"
  printf '%s\n' 'com.example.bypass' >"$MODDIR/.config/magicnet/app-bypass.list"
  "$JQ_BIN" '.dns = {"rules": [
    {"package_name": ["com.example.legacy"], "server": "bootstrap-local-dns"},
    {"domain_suffix": ["example.org"], "server": "doh-cloudflare"}
  ]}' "$MODDIR/.config/sing-box/config.json" >"$MODDIR/config.new"
  mv -f "$MODDIR/config.new" "$MODDIR/.config/sing-box/config.json"
  PATH="$MOCK_BIN:$PATH" magicnet_singbox_apply_app_policy
  "$JQ_BIN" -e '
    ([.dns.rules[] | select(has("package_name"))] | length) == 0
    and ([.dns.rules[] | select(.domain_suffix == ["example.org"])] | length) == 1
  ' "$MODDIR/.config/sing-box/config.json" >/dev/null
}

assert_missing_packaged_jq_does_not_mutate_config() {
  MODDIR="$WORK/missing-jq/module"
  export MODDIR
  mkdir -p "$MODDIR/.config/sing-box"
  write_base_config
  original_hash=$($JQ_BIN -c . "$MODDIR/.config/sing-box/config.json" | sha256sum)
  if PATH="$MOCK_BIN:$PATH" magicnet_singbox_apply_app_policy; then
    printf '%s\n' 'application policy must reject a missing packaged jq' >&2
    exit 1
  fi
  current_hash=$($JQ_BIN -c . "$MODDIR/.config/sing-box/config.json" | sha256sum)
  test "$current_hash" = "$original_hash"
}

assert_jq_removes_legacy_dns_package_rules
assert_missing_packaged_jq_does_not_mutate_config

assert_dns_capture_bypass_uids() (
  MODDIR="$WORK/dns-capture/module"
  export MODDIR
  mkdir -p "$MODDIR/.state/app-policy"
  cat >"$MODDIR/.state/app-policy/exclude-uids.list" <<'EOF'
11001
1011001
11001
invalid
EOF

  dns_capture_log="$WORK/dns-capture-iptables.log"
  : >"$dns_capture_log"

  iptables() {
    printf '%s\n' "iptables $*" >>"$dns_capture_log"
    case " $* " in
      *' -C '*) return 1 ;;
      *) return 0 ;;
    esac
  }
  ip6tables() {
    printf '%s\n' "ip6tables $*" >>"$dns_capture_log"
    case " $* " in
      *' -C '*) return 1 ;;
      *) return 0 ;;
    esac
  }
  magicnet_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
  magicnet_dns_profile() { printf '%s\n' default; }
  magicnet_log() { :; }
  magicnet_warn() { printf '%s\n' "$*" >&2; }

  magicnet_enable_dns_capture

  for family in iptables ip6tables; do
    for uid in 11001 1011001; do
      bypass_line=$(sed -n "/$family -t nat -A magicnet-dns-output -m owner --uid-owner $uid -j RETURN/=" "$dns_capture_log")
      redirect_line=$(sed -n "/$family -t nat -A magicnet-dns-output -p udp --dport 53 -j REDIRECT --to-ports 1053/=" "$dns_capture_log")
      if [ -z "$bypass_line" ] || [ -z "$redirect_line" ] || [ "$bypass_line" -ge "$redirect_line" ]; then
        printf '%s\n' "$family app-bypass UID $uid must return before DNS capture redirect" >&2
        cat "$dns_capture_log" >&2
        exit 1
      fi
    done
  done

  if [ "$(grep -c -- '--uid-owner 11001 -j RETURN' "$dns_capture_log")" -ne 4 ]; then
    printf '%s\n' 'duplicate app-bypass UIDs must produce one check and one append per address family only' >&2
    cat "$dns_capture_log" >&2
    exit 1
  fi
  if grep -q -- '--uid-owner invalid' "$dns_capture_log"; then
    printf '%s\n' 'invalid app-bypass UID reached iptables' >&2
    cat "$dns_capture_log" >&2
    exit 1
  fi
)

assert_dns_capture_bypass_uids

assert_dns_capture_failure_is_visible() (
  MODDIR="$WORK/dns-capture-failure/module"
  export MODDIR
  mkdir -p "$MODDIR"
  dns_capture_log="$WORK/dns-capture-failure-iptables.log"
  : >"$dns_capture_log"

  iptables() {
    printf '%s\n' "iptables $*" >>"$dns_capture_log"
    return 1
  }
  ip6tables() {
    printf '%s\n' "ip6tables $*" >>"$dns_capture_log"
    return 1
  }
  magicnet_cmd_exists() { return 0; }
  magicnet_dns_profile() { printf '%s\n' default; }
  magicnet_ipv6_mode() { printf '%s\n' ipv4_only; }
  magicnet_log() { printf '%s\n' "$*" >>"$dns_capture_log"; }
  magicnet_warn() { printf '%s\n' "$*" >&2; }

  if magicnet_enable_dns_capture; then
    printf '%s\n' 'DNS capture must report an iptables installation failure' >&2
    exit 1
  fi
  if grep -q 'DNS capture redirected' "$dns_capture_log"; then
    printf '%s\n' 'DNS capture must not claim success after iptables failure' >&2
    exit 1
  fi

  if MAGIC_DNS_LEAK_GUARD=1 MAGIC_DNS_GUARD_IFACES=lo magicnet_enable_dns_leak_guard; then
    printf '%s\n' 'DNS leak guard must report an iptables installation failure' >&2
    exit 1
  fi
  if grep -q 'DNS leak guard blocked' "$dns_capture_log"; then
    printf '%s\n' 'DNS leak guard must not claim success after iptables failure' >&2
    exit 1
  fi
)

assert_dns_capture_failure_is_visible

assert_dns_capture_disable_removes_duplicate_output_jumps() (
  MODDIR="$WORK/dns-capture-duplicate-jumps/module"
  export MODDIR
  mkdir -p "$MODDIR"
  dns_output_jump_count_file="$WORK/dns-capture-duplicate-jumps.count"
  printf '%s\n' 2 >"$dns_output_jump_count_file"

  iptables() {
    dns_output_jump_count=$(cat "$dns_output_jump_count_file")
    case " $* " in
      *' -D OUTPUT -j magicnet-dns-output '*)
        if [ "$dns_output_jump_count" -gt 0 ]; then
          printf '%s\n' "$((dns_output_jump_count - 1))" >"$dns_output_jump_count_file"
          return 0
        fi
        return 1
        ;;
      *' -C OUTPUT -j magicnet-dns-output '*)
        [ "$dns_output_jump_count" -gt 0 ]
        ;;
      *' -L magicnet-dns-output '*|*' -F magicnet-dns-output '*|*' -X magicnet-dns-output '*)
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  }
  ip6tables() { return 1; }
  magicnet_cmd_exists() {
    [ "${1:-}" = iptables ] || [ "${1:-}" = ip6tables ]
  }

  magicnet_disable_dns_capture
  if [ "$(cat "$dns_output_jump_count_file")" -ne 0 ]; then
    printf '%s\n' 'DNS capture cleanup must remove every duplicate OUTPUT jump' >&2
    exit 1
  fi
)

assert_dns_capture_disable_removes_duplicate_output_jumps

assert_dns_capture_disable_retries_transient_delete_failure() (
  MODDIR="$WORK/dns-capture-transient-delete/module"
  export MODDIR
  mkdir -p "$MODDIR"
  dns_output_jump_count_file="$WORK/dns-capture-transient-delete.count"
  transient_delete_file="$WORK/dns-capture-transient-delete.once"
  printf '%s\n' 1 >"$dns_output_jump_count_file"
  : >"$transient_delete_file"

  iptables() {
    dns_output_jump_count=$(cat "$dns_output_jump_count_file")
    case " $* " in
      *' -D OUTPUT -j magicnet-dns-output '*)
        if [ -e "$transient_delete_file" ]; then
          rm -f "$transient_delete_file"
          return 1
        fi
        if [ "$dns_output_jump_count" -gt 0 ]; then
          printf '%s\n' "$((dns_output_jump_count - 1))" >"$dns_output_jump_count_file"
          return 0
        fi
        return 1
        ;;
      *' -C OUTPUT -j magicnet-dns-output '*)
        [ "$dns_output_jump_count" -gt 0 ]
        ;;
      *)
        return 0
        ;;
    esac
  }
  ip6tables() { return 1; }
  magicnet_cmd_exists() {
    [ "${1:-}" = iptables ] || [ "${1:-}" = ip6tables ]
  }

  magicnet_disable_dns_capture
  if [ "$(cat "$dns_output_jump_count_file")" -ne 0 ]; then
    printf '%s\n' 'DNS capture cleanup must retry a transient OUTPUT jump deletion failure' >&2
    exit 1
  fi
)

assert_dns_capture_disable_retries_transient_delete_failure

assert_dns_capture_disable_reports_cleanup_failure() (
  MODDIR="$WORK/dns-capture-cleanup-failure/module"
  export MODDIR
  mkdir -p "$MODDIR"

  iptables() {
    case " $* " in
      *' -D OUTPUT -j magicnet-dns-output '*) return 1 ;;
      *' -C OUTPUT -j magicnet-dns-output '*) return 0 ;;
      *' -L magicnet-dns-output '*|*' -F magicnet-dns-output '*|*' -X magicnet-dns-output '*) return 0 ;;
      *) return 1 ;;
    esac
  }
  magicnet_cmd_exists() { [ "${1:-}" = iptables ]; }

  if magicnet_disable_dns_capture; then
    printf '%s\n' 'DNS capture cleanup must report a jump that remains installed' >&2
    exit 1
  fi
  if MAGIC_DNS_CAPTURE=0 magicnet_enable_dns_capture; then
    printf '%s\n' 'disabled DNS capture must not hide a failed cleanup' >&2
    exit 1
  fi
)

assert_dns_capture_disable_reports_cleanup_failure

assert_dns_leak_guard_disable_removes_duplicate_rules() (
  MODDIR="$WORK/dns-leak-guard-duplicate-rules/module"
  export MODDIR
  mkdir -p "$MODDIR"
  dns_guard_count_file="$WORK/dns-leak-guard-duplicate-rules.count"
  printf '%s\n' 2 >"$dns_guard_count_file"

  iptables() {
    case " $* " in
      *' -D OUTPUT -o wlan0 -p udp --dport 53 -j REJECT '*)
        dns_guard_rule_count="$(cat "$dns_guard_count_file")"
        if [ "$dns_guard_rule_count" -gt 0 ]; then
          printf '%s\n' "$((dns_guard_rule_count - 1))" >"$dns_guard_count_file"
          return 0
        fi
        return 1
        ;;
      *' -C OUTPUT -o wlan0 -p udp --dport 53 -j REJECT '*)
        [ "$(cat "$dns_guard_count_file")" -gt 0 ]
        ;;
      *' -D OUTPUT -o wlan0 '*|*' -C OUTPUT -o wlan0 '*)
        return 1
        ;;
      *)
        return 1
        ;;
    esac
  }
  magicnet_cmd_exists() { [ "${1:-}" = iptables ]; }
  magicnet_collect_physical_egress_ifaces() { printf '%s\n' wlan0; }

  magicnet_disable_dns_leak_guard
  if [ "$(cat "$dns_guard_count_file")" -ne 0 ]; then
    printf '%s\n' 'DNS leak guard cleanup must remove every duplicate interface rule' >&2
    exit 1
  fi
)

assert_dns_leak_guard_disable_removes_duplicate_rules

assert_dns_leak_guard_disable_cleans_previous_interfaces() (
  MODDIR="$WORK/dns-leak-guard-stale-interface/module"
  export MODDIR
  mkdir -p "$MODDIR/.state"
  printf '%s\n' wlan0 >"$MODDIR/.state/dns-leak-guard.ifaces"
  stale_guard_count_file="$WORK/dns-leak-guard-stale-interface.count"
  printf '%s\n' 1 >"$stale_guard_count_file"

  iptables() {
    case " $* " in
      *' -D OUTPUT -o wlan0 -p udp --dport 53 -j REJECT '*)
        stale_guard_rule_count="$(cat "$stale_guard_count_file")"
        if [ "$stale_guard_rule_count" -gt 0 ]; then
          printf '%s\n' "$((stale_guard_rule_count - 1))" >"$stale_guard_count_file"
          return 0
        fi
        return 1
        ;;
      *)
        return 1
        ;;
    esac
  }
  magicnet_cmd_exists() { [ "${1:-}" = iptables ]; }
  magicnet_collect_physical_egress_ifaces() { printf '%s\n' rmnet0; }

  magicnet_disable_dns_leak_guard
  if [ "$(cat "$stale_guard_count_file")" -ne 0 ]; then
    printf '%s\n' 'DNS leak guard cleanup must include interfaces saved before a network switch' >&2
    exit 1
  fi
)

assert_dns_leak_guard_disable_cleans_previous_interfaces

assert_dns_leak_guard_records_interfaces() (
  MODDIR="$WORK/dns-leak-guard-state/module"
  export MODDIR
  mkdir -p "$MODDIR"

  iptables() {
    case " $* " in
      *' -D '*|*' -C '*) return 1 ;;
      *) return 0 ;;
    esac
  }
  magicnet_cmd_exists() { [ "${1:-}" = iptables ]; }
  magicnet_collect_physical_egress_ifaces() { printf '%s\n' wlan0 rmnet0 wlan0; }
  magicnet_ipv6_mode() { printf '%s\n' ipv4_only; }
  magicnet_log() { :; }
  magicnet_warn() { printf '%s\n' "$*" >&2; }

  MAGIC_DNS_LEAK_GUARD=1 magicnet_enable_dns_leak_guard
  test "$(sed -n '1p' "$MODDIR/.state/dns-leak-guard.ifaces")" = wlan0
  grep -qx rmnet0 "$MODDIR/.state/dns-leak-guard.ifaces"
  magicnet_disable_dns_leak_guard
  test ! -e "$MODDIR/.state/dns-leak-guard.ifaces"
)

assert_dns_leak_guard_records_interfaces

assert_dns_leak_guard_ipv4_first_tolerates_missing_ipv6_nat() (
  MODDIR="$WORK/dns-leak-guard-ipv4-first/module"
  export MODDIR
  mkdir -p "$MODDIR"
  guard_log="$WORK/dns-leak-guard-ipv4-first.log"
  : >"$guard_log"

  iptables() {
    case " $* " in
      *' -D '*|*' -C '*) return 1 ;;
      *' -I '*) return 0 ;;
      *) printf '%s\n' "iptables $*" >>"$guard_log"; return 1 ;;
    esac
  }
  ip6tables() { return 1; }
  magicnet_cmd_exists() { return 0; }
  magicnet_collect_physical_egress_ifaces() { printf '%s\n' wlan0; }
  magicnet_ipv6_mode() { printf '%s\n' prefer_ipv4; }
  magicnet_log() { printf '%s\n' "$*" >>"$guard_log"; }
  magicnet_warn() { printf '%s\n' "$*" >>"$guard_log"; }

  MAGIC_DNS_LEAK_GUARD=1 magicnet_enable_dns_leak_guard
  grep -q 'IPv6 DNS leak guard unavailable' "$guard_log"
  magicnet_disable_dns_leak_guard
)

assert_dns_leak_guard_ipv4_first_tolerates_missing_ipv6_nat

assert_dns_leak_guard_uses_ipv6_filter_without_nat() (
  MODDIR="$WORK/dns-leak-guard-ipv6-filter/module"
  export MODDIR
  mkdir -p "$MODDIR"
  guard_log="$WORK/dns-leak-guard-ipv6-filter.log"
  : >"$guard_log"

  iptables() {
    case " $* " in
      *' -C '*|*' -D '*) return 1 ;;
      *' -I '*) printf '%s\n' "iptables $*" >>"$guard_log"; return 0 ;;
      *) return 0 ;;
    esac
  }
  ip6tables() {
    case " $* " in
      *' -t nat -L '*) return 1 ;;
      *' -C '*|*' -D '*) return 1 ;;
      *' -I '*) printf '%s\n' "ip6tables $*" >>"$guard_log"; return 0 ;;
      *' -L '*) return 0 ;;
      *) return 0 ;;
    esac
  }
  magicnet_cmd_exists() { [ "${1:-}" = iptables ] || [ "${1:-}" = ip6tables ]; }
  magicnet_collect_physical_egress_ifaces() { printf '%s\n' lo; }
  magicnet_ipv6_mode() { printf '%s\n' prefer_ipv6; }
  magicnet_log() { printf '%s\n' "$*" >>"$guard_log"; }
  magicnet_warn() { printf '%s\n' "$*" >>"$guard_log"; }

  MAGIC_DNS_LEAK_GUARD=1 MAGIC_DNS_GUARD_IFACES=lo magicnet_enable_dns_leak_guard
  grep -q '^ip6tables -I OUTPUT -o lo -p udp --dport 53 -j REJECT$' "$guard_log"
  if grep -q 'IPv6 DNS leak guard unavailable' "$guard_log"; then
    printf '%s\n' 'IPv6 leak guard must probe the filter table, not the optional nat table' >&2
    exit 1
  fi
)

assert_dns_leak_guard_uses_ipv6_filter_without_nat

assert_dns_leak_guard_preserves_state_after_cleanup_failure() (
  MODDIR="$WORK/dns-leak-guard-cleanup-failure/module"
  export MODDIR
  mkdir -p "$MODDIR/.state"
  state_file="$MODDIR/.state/dns-leak-guard.ifaces"
  printf '%s\n' wlan0 >"$state_file"

  iptables() {
    case " $* " in
      *' -D OUTPUT -o wlan0 -p udp --dport 53 -j REJECT '*) return 1 ;;
      *' -C OUTPUT -o wlan0 -p udp --dport 53 -j REJECT '*) return 0 ;;
      *) return 1 ;;
    esac
  }
  magicnet_cmd_exists() { [ "${1:-}" = iptables ]; }
  magicnet_collect_physical_egress_ifaces() { printf '%s\n' wlan0; }

  if magicnet_disable_dns_leak_guard; then
    printf '%s\n' 'DNS leak guard cleanup must report a failed rule deletion' >&2
    exit 1
  fi
  if [ ! -e "$state_file" ]; then
    printf '%s\n' 'DNS leak guard cleanup must retain interface state after a failed rule deletion' >&2
    exit 1
  fi
)

assert_dns_leak_guard_preserves_state_after_cleanup_failure

assert_dns_leak_guard_disabled_cleanup_failure_is_visible() (
  MODDIR="$WORK/dns-leak-guard-disabled-cleanup-failure/module"
  export MODDIR
  mkdir -p "$MODDIR/.state"

  iptables() {
    case " $* " in
      *' -D OUTPUT '* ) return 1 ;;
      *' -C OUTPUT '* ) return 0 ;;
      *) return 1 ;;
    esac
  }
  magicnet_cmd_exists() { [ "${1:-}" = iptables ]; }
  magicnet_collect_physical_egress_ifaces() { printf '%s\n' wlan0; }

  if MAGIC_DNS_LEAK_GUARD=0 magicnet_enable_dns_leak_guard; then
    printf '%s\n' 'disabled DNS leak guard must not hide a failed cleanup' >&2
    exit 1
  fi
)

assert_dns_leak_guard_disabled_cleanup_failure_is_visible

assert_dns_leak_guard_reapply_fails_closed_after_cleanup_failure() (
  MODDIR="$WORK/dns-leak-guard-reapply-failure/module"
  export MODDIR
  mkdir -p "$MODDIR/.state"
  printf '%s\n' wlan0 >"$MODDIR/.state/dns-leak-guard.ifaces"
  new_rule_attempts=0

  iptables() {
    case " $* " in
      *' -D OUTPUT '*) return 1 ;;
      *' -C OUTPUT '*) return 2 ;;
      *' -I OUTPUT '*) new_rule_attempts=$((new_rule_attempts + 1)); return 0 ;;
      *) return 0 ;;
    esac
  }
  magicnet_cmd_exists() { [ "${1:-}" = iptables ]; }
  magicnet_collect_physical_egress_ifaces() { printf '%s\n' rmnet0; }
  magicnet_ipv6_mode() { printf '%s\n' ipv4_only; }
  magicnet_log() { :; }
  magicnet_warn() { :; }

  if MAGIC_DNS_LEAK_GUARD=1 magicnet_enable_dns_leak_guard; then
    printf '%s\n' 'DNS leak guard must fail when old rules cannot be removed' >&2
    exit 1
  fi
  if [ "$new_rule_attempts" -ne 0 ]; then
    printf '%s\n' 'DNS leak guard must not install new rules after cleanup failure' >&2
    exit 1
  fi
  test -f "$MODDIR/.state/dns-leak-guard.ifaces"
)

assert_dns_leak_guard_reapply_fails_closed_after_cleanup_failure

assert_dns_leak_guard_reapply_cleans_old_interfaces() (
  MODDIR="$WORK/dns-leak-guard-reapply/module"
  export MODDIR
  mkdir -p "$MODDIR/.state"
  printf '%s\n' wlan0 >"$MODDIR/.state/dns-leak-guard.ifaces"
  stale_guard_count_file="$WORK/dns-leak-guard-reapply.count"
  printf '%s\n' 1 >"$stale_guard_count_file"

  iptables() {
    case " $* " in
      *' -D OUTPUT -o wlan0 -p udp --dport 53 -j REJECT '*)
        stale_guard_rule_count="$(cat "$stale_guard_count_file")"
        if [ "$stale_guard_rule_count" -gt 0 ]; then
          printf '%s\n' "$((stale_guard_rule_count - 1))" >"$stale_guard_count_file"
          return 0
        fi
        return 1
        ;;
      *' -C '*) return 1 ;;
      *) return 0 ;;
    esac
  }
  magicnet_cmd_exists() { [ "${1:-}" = iptables ]; }
  magicnet_collect_physical_egress_ifaces() { printf '%s\n' rmnet0; }
  magicnet_ipv6_mode() { printf '%s\n' ipv4_only; }
  magicnet_log() { :; }
  magicnet_warn() { printf '%s\n' "$*" >&2; }

  MAGIC_DNS_LEAK_GUARD=1 magicnet_enable_dns_leak_guard
  if [ "$(cat "$stale_guard_count_file")" -ne 0 ]; then
    printf '%s\n' 'reapplying DNS leak guard must clear rules from the previous interface' >&2
    exit 1
  fi
  grep -qx rmnet0 "$MODDIR/.state/dns-leak-guard.ifaces"
  if grep -qx wlan0 "$MODDIR/.state/dns-leak-guard.ifaces"; then
    printf '%s\n' 'reapplying DNS leak guard must replace the saved interface set' >&2
    exit 1
  fi
)

assert_dns_leak_guard_reapply_cleans_old_interfaces

assert_ipv4_first_dns_capture_tolerates_missing_ipv6_nat() (
  MODDIR="$WORK/dns-capture-ipv4-first/module"
  export MODDIR
  mkdir -p "$MODDIR"
  dns_capture_log="$WORK/dns-capture-ipv4-first.log"
  : >"$dns_capture_log"

  iptables() { printf '%s\n' "iptables $*" >>"$dns_capture_log"; return 0; }
  ip6tables() { printf '%s\n' "ip6tables $*" >>"$dns_capture_log"; return 1; }
  magicnet_cmd_exists() { return 0; }
  magicnet_dns_profile() { printf '%s\n' default; }
  magicnet_ipv6_mode() { printf '%s\n' prefer_ipv4; }
  magicnet_log() { printf '%s\n' "$*" >>"$dns_capture_log"; }
  magicnet_warn() { printf '%s\n' "$*" >>"$dns_capture_log"; }
  magicnet_disable_dns_capture() { :; }

  magicnet_enable_dns_capture
  grep -q 'IPv6 DNS capture unavailable; continuing with IPv4-first capture' "$dns_capture_log"
)

assert_ipv4_first_dns_capture_tolerates_missing_ipv6_nat

assert_startup_policy_order() {
  startup_events="$WORK/startup-events.log"
  : >"$startup_events"

  magicnet_module_disabled() { return 1; }
  magicnet_cmd_exists() { return 0; }
  import() { return 0; }
  is_singbox_running() { return 1; }
  magicnet_prepare_singbox_nodes_unlocked() { printf '%s\n' prepare >>"$startup_events"; }
  magicnet_singbox_apply_transparent_mode() { printf '%s\n' transparent >>"$startup_events"; }
  magicnet_singbox_apply_hotspot_policy() { printf '%s\n' hotspot >>"$startup_events"; }
  magicnet_dns_apply_unlocked() { printf '%s\n' dns >>"$startup_events"; }
  magicnet_app_policy_apply_unlocked() { printf '%s\n' app-policy >>"$startup_events"; }
  magicnet_tailscale_apply_unlocked() { printf '%s\n' tailscale >>"$startup_events"; }
  magicnet_warp_apply_unlocked() { printf '%s\n' warp >>"$startup_events"; }
  magicnet_tailscale_inject_auth_key() { printf '%s\n' tailscale-auth >>"$startup_events"; }
  magicnet_tailscale_scrub_auth_key() { return 0; }
  singbox_start() { printf '%s\n' singbox-start >>"$startup_events"; }
  magicnet_singbox_running_has_nodes() { return 0; }

  MAGIC_SINGBOX=1 magicnet_start_singbox_unlocked
  if ! diff -u - "$startup_events" <<'EOF'
prepare
transparent
hotspot
dns
tailscale
app-policy
warp
tailscale-auth
singbox-start
EOF
  then
    printf '%s\n' 'app policy must be materialized before sing-box starts' >&2
    exit 1
  fi
}

assert_startup_policy_order

assert_deferred_failure_disables_dns_controls() (
  events="$WORK/deferred-failure-events.log"
  : >"$events"

  magicnet_dns_apply_unlocked() { printf '%s\n' dns-apply >>"$events"; return 1; }
  magicnet_transparent_apply_unlocked() { printf '%s\n' transparent >>"$events"; }
  magicnet_app_policy_apply_unlocked() { printf '%s\n' app-policy >>"$events"; }
  magicnet_warp_apply_unlocked() { printf '%s\n' warp >>"$events"; return 1; }
  magicnet_singbox_apply_hotspot_policy() { printf '%s\n' hotspot >>"$events"; }
  magicnet_enable_dns_capture() { printf '%s\n' capture-enable >>"$events"; }
  magicnet_enable_dns_leak_guard() { printf '%s\n' guard-enable >>"$events"; }
  magicnet_disable_dns_capture() { printf '%s\n' capture-disable >>"$events"; }
  magicnet_disable_dns_leak_guard() { printf '%s\n' guard-disable >>"$events"; }
  magicnet_warn() { printf 'warning:%s\n' "$*" >>"$events"; }

  if magicnet_after_kernel_start_deferred_unlocked; then
    printf '%s\n' 'deferred config failure must return non-zero' >&2
    exit 1
  fi
  grep -qx capture-disable "$events"
  grep -qx guard-disable "$events"
  grep -qx 'warning:Deferred network configuration failed: dns,warp; DNS interception disabled' "$events"
  grep -qx 'warning:Post-start network rewrites failed: dns,warp' "$events"
  if grep -Eq '^(capture|guard)-enable$' "$events"; then
    printf '%s\n' 'deferred config failure enabled DNS controls' >&2
    cat "$events" >&2
    exit 1
  fi
)

assert_deferred_failure_disables_dns_controls

assert_startup_reports_deferred_failure() (
  module="$WORK/startup-failure-module"
  mkdir -p "$module"
  printf '%s\n' '#!/bin/sh' >"$module/cli"
  chmod +x "$module/cli"
  MODDIR="$module"

  magicnet_module_disabled() { return 1; }
  magicnet_kernel_running() { return 1; }
  magicnet_require_subscription_or_stop() { return 0; }
  magicnet_start_singbox() { return 0; }
  magicnet_after_kernel_start() { return 1; }
  magicnet_kernel_stopped=0
  import() { :; }
  singbox_stop() { magicnet_kernel_stopped=1; }
  magicnet_disable_dns_capture() { return 0; }
  magicnet_disable_dns_leak_guard() { return 0; }
  magicnet_notify() { :; }

  if magicnet_start_kernel; then
    printf '%s\n' 'startup must report a deferred configuration failure' >&2
    exit 1
  fi
  [ "$magicnet_kernel_stopped" -eq 1 ] || {
    printf '%s\n' 'failed startup must stop the half-initialized sing-box core' >&2
    exit 1
  }
)

assert_startup_reports_deferred_failure

assert_post_start_phase_is_synchronous() (
  magicnet_with_config_lock() { "$@"; }
  magicnet_singbox_apply_zashboard() { return 0; }
  magicnet_after_kernel_start_deferred() { return 1; }

  if magicnet_after_kernel_start; then
    printf '%s\n' 'post-start phase must not hide a deferred failure' >&2
    exit 1
  fi
)

assert_post_start_phase_is_synchronous

assert_post_start_phase_holds_config_lock() (
  post_start_events="$WORK/post-start-lock-events.log"
  : >"$post_start_events"
  magicnet_with_config_lock() {
    MAGICNET_CONFIG_LOCK_HELD=1
    "$@"
  }
  magicnet_singbox_apply_zashboard() {
    [ "${MAGICNET_CONFIG_LOCK_HELD:-0}" = 1 ] || return 1
    printf '%s\n' zashboard >>"$post_start_events"
  }
  magicnet_after_kernel_start_deferred() {
    [ "${MAGICNET_CONFIG_LOCK_HELD:-0}" = 1 ] || return 1
    printf '%s\n' deferred >>"$post_start_events"
  }

  magicnet_after_kernel_start
  diff -u - "$post_start_events" <<'EOF'
zashboard
deferred
EOF
)

assert_post_start_phase_holds_config_lock

assert_runtime_config_failure_is_visible() (
  magicnet_module_disabled() { return 1; }
  magicnet_ipset_lkm_prepare() { return 0; }
  magicnet_dns_apply_unlocked() { return 0; }
  magicnet_transparent_apply_unlocked() { return 0; }
  magicnet_app_policy_apply_unlocked() { return 0; }
  magicnet_warp_apply_unlocked() { return 0; }
  magicnet_route_apply_unlocked() { return 0; }
  magicnet_block_apply_unlocked() { return 0; }
  magicnet_tailscale_apply_unlocked() { return 0; }
  magicnet_wifi_policy_start() { return 0; }
  magicnet_kernel_running() { return 0; }
  magicnet_disable_dns_capture() { return 0; }
  magicnet_disable_dns_leak_guard() { return 0; }

  magicnet_singbox_apply_zashboard() { return 1; }
  magicnet_enable_dns_capture() { return 0; }
  magicnet_enable_dns_leak_guard() { return 0; }
  if magicnet_apply_runtime_config_unlocked; then
    printf '%s\n' 'runtime config must report a zashboard materialization failure' >&2
    exit 1
  fi

  magicnet_singbox_apply_zashboard() { return 0; }
  magicnet_enable_dns_capture() { return 1; }
  if magicnet_apply_runtime_config_unlocked; then
    printf '%s\n' 'runtime config must report a DNS capture installation failure' >&2
    exit 1
  fi
)

assert_runtime_config_failure_is_visible

printf '%s\n' 'app routing policy regression tests passed'

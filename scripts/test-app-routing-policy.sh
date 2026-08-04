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

. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/apps.sh"
. "$ROOT/src/MagicNet/lib/magicnet/core.sh"
. "$ROOT/src/MagicNet/lib/magicnet/network.sh"

magicnet_warn() { :; }

NO_JQ_BIN="$WORK/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for command_name in awk cp grep mkdir mv rm sed tr wc; do
  command_path=$(command -v "$command_name")
  ln -s "$command_path" "$NO_JQ_BIN/$command_name"
done

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
      0:com.example.direct-force) printf '%s\n' 'package:com.example.direct-force uid:11002' ;;
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
         | .package_name == ["__magicnet_app_direct__", "com.example.direct-force"]
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
  if [ "$EXPECT_UID_POLICY" = 1 ]; then
    "$JQ_BIN" -e '
      (.inbounds[] | select(.type == "tun")
        | .exclude_package == ["com.example.bypass"]
          and .exclude_uid == [0, 42, 11001, 1011001]
          and (has("include_package") | not)
          and (has("include_uid") | not))
    ' "$MODDIR/.config/sing-box/config.json" >/dev/null
  else
    "$JQ_BIN" -e '
      (.inbounds[] | select(.type == "tun")
        | .exclude_package == ["com.example.bypass"]
          and .exclude_uid == [0, 42]
          and (has("include_package") | not))
    ' "$MODDIR/.config/sing-box/config.json" >/dev/null
  fi
  assert_proxy_rule_and_order
}

assert_whitelist() {
  if [ "$EXPECT_UID_POLICY" = 1 ]; then
    "$JQ_BIN" -e '
      (.inbounds[] | select(.type == "tun")
        | .include_package == ["com.example.direct-force", "com.example.proxy"]
          and .include_uid == [11002, 11003]
          and .exclude_uid == [0, 42]
          and (has("exclude_package") | not))
    ' "$MODDIR/.config/sing-box/config.json" >/dev/null
  else
    "$JQ_BIN" -e '
      (.inbounds[] | select(.type == "tun")
        | .include_package == ["com.example.direct-force", "com.example.proxy"]
          and .exclude_uid == [0, 42]
          and (has("exclude_package") | not))
    ' "$MODDIR/.config/sing-box/config.json" >/dev/null
  fi
  assert_proxy_rule_and_order
}

apply_policy() {
  implementation="$1"
  if [ "$implementation" = "no-jq" ]; then
    PATH="$MOCK_BIN:$NO_JQ_BIN" magicnet_singbox_apply_app_policy
  else
    PATH="$MOCK_BIN:$PATH" magicnet_singbox_apply_app_policy
  fi
}

run_case() {
  implementation="$1"
  if [ "$implementation" = jq ]; then
    EXPECT_UID_POLICY=1
  else
    EXPECT_UID_POLICY=0
  fi
  export EXPECT_UID_POLICY
  MODDIR="$WORK/$implementation/module"
  export MODDIR
  mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box"
  write_base_config

  printf '%s\n' 'MAGICNET_APP_MODE=blacklist' >"$MODDIR/.config/magicnet/app-mode.conf"
  cat >"$MODDIR/.config/magicnet/app-proxy.list" <<'EOF'
com.example.proxy
com.example.proxy
EOF
  cat >"$MODDIR/.config/magicnet/app-direct.list" <<'EOF'
com.example.direct-force
com.example.direct-force
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
}

run_case jq
run_case no-jq

assert_jq_removes_legacy_dns_package_rules() {
  MODDIR="$WORK/jq-dns/module"
  export MODDIR
  mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box"
  write_base_config
  printf '%s\n' 'MAGICNET_APP_MODE=blacklist' >"$MODDIR/.config/magicnet/app-mode.conf"
  printf '%s\n' 'com.example.proxy' >"$MODDIR/.config/magicnet/app-proxy.list"
  printf '%s\n' 'com.example.direct-force' >"$MODDIR/.config/magicnet/app-direct.list"
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

assert_no_jq_rejects_legacy_dns_package_rules() {
  MODDIR="$WORK/no-jq-dns/module"
  export MODDIR
  mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box"
  cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "dns": {
    "rules": [
      {"package_name": ["com.example.legacy"], "server": "bootstrap-local-dns"}
    ]
  },
  "route": {"rules": []}
}
EOF
  if PATH="$MOCK_BIN:$NO_JQ_BIN" magicnet_singbox_apply_app_policy; then
    printf '%s\n' 'no-jq app policy must reject legacy DNS package rules' >&2
    exit 1
  fi
  "$JQ_BIN" -e '([.dns.rules[] | select(has("package_name"))] | length) == 1' \
    "$MODDIR/.config/sing-box/config.json" >/dev/null
}

assert_jq_removes_legacy_dns_package_rules
assert_no_jq_rejects_legacy_dns_package_rules

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
  magicnet_app_policy_apply_unlocked() { printf '%s\n' app-policy >>"$startup_events"; }
  magicnet_tailscale_apply_unlocked() { printf '%s\n' tailscale >>"$startup_events"; }
  magicnet_tailscale_inject_auth_key() { printf '%s\n' tailscale-auth >>"$startup_events"; }
  magicnet_tailscale_scrub_auth_key() { return 0; }
  singbox_start() { printf '%s\n' singbox-start >>"$startup_events"; }
  magicnet_singbox_running_has_nodes() { return 0; }

  MAGIC_SINGBOX=1 magicnet_start_singbox_unlocked
  if ! diff -u - "$startup_events" <<'EOF'
prepare
transparent
hotspot
tailscale
app-policy
tailscale-auth
singbox-start
EOF
  then
    printf '%s\n' 'app policy must be materialized before sing-box starts' >&2
    exit 1
  fi
}

assert_startup_policy_order

printf '%s\n' 'app routing policy regression tests passed'

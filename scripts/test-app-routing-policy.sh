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

NO_JQ_BIN="$WORK/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for command_name in awk grep mv rm sed tr wc; do
  command_path=$(command -v "$command_name")
  ln -s "$command_path" "$NO_JQ_BIN/$command_name"
done

write_base_config() {
  cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
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
  "$JQ_BIN" -e '
    (.inbounds[] | select(.type == "tun")
      | .exclude_package == ["com.example.bypass"] and (has("include_package") | not))
  ' "$MODDIR/.config/sing-box/config.json" >/dev/null
  assert_proxy_rule_and_order
}

assert_whitelist() {
  "$JQ_BIN" -e '
    (.inbounds[] | select(.type == "tun")
      | .include_package == ["com.example.direct-force", "com.example.proxy"] and (has("exclude_package") | not))
  ' "$MODDIR/.config/sing-box/config.json" >/dev/null
  assert_proxy_rule_and_order
}

apply_policy() {
  implementation="$1"
  if [ "$implementation" = "no-jq" ]; then
    PATH="$NO_JQ_BIN" magicnet_singbox_apply_app_policy
  else
    magicnet_singbox_apply_app_policy
  fi
}

run_case() {
  implementation="$1"
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

printf '%s\n' 'app routing policy regression tests passed'

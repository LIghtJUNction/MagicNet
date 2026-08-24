#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAGICNET_TRANSPARENT_SCRIPT=${1:-$ROOT_DIR/src/MagicNet/lib/magicnet/transparent.sh}
export MAGICNET_TRANSPARENT_SCRIPT

if [[ ! -f "$MAGICNET_TRANSPARENT_SCRIPT" ]]; then
    echo "orchestrator smoke failed: transparent script not found: $MAGICNET_TRANSPARENT_SCRIPT" >&2
    exit 1
fi

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "orchestrator smoke failed: missing required command: $1" >&2
        exit 1
    fi
}

require jq
require sing-box

TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/magicnet-orchestrator.XXXXXX")
cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

MODDIR="$TMPDIR/module"
export MODDIR
mkdir -p "$MODDIR/.config/sing-box" "$MODDIR/.config/magicnet" "$MODDIR/bin"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"

cat >"$TMPDIR/harness.sh" <<'HARNESS'
#!/usr/bin/env sh
set -eu
import() { :; }
info() { :; }
warn() { printf '%s\n' "$*" >&2; }
magicnet_warn() { warn "$@"; }
singbox_prepare_route_config() { :; }
# common.sh intentionally resolves primitives through the production MODDIR
# path under ash. Source the real dependency first instead of weakening that
# production contract for this synthetic fixture.
. "$ROOT_DIR/src/MagicNet/lib/magicnet/primitives.sh"
. "$ROOT_DIR/src/MagicNet/lib/magicnet/common.sh"
. "$ROOT_DIR/src/MagicNet/lib/magicnet/transparent_dns.sh"
. "$MAGICNET_TRANSPARENT_SCRIPT"
magicnet_singbox_apply_transparent_mode
HARNESS
# shellcheck disable=SC2016
perl -0pi -e 's#\$ROOT_DIR#'"$ROOT_DIR"'#g' "$TMPDIR/harness.sh"
chmod +x "$TMPDIR/harness.sh"

write_sample_config() {
    local managed_variant=$1
    local managed_rules=""
    if [ "$managed_variant" = "duplicate" ]; then
        managed_rules='      { "ip_version": 6, "outbound": "block" },
      { "outbound": "block", "ip_version": 6 },
      { "no_drop": true, "action": "reject", "ip_version": 6 },
      { "no_drop": true, "method": "default", "action": "reject", "ip_version": 6 },'
    fi
    cat >"$MODDIR/.config/sing-box/config.json" <<JSON
{
  "dns": {
    "strategy": "prefer_ipv6",
    "servers": [
      { "type": "local", "tag": "local" }
    ],
    "rules": [
      { "query_type": ["A", "AAAA"], "server": "local" }
    ]
  },
  "inbounds": [
    { "type": "mixed", "tag": "user-mixed", "listen": "127.0.0.1", "listen_port": 1080, "users": [{ "username": "type=tun", "password": "tag=magicnet-old }" }] },
    { "type": "tun", "tag": "old-tun", "interface_name": "old0" },
    { "type": "tproxy", "tag": "old-tproxy" },
    { "type": "mixed", "tag": "magicnet-old", "listen": "127.0.0.1", "listen_port": 10000 }
  ],
  "route": {
    "rules": [
      { "action": "sniff", "inbound": ["magicnet-old"] },
      { "action": "sniff", "network": "udp" },
      { "protocol": "dns", "action": "hijack-dns" },
$managed_rules
      { "inbound": ["magicnet-old"], "outbound": "direct" },
      { "inbound": "magicnet-stale", "outbound": "direct" },
      { "inbound": ["user-in", "magicnet-stale"], "outbound": "direct" },
      { "domain_suffix": ["example.com"], "domain_keyword": ["{"], "outbound": "proxy-rule" },
      { "ip_version": 6, "domain_suffix": ["custom-ipv6.example"], "outbound": "direct" },
      { "ip_version": 6, "outbound": "block", "network": "tcp" },
      { "no_drop": true, "method": "default", "action": "reject", "ip_version": 6, "network": "udp" },
      { "domain_keyword": ["action=sniff", "action=hijack-dns", "protocol=icmp", "outbound=block"], "outbound": "proxy-rule" },
      { "domain_keyword": ["magicnet-stale"], "outbound": "proxy-rule" },
      { "ip_version": 6, "outbound": "bl ock" },
      { "protocol": "icmp", "outbound": "block" },
      { "domain_suffix": ["local", "home.arpa", "lan"], "outbound": "lan" },
      { "domain_keyword": ["adservice", "analytics", "tracking", "tracker"], "outbound": "ad-block" },
      { "domain_suffix": ["cn.example"], "outbound": "cn-direct" }
    ],
    "final": "direct"
  },
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" },
    { "type": "direct", "tag": "proxy-rule" },
    { "type": "direct", "tag": "cn-direct" },
    { "type": "direct", "tag": "lan" },
    { "type": "block", "tag": "ad-block" },
    { "type": "direct", "tag": "bl ock" }
  ]
}
JSON
}

CANONICAL_TUN_EXCLUSIONS='["192.168.0.0/16","10.0.0.0/8","172.16.0.0/12","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","224.0.0.0/4","::1/128","fc00::/7","fe80::/10","ff00::/8","fd7a:115c:a1e0::/48"]'

tun_exclusions_canonical() {
    local config=$1
    jq -e --argjson expected "$CANONICAL_TUN_EXCLUSIONS" '
      [.inbounds[]? | select(.type == "tun" and .tag == "tun-in")] as $managed_tuns
      | ($managed_tuns | length) == 1
        and $managed_tuns[0].route_exclude_address == $expected
    ' "$config" >/dev/null
}

assert_tun_exclusions() {
    local config=$1
    local context=$2
    if ! tun_exclusions_canonical "$config"; then
        echo "orchestrator smoke failed: noncanonical TUN exclusions for $context" >&2
        jq '[.inbounds[]? | select(.type == "tun" and .tag == "tun-in") | .route_exclude_address]' "$config" >&2
        exit 1
    fi
}

assert_ipv6_migration() {
    local config=$1
    local context=$2
    if ! jq -e '
        def canonical_guard: {"ip_version": 6, "action": "reject", "method": "default", "no_drop": true};
        def legacy_guard: {"ip_version": 6, "outbound": "block"};
        def lan_rule: {"domain_suffix": ["local", "home.arpa", "lan"], "outbound": "lan"};
        def ad_rule: {"domain_keyword": ["adservice", "analytics", "tracking", "tracker"], "outbound": "ad-block"};
        def has_value($value):
          if type == "array" then index($value) != null else . == $value end;
        .route.rules as $rules
        | ($rules | to_entries) as $indexed
        | ([$indexed[] | select(.value == canonical_guard) | .key]) as $managed
        | ([$indexed[] | select(.value == legacy_guard) | .key]) as $legacy
        | ([$indexed[] | select((.value.action // "") == "sniff") | .key]) as $sniff
        | ([$indexed[] | select((.value.action // "") == "hijack-dns") | .key]) as $dns
        | ([$indexed[] | select((.value.protocol // "") == "icmp" and (.value.outbound // "") == "block") | .key]) as $icmp
        | ([$indexed[] | select(.value == lan_rule) | .key]) as $lan
        | ([$indexed[] | select(.value == ad_rule) | .key]) as $ad
        | ([$indexed[] | select(
              (.value.domain_suffix // [] | has_value("example.com"))
              or (.value.domain_suffix // [] | has_value("cn.example"))
              or (.value.domain_suffix // [] | has_value("custom-ipv6.example"))
              or (.value.domain_keyword // [] | has_value("action=sniff"))
              or (.value.outbound // "") == "bl ock"
              or (.value.ip_version == 6 and (
                (.value.network // "") == "tcp"
                or (.value.network // "") == "udp"
              ))
            ) | .key]) as $ordinary
        | ($managed | length) == 1
          and ($legacy | length) == 0
          and ($sniff | length) > 0
          and all($sniff[]; $rules[.].inbound == ["mixed-in", "tun-in"] or $rules[.].inbound == ["mixed-in"])
          and ($dns | length) == 1
          and ($rules[$dns[0]] == {"inbound": ["magicnet-dns-in"], "action": "hijack-dns"})
          and ($icmp | length) > 0
          and ($lan | length) == 1
          and ($ad | length) == 1
          and $lan[0] < $ad[0]
          and ($ordinary | length) == 7
          and ($managed[0] as $managed_index
            | all($sniff[]; . < $managed_index)
              and all($dns[]; . < $managed_index)
              and all($icmp[]; . < $managed_index)
              and all($ordinary[]; . > $managed_index))
          and ([.route.rules[] | select(
                .ip_version == 6
                and .outbound == "direct"
                and (.domain_suffix | has_value("custom-ipv6.example"))
              )] | length) == 1
          and ([.route.rules[] | select(. == {"ip_version": 6, "outbound": "block", "network": "tcp"})] | length) == 1
          and ([.route.rules[] | select(
                .ip_version == 6
                and .action == "reject"
                and (.method // "default") == "default"
                and .no_drop == true
                and .network == "udp"
                and (keys | length) == (if has("method") then 5 else 4 end)
              )] | length) == 1
          and ([.route.rules[] | select(. == {"ip_version": 6, "outbound": "bl ock"})] | length) == 1
          and ([.route.rules[] | select(
                .domain_keyword == ["action=sniff", "action=hijack-dns", "protocol=icmp", "outbound=block"]
                and .outbound == "proxy-rule"
              )] | length) == 1
          and ([.route.rules[] | select(
                (.domain_keyword | has_value("magicnet-stale"))
                and .outbound == "proxy-rule"
              )] | length) == 1
          and all(.route.rules[];
                if .action == "hijack-dns" then true
                else (.inbound // []) as $inbound
                  | (if ($inbound | type) == "array" then $inbound else [$inbound] end)
                  | all(.[]; (type != "string") or (startswith("magicnet-") | not))
                end)
          and ([.dns.rules[]? | select(has("ip_version"))] | length) == 0
          and ([.route.rules[]? | select(has("query_type"))] | length) == 0
    ' "$config" >/dev/null; then
        echo "orchestrator smoke failed: IPv6 migration invariant failed for $context" >&2
        jq '.route.rules' "$config" >&2
        exit 1
    fi
}

assert_singbox_check() {
    local config=$1
    local context=$2
    if ! sing-box check -c "$config"; then
        echo "orchestrator smoke failed: sing-box check failed for $context" >&2
        exit 1
    fi
}

assert_mode() {
    local mode=$1
    local expect_tun=$2
    local managed_variant=$3
    write_sample_config "$managed_variant"
    printf 'MAGICNET_TRANSPARENT_MODE=%s\n' "$mode" >"$MODDIR/.config/magicnet/transparent-mode.conf"
    local config="$MODDIR/.config/sing-box/config.json"
    local initial_count
    local dns_rules_before
    initial_count=$(jq '[.route.rules[] | select(
      . == {"ip_version": 6, "outbound": "block"}
      or . == {"ip_version": 6, "action": "reject", "no_drop": true}
      or . == {"ip_version": 6, "action": "reject", "method": "default", "no_drop": true}
    )] | length' "$config")
    dns_rules_before=$(jq -c '.dns.rules' "$config")
    if { [ "$managed_variant" = "missing" ] && [ "$initial_count" -ne 0 ]; } ||
        { [ "$managed_variant" = "duplicate" ] && [ "$initial_count" -ne 4 ]; }; then
        echo "orchestrator smoke failed: invalid $managed_variant fixture for mode $mode" >&2
        exit 1
    fi
    "$TMPDIR/harness.sh"

    assert_ipv6_migration "$config" "$mode/$managed_variant first apply"
    assert_singbox_check "$config" "$mode/$managed_variant first apply"
    cp "$config" "$TMPDIR/$mode-$managed_variant-first.json"
    "$TMPDIR/harness.sh"
    assert_ipv6_migration "$config" "$mode/$managed_variant second apply"
    if ! cmp -s "$TMPDIR/$mode-$managed_variant-first.json" "$config"; then
        echo "orchestrator smoke failed: repeated apply changed config ordering for mode $mode ($managed_variant)" >&2
        diff -u "$TMPDIR/$mode-$managed_variant-first.json" "$config" >&2 || true
        exit 1
    fi
    if [ "$(jq -c '.dns.rules' "$config")" != "$dns_rules_before" ]; then
        echo "orchestrator smoke failed: DNS rules changed for mode $mode ($managed_variant)" >&2
        exit 1
    fi

    jq -e '.inbounds[] | select(.type == "mixed" and .tag == "mixed-in" and .listen == "127.0.0.1" and .listen_port == 7892)' "$config" >/dev/null
    jq -e '.inbounds[] | select(.type == "direct" and .tag == "magicnet-dns-in" and .listen == "127.0.0.1" and .listen_port == 1053)' "$config" >/dev/null
    jq -e '.route.rules[] | select(.action == "hijack-dns" and (.inbound == ["magicnet-dns-in"]) and (has("protocol") | not))' "$config" >/dev/null
    jq -e --arg expect_tun "$expect_tun" '
      .route.rules[]
      | select(
          .action == "sniff"
          and .network == "udp"
          and (.inbound == (if $expect_tun == "yes" then ["mixed-in", "tun-in"] else ["mixed-in"] end))
        )
    ' "$config" >/dev/null
    jq -e '.inbounds[] | select(.tag == "user-mixed" and .users[0].username == "type=tun" and .users[0].password == "tag=magicnet-old }")' "$config" >/dev/null
    if jq -e '.inbounds[] | select(.type == "tproxy" or .tag == "magicnet-old" or .tag == "old-tun")' "$config" >/dev/null; then
        echo "orchestrator smoke failed: stale managed inbound survived for mode $mode" >&2
        jq '.inbounds' "$config" >&2
        exit 1
    fi

    if [ "$expect_tun" = "yes" ]; then
        jq -e '.inbounds[] | select(.type == "tun" and .tag == "tun-in" and .interface_name == "magicnet0" and .stack == "mixed" and .mtu == 1400 and .udp_timeout == "5m")' "$config" >/dev/null
        assert_tun_exclusions "$config" "$mode/$managed_variant second apply"
        jq -e '.route.rules[] | select(.action == "sniff" and (.inbound == ["mixed-in", "tun-in"]))' "$config" >/dev/null
    else
        if jq -e '.inbounds[] | select(.type == "tun" or .tag == "tun-in")' "$config" >/dev/null; then
            echo "orchestrator smoke failed: mode $mode unexpectedly emitted a managed TUN inbound" >&2
            jq '.inbounds' "$config" >&2
            exit 1
        fi
        jq -e '.route.rules[] | select(.action == "sniff" and (.inbound == ["mixed-in"]))' "$config" >/dev/null
    fi

    if jq -e '.route.rules[] | select((.inbound // []) | index("magicnet-old"))' "$config" >/dev/null; then
        echo "orchestrator smoke failed: stale magicnet inbound route reference survived for mode $mode" >&2
        jq '.route.rules' "$config" >&2
        exit 1
    fi

    jq -e '.dns.strategy == "ipv4_only"' "$config" >/dev/null
}

export MAGICNET_TEST_DNS_STRATEGY=ipv4_only
export MAGICNET_TEST_TUN_MTU=1400
export MAGICNET_TEST_UDP_TIMEOUT=5m
export MAGICNET_IPV6_MODE="$MAGICNET_TEST_DNS_STRATEGY"
export MAGICNET_TUN_MTU="$MAGICNET_TEST_TUN_MTU"
export MAGICNET_UDP_TIMEOUT="$MAGICNET_TEST_UDP_TIMEOUT"
assert_mode tun yes duplicate

assert_dual_stack_policy() {
    local strategy=$1
    local mtu=$2
    local udp_timeout=$3
    local config="$MODDIR/.config/sing-box/config.json"
    export MAGICNET_TEST_DNS_STRATEGY=$strategy
    export MAGICNET_TEST_TUN_MTU=$mtu
    export MAGICNET_TEST_UDP_TIMEOUT=$udp_timeout
    export MAGICNET_IPV6_MODE=$strategy
    export MAGICNET_TUN_MTU=$mtu
    export MAGICNET_UDP_TIMEOUT=$udp_timeout
    "$TMPDIR/harness.sh"
    if ! jq -e --arg strategy "$strategy" --argjson mtu "$mtu" --arg timeout "$udp_timeout" '
        def managed_guard:
          . == {"ip_version": 6, "outbound": "block"}
          or . == {"ip_version": 6, "action": "reject", "no_drop": true}
          or . == {"ip_version": 6, "action": "reject", "method": "default", "no_drop": true};
        .dns.strategy == $strategy
        and ([.route.rules[]? | select(managed_guard)] | length) == 0
        and ([.inbounds[]? | select(
          .type == "tun"
          and .tag == "tun-in"
          and .stack == "mixed"
          and .mtu == $mtu
          and .udp_timeout == $timeout
          and any(.address[]?; contains(":"))
        )] | length) == 1
    ' "$config" >/dev/null; then
        echo "orchestrator smoke failed: invalid $strategy/$mtu/$udp_timeout policy output" >&2
        jq '{dns:.dns.strategy,tun:(.inbounds[]? | select(.type == "tun")),ipv6:[.route.rules[]? | select(.ip_version == 6)]}' "$config" >&2
        exit 1
    fi
    assert_singbox_check "$config" "$strategy/$mtu/$udp_timeout policy"
}

# A previous ipv4_only apply leaves a managed IPv6 guard. Switching back to
# dual stack must remove it while retaining the IPv6 TUN address.
assert_dual_stack_policy prefer_ipv4 1400 5m
assert_dual_stack_policy prefer_ipv6 1280 10m
export MAGICNET_TEST_DNS_STRATEGY=ipv4_only
export MAGICNET_TEST_TUN_MTU=1400
export MAGICNET_TEST_UDP_TIMEOUT=5m
export MAGICNET_IPV6_MODE="$MAGICNET_TEST_DNS_STRATEGY"
export MAGICNET_TUN_MTU="$MAGICNET_TEST_TUN_MTU"
export MAGICNET_UDP_TIMEOUT="$MAGICNET_TEST_UDP_TIMEOUT"

for legacy_mode in proxy external external-tun hybrid; do
    printf 'MAGICNET_TRANSPARENT_MODE=%s\n' "$legacy_mode" >"$MODDIR/.config/magicnet/transparent-mode.conf"
    normalized_mode=$(
        import() { :; }
        info() { :; }
        warn() { :; }
        # shellcheck disable=SC1090
        . "$ROOT_DIR/src/MagicNet/lib/magicnet/common.sh"
        magicnet_transparent_mode
    )
    [ "$normalized_mode" = "tun" ] || {
        echo "orchestrator smoke failed: legacy mode $legacy_mode did not normalize to tun" >&2
        exit 1
    }
done
printf 'MAGICNET_TRANSPARENT_MODE=tun\n' >"$MODDIR/.config/magicnet/transparent-mode.conf"

# JSON mutation is owned by the packaged jq binary. Missing tooling must fail
# before touching the active config rather than entering a textual fallback.
cp "$MODDIR/.config/sing-box/config.json" "$TMPDIR/missing-jq.before.json"
rm -f "$MODDIR/bin/jq"
if /bin/sh "$TMPDIR/harness.sh" >/dev/null 2>&1; then
    echo "orchestrator smoke failed: missing packaged jq unexpectedly succeeded" >&2
    exit 1
fi
cmp -s "$TMPDIR/missing-jq.before.json" "$MODDIR/.config/sing-box/config.json" || {
    echo "orchestrator smoke failed: missing packaged jq mutated active config" >&2
    exit 1
}
ln -s "$(command -v jq)" "$MODDIR/bin/jq"

TUN_CANONICAL_CONFIG="$TMPDIR/tun-duplicate-first.json"
jq 'del(.inbounds[] | select(.type == "tun" and .tag == "tun-in") | .route_exclude_address[3])' \
    "$TUN_CANONICAL_CONFIG" >"$TMPDIR/tun-exclusions-missing.json"
jq '(.inbounds[] | select(.type == "tun" and .tag == "tun-in") | .route_exclude_address) |=
      (.[2] as $left | .[3] as $right | .[2] = $right | .[3] = $left)' \
    "$TUN_CANONICAL_CONFIG" >"$TMPDIR/tun-exclusions-reordered.json"
jq '(.inbounds[] | select(.type == "tun" and .tag == "tun-in") | .route_exclude_address) +=
      ["100.64.0.0/10"]' \
    "$TUN_CANONICAL_CONFIG" >"$TMPDIR/tun-exclusions-duplicate.json"
for exclusion_mutant in missing reordered duplicate; do
    if tun_exclusions_canonical "$TMPDIR/tun-exclusions-$exclusion_mutant.json"; then
        echo "orchestrator smoke failed: canonical guard accepted $exclusion_mutant TUN exclusions" >&2
        exit 1
    fi
done

echo "orchestrator mode smoke passed"

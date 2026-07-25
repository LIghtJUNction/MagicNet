#!/usr/bin/env bash
# Architecture guard: geodata is primary; app-bypass is not a domestic app catalog.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BYPASS="$ROOT/src/MagicNet/.config/magicnet/app-bypass.list"
APPS_SH="$ROOT/src/MagicNet/lib/magicnet/apps.sh"
CONFIG="$ROOT/src/MagicNet/.config/sing-box/config.json"

fail() {
    printf 'policy architecture failed: %s\n' "$*" >&2
    exit 1
}

[[ -f "$BYPASS" ]] || fail "missing app-bypass.list"
[[ -f "$APPS_SH" ]] || fail "missing apps.sh"
[[ -f "$CONFIG" ]] || fail "missing sing-box config.json"

# No runtime auto-seed of domestic catalogs (function definitions only — not comments).
if grep -Eq '^[[:space:]]*magicnet_app_bypass_ensure_critical|^[[:space:]]*magicnet_app_bypass_critical_packages' "$APPS_SH"; then
    fail "apps.sh still contains package-catalog auto-seed machinery"
fi
if grep -Fq 'magicnet-critical-bypass' "$APPS_SH" "$BYPASS" 2>/dev/null; then
    fail "critical-bypass seed markers must not remain in policy sources"
fi

# Bypass list must stay small and not pretend to cover all domestic apps.
bypass_count=$(grep -Ecv '^[[:space:]]*(#|$)' "$BYPASS" || true)
[[ "$bypass_count" -le 40 ]] || fail "app-bypass.list looks like a domestic catalog ($bypass_count packages)"

# Multi-VPN coexistence entries should remain (representative).
grep -Eq 'com\.tailscale\.ipn|com\.v2ray\.ang|com\.github\.metacubex\.clash\.meta' "$BYPASS" \
    || fail "app-bypass.list missing multi-VPN coexistence packages"

# Geodata / CN rule-set path must exist in shipped config (primary domestic split).
jq -e '
  ([.route.rules[]?
    | select((.outbound? == "cn-direct") and ((.rule_set // []) | length) > 0)] | length) >= 1
  and ([.route.rules[]?
    | select((.outbound? == "cn-direct") and (.package_name? != null))] | length) <= 1
' "$CONFIG" >/dev/null \
    || fail "config must prefer rule_set cn-direct; package cn-direct only as last-resort fallback"

# Package cn-direct, if present, must be the last route rule (last-resort).
jq -e '
  (.route.rules | length) as $n
  | (.route.rules
      | to_entries
      | map(select(.value.outbound? == "cn-direct" and (.value.package_name? != null)))
      | if length == 0 then true
        else length == 1 and .[0].key == ($n - 1)
        end)
' "$CONFIG" >/dev/null \
    || fail "domestic package cn-direct must be a single last-resort rule if present"

# recommendedBypass is WebUI-only — must not be imported by shell policy apply.
if grep -Fq 'recommendedBypass' "$APPS_SH"; then
    fail "apps.sh must not couple to WebUI recommendedBypass"
fi

printf 'policy architecture tests passed\n'

#!/usr/bin/env bash
# Architecture guard: geodata is primary; app-bypass is not a domestic app catalog.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BYPASS="$ROOT/src/MagicNet/.config/magicnet/app-bypass.list"
APPS_SH="$ROOT/src/MagicNet/lib/magicnet/apps.sh"
CONFIG="$ROOT/src/MagicNet/.config/sing-box/config.json"
CLI_RULES="$ROOT/crates/magicnet-cli/src/rules.rs"
MAGICBOX_CONFIG="$ROOT/MagicBox/app/src/Config.kt"
MAGICBOX_APPS="$ROOT/MagicBox/app/src/AppsPage.kt"
WEBUI_INSIGHTS="$ROOT/webui/src/components/pages/appPolicyInsights.ts"
WEBUI_APPS="$ROOT/webui/src/components/pages/AppsPage.vue"

fail() {
    printf 'policy architecture failed: %s\n' "$*" >&2
    exit 1
}

[[ -f "$BYPASS" ]] || fail "missing app-bypass.list"
[[ -f "$APPS_SH" ]] || fail "missing apps.sh"
[[ -f "$CONFIG" ]] || fail "missing sing-box config.json"
[[ -f "$CLI_RULES" ]] || fail "missing magicnet-cli rules.rs"

# No runtime auto-seed of domestic catalogs (function definitions only — not comments).
if grep -Eq '^[[:space:]]*magicnet_app_bypass_ensure_critical|^[[:space:]]*magicnet_app_bypass_critical_packages' "$APPS_SH"; then
    fail "apps.sh still contains package-catalog auto-seed machinery"
fi
if grep -Fq 'magicnet-critical-bypass' "$APPS_SH" "$BYPASS" 2>/dev/null; then
    fail "critical-bypass seed markers must not remain in policy sources"
fi

# Shipped bypass policy must be empty. Device-specific choices belong to runtime state, not source.
bypass_count=$(grep -Ecv '^[[:space:]]*(#|$)' "$BYPASS" || true)
[[ "$bypass_count" -eq 0 ]] \
    || fail "shipped app-bypass.list must not hardcode device-specific packages ($bypass_count found)"

jq -ne '
  def package_catalog:
    (.package_name? | type) == "array" and (.package_name | length) > 1;
  ({"package_name": "single"} | package_catalog | not)
  and ({"package_name": ["single"]} | package_catalog | not)
  and ({"package_name": ["first", "second"]} | package_catalog)
' >/dev/null || fail "package catalog detection must distinguish strings from multi-value arrays"

# Geodata / CN rule-set path must exist in shipped config (primary domestic split).
jq -e '
  ([.route.rules[]?
    | select((.outbound? == "cn-direct") and ((.rule_set // []) | length) > 0)] | length) >= 1
  and ([.route.rules[]?
    | select((.outbound? == "cn-direct") and (.package_name? != null))] | length) == 0
  and ([.dns.rules[]?
    | select((.package_name? | type) == "array" and (.package_name | length) > 1)] | length) == 0
' "$CONFIG" >/dev/null \
    || fail "config must use rule-set routing instead of hardcoded domestic package catalogs"

# Shipped TUN policy must not bypass a static package catalog.
jq -e '
  ([.inbounds[]?
    | select((.type // "") == "tun" and ((.exclude_package // []) | length) > 0)] | length) == 0
' "$CONFIG" >/dev/null \
    || fail "shipped TUN config must not hardcode package bypasses"

# Recommended bypass candidates are discovered from Android VpnService declarations.
# UI clients must not maintain separate package-name catalogs.
grep -Fq 'android.net.VpnService' "$CLI_RULES" \
    || fail "CLI recommendations must query Android VpnService declarations"
grep -Fq 'app recommendations' "$MAGICBOX_APPS" \
    || fail "MagicBox must load dynamic app recommendations from the CLI"
grep -Fq 'app recommendations' "$WEBUI_APPS" \
    || fail "WebUI must load dynamic app recommendations from the CLI"
if grep -Fq 'RECOMMENDED_BYPASS_PACKAGES' "$MAGICBOX_CONFIG" "$MAGICBOX_APPS"; then
    fail "MagicBox must not hardcode a recommended bypass package catalog"
fi
if grep -Eq 'export const recommendedBypass[[:space:]]*=[[:space:]]*\[' "$WEBUI_INSIGHTS"; then
    fail "WebUI must not hardcode a recommended bypass package catalog"
fi
if grep -Ehq "^[[:space:]]*['\"][A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*){2,}['\"],?[[:space:]]*$" \
    "$MAGICBOX_CONFIG" "$MAGICBOX_APPS" "$WEBUI_INSIGHTS" "$WEBUI_APPS"; then
    fail "app-policy UI sources must not contain hardcoded Android package catalogs"
fi

printf 'policy architecture tests passed\n'

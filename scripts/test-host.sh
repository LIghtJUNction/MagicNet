#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Shared fixture-based regression suite. Prepared-asset checks are opt-in so
# a clean checkout/CI does not depend on untracked rule sets or a system core.
# Generic KAM fswatch internals are checked in the KAM repo.
with_routing_assets=0
case "${1:-}" in
"") ;;
--with-routing-assets)
    with_routing_assets=1
    shift
    ;;
*)
    printf 'usage: bash scripts/test-host.sh [--with-routing-assets]\n' >&2
    exit 64
    ;;
esac
[ "$#" -eq 0 ] || {
    printf 'unexpected arguments\n' >&2
    exit 64
}
if [ "$with_routing_assets" -eq 1 ]; then
    command -v sing-box >/dev/null 2>&1 || {
        printf 'prepared routing checks require sing-box and rule-set assets\n' >&2
        exit 127
    }
else
    printf 'Prepared routing/DNS asset checks excluded; use --with-routing-assets to include them.\n'
fi

for tool in jq python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'missing required command: %s\n' "$tool" >&2
        exit 127
    fi
done

jq empty src/MagicNet/.config/sing-box/config.json
bash scripts/test-repository-hygiene.sh
bash scripts/test-config-template-pin.sh
sh scripts/test-kamfw-i18n.sh
sh scripts/test-magicnet-i18n.sh
if [ "$with_routing_assets" -eq 1 ]; then
    bash scripts/test-default-routing-policy.sh
fi
bash scripts/test-policy-architecture.sh
bash scripts/test-ad-routing.sh
bash scripts/test-app-routing-policy.sh
bash scripts/test-block-conf-safety.sh
bash scripts/test-block-apply-safety.sh
bash scripts/test-wechat-routing.sh
bash scripts/test-action-routing.sh
bash scripts/test-route-apply-safety.sh
bash scripts/test-hotspot-routing.sh
bash scripts/test-singbox-route-apply-safety.sh
bash scripts/test-anthropic-routing.sh
bash scripts/test-mcp-phase-config.sh
bash scripts/test-chatgpt-voice-rules.sh
bash scripts/test-rule-hash-retry.sh
bash scripts/singbox-subscription-protocol-smoke.sh
bash scripts/test-subscription-fetch-policy.sh
bash scripts/test-subscription-usage.sh
bash scripts/test-singbox-pid-discovery.sh
bash scripts/test-singbox-ownership.sh
bash scripts/test-singbox-tristate-safety.sh
bash scripts/test-singbox-readiness.sh
bash scripts/test-supervisor-pid-safety.sh
bash scripts/test-process-cgroup-detach.sh
bash scripts/test-supervisor-orphan-prefilter.sh
bash scripts/test-supervisor-start-policy.sh
bash scripts/test-tun-interface-safety.sh
bash scripts/test-singbox-dataplane-preflight.sh
bash scripts/test-transparent-mode-config-safety.sh
bash scripts/test-ebpf-transparent-mode.sh
bash scripts/test-config-permissions.sh
bash scripts/test-config-lock-safety.sh
if [ "$with_routing_assets" -eq 1 ]; then
    bash scripts/test-dns-profile-safety.sh
fi
bash scripts/test-dns-leak-guard-timeout.sh
bash scripts/test-subscription-activation-order.sh
bash scripts/test-subscription-transaction-atomicity.sh
bash scripts/test-subscription-update-lock-safety.sh
bash scripts/test-subscription-transaction-journal-safety.sh
bash scripts/test-subscription-lifecycle.sh
bash scripts/test-subscription-stop-safety.sh
bash scripts/test-release-integrity.sh
python3 scripts/test-release-workflow.py

printf 'host regression suite passed\n'

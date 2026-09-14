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
    # Prepared/untracked assets describe this machine, not a reusable fixture.
    export CI_TEST_FORCE=1
else
    printf 'Prepared routing/DNS asset checks excluded; use --with-routing-assets to include them.\n'
fi

for tool in jq python3 curl openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'missing required command: %s\n' "$tool" >&2
        exit 127
    fi
done

check() {
    local script="$2"
    python3 "$ROOT/scripts/ci-test-cache.py" host "${script##*/}" -- "$@"
}

# Real loopback HTTPS/SOCKS tests; never substitute these for device acceptance.
check python3 scripts/test-website-probe.py
python3 scripts/ci-test-cache.py host config-json -- jq empty src/MagicNet/.config/sing-box/config.json
check bash scripts/test-repository-hygiene.sh
check bash scripts/test-module-entrypoints.sh
check bash scripts/test-config-template-pin.sh
check bash scripts/test-config-repository-migration.sh
check bash scripts/test-install-config-template.sh
check bash scripts/test-install-config-refresh.sh
check sh scripts/test-kamfw-i18n.sh
check sh scripts/test-magicnet-i18n.sh
if [ "$with_routing_assets" -eq 1 ]; then
    check bash scripts/test-default-routing-policy.sh
fi
check bash scripts/test-policy-architecture.sh
check python3 scripts/test-routing-optimizer.py
check bash scripts/test-ad-routing.sh
check bash scripts/test-app-routing-policy.sh
check bash scripts/test-block-conf-safety.sh
check bash scripts/test-block-apply-safety.sh
check bash scripts/test-wechat-routing.sh
check bash scripts/test-action-routing.sh
check bash scripts/test-route-apply-safety.sh
check bash scripts/test-hotspot-routing.sh
check bash scripts/test-singbox-route-apply-safety.sh
check bash scripts/test-anthropic-routing.sh
check bash scripts/test-mcp-phase-config.sh
check bash scripts/test-tailscale-login.sh
check bash scripts/test-chatgpt-voice-rules.sh
check bash scripts/test-rule-hash-retry.sh
check bash scripts/singbox-subscription-protocol-smoke.sh
check bash scripts/test-service-selectors.sh
check bash scripts/test-subscription-fetch-policy.sh
check bash scripts/test-subscription-usage.sh
check bash scripts/test-singbox-pid-discovery.sh
check bash scripts/test-singbox-ownership.sh
check bash scripts/test-singbox-tristate-safety.sh
check bash scripts/test-singbox-readiness.sh
check sh scripts/test-singbox-runtime-memory.sh
check bash scripts/test-supervisor-pid-safety.sh
check bash scripts/test-process-cgroup-detach.sh
check bash scripts/test-supervisor-orphan-prefilter.sh
check bash scripts/test-supervisor-start-policy.sh
check bash scripts/test-tun-interface-safety.sh
check bash scripts/test-singbox-dataplane-preflight.sh
check bash scripts/test-transparent-mode-config-safety.sh
check bash scripts/test-ebpf-transparent-mode.sh
check bash scripts/test-config-permissions.sh
check bash scripts/test-config-lock-safety.sh
check sh scripts/test-runtime-fingerprint-safety.sh
check sh scripts/test-runtime-temp-dirs.sh
if [ "$with_routing_assets" -eq 1 ]; then
    check bash scripts/test-dns-profile-safety.sh --with-routing-assets
else
    check bash scripts/test-dns-profile-safety.sh
fi
check bash scripts/test-dns-leak-guard-timeout.sh
check python3 scripts/test-dns-capture-fast-path.py
check python3 scripts/test-dns-output-order.py
check sh scripts/test-startup-network-safety.sh
check bash scripts/test-submodule-updates.sh
check bash scripts/test-subscription-activation-order.sh
check bash scripts/test-subscription-transaction-atomicity.sh
check bash scripts/test-subscription-update-lock-safety.sh
check bash scripts/test-subscription-transaction-journal-safety.sh
check bash scripts/test-subscription-lifecycle.sh
check bash scripts/test-subscription-stop-safety.sh
check bash scripts/test-webui-build-cache.sh
check bash scripts/test-release-integrity.sh
check python3 scripts/test-release-workflow.py
check python3 scripts/test-release-cache.py
check python3 scripts/test-ci-submodules.py
check python3 scripts/test-network-check.py

printf 'host regression suite passed\n'

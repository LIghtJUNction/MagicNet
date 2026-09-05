#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 127
    fi
}

need kam
need shellcheck
need jq
need python3
need cargo

kam validate

bash scripts/lint-shell.sh

jq empty src/MagicNet/.config/sing-box/config.json
bash scripts/test-repository-hygiene.sh
bash scripts/test-config-template-pin.sh
sh scripts/test-kamfw-i18n.sh
bash scripts/test-default-routing-policy.sh
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
# Generic KAM fswatch internals are tested in the KAM repository; keep this
# gate focused on MagicNet's supervisor policy and process-identity boundary.
bash scripts/test-supervisor-start-policy.sh
bash scripts/test-tun-interface-safety.sh
bash scripts/test-singbox-dataplane-preflight.sh
bash scripts/test-transparent-mode-config-safety.sh
bash scripts/test-ebpf-transparent-mode.sh
bash scripts/test-config-permissions.sh
bash scripts/test-config-lock-safety.sh
bash scripts/test-dns-profile-safety.sh
bash scripts/test-dns-leak-guard-timeout.sh
bash scripts/test-subscription-activation-order.sh
bash scripts/test-subscription-transaction-atomicity.sh
bash scripts/test-subscription-update-lock-safety.sh
bash scripts/test-subscription-transaction-journal-safety.sh
bash scripts/test-subscription-lifecycle.sh
bash scripts/test-release-integrity.sh
python3 scripts/test-release-workflow.py

KAM_HOOKS_ROOT=hooks KAM_MODULE_ROOT=src/MagicNet bash hooks/pre-build/6000.check_config.sh
MODPATH="$ROOT/src/MagicNet" sh -c '. "$MODPATH/lib/kamfw/.kamfwrc"; import __runtime__; . "$MODPATH/lib/magicnet.sh"; kamfw run post-mount -- smoke'

if command -v bun >/dev/null 2>&1; then
    (cd webui && bun install --frozen-lockfile && bun run typecheck && bun run build && bun run test)
else
    need npm
    (cd webui && npm ci && npm run check)
fi
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
if compgen -G "dist/*.zip" >/dev/null; then
    package_zip="$(compgen -G "dist/*.zip" | head -n1)"
    scripts/package-smoke.sh "$package_zip"
    scripts/package-install-smoke.sh "$package_zip"
    scripts/fake-magisk-smoke.sh "$package_zip"
else
    scripts/fake-magisk-smoke.sh
fi
git diff --check

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

mapfile -t bash_shell_files < <(
    find hooks/pre-build hooks/post-build hooks/lib -type f -name '*.sh' -print
    find scripts -maxdepth 1 -type f -name '*.sh' -print
    printf '%s\n' kam.sh
)
shellcheck -s bash -e SC1091,SC2317,SC2329,SC2059 "${bash_shell_files[@]}"

mapfile -t posix_shell_files < <(
    find src/MagicNet -maxdepth 1 -type f -name '*.sh' -print
    find src/MagicNet/system/bin -type f -print 2>/dev/null || true
    printf '%s\n' src/MagicNet/lib/magicnet.sh
)
shellcheck -s sh -e SC1091,SC1090,SC2329,SC2059 "${posix_shell_files[@]}"

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
bash scripts/test-singbox-pid-discovery.sh
bash scripts/test-singbox-ownership.sh
bash scripts/test-singbox-readiness.sh
bash scripts/test-supervisor-pid-safety.sh
bash scripts/test-fswatch-install-contract.sh
bash scripts/test-supervisor-start-policy.sh
bash scripts/test-tun-interface-safety.sh
bash scripts/test-transparent-mode-config-safety.sh
bash scripts/test-config-permissions.sh
bash scripts/test-config-lock-safety.sh
bash scripts/test-dns-profile-safety.sh
bash scripts/test-subscription-activation-order.sh
bash scripts/test-subscription-transaction-atomicity.sh
bash scripts/test-subscription-update-lock-safety.sh
bash scripts/test-subscription-transaction-journal-safety.sh
bash scripts/test-subscription-lifecycle.sh
bash scripts/test-release-integrity.sh

KAM_HOOKS_ROOT=hooks KAM_MODULE_ROOT=src/MagicNet bash hooks/pre-build/6000.check_config.sh
MODPATH="$ROOT/src/MagicNet" sh -c '. "$MODPATH/lib/kamfw/.kamfwrc"; import __runtime__; . "$MODPATH/lib/magicnet.sh"; kamfw run post-mount -- smoke'

if command -v bun >/dev/null 2>&1; then
    (cd webui && bun install --frozen-lockfile && bun run typecheck && bun run build && bun run test)
else
    need npm
    (cd webui && npm install && npm run typecheck && npm run build && npm run test)
fi
cargo check -p magicnet-cli
cargo check -p magicnet-mcp-server
if compgen -G "dist/*.zip" >/dev/null; then
    package_zip="$(compgen -G "dist/*.zip" | head -n1)"
    scripts/package-smoke.sh "$package_zip"
    scripts/package-install-smoke.sh "$package_zip"
    scripts/fake-magisk-smoke.sh "$package_zip"
else
    scripts/fake-magisk-smoke.sh
fi
git diff --check

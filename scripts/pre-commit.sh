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
bash scripts/test-host.sh --with-routing-assets

KAM_HOOKS_ROOT=hooks KAM_MODULE_ROOT=src/MagicNet bash hooks/pre-build/6000.check_config.sh
MODPATH="$ROOT/src/MagicNet" sh -c '. "$MODPATH/lib/kamfw/.kamfwrc"; import __runtime__; . "$MODPATH/lib/magicnet.sh"; kamfw run post-mount -- smoke'

if command -v bun >/dev/null 2>&1; then
    (cd webui && bun install --frozen-lockfile && bun run check)
else
    need npm
    (cd webui && npm ci && npm run check)
fi
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-targets --all-features --locked
if compgen -G "dist/*.zip" >/dev/null; then
    package_zip="$(compgen -G "dist/*.zip" | head -n1)"
    scripts/package-smoke.sh "$package_zip"
    scripts/package-install-smoke.sh "$package_zip"
    scripts/fake-magisk-smoke.sh "$package_zip"
else
    scripts/fake-magisk-smoke.sh
fi
git diff --check

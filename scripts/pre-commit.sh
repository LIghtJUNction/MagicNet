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

KAM_HOOKS_ROOT=hooks KAM_MODULE_ROOT=src/MagicNet bash hooks/pre-build/6000.check_config.sh
MODPATH="$ROOT/src/MagicNet" sh -c '. "$MODPATH/lib/kamfw/.kamfwrc"; import __runtime__; . "$MODPATH/lib/magicnet.sh"; kamfw run post-mount -- smoke'

if command -v bun >/dev/null 2>&1; then
    (cd webui && bun install --frozen-lockfile && bun run typecheck && bun run build)
else
    need npm
    (cd webui && npm install && npm run typecheck && npm run build)
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

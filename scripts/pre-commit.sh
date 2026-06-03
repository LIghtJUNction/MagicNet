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
need bun

kam validate

shellcheck -s bash -e SC1091,SC2317,SC2329,SC2059 \
    hooks/pre-build/*.sh \
    hooks/post-build/*.sh \
    hooks/lib/*.sh \
    kam.sh

shellcheck -s sh -e SC1091,SC1090,SC2329,SC2059 \
    src/MagicNet/*.sh \
    src/MagicNet/system/bin/* \
    src/MagicNet/lib/magicnet.sh

python3 -c 'import yaml, pathlib; yaml.safe_load(pathlib.Path("src/MagicNet/.config/mihomo/config.yaml").read_text())'
jq empty src/MagicNet/.config/sing-box/config.json

KAM_HOOKS_ROOT=hooks KAM_MODULE_ROOT=src/MagicNet bash hooks/pre-build/6000.check_config.sh
MODPATH="$ROOT/src/MagicNet" sh -c '. "$MODPATH/lib/kamfw/.kamfwrc"; import __runtime__; . "$MODPATH/lib/magicnet.sh"; kamfw run post-mount -- smoke'

(cd webui && bun run typecheck && bun run build)
cargo check -p magicnet-cli
cargo check -p magicnet-mcp-server
git diff --check

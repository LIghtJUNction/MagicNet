#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT/src/MagicNet/.config/sing-box"
EDITOR="$ROOT/crates/magicnet-cli/src/config_editor.rs"

fail() {
    printf 'config template pin test failed: %s\n' "$*" >&2
    exit 1
}

[[ -f "$CONFIG_DIR/config.json" ]] || fail "MagicSingBox submodule is not initialized"

submodule_revision=$(git -C "$CONFIG_DIR" rev-parse HEAD)
pinned_revision=$(sed -n 's#.*MagicSingBox/\([0-9a-f]\{40\}\)/config\.json.*#\1#p' "$EDITOR")
[[ "$pinned_revision" == "$submodule_revision" ]] ||
    fail "runtime template revision $pinned_revision differs from submodule $submodule_revision"

pinned_sha256=$(sed -n '/MAGIC_SINGBOX_TEMPLATE_SHA256/{n;s/.*"\([0-9a-f]\{64\}\)".*/\1/p;}' "$EDITOR")
config_sha256=$(sha256sum "$CONFIG_DIR/config.json" | awk '{print $1}')
[[ "$pinned_sha256" == "$config_sha256" ]] ||
    fail "runtime template checksum $pinned_sha256 differs from packaged config $config_sha256"

printf 'Config template pin test passed\n'

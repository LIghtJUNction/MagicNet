#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT/src/MagicNet/.config/sing-box"
REPOSITORY_CONFIG="$ROOT/src/MagicNet/.config/magicnet/singbox-config-repo.conf"

fail() {
    printf 'config template pin test failed: %s\n' "$*" >&2
    exit 1
}

[[ -f "$CONFIG_DIR/config.json" ]] || fail "MagicSingBox submodule is not initialized"

[[ -f "$REPOSITORY_CONFIG" ]] || fail "config repository settings are missing"
grep -Fqx 'MAGICNET_SINGBOX_CONFIG_REPO_URL=https://github.com/LIghtJUNction/MagicSingBox.git' "$REPOSITORY_CONFIG" ||
    fail "default config repository is not MagicSingBox"
grep -Fqx 'MAGICNET_SINGBOX_CONFIG_REPO_REF=ba67cdbe771dff7e06c06bd754cc67699eeea8c0' "$REPOSITORY_CONFIG" ||
    fail "default config repository ref is not pinned"
grep -Fqx 'MAGICNET_SINGBOX_CONFIG_REPO_PATH=config.json' "$REPOSITORY_CONFIG" ||
    fail "default config repository file is not config.json"
grep -Fqx 'MAGICNET_SINGBOX_CONFIG_REPO_SHA256=6faa2cfcc44c305e30bc64cec84202b95d0a1592f012ab1f8dd65eae6d489258' "$REPOSITORY_CONFIG" ||
    fail "default config repository digest is not pinned"

packaged_sha256=$(sha256sum "$CONFIG_DIR/config.json" | awk '{print $1}')
submodule_sha256=$(git -C "$CONFIG_DIR" show HEAD:config.json | sha256sum | awk '{print $1}')
[[ "$packaged_sha256" == "$submodule_sha256" ]] ||
    fail "packaged config differs from the pinned MagicSingBox submodule"

printf 'Config template repository test passed\n'

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT/src/MagicNet/.config/sing-box"
REPOSITORY_CONFIG="$ROOT/src/MagicNet/.config/magicnet/singbox-config-repo.conf"
CLI_CONFIG="$ROOT/crates/magicnet-cli/src/config_editor.rs"
CUSTOMIZE="$ROOT/src/MagicNet/customize.sh"
WEBUI_CONFIG="$ROOT/webui/src/components/pages/ConfigPage.vue"

fail() {
    printf 'config template pin test failed: %s\n' "$*" >&2
    exit 1
}

[[ -f "$CONFIG_DIR/config.json" ]] || fail "MagicSingBox submodule is not initialized"
[[ -f "$REPOSITORY_CONFIG" ]] || fail "config repository settings are missing"

submodule_ref="$(git -C "$CONFIG_DIR" rev-parse HEAD)"
packaged_sha256="$(sha256sum "$CONFIG_DIR/config.json" | awk '{print $1}')"
submodule_sha256="$(git -C "$CONFIG_DIR" show HEAD:config.json | sha256sum | awk '{print $1}')"
[[ "$packaged_sha256" == "$submodule_sha256" ]] ||
    fail "packaged config differs from the pinned MagicSingBox submodule"

repo_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key { sub($1 "=", ""); print; exit }' "$REPOSITORY_CONFIG"
}

repo_url="$(repo_value MAGICNET_SINGBOX_CONFIG_REPO_URL)"
repo_ref="$(repo_value MAGICNET_SINGBOX_CONFIG_REPO_REF)"
repo_path="$(repo_value MAGICNET_SINGBOX_CONFIG_REPO_PATH)"
repo_sha256="$(repo_value MAGICNET_SINGBOX_CONFIG_REPO_SHA256)"

[[ "$repo_url" == 'https://github.com/LIghtJUNction/MagicSingBox.git' ]] ||
    fail "default config repository is not MagicSingBox"
[[ "$repo_path" == 'config.json' ]] ||
    fail "default config repository file is not config.json"
[[ "$repo_ref" == "$submodule_ref" && "$repo_sha256" == "$packaged_sha256" ]] ||
    fail "default config pin is stale: configured ref=$repo_ref sha256=$repo_sha256; expected ref=$submodule_ref sha256=$packaged_sha256"

grep -Fq "const MAGIC_SINGBOX_REPOSITORY_REF: &str = \"$submodule_ref\";" "$CLI_CONFIG" ||
    fail "CLI default repository ref does not match the MagicSingBox submodule"
grep -Fq "    \"$packaged_sha256\";" "$CLI_CONFIG" ||
    fail "CLI default repository digest does not match packaged config.json"
grep -Fq "'MAGICNET_SINGBOX_CONFIG_REPO_REF=$submodule_ref'" "$CUSTOMIZE" ||
    fail "installer default repository ref does not match the MagicSingBox submodule"
grep -Fq "'MAGICNET_SINGBOX_CONFIG_REPO_SHA256=$packaged_sha256'" "$CUSTOMIZE" ||
    fail "installer default repository digest does not match packaged config.json"
grep -Fq "const DEFAULT_CONFIG_REPO_REF = \"$submodule_ref\";" "$WEBUI_CONFIG" ||
    fail "WebUI default repository ref does not match the MagicSingBox submodule"
grep -Fq "const DEFAULT_CONFIG_REPO_SHA256 = \"$packaged_sha256\";" "$WEBUI_CONFIG" ||
    fail "WebUI default repository digest does not match packaged config.json"

printf 'Config template repository test passed\n'

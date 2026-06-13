#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP_PATH="${1:-}"

if [[ -z "$ZIP_PATH" ]]; then
    module_id="$(sed -n 's/^id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$ROOT/kam.toml" | head -n1)"
    ZIP_PATH="$ROOT/dist/${module_id}.zip"
elif [[ "$ZIP_PATH" != /* ]]; then
    ZIP_PATH="$ROOT/$ZIP_PATH"
fi

fail() {
    printf 'package smoke failed: %s\n' "$*" >&2
    exit 1
}

require_entry() {
    local entry="$1"
    grep -Fx "$entry" "$entries_file" >/dev/null || fail "missing zip entry: $entry"
}

for tool in file grep readelf sed unzip zipinfo; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

[[ -f "$ZIP_PATH" ]] || fail "zip not found: $ZIP_PATH"
unzip -tq "$ZIP_PATH"

entries_file="$(mktemp)"
elf_tmp="$(mktemp -d)"
cleanup() {
    rm -f "$entries_file"
    rm -rf "$elf_tmp"
}
trap cleanup EXIT
unzip -Z1 "$ZIP_PATH" >"$entries_file"

require_entry module.prop
require_entry customize.sh
require_entry cli
require_entry post-fs-data.sh
require_entry bin/magicnet-cli
require_entry bin/magicnet-mcp-server
require_entry bin/mihomo
require_entry bin/sing-box
require_entry lib/kamfw/watchdog.sh
require_entry lib/kamfw/fswatch.sh

require_executable_entry() {
    local entry="$1"
    zipinfo -l "$ZIP_PATH" "$entry" 2>/dev/null | grep -E '^-rwx' >/dev/null \
        || fail "$entry is not executable in zip"
}

require_android_arm64_elf() {
    local entry="$1"
    local output
    unzip -oq "$ZIP_PATH" "$entry" -d "$elf_tmp"
    output="$(file -L "$elf_tmp/$entry")"
    grep -F 'ELF 64-bit' <<<"$output" >/dev/null \
        || fail "$entry is not an ELF64 binary: $output"
    grep -F 'ARM aarch64' <<<"$output" >/dev/null \
        || fail "$entry is not AArch64: $output"
    grep -F 'interpreter /system/bin/linker64' <<<"$output" >/dev/null \
        || fail "$entry is not linked for Android linker64: $output"
    readelf -h "$elf_tmp/$entry" | grep -F 'Machine:                           AArch64' >/dev/null \
        || fail "$entry ELF machine is not AArch64"
}

for entry in cli post-fs-data.sh bin/magicnet-cli bin/magicnet-mcp-server bin/mihomo bin/sing-box; do
    require_executable_entry "$entry"
done

for entry in cli bin/magicnet-cli bin/magicnet-mcp-server bin/mihomo bin/sing-box; do
    require_android_arm64_elf "$entry"
done

if grep -E '(^|/)\.git($|/)' "$entries_file" >/dev/null; then
    fail "zip contains .git metadata"
fi

legacy_bin_pattern='^\.local/'"bin"
if grep -E "$legacy_bin_pattern" "$entries_file" >/dev/null; then
    fail "zip contains legacy runtime bin entries"
fi

if grep -Fx '.local/subscriptions.env' "$entries_file" >/dev/null; then
    fail "zip contains local subscription memory"
fi

check_no_subscription_secret() {
    local entry="$1"
    grep -Fx "$entry" "$entries_file" >/dev/null || return 0
    if unzip -p "$ZIP_PATH" "$entry" | grep -Eiq '^[[:space:]]*[^#[:space:]].*(https?://|ss://|trojan://|vmess://|vless://|hysteria2://|tuic://|socks5://|sub=|token=|uuid=|password=|passwd=)'; then
        fail "$entry contains subscription-like secrets"
    fi
}

check_no_subscription_secret '.config/sing-box/subscription.url'

watchdog_text="$(unzip -p "$ZIP_PATH" lib/kamfw/watchdog.sh)"
fswatch_text="$(unzip -p "$ZIP_PATH" lib/kamfw/fswatch.sh)"
# shellcheck disable=SC2016
grep -F 'nohup sh "$_wd_script_file"' <<<"$watchdog_text" >/dev/null \
    || fail "watchdog does not launch detached loop script"
grep -F 'KAM_MODULES' <<<"$watchdog_text" >/dev/null \
    || fail "watchdog loop does not reset KAM_MODULES"
# shellcheck disable=SC2016
grep -F 'nohup sh "$_fw_script_file"' <<<"$fswatch_text" >/dev/null \
    || fail "fswatch does not launch detached loop script"
# shellcheck disable=SC2016
grep -F '_fw_tmp_dir="${TMPDIR:-}"' <<<"$fswatch_text" >/dev/null \
    || fail "fswatch does not guard invalid TMPDIR"

printf 'package smoke passed: %s\n' "$ZIP_PATH"

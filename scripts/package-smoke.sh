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

for tool in file grep jq python3 readelf sed unzip zipinfo; do
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

if grep -Eq '(^/)|((^|/)\.\.(/|$))' "$entries_file"; then
    fail "zip contains an unsafe absolute or parent-traversal entry"
fi

require_entry module.prop
require_entry customize.sh
require_entry cli
require_entry bin/magicnet-cli
require_entry bin/magicnet-mcp-server
require_entry bin/sing-box
require_entry bin/ecapture
require_entry lib/kamfw/watchdog.sh
require_entry lib/kamfw/fswatch.sh
require_entry lib/kamfw/__singbox__.sh
require_entry lib/magicnet_singbox_subscribe.sh
require_entry lib/magicnet/transparent.sh
require_entry .config/sing-box/config.json
for entry in common fetch parse config proxylink update; do
    require_entry "lib/magicnet/singbox_subscribe/$entry.sh"
done

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
    if ! grep -F 'interpreter /system/bin/linker64' <<<"$output" >/dev/null \
        && ! grep -F 'statically linked' <<<"$output" >/dev/null; then
        fail "$entry is neither linked for Android linker64 nor static: $output"
    fi
    readelf -h "$elf_tmp/$entry" | grep -F 'Machine:                           AArch64' >/dev/null \
        || fail "$entry ELF machine is not AArch64"
}

for entry in cli bin/magicnet-cli bin/magicnet-mcp-server bin/sing-box bin/ecapture; do
    require_executable_entry "$entry"
done

for entry in cli bin/magicnet-cli bin/magicnet-mcp-server bin/sing-box bin/ecapture; do
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

if grep -E '(^|/)(mihomo|__mihomo__)(\.sh)?($|/)' "$entries_file" >/dev/null; then
    fail "zip contains legacy mihomo entries"
fi

if grep -E '(^|/)\.local/bin($|/)' "$entries_file" >/dev/null; then
    fail "zip contains legacy .local/bin runtime entries"
fi

if unzip -p "$ZIP_PATH" .config/kamfw/.envrc 2>/dev/null | grep -Eq 'MAGIC_(MIHOMO|HOTSPOT_FORWARD|VPN_COEXIST)'; then
    fail "kamfw env exports legacy runtime flags"
fi

if grep -E '(^|/)(capture_(common|mihomo|singbox)\.sh|capture\.conf|post-fs-data\.sh|sepolice\.rule|system/etc/security/cacerts)(/|$)' "$entries_file" >/dev/null; then
    fail "zip contains legacy proxy-capture entries"
fi

check_no_subscription_secret() {
    local entry="$1"
    grep -Fx "$entry" "$entries_file" >/dev/null || return 0
    if unzip -p "$ZIP_PATH" "$entry" | grep -Eiq '^[[:space:]]*[^#[:space:]].*(https?://|ss://|trojan://|vmess://|vless://|hysteria2://|tuic://|socks5://|sub=|token=|uuid=|password=|passwd=)'; then
        fail "$entry contains subscription-like secrets"
    fi
}

check_no_subscription_secret '.config/sing-box/subscription.url'

subscription_module_root="$elf_tmp/subscription-module"
mkdir -p "$subscription_module_root"
unzip -oq "$ZIP_PATH" \
    'lib/magicnet_singbox_subscribe.sh' \
    'lib/magicnet/singbox_subscribe/*.sh' \
    -d "$subscription_module_root"
bash "$ROOT/scripts/singbox-subscription-protocol-smoke.sh" "$subscription_module_root"

transparent_module_root="$elf_tmp/transparent-module"
mkdir -p "$transparent_module_root/lib/magicnet"
unzip -p "$ZIP_PATH" lib/magicnet/transparent.sh \
    >"$transparent_module_root/lib/magicnet/transparent.sh"
if command -v sing-box >/dev/null 2>&1; then
    bash "$ROOT/scripts/orchestrator-mode-smoke.sh" \
        "$transparent_module_root/lib/magicnet/transparent.sh"
else
    printf '%s\n' 'package smoke: host sing-box unavailable; orchestrator runtime smoke skipped'
fi

route_fixture_dir="$elf_tmp/route-config"
mkdir -p "$route_fixture_dir"
unzip -p "$ZIP_PATH" lib/kamfw/__singbox__.sh >"$route_fixture_dir/__singbox__.sh"
cat >"$route_fixture_dir/config.json" <<'JSON'
{
  "route": {
    "auto_detect_interface": false,
    "default_interface": "rmnet_data3",
    "rules": []
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "bind_interface": "rmnet_data3"
    },
    {
      "type": "urltest",
      "tag": "proxy-auto",
      "interrupt_exist_connections": false,
      "outbounds": ["proxy", "direct"]
    },
    {
      "type": "selector",
      "tag": "proxy-rule",
      "outbounds": ["proxy", "direct"]
    },
    {
      "type": "selector",
      "tag": "network-test",
      "interrupt_exist_connections": false,
      "outbounds": ["proxy", "direct"]
    }
  ]
}
JSON

(
    import() { :; }
    set_i18n() { :; }
    # shellcheck disable=SC2034
    MODDIR="$route_fixture_dir"
    # shellcheck disable=SC1091
    . "$route_fixture_dir/__singbox__.sh"
    singbox_prepare_route_config "$route_fixture_dir/config.json"
)

jq -e '
    .route.auto_detect_interface == true
    and (.route | has("default_interface") | not)
    and ([.outbounds[] | select(.type == "direct") | has("bind_interface")] | all(. == false))
    and ([.outbounds[] | select(.type == "selector") | .interrupt_exist_connections] | all(. == true))
    and ([.outbounds[] | select(.type == "urltest") | .interrupt_exist_connections] == [false])
' "$route_fixture_dir/config.json" >/dev/null \
    || fail "sing-box route preparation keeps stale interfaces or selector connections"

route_no_jq_dir="$elf_tmp/route-config-no-jq"
route_no_jq_bin="$route_no_jq_dir/bin"
mkdir -p "$route_no_jq_bin"
for tool in awk mv rm; do
    ln -s "$(command -v "$tool")" "$route_no_jq_bin/$tool"
done
cp "$route_fixture_dir/__singbox__.sh" "$route_no_jq_dir/__singbox__.sh"
cat >"$route_no_jq_dir/config.json" <<'JSON'
{
  "route": {
    "auto_detect_interface": false,
    "default_interface": "rmnet_data3",
    "rules": []
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "bind_interface": "rmnet_data3"
    },
    {
      "type": "urltest",
      "tag": "proxy-auto",
      "interrupt_exist_connections": false,
      "outbounds": ["proxy", "direct"]
    },
    {
      "type": "selector",
      "tag": "proxy-} { } path\\segment \"quoted\"",
      "interrupt_exist_connections": false,
      "outbounds": ["proxy", "direct"]
    }
  ]
}
JSON

(
    import() { :; }
    set_i18n() { :; }
    # shellcheck disable=SC2034
    MODDIR="$route_no_jq_dir"
    PATH="$route_no_jq_bin"
    export PATH
    # shellcheck disable=SC1091
    . "$route_no_jq_dir/__singbox__.sh"
    singbox_prepare_route_config "$route_no_jq_dir/config.json"
)

jq -e '
    .route.auto_detect_interface == true
    and (.route | has("default_interface") | not)
    and ([.outbounds[] | select(.type == "direct") | has("bind_interface")] | all(. == false))
    and ([.outbounds[] | select(.type == "selector") | .interrupt_exist_connections] == [true])
    and ([.outbounds[] | select(.type == "urltest") | .interrupt_exist_connections] == [false])
' "$route_no_jq_dir/config.json" >/dev/null \
    || fail "sing-box no-jq route preparation changed URLTest interruption semantics"

python3 - "$ZIP_PATH" <<'PY'
import functools
import json
import os
import posixpath
import subprocess
import sys
import tempfile
import zipfile

zip_path = sys.argv[1]
package_zip = zipfile.ZipFile(zip_path)
config = json.loads(package_zip.read(".config/sing-box/config.json"))
rule_set_definitions = config.get("route", {}).get("rule_set", [])
rule_set_temp_dir = tempfile.TemporaryDirectory(prefix="magicnet-package-rules-")

canonical_tun_exclusions = [
    "192.168.0.0/16",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "224.0.0.0/4",
    "::1/128",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8",
    "fd7a:115c:a1e0::/48",
]
packaged_tuns = [
    inbound
    for inbound in config.get("inbounds", [])
    if inbound.get("type") == "tun" and inbound.get("tag") == "tun-in"
]
if len(packaged_tuns) != 1 or packaged_tuns[0].get("route_exclude_address") != canonical_tun_exclusions:
    raise SystemExit(
        "packaged base TUN exclusions are not canonical or exactly ordered: "

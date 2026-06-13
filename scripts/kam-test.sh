#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${KAM_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KAM_BIN="${KAM_BIN:-kam}"
MODE="${1:-quick}"
if [[ $# -gt 0 ]]; then
    shift
fi

HOST_ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-}"
if [[ -n "${MAGICNET_ANDROID_SDK_ROOT:-}" ]]; then
    ANDROID_SDK_ROOT="$MAGICNET_ANDROID_SDK_ROOT"
elif [[ -d "$HOME/.android-sdk-magicnet" ]]; then
    ANDROID_SDK_ROOT="$HOME/.android-sdk-magicnet"
elif [[ -n "$HOST_ANDROID_SDK_ROOT" ]]; then
    ANDROID_SDK_ROOT="$HOST_ANDROID_SDK_ROOT"
else
    ANDROID_SDK_ROOT="$HOME/.android-sdk-magicnet"
fi
ANDROID_HOME="${MAGICNET_ANDROID_HOME:-$ANDROID_SDK_ROOT}"
AVD_NAME="${MAGICNET_AVD_NAME:-MagicNet_API_33}"
ROOTAVD_DIR="${MAGICNET_ROOTAVD_DIR:-$HOME/.cache/magicnet-tools/rootAVD}"
ADB="${ADB:-adb}"
EMULATOR="${EMULATOR:-emulator}"

log() {
    printf '[kam-test] %s\n' "$*" >&2
}

fail() {
    printf '[kam-test] failed: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

sdk_path() {
    printf '%s:%s:%s:%s' \
        "$ANDROID_SDK_ROOT/platform-tools" \
        "$ANDROID_SDK_ROOT/emulator" \
        "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin" \
        "${PATH:-}"
}

zip_path() {
    local module_id
    module_id="$(sed -n 's/^id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$ROOT/kam.toml" | head -n1)"
    printf '%s/dist/%s.zip' "$ROOT" "$module_id"
}

ensure_zip() {
    local zip
    zip="$(zip_path)"
    if [[ ! -f "$zip" ]]; then
        log "dist zip missing; running kam build"
        (cd "$ROOT" && "$KAM_BIN" build)
    fi
    [[ -f "$zip" ]] || fail "zip not found after build: $zip"
    printf '%s' "$zip"
}

run_quick() {
    need cargo
    need jq
    need python3
    log "validating kam.toml"
    (cd "$ROOT" && "$KAM_BIN" validate)
    log "checking Rust crates"
    (cd "$ROOT" && cargo check -p magicnet-cli)
    (cd "$ROOT" && cargo check -p magicnet-mcp-server)
    log "checking default configs"
    python3 -c 'import yaml, pathlib; yaml.safe_load(pathlib.Path("src/MagicNet/.config/mihomo/config.yaml").read_text())'
    jq empty "$ROOT/src/MagicNet/.config/sing-box/config.json"
}

run_package() {
    local zip
    zip="$(ensure_zip)"
    "$ROOT/scripts/package-smoke.sh" "$zip"
    "$ROOT/scripts/package-install-smoke.sh" "$zip"
}

run_fake_magisk() {
    local zip
    zip="$(ensure_zip)"
    "$ROOT/scripts/fake-magisk-smoke.sh" "$zip"
}

find_emulator_serial() {
    "$ADB" devices | awk '$1 ~ /^emulator-/ && $2 == "device" { print $1; exit }'
}

adb_sh() {
    local serial="$1"
    shift
    "$ADB" -s "$serial" shell "$@"
}

adb_su() {
    local serial="$1"
    shift
    adb_sh "$serial" "su -c '$*'"
}

adb_su_retry() {
    local serial="$1"
    local attempts="$2"
    shift 2
    local delay="${MAGICNET_AVD_RETRY_DELAY:-2}"
    local rc=1
    for _attempt in $(seq 1 "$attempts"); do
        if adb_su "$serial" "$@"; then
            rc=0
            break
        fi
        rc=$?
        sleep "$delay"
    done
    return "$rc"
}

wait_for_boot() {
    local serial="$1"
    local booted=""
    "$ADB" -s "$serial" wait-for-device
    for _ in $(seq 1 180); do
        booted="$(adb_sh "$serial" getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
        if [[ "$booted" == "1" ]]; then
            log "emulator boot completed: $serial"
            return 0
        fi
        sleep 2
    done
    fail "emulator did not finish booting: $serial"
}

start_emulator() {
    local serial
    serial="$(find_emulator_serial)"
    if [[ -n "$serial" ]]; then
        printf '%s' "$serial"
        return 0
    fi

    need "$EMULATOR"
    log "starting AVD $AVD_NAME"
    "$EMULATOR" @"$AVD_NAME" \
        -no-snapshot \
        -writable-system \
        -no-audio \
        -no-window \
        -gpu swiftshader_indirect \
        -memory "${MAGICNET_AVD_MEMORY:-4096}" \
        >/tmp/magicnet-avd-emulator.log 2>&1 &

    for _ in $(seq 1 90); do
        serial="$(find_emulator_serial)"
        if [[ -n "$serial" ]]; then
            wait_for_boot "$serial"
            printf '%s' "$serial"
            return 0
        fi
        sleep 2
    done
    fail "failed to start emulator; see /tmp/magicnet-avd-emulator.log"
}

require_magisk_root() {
    local serial="$1"
    if ! adb_su "$serial" id | grep -q 'uid=0'; then
        fail "Magisk su is unavailable on $serial. Run: kam test rootavd-setup, then enable Shell in Magisk Superuser UI."
    fi
}

install_zip_on_avd() {
    local serial="$1"
    local zip="$2"
    local device_zip="/data/local/tmp/MagicNet.zip"
    log "removing stale MagicNet module state from emulator"
    adb_su "$serial" 'rm -rf /data/adb/modules_update/MagicNet /data/adb/modules/MagicNet'
    log "pushing module zip to $serial"
    "$ADB" -s "$serial" push "$zip" "$device_zip" >/dev/null
    adb_su "$serial" "chmod 0644 '$device_zip'"
    log "installing module through Magisk CLI"
    if ! adb_su "$serial" "MAGICNET_NONINTERACTIVE=1 magisk --install-module '$device_zip'"; then
        log "Magisk install failed; collecting device-side zip diagnostics"
        adb_su "$serial" "ls -l '$device_zip'; toybox ls -l '$device_zip' 2>/dev/null || true"
        adb_su "$serial" "unzip -t '$device_zip' >/dev/null && echo device_unzip_ok || echo device_unzip_failed" || true
        adb_su "$serial" "toybox unzip -l '$device_zip' >/dev/null && echo toybox_unzip_ok || echo toybox_unzip_failed" || true
        return 1
    fi
    log "rebooting emulator after module install"
    "$ADB" -s "$serial" reboot
    wait_for_boot "$serial"
}

build_and_push_x86_control_plane() {
    local serial="$1"
    if ! command -v cargo-ndk >/dev/null 2>&1; then
        log "cargo-ndk not found; skipping x86_64 CLI/MCP hot replacement"
        return 0
    fi
    log "building x86_64 CLI/MCP for AVD control-plane checks"
    (cd "$ROOT" && cargo ndk -t x86_64 build --release -p magicnet-cli -p magicnet-mcp-server)
    "$ADB" -s "$serial" push "$ROOT/target/x86_64-linux-android/release/magicnet-cli" /sdcard/Download/magicnet-cli >/dev/null
    "$ADB" -s "$serial" push "$ROOT/target/x86_64-linux-android/release/magicnet-mcp-server" /sdcard/Download/magicnet-mcp-server >/dev/null
    adb_su "$serial" 'cp /sdcard/Download/magicnet-cli /data/adb/modules/MagicNet/bin/magicnet-cli'
    adb_su "$serial" 'cp /sdcard/Download/magicnet-mcp-server /data/adb/modules/MagicNet/bin/magicnet-mcp-server'
    adb_su "$serial" 'chmod 0755 /data/adb/modules/MagicNet/bin/magicnet-cli /data/adb/modules/MagicNet/bin/magicnet-mcp-server'
}

download_release_asset() {
    local repo="$1"
    local pattern="$2"
    local output="$3"
    local api="https://api.github.com/repos/${repo}/releases/latest"
    local meta
    local name
    local url
    local digest
    local expected

    need curl
    need jq
    need sha256sum
    meta="$(curl -fsSL "$api" | jq -r --arg pattern "$pattern" '
        .assets[]
        | select(.name | test($pattern))
        | [.name, .browser_download_url, (.digest // "")]
        | @tsv
    ' | head -n1)"
    [[ -n "$meta" ]] || fail "release asset not found: $repo $pattern"
    IFS=$'\t' read -r name url digest <<<"$meta"
    [[ "$digest" == sha256:* ]] || fail "release asset missing sha256 digest: $name"
    expected="${digest#sha256:}"

    if [[ -f "$output" ]] && printf '%s  %s\n' "$expected" "$output" | sha256sum -c >/dev/null 2>&1; then
        log "cached $name matches release digest"
        return 0
    fi

    log "downloading $name"
    mkdir -p "$(dirname "$output")"
    if command -v aria2c >/dev/null 2>&1; then
        aria2c \
            --allow-overwrite=true \
            --auto-file-renaming=false \
            --continue=true \
            --connect-timeout=30 \
            --dir="$(dirname "$output")" \
            --file-allocation=none \
            --max-connection-per-server=8 \
            --max-tries=10 \
            --min-split-size=1M \
            --out="$(basename "$output")" \
            --retry-wait=2 \
            --split=8 \
            "$url"
    else
        curl -fL -C - \
            --retry 10 \
            --retry-all-errors \
            --connect-timeout 30 \
            --speed-limit 1024 \
            --speed-time 120 \
            --max-time 0 \
            "$url" -o "$output"
    fi
    printf '%s  %s\n' "$expected" "$output" | sha256sum -c >/dev/null
}

push_x86_core_binaries() {
    local serial="$1"
    local cache="${MAGICNET_AVD_CORE_CACHE:-$HOME/.cache/magicnet-tools/avd-cores}"
    local singbox_archive="$cache/sing-box-android-amd64.tar.gz"
    local mihomo_archive="$cache/mihomo-android-amd64.gz"
    local work

    need tar
    need gzip
    download_release_asset "SagerNet/sing-box" "android-amd64[.]tar[.]gz$" "$singbox_archive"
    download_release_asset "MetaCubeX/mihomo" "mihomo-android-amd64-.*[.]gz$" "$mihomo_archive"

    work="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-avd-cores.XXXXXX")"
    tar -xzf "$singbox_archive" -C "$work"
    find "$work" -type f -name sing-box -perm -u+x -print -quit | xargs -r -I{} cp "{}" "$work/sing-box"
    gzip -cd "$mihomo_archive" >"$work/mihomo"
    chmod 0755 "$work/sing-box" "$work/mihomo"

    "$ADB" -s "$serial" push "$work/sing-box" /data/local/tmp/sing-box >/dev/null
    "$ADB" -s "$serial" push "$work/mihomo" /data/local/tmp/mihomo >/dev/null
    adb_su "$serial" 'cp /data/local/tmp/sing-box /data/adb/modules/MagicNet/bin/sing-box'
    adb_su "$serial" 'cp /data/local/tmp/mihomo /data/adb/modules/MagicNet/bin/mihomo'
    adb_su "$serial" 'chmod 0755 /data/adb/modules/MagicNet/bin/sing-box /data/adb/modules/MagicNet/bin/mihomo'
    rm -rf "$work"
}

prepare_avd_node_fixtures() {
    local serial="$1"
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-avd-fixtures.XXXXXX")"

    "$ADB" -s "$serial" exec-out su -c 'cat /data/adb/modules/MagicNet/.config/sing-box/config.json' >"$work/sing-box.json"
    jq '.outbounds += [{"type":"vmess","tag":"fake-node","server":"127.0.0.1","server_port":443,"uuid":"00000000-0000-0000-0000-000000000000","security":"auto"}]' \
        "$work/sing-box.json" >"$work/sing-box.new.json"
    cat >"$work/A.yaml" <<'YAML'
proxies:
  - name: fake-node
    type: vmess
    server: 127.0.0.1
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    alterId: 0
    cipher: auto
YAML

    "$ADB" -s "$serial" push "$work/sing-box.new.json" /data/local/tmp/magicnet-sing-box.json >/dev/null
    "$ADB" -s "$serial" push "$work/A.yaml" /data/local/tmp/magicnet-mihomo-A.yaml >/dev/null
    adb_su "$serial" 'cp /data/local/tmp/magicnet-sing-box.json /data/adb/modules/MagicNet/.config/sing-box/config.json'
    adb_su "$serial" 'mkdir -p /data/adb/modules/MagicNet/.config/mihomo/proxies'
    adb_su "$serial" 'cp /data/local/tmp/magicnet-mihomo-A.yaml /data/adb/modules/MagicNet/.config/mihomo/proxies/A.yaml'
    adb_su "$serial" 'printf "%s\n" "https://example.invalid/subscription.yaml" > /data/adb/modules/MagicNet/.config/sing-box/subscription.url'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli sub set mihomo premium_a https://example.invalid/mihomo.yaml >/dev/null'
    rm -rf "$work"
}

verify_avd_network_rules() {
    local serial="$1"
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-avd-network.XXXXXX")"
    cat >"$work/verify-network.sh" <<'SH'
#!/system/bin/sh
set -e
MODDIR=/data/adb/modules/MagicNet
MODPATH=$MODDIR
export MODDIR MODPATH MAGIC_HOTSPOT_IFACES=ap0 MAGIC_TUN_IFACES=magicnet0 MAGIC_VPN_COEXIST_IFACES=tun0
. "$MODDIR/lib/kamfw/.kamfwrc"
import __runtime__
. "$MODDIR/lib/magicnet.sh"
magicnet_iface_exists() {
    case "$1" in
        ap0|magicnet0|tun0) return 0 ;;
        *) return 1 ;;
    esac
}
magicnet_collect_tun_ifaces() {
    printf '%s\n' magicnet0
}
magicnet_collect_hotspot_ifaces() {
    printf '%s\n' ap0
}
magicnet_collect_external_vpn_ifaces() {
    printf '%s\n' tun0
}
magicnet_enable_hotspot_forward
chain="$(magicnet_pick_forward_chain)"
if ! iptables -S "$chain" | grep -F -- "-i ap0 -o magicnet0 -j ACCEPT" >/dev/null; then
    iptables -S "$chain"
    exit 1
fi
if ! iptables -t nat -S POSTROUTING | grep -F -- "-o magicnet0 -j MASQUERADE" >/dev/null; then
    iptables -t nat -S POSTROUTING
    exit 1
fi
magicnet_enable_vpn_coexist
if ! ip rule show | grep -F "iif tun0" | grep -F "lookup main" >/dev/null; then
    ip rule show
    exit 1
fi
magicnet_disable_hotspot_forward
magicnet_disable_vpn_coexist
SH
    "$ADB" -s "$serial" push "$work/verify-network.sh" /data/local/tmp/magicnet-verify-network.sh >/dev/null
    adb_su "$serial" 'chmod 0755 /data/local/tmp/magicnet-verify-network.sh'
    adb_su "$serial" 'sh /data/local/tmp/magicnet-verify-network.sh'
    rm -rf "$work"
}

verify_avd_runtime_features() {
    local serial="$1"
    log "verifying hotspot, VPN coexistence, and core startup on AVD"
    prepare_avd_node_fixtures "$serial"
    adb_su_retry "$serial" 3 '/data/adb/modules/MagicNet/cli config-editor validate sing-box'
    adb_su_retry "$serial" 3 '/data/adb/modules/MagicNet/cli config-editor validate mihomo'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli hotspot set proxy'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli hotspot status' | grep -qx 'mode=proxy'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli vpn set on'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli vpn status' | grep -qx 'mode=on'
    verify_avd_network_rules "$serial"
    adb_su "$serial" 'MAGICNET_WATCHDOG_ENABLED=0 MAGICNET_FSWATCH_ENABLED=0 MAGICNET_NOTIFY_ENABLED=0 /data/adb/modules/MagicNet/cli service restart sing-box'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli service status' | grep -Eq '^  sing-box: [0-9]+'
    adb_su "$serial" 'MAGICNET_WATCHDOG_ENABLED=0 MAGICNET_FSWATCH_ENABLED=0 MAGICNET_NOTIFY_ENABLED=0 /data/adb/modules/MagicNet/cli service restart mihomo'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli service status' | grep -Eq '^  mihomo:[[:space:]]+[0-9]+'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli service stop'
}

verify_avd_install() {
    local serial="$1"
    local abi
    abi="$(adb_sh "$serial" getprop ro.product.cpu.abi | tr -d '\r')"
    log "AVD ABI: $abi"
    adb_su "$serial" 'test -d /data/adb/modules/MagicNet && echo module_present'
    adb_su "$serial" 'cat /data/adb/modules/MagicNet/module.prop | sed -n "1,20p"'
    adb_su "$serial" 'test ! -e /data/adb/modules/MagicNet/.local/bin && echo legacy_local_bin_absent'

    case "$abi" in
        x86|x86_64)
            log "official package binaries are arm64; using x86_64 CLI/MCP hot replacement for management checks only"
            build_and_push_x86_control_plane "$serial"
            push_x86_core_binaries "$serial"
            ;;
    esac

    adb_su "$serial" '/data/adb/modules/MagicNet/cli help >/dev/null && echo cli_ok'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli mcp status || true'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli service status || true'
    verify_avd_runtime_features "$serial"
}

collect_avd_logs() {
    local serial="$1"
    local out_dir="$ROOT/logs"
    mkdir -p "$out_dir"
    "$ADB" -s "$serial" logcat -d -b all -v threadtime >"$out_dir/avd-logcat.log" 2>/dev/null || true
    adb_su "$serial" 'tail -n 200 /data/adb/modules/MagicNet/.log/service.log 2>/dev/null || true'
    adb_su "$serial" 'tail -n 200 /data/adb/modules/MagicNet/.log/sing-box.log 2>/dev/null || true'
    adb_su "$serial" 'tail -n 200 /data/adb/modules/MagicNet/.log/mcp-server.log 2>/dev/null || true'
    log "saved logcat to $out_dir/avd-logcat.log"
}

run_avd() {
    export ANDROID_SDK_ROOT ANDROID_HOME
    export PATH
    PATH="$(sdk_path)"
    need "$ADB"
    local zip
    local serial
    zip="$(ensure_zip)"
    "$ROOT/scripts/package-smoke.sh" "$zip"
    serial="${ANDROID_SERIAL:-$(start_emulator)}"
    wait_for_boot "$serial"
    require_magisk_root "$serial"
    install_zip_on_avd "$serial" "$zip"
    require_magisk_root "$serial"
    verify_avd_install "$serial"
    collect_avd_logs "$serial"
}

run_rootavd_setup() {
    export ANDROID_SDK_ROOT ANDROID_HOME
    export PATH
    PATH="$(sdk_path)"
    local ramdisk="$ANDROID_SDK_ROOT/system-images/android-33/google_apis_playstore/x86_64/ramdisk.img"
    [[ -x "$ROOTAVD_DIR/rootAVD.sh" ]] || fail "rootAVD.sh not found: $ROOTAVD_DIR/rootAVD.sh"
    [[ -f "$ramdisk" ]] || fail "AVD ramdisk not found: $ramdisk"
    log "patching AVD ramdisk with rootAVD"
    (cd "$ROOTAVD_DIR" && printf '\n' | ./rootAVD.sh "$ramdisk")
}

usage() {
    cat <<'EOF'
Usage: kam test [mode]

Modes:
  quick          Validate metadata, Rust crates, and default config syntax.
  package        Build if needed, then run ZIP structure and install smoke tests.
  fake-magisk    Run host-side Magisk module simulation.
  local          Run quick + package + fake-magisk.
  avd            Install and verify the ZIP on a Magisk-enabled AVD/rootAVD emulator.
  rootavd-setup  Patch the default API 33 x86_64 AVD ramdisk with rootAVD.
  help           Show this help.

Environment:
  MAGICNET_AVD_NAME       AVD name, default MagicNet_API_33.
  MAGICNET_ANDROID_SDK_ROOT
                         SDK path, default ~/.android-sdk-magicnet when present.
  MAGICNET_ROOTAVD_DIR    rootAVD checkout, default ~/.cache/magicnet-tools/rootAVD.
  ANDROID_SERIAL          Explicit emulator serial. If unset, only emulator-* devices are used.
EOF
}

main() {
    cd "$ROOT"
    case "$MODE" in
        quick)
            run_quick "$@"
            ;;
        package)
            run_package "$@"
            ;;
        fake-magisk)
            run_fake_magisk "$@"
            ;;
        local)
            run_quick "$@"
            run_package "$@"
            run_fake_magisk "$@"
            ;;
        avd)
            run_avd "$@"
            ;;
        rootavd-setup)
            run_rootavd_setup "$@"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            usage >&2
            fail "unknown mode: $MODE"
            ;;
    esac
}

main "$@"

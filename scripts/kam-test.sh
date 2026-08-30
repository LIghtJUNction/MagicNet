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
    local device_tmp_dir="/sdcard/Download/MagicNet"
    local device_zip="$device_tmp_dir/MagicNet.zip"
    log "removing stale MagicNet module state from emulator"
    adb_su "$serial" 'rm -rf /data/adb/modules_update/MagicNet /data/adb/modules/MagicNet'
    log "pushing module zip to $serial"
    adb_su "$serial" "mkdir -p '$device_tmp_dir'"
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
    adb_su "$serial" "rm -f '$device_zip'" || true
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

push_x86_core_binaries() {
    local serial="$1"
    local cache="${MAGICNET_AVD_CORE_CACHE:-$HOME/.cache/magicnet-tools/avd-cores}"
    local source_revision
    local singbox_bin

    need go
    source_revision="$(git -C "$ROOT/sing-box" rev-parse HEAD 2>/dev/null)" ||
        fail "sing-box source submodule is not initialized"
    singbox_bin="$cache/sing-box-${source_revision}-android-amd64"

    if [[ ! -x "$singbox_bin" ]]; then
        log "building forked sing-box for the x86_64 AVD"
        mkdir -p "$cache"
        "$ROOT/scripts/build-sing-box.sh" android amd64 "$singbox_bin" >/dev/null
    else
        log "using cached forked sing-box for revision $source_revision"
    fi

    adb_su "$serial" 'mkdir -p /sdcard/Download/MagicNet'
    "$ADB" -s "$serial" push "$singbox_bin" /sdcard/Download/MagicNet/sing-box >/dev/null
    adb_su "$serial" 'cp /sdcard/Download/MagicNet/sing-box /data/adb/modules/MagicNet/bin/sing-box'
    adb_su "$serial" 'chmod 0755 /data/adb/modules/MagicNet/bin/sing-box'
    adb_su "$serial" 'rm -f /sdcard/Download/MagicNet/sing-box' || true
}

prepare_avd_node_fixtures() {
    local serial="$1"
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-avd-fixtures.XXXXXX")"

    "$ADB" -s "$serial" exec-out su -c 'cat /data/adb/modules/MagicNet/.config/sing-box/config.json' >"$work/sing-box.json"
    jq '.outbounds += [{"type":"vmess","tag":"fake-node","server":"127.0.0.1","server_port":443,"uuid":"00000000-0000-0000-0000-000000000000","security":"auto"}]' \
        "$work/sing-box.json" >"$work/sing-box.new.json"
    adb_su "$serial" 'mkdir -p /sdcard/Download/MagicNet'
    "$ADB" -s "$serial" push "$work/sing-box.new.json" /sdcard/Download/MagicNet/magicnet-sing-box.json >/dev/null
    adb_su "$serial" 'cp /sdcard/Download/MagicNet/magicnet-sing-box.json /data/adb/modules/MagicNet/.config/sing-box/config.json'
    adb_su "$serial" 'rm -f /sdcard/Download/MagicNet/magicnet-sing-box.json' || true
    adb_su "$serial" 'printf "%s\n" "https://example.invalid/subscription.yaml" > /data/adb/modules/MagicNet/.config/sing-box/subscription.url'
    rm -rf "$work"
}

verify_avd_runtime_features() {
    local serial="$1"
    log "verifying core startup on AVD"
    prepare_avd_node_fixtures "$serial"
    adb_su_retry "$serial" 3 '/data/adb/modules/MagicNet/cli config-editor validate sing-box'
    adb_su "$serial" 'MAGICNET_WATCHDOG_ENABLED=0 MAGICNET_FSWATCH_ENABLED=0 MAGICNET_NOTIFY_ENABLED=0 /data/adb/modules/MagicNet/cli service restart sing-box'
    adb_su "$serial" '/data/adb/modules/MagicNet/cli service status' | grep -Eq '^  sing-box: [0-9]+'
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
    x86 | x86_64)
        log "module package binaries are arm64; using x86_64 hot replacements for AVD checks"
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
    help | --help | -h)
        usage
        ;;
    *)
        usage >&2
        fail "unknown mode: $MODE"
        ;;
    esac
}

main "$@"

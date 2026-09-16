#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${MAGICNET_ANDROID_REPORT_DIR:-$ROOT/artifacts/android-kernelsu}"
MODULE_ZIP="${MAGICNET_MODULE_ZIP:-$ROOT/dist/MagicNet.zip}"
KSUD_HOST="${MAGICNET_KSUD_HOST:?MAGICNET_KSUD_HOST is required}"
X86_CLI="${MAGICNET_X86_CLI:?MAGICNET_X86_CLI is required}"
X86_SINGBOX="${MAGICNET_X86_SINGBOX:?MAGICNET_X86_SINGBOX is required}"
X86_TOOLS="${MAGICNET_X86_TOOLS:?MAGICNET_X86_TOOLS is required}"
PROBE_APK="${MAGICNET_NETWORK_PROBE_APK:?MAGICNET_NETWORK_PROBE_APK is required}"
PROXY_REGION="${MAGICNET_PROXY_REGION:-global}"
ROUNDS="${MAGICNET_BENCHMARK_ROUNDS:-3}"
RUN_SPEED="${MAGICNET_RUN_SPEED:-1}"
MODDIR=/data/adb/modules/MagicNet
REMOTE_DIR=/sdcard/Download/MagicNet
REMOTE_ZIP=$REMOTE_DIR/MagicNet.zip

mkdir -p "$OUT"

log() { printf '[android-ksu] %s\n' "$*"; }
fail() { printf '[android-ksu] ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=scripts/lib/android-adb.sh
. "$ROOT/scripts/lib/android-adb.sh"

adb_root() {
    adb root >/dev/null 2>&1 || true
    adb wait-for-device
    sleep 1
    adb shell id | grep -q 'uid=0' || fail 'AVD adbd is not root; use a google_apis/debuggable system image'
}

collect_debug() {
    local budget="${MAGICNET_DIAGNOSTIC_BUDGET:-30}"
    [[ "$budget" =~ ^[1-9][0-9]*$ ]] && ((budget <= 60)) || budget=30
    local deadline=$((SECONDS + budget))
    debug_adb() {
        local remaining=$((deadline - SECONDS))
        ((remaining > 0)) || return 124
        MAGICNET_ADB_CALL_TIMEOUT="$((remaining < 5 ? remaining : 5))" adb "$@"
    }
    if debug_adb get-state >/dev/null 2>&1; then
        debug_adb shell uname -a >"$OUT/uname.txt" 2>&1 || true
        debug_adb shell dmesg >"$OUT/dmesg.txt" 2>&1 || true
        debug_adb logcat -d -t 1500 >"$OUT/logcat.txt" 2>&1 || true
        debug_adb shell "tail -n 500 $MODDIR/.log/service.log" >"$OUT/magicnet-service.log" 2>&1 || true
        debug_adb shell "tail -n 500 $MODDIR/.log/sing-box.log" >"$OUT/sing-box.log" 2>&1 || true
    fi
}
finish() {
    local result=$?
    trap - EXIT
    set +e
    collect_debug
    exit "$result"
}
trap finish EXIT

[[ -s "$MODULE_ZIP" ]] || fail "module archive missing: $MODULE_ZIP"
for f in "$KSUD_HOST" "$X86_CLI" "$X86_SINGBOX" "$X86_TOOLS/jq" "$X86_TOOLS/yq" "$PROBE_APK"; do
    [[ -s "$f" ]] || fail "required host artifact missing: $f"
done

log 'waiting for Android boot'
wait_boot || fail 'Android did not finish booting'
adb_root

arch="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
[[ "$arch" == x86_64 ]] || fail "expected x86_64 AVD, got $arch"

log 'installing matching KernelSU userspace'
adb shell "mkdir -p '$REMOTE_DIR'"
adb push "$KSUD_HOST" "$REMOTE_DIR/ksud" >/dev/null
# /sdcard is staging, not executable storage. Install to the actual userspace
# destination before execution; do not depend on relaxed/noexec mount behavior.
adb shell "mkdir -p /data/adb && cp '$REMOTE_DIR/ksud' /data/adb/ksud && chmod 0755 /data/adb/ksud && /data/adb/ksud debug version" | tee "$OUT/kernelsu-kernel.txt"
adb shell '/data/adb/ksud install'
adb shell 'test -x /data/adb/ksud && test -x /data/adb/ksu/bin/busybox' || fail 'KernelSU userspace install incomplete'
adb shell "rm -f '$REMOTE_DIR/ksud'" || true

log 'rebooting once so KernelSU init lifecycle owns /data/adb'
adb reboot >/dev/null
wait_boot || fail 'Android did not return after KernelSU userspace install'
adb_root

KSU_BIN=/data/adb/ksu/bin/ksud
if ! adb shell "test -x $KSU_BIN" >/dev/null 2>&1; then
    KSU_BIN=/data/adb/ksud
fi
adb shell "$KSU_BIN debug version" | tee -a "$OUT/kernelsu-kernel.txt"

log 'installing current MagicNet archive through the real KernelSU module installer'
adb shell "mkdir -p '$REMOTE_DIR'"
adb push "$MODULE_ZIP" "$REMOTE_ZIP" >/dev/null
MAGICNET_ADB_CALL_TIMEOUT=180 adb shell "MAGICNET_NONINTERACTIVE=1 $KSU_BIN module install '$REMOTE_ZIP'" | tee "$OUT/module-install.txt"
adb shell "rm -f '$REMOTE_ZIP'" || true

log 'rebooting to execute KernelSU post-fs-data/service lifecycle'
adb reboot >/dev/null
wait_boot || fail 'Android did not return after MagicNet install'
adb_root
adb shell "test -f $MODDIR/module.prop" || fail 'MagicNet module was not activated by KernelSU'

# The release archive intentionally contains arm64 Android binaries. AVD tests run
# x86_64 for hardware acceleration, so replace only executable payloads after the
# real module installer/lifecycle has been exercised.
log 'injecting x86_64 test binaries into the installed module'
adb push "$X86_CLI" "$MODDIR/bin/magicnet-cli" >/dev/null
adb push "$X86_SINGBOX" "$MODDIR/bin/sing-box" >/dev/null
adb shell "chmod 0755 $MODDIR/bin/magicnet-cli $MODDIR/bin/sing-box; rm -f $MODDIR/bin/magicnet-mcp-server; rm -f $MODDIR/cli; ln -s bin/magicnet-cli $MODDIR/cli"
adb shell "test ! -e $MODDIR/bin/magicnet-mcp-server" || fail 'standalone MCP binary survived install'

# The module's jq/yq are arm64 too. Testing only two replacement binaries left
# the first config rewrite vulnerable to Exec format error on an x86_64 AVD.
for tool in jq yq; do
    adb push "$X86_TOOLS/$tool" "$MODDIR/bin/$tool" >/dev/null
    adb shell "chmod 0755 $MODDIR/bin/$tool && $MODDIR/bin/$tool --version"
done
adb shell "$MODDIR/bin/jq -n '{probe:true}'" | grep -q 'true'
adb install -t -r "$PROBE_APK" >"$OUT/probe-install.txt"

case "$PROXY_REGION" in
    global)
        SUB_URL='https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/clash.yaml'
        ;;
    US)
        SUB_URL='https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/by-country/clash-US.yaml'
        ;;
    JP)
        SUB_URL='https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/by-country/clash-JP.yaml'
        ;;
    *)
        fail "unsupported proxy region: $PROXY_REGION"
        ;;
esac

log "configuring hourly-refreshed public proxy feed ($PROXY_REGION)"
# This is a public, credential-free URL. Never use account tokens or private
# subscriptions in this workflow; reports and logs are uploaded as artifacts.
adb shell "$MODDIR/cli setup '$SUB_URL'" | tee "$OUT/setup.txt"
MAGICNET_ADB_CALL_TIMEOUT=180 adb shell "$MODDIR/cli sub update-all" | tee "$OUT/subscription-update.txt"
adb shell "$MODDIR/cli sub status" | tee "$OUT/subscription-status.txt"

log 'starting MagicNet with the x86_64 test payloads'
adb shell "sh $MODDIR/service.sh" >"$OUT/service-start.txt" 2>&1 || {
    cat "$OUT/service-start.txt" >&2
    fail 'MagicNet service.sh failed'
}

sleep 8
adb shell "$MODDIR/cli health" | tee "$OUT/health.txt"
adb shell "$MODDIR/cli transparent status" | tee "$OUT/transparent-status.txt"
adb shell "$MODDIR/cli service status sing-box" | tee "$OUT/sing-box-status.txt"
adb shell 'ip link show magicnet0' | tee "$OUT/tun.txt"
adb shell "$MODDIR/cli config-editor validate sing-box" | tee "$OUT/config-validate.txt"

log 'verifying test-app TUN capture, then anonymous HTTPS outcomes and bounded throughput'
bench_args=(
    "$ROOT/scripts/android-network-benchmark.py"
    --targets "$ROOT/src/MagicNet/lib/magicnet/network-targets.tsv"
    --output "$OUT/benchmark"
    --rounds "$ROUNDS"
    --verify-tun
)
[[ "$RUN_SPEED" == 1 ]] && bench_args+=(--speed)
benchmark_result=0
python3 "${bench_args[@]}" || benchmark_result=$?

cat "$OUT/benchmark/summary.md"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$OUT/benchmark/summary.md" >>"$GITHUB_STEP_SUMMARY"
fi

[[ "$benchmark_result" == 0 ]] || exit "$benchmark_result"
log 'Android test-app TUN and anonymous HTTPS checks passed; Play/GMS app acceptance NOT TESTED'

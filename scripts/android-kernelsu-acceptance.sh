#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${MAGICNET_ANDROID_REPORT_DIR:-$ROOT/artifacts/android-kernelsu}"
MODULE_ZIP="${MAGICNET_MODULE_ZIP:-$ROOT/dist/MagicNet.zip}"
KSUD_HOST="${MAGICNET_KSUD_HOST:?MAGICNET_KSUD_HOST is required}"
X86_CLI="${MAGICNET_X86_CLI:?MAGICNET_X86_CLI is required}"
X86_MCP="${MAGICNET_X86_MCP:?MAGICNET_X86_MCP is required}"
X86_SINGBOX="${MAGICNET_X86_SINGBOX:?MAGICNET_X86_SINGBOX is required}"
PROXY_REGION="${MAGICNET_PROXY_REGION:-global}"
ROUNDS="${MAGICNET_BENCHMARK_ROUNDS:-3}"
STRICT_EXTERNAL="${MAGICNET_STRICT_EXTERNAL:-0}"
RUN_SPEED="${MAGICNET_RUN_SPEED:-1}"
REQUIRE_PLAY_STORE="${MAGICNET_REQUIRE_PLAY_STORE:-0}"
MODDIR=/data/adb/modules/MagicNet
REMOTE_ZIP=/data/local/tmp/MagicNet.zip

mkdir -p "$OUT"

log() { printf '[android-ksu] %s\n' "$*"; }
fail() { printf '[android-ksu] ERROR: %s\n' "$*" >&2; exit 1; }

if ! command -v adb >/dev/null 2>&1; then
    for sdk_root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
        if [[ -n "$sdk_root" && -x "$sdk_root/platform-tools/adb" ]]; then
            export PATH="$sdk_root/platform-tools:$PATH"
            break
        fi
    done
fi
command -v adb >/dev/null 2>&1 || fail 'adb not found in PATH or Android SDK platform-tools'

wait_boot() {
    adb wait-for-device
    local deadline=$((SECONDS + 300))
    while (( SECONDS < deadline )); do
        if [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
            adb shell input keyevent 82 >/dev/null 2>&1 || true
            return 0
        fi
        sleep 3
    done
    return 1
}

adb_root() {
    adb root >/dev/null 2>&1 || true
    adb wait-for-device
    sleep 1
    adb shell id | grep -q 'uid=0' || fail 'AVD adbd is not root; Play Store ramdisk must be patched for debuggable adbd'
}

collect_debug() {
    set +e
    if adb get-state >/dev/null 2>&1; then
        adb root >/dev/null 2>&1 || true
        adb wait-for-device >/dev/null 2>&1 || true
        adb shell getprop >"$OUT/getprop.txt" 2>&1 || true
        adb shell uname -a >"$OUT/uname.txt" 2>&1 || true
        adb shell dmesg >"$OUT/dmesg.txt" 2>&1 || true
        adb logcat -d >"$OUT/logcat.txt" 2>&1 || true
        adb shell "ls -lR /data/adb/ksu /data/adb/modules/MagicNet 2>/dev/null" >"$OUT/module-tree.txt" 2>&1 || true
        adb shell "cat /data/adb/modules/MagicNet/.log/service.log 2>/dev/null || true" >"$OUT/magicnet-service.log" 2>&1 || true
        adb shell "cat /data/adb/modules/MagicNet/.log/sing-box.log 2>/dev/null || true" >"$OUT/sing-box.log" 2>&1 || true
        adb shell "/data/adb/ksu/bin/ksud debug version 2>&1 || /data/adb/ksud debug version 2>&1 || true" >"$OUT/kernelsu-version.txt" 2>&1 || true
        adb shell "dumpsys package com.android.vending 2>/dev/null || true" >"$OUT/play-store-package.txt" 2>&1 || true
        adb shell "dumpsys activity activities 2>/dev/null || true" >"$OUT/play-store-activity.txt" 2>&1 || true
    fi
}
trap collect_debug EXIT

play_store_gate() {
    [[ "$REQUIRE_PLAY_STORE" == 1 ]] || return 0

    log 'verifying the Android image contains the real Google Play Store app'
    adb shell 'pm path com.android.vending' | tee "$OUT/play-store-path.txt" | grep -q '^package:' \
        || fail 'com.android.vending is absent; acceptance image is not a Play Store image'
    adb shell 'pm path com.google.android.gms' | tee "$OUT/gms-path.txt" | grep -q '^package:' \
        || fail 'Google Play services is absent from the acceptance image'

    log 'verifying Play Store/GMS/GSF are routed through the direct fallback'
    adb shell "$MODDIR/bin/jq -e '
      def packages:
        if ((.package_name? // null) | type) == \"array\" then .package_name
        elif ((.package_name? // null) | type) == \"string\" then [.package_name]
        else [] end;
      [\"com.android.vending\", \"com.google.android.gms\", \"com.google.android.gsf\"]
      | all(. as \$pkg; any(.route.rules[]?; .outbound? == \"direct\" and ((packages | index(\$pkg)) != null)))
    ' $MODDIR/.config/sing-box/config.json" \
        || fail 'effective sing-box config is missing one or more Play/GMS/GSF direct package routes'

    # A fresh CI device intentionally has no personal Google account. Successful
    # acceptance therefore means that the real Play app launches into either its
    # storefront or Google sign-in flow without a process crash. It is stronger
    # than a shell curl probe while remaining credential-free.
    log 'launching the real Play Store app through MagicNet'
    adb shell settings put global device_provisioned 1 >/dev/null 2>&1 || true
    adb shell settings put secure user_setup_complete 1 >/dev/null 2>&1 || true
    adb shell am force-stop com.android.vending >/dev/null 2>&1 || true
    adb logcat -c || true
    adb shell monkey -p com.android.vending -c android.intent.category.LAUNCHER 1 \
        >"$OUT/play-store-launch.txt" 2>&1 \
        || fail 'Play Store launcher intent failed'
    sleep 15

    adb shell 'dumpsys activity activities | grep -m 1 -E "mResumedActivity|topResumedActivity" || true' \
        | tee "$OUT/play-store-resumed.txt"
    adb logcat -d >"$OUT/play-store-logcat.txt" 2>&1 || true
    timeout 20 adb shell uiautomator dump /data/local/tmp/play-store.xml >/dev/null 2>&1 || true
    adb pull /data/local/tmp/play-store.xml "$OUT/play-store-ui.xml" >/dev/null 2>&1 || true

    if grep -Eiq 'FATAL EXCEPTION:.*|Process: com\.android\.vending.*FATAL|Force finishing activity .*com\.android\.vending' \
        "$OUT/play-store-logcat.txt"; then
        fail 'Play Store crashed after launch with MagicNet active'
    fi

    if ! grep -Eq 'com\.android\.vending|com\.google\.android\.gms' "$OUT/play-store-resumed.txt"; then
        # Some Play builds hand the first launch to an account/setup activity.
        # Record the full activity state before deciding whether the launch died.
        adb shell dumpsys activity activities >"$OUT/play-store-activities-full.txt" 2>&1 || true
        if ! grep -Eq 'com\.android\.vending|com\.google\.android\.gms' "$OUT/play-store-activities-full.txt"; then
            fail 'Play Store did not remain active or hand off to Google sign-in/setup'
        fi
    fi

    log 'real Play Store app launch gate passed'
}

[[ -s "$MODULE_ZIP" ]] || fail "module archive missing: $MODULE_ZIP"
for f in "$KSUD_HOST" "$X86_CLI" "$X86_MCP" "$X86_SINGBOX"; do
    [[ -s "$f" ]] || fail "required host artifact missing: $f"
done

log 'waiting for Android boot'
wait_boot || fail 'Android did not finish booting'
adb_root

arch="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
[[ "$arch" == x86_64 ]] || fail "expected x86_64 AVD, got $arch"

log 'installing matching KernelSU userspace'
adb push "$KSUD_HOST" /data/local/tmp/ksud >/dev/null
adb shell 'chmod 0755 /data/local/tmp/ksud && /data/local/tmp/ksud debug version' | tee "$OUT/kernelsu-kernel.txt"
adb shell '/data/local/tmp/ksud install'
adb shell 'test -x /data/adb/ksud && test -x /data/adb/ksu/bin/busybox' || fail 'KernelSU userspace install incomplete'

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
adb push "$MODULE_ZIP" "$REMOTE_ZIP" >/dev/null
adb shell "MAGICNET_NONINTERACTIVE=1 $KSU_BIN module install $REMOTE_ZIP" | tee "$OUT/module-install.txt"

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
adb push "$X86_MCP" "$MODDIR/bin/magicnet-mcp-server" >/dev/null
adb push "$X86_SINGBOX" "$MODDIR/bin/sing-box" >/dev/null
adb shell "chmod 0755 $MODDIR/bin/magicnet-cli $MODDIR/bin/magicnet-mcp-server $MODDIR/bin/sing-box; rm -f $MODDIR/cli; ln -s bin/magicnet-cli $MODDIR/cli"

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
adb shell "$MODDIR/cli sub update-all" | tee "$OUT/subscription-update.txt"
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

play_store_gate

log 'running domestic/global app-service matrix, latency, throughput and memory probes'
# Keep the shared target corpus stable while extending Android acceptance with
# apps that previously failed on-device.
android_targets="$OUT/android-network-targets.tsv"
cp "$ROOT/src/MagicNet/lib/magicnet/network-targets.tsv" "$android_targets"
printf '%s\n' \
    'play-store-web|google|https://play.google.com/store/apps|200' \
    'gmail|google|https://mail.google.com/mail/u/0/|200' \
    'gemini|google|https://gemini.google.com/|200' >>"$android_targets"
bench_args=(
    "$ROOT/scripts/android-network-benchmark.py"
    --targets "$android_targets"
    --output "$OUT/benchmark"
    --rounds "$ROUNDS"
)
[[ "$RUN_SPEED" == 1 ]] && bench_args+=(--speed)
[[ "$STRICT_EXTERNAL" == 1 ]] && bench_args+=(--strict-external)
python3 "${bench_args[@]}"

cat "$OUT/benchmark/summary.md"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$OUT/benchmark/summary.md" >>"$GITHUB_STEP_SUMMARY"
fi

log 'Android KernelSU Play Store acceptance passed'

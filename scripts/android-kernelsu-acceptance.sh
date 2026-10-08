#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${MAGICNET_ANDROID_REPORT_DIR:-$ROOT/artifacts/android-kernelsu}"
MODULE_ZIP="${MAGICNET_MODULE_ZIP:-$ROOT/dist/MagicNet.zip}"
PUBLIC_RUNTIME="${MAGICNET_PUBLIC_RUNTIME:-stock-late-load}"
PREPARED_RUNTIME_DIR="${MAGICNET_PREPARED_RUNTIME_DIR:-}"
PROXY_REGION="${MAGICNET_PROXY_REGION:-global}"
ROUNDS="${MAGICNET_BENCHMARK_ROUNDS:-3}"
RUN_SPEED="${MAGICNET_RUN_SPEED:-1}"
MODDIR=/data/adb/modules/MagicNet
REMOTE_DIR=/sdcard/Download/MagicNet
REMOTE_ZIP=$REMOTE_DIR/MagicNet.zip

mkdir -p "$OUT"

log() { printf '[android-ksu] %s\n' "$*"; }
fail() { printf '[android-ksu] ERROR: %s\n' "$*" >&2; exit 1; }

case "$PUBLIC_RUNTIME" in
    prepared|stock-late-load) ;;
    *) fail "unsupported public runtime: $PUBLIC_RUNTIME" ;;
esac

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

if [[ "$PUBLIC_RUNTIME" == prepared ]]; then
    [[ "${MAGICNET_DISPOSABLE_AVD:-}" == 1 ]] || fail 'prepared runtime requires a disposable AVD'
    [[ -n "$PREPARED_RUNTIME_DIR" ]] || fail 'prepared runtime report directory is required'
    # Verify the report and live device before any public subscription mutation.
    # Failure never falls back to the stock-kernel installer.
    python3 "$ROOT/scripts/android-public-runtime.py" verify --output "$PREPARED_RUNTIME_DIR"
else
    KSUD_HOST="${MAGICNET_KSUD_HOST:?MAGICNET_KSUD_HOST is required}"
    X86_CLI="${MAGICNET_X86_CLI:?MAGICNET_X86_CLI is required}"
    X86_SINGBOX="${MAGICNET_X86_SINGBOX:?MAGICNET_X86_SINGBOX is required}"
    X86_TOOLS="${MAGICNET_X86_TOOLS:?MAGICNET_X86_TOOLS is required}"
    PROBE_APK="${MAGICNET_NETWORK_PROBE_APK:?MAGICNET_NETWORK_PROBE_APK is required}"

    [[ -s "$MODULE_ZIP" ]] || fail "module archive missing: $MODULE_ZIP"
    for f in "$KSUD_HOST" "$X86_CLI" "$X86_SINGBOX" "$X86_TOOLS/jq" "$X86_TOOLS/yq" "$PROBE_APK"; do
        [[ -s "$f" ]] || fail "required host artifact missing: $f"
    done

    log 'waiting for Android boot'
    wait_boot || fail 'Android did not finish booting'
    adb_root

    arch="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
    [[ "$arch" == x86_64 ]] || fail "expected x86_64 AVD, got $arch"

    log 'staging official KernelSU userspace for stock-kernel late-load'
    adb shell "mkdir -p '$REMOTE_DIR' /data/adb"
    adb push "$KSUD_HOST" "$REMOTE_DIR/ksud" >/dev/null
    # Keep the stock AVD kernel paired with its stock vendor modules. Official
    # KernelSU v3.2.0 embeds an x86_64 KMI-matched LKM in the x86_64 ksud binary.
    adb shell "cp '$REMOTE_DIR/ksud' /data/adb/ksud && chmod 0755 /data/adb/ksud"
    adb shell "rm -f '$REMOTE_DIR/ksud'" || true
    KSU_BIN=/data/adb/ksud
    # v3.2.0 install() copies the running executable onto /data/adb/ksud.
    KSU_LAUNCH=/data/adb/ksu/ci-ksud

    late_load_ksu() {
        local current supported version
        current="$(adb shell "$KSU_BIN boot-info current-kmi" | tr -d '\r')"
        supported="$(adb shell "$KSU_BIN boot-info supported-kmis" | tr -d '\r')"
        printf '%s\n' "$current" >"$OUT/kernelsu-kmi.txt"
        printf '%s\n' "$supported" >>"$OUT/kernelsu-kmi.txt"
        grep -Fqx "$current" <<<"$supported" || fail "KernelSU does not embed stock KMI: $current"
        adb shell "mkdir -p /data/adb/ksu && cp '$KSU_BIN' '$KSU_LAUNCH' && chmod 0755 '$KSU_LAUNCH'"
        MAGICNET_ADB_CALL_TIMEOUT=120 adb shell "PATH=/data/adb/ksu/bin:/system/bin:/system/xbin '$KSU_LAUNCH' late-load" >"$OUT/kernelsu-late-load.txt" 2>&1 ||
            fail 'KernelSU late-load failed'
        version="$(adb shell "$KSU_BIN debug version" | tr -d '\r')"
        grep -Eq '^Kernel Version: [1-9][0-9]*$' <<<"$version" ||
            fail "KernelSU interface unavailable after late-load: $version"
        printf '%s\n' "$version" | tee -a "$OUT/kernelsu-kernel.txt"
        adb shell 'test -x /data/adb/ksu/bin/busybox' ||
            fail 'KernelSU late-load did not install userspace'
    }

    late_load_ksu

    log 'installing current MagicNet archive through the real KernelSU module installer'
    adb shell "mkdir -p '$REMOTE_DIR'"
    adb push "$MODULE_ZIP" "$REMOTE_ZIP" >/dev/null
    MAGICNET_ADB_CALL_TIMEOUT=180 adb shell "MAGICNET_NONINTERACTIVE=1 $KSU_BIN module install '$REMOTE_ZIP'" | tee "$OUT/module-install.txt"
    adb shell "rm -f '$REMOTE_ZIP'" || true

    log 'rebooting to execute KernelSU late-load service/boot-completed lifecycle'
    adb reboot >/dev/null
    wait_boot || fail 'Android did not return after MagicNet install'
    adb_root
    late_load_ksu
    adb shell "test -f $MODDIR/module.prop" || fail 'MagicNet module was not activated by KernelSU late-load'

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
fi

# Only module CLI operations use this transport; the prepared path enters the
# same real KernelSU domain and BusyBox standalone shell as Device.kshell.
module_cli() {
    if [[ "$PUBLIC_RUNTIME" == prepared ]]; then
        python3 - "$MODDIR/cli" "$@" <<'PY_KSU' | adb shell -T '/data/adb/ksud debug su'
import shlex
import sys
command = shlex.join(sys.argv[1:])
print('export KSU=true ASH_STANDALONE=1')
print('exec /data/adb/ksu/bin/busybox sh -c ' + shlex.quote(command))
PY_KSU
    else
        local command
        command="$(python3 - "$MODDIR/cli" "$@" <<'PY_CLI'
import shlex
import sys
print(shlex.join(sys.argv[1:]))
PY_CLI
)"
        adb shell "$command"
    fi
}

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
module_cli setup "$SUB_URL" | tee "$OUT/setup.txt"
MAGICNET_ADB_CALL_TIMEOUT=180 module_cli sub update-all | tee "$OUT/subscription-update.txt"
module_cli sub status | tee "$OUT/subscription-status.txt"

log 'starting MagicNet with the x86_64 test payloads'
if [[ "$PUBLIC_RUNTIME" == prepared ]]; then
    # One explicit lifecycle command; do not replay service.sh or retry restart.
    MAGICNET_ADB_CALL_TIMEOUT=90 module_cli service restart sing-box >"$OUT/service-start.txt" 2>&1 || {
        cat "$OUT/service-start.txt" >&2
        fail 'MagicNet CLI restart failed'
    }
    ready_deadline=$((SECONDS + 90))
    ready=0
    while ((SECONDS < ready_deadline)); do
        remaining=$((ready_deadline - SECONDS))
        slice=$((remaining < 10 ? remaining : 10))
        if MAGICNET_ADB_CALL_TIMEOUT="$slice" module_cli --json service status >"$OUT/service-status.json" &&
            python3 - "$ROOT/scripts/android-device-simulation.py" "$OUT/service-status.json" <<'PY_READY'
import importlib.util
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('public_simulation', sys.argv[1])
simulation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(simulation)
raise SystemExit(0 if simulation.is_ready(Path(sys.argv[2]).read_text()) else 1)
PY_READY
        then
            ready=1
            break
        fi
        remaining=$((ready_deadline - SECONDS))
        ((remaining > 0)) || break
        sleep "$((remaining < 2 ? remaining : 2))"
    done
    [[ "$ready" == 1 ]] || fail 'prepared core process/API/TUN did not become ready'
else
    adb shell "sh $MODDIR/service.sh" >"$OUT/service-start.txt" 2>&1 || {
        cat "$OUT/service-start.txt" >&2
        fail 'MagicNet service.sh failed'
    }
    sleep 8
fi
module_cli health | tee "$OUT/health.txt"
module_cli transparent status | tee "$OUT/transparent-status.txt"
module_cli service status sing-box | tee "$OUT/sing-box-status.txt"
adb shell 'ip link show magicnet0' | tee "$OUT/tun.txt"
module_cli config-editor validate sing-box | tee "$OUT/config-validate.txt"

log 'verifying test-app TUN capture, then anonymous HTTPS outcomes and bounded throughput'
bench_args=(
    "$ROOT/scripts/android-network-benchmark.py"
    --targets "$ROOT/src/MagicNet/lib/magicnet/network-targets.tsv"
    --output "$OUT/benchmark"
    --rounds "$ROUNDS"
    --verify-tun
)
[[ "$PUBLIC_RUNTIME" == prepared ]] && bench_args+=(--root-mode ksud --prepared-runtime-dir "$PREPARED_RUNTIME_DIR")
[[ "$RUN_SPEED" == 1 ]] && bench_args+=(--speed)
benchmark_result=0
python3 "${bench_args[@]}" || benchmark_result=$?

cat "$OUT/benchmark/summary.md"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$OUT/benchmark/summary.md" >>"$GITHUB_STEP_SUMMARY"
fi

[[ "$benchmark_result" == 0 ]] || exit "$benchmark_result"
log 'Android test-app TUN and anonymous HTTPS checks passed; Play/GMS app acceptance NOT TESTED'

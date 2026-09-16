#!/usr/bin/env bash
# Host-side only. Every ADB command has a deadline, including device discovery.
MAGICNET_ADB_BIN="$(command -v adb)" || return 127
command -v timeout >/dev/null 2>&1 || return 127

adb() {
    local budget="${MAGICNET_ADB_CALL_TIMEOUT:-60}"
    [[ "$budget" =~ ^[1-9][0-9]*$ ]] && ((budget <= 600)) || return 64
    timeout --kill-after=2s "${budget}s" "$MAGICNET_ADB_BIN" "$@"
}

wait_boot() {
    local budget="${MAGICNET_BOOT_TIMEOUT:-300}"
    [[ "$budget" =~ ^[1-9][0-9]*$ ]] && ((budget <= 300)) || return 64
    local deadline=$((SECONDS + budget)) remaining slice
    MAGICNET_ADB_CALL_TIMEOUT="$budget" adb wait-for-device || return 1
    while ((SECONDS < deadline)); do
        remaining=$((deadline - SECONDS))
        slice=$((remaining < 5 ? remaining : 5))
        if [[ "$(MAGICNET_ADB_CALL_TIMEOUT="$slice" adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
            MAGICNET_ADB_CALL_TIMEOUT=2 adb shell input keyevent 82 >/dev/null 2>&1 || true
            return 0
        fi
        remaining=$((deadline - SECONDS))
        ((remaining > 0)) || break
        sleep "$((remaining < 3 ? remaining : 3))"
    done
    return 1
}

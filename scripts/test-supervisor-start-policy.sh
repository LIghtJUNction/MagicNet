#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

set_i18n() { :; }
i18n() { printf '%s\n' "$1"; }
t() { cat; }
import() { :; }
magicnet_json_escape() { printf '%s' "$1"; }
MODDIR="$fixture/module"
export MODDIR

# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/supervisors.sh"

(
magicnet_fswatch_start() { return 1; }
magicnet_subscription_refresh_start() { return 0; }
magicnet_wifi_policy_start() { return 0; }
magicnet_hotspot_watchdog_start() { return 0; }
magicnet_kernel_running() { return 1; }

if ! magicnet_supervisors_start; then
    printf '%s\n' 'optional fswatch failure changed supervisor startup status' >&2
    exit 1
fi

magicnet_subscription_refresh_start() { return 1; }
if magicnet_supervisors_start; then
    printf '%s\n' 'required supervisor failure was swallowed' >&2
    exit 1
fi
)

(
start_order="$fixture/supervisor-start-order.log"
magicnet_kernel_running() { return 0; }
magicnet_singbox_record_runtime_fingerprint() { printf '%s\n' fingerprint >>"$start_order"; }
magicnet_subscription_refresh_start() { printf '%s\n' subscription >>"$start_order"; }
magicnet_wifi_policy_start() { printf '%s\n' wifi >>"$start_order"; }
magicnet_hotspot_watchdog_start() { printf '%s\n' hotspot >>"$start_order"; }
magicnet_fswatch_start() { printf '%s\n' fswatch >>"$start_order"; }
magicnet_supervisors_start
diff -u - "$start_order" <<'EOF'
fingerprint
subscription
wifi
hotspot
fswatch
EOF
)

mkdir -p "$MODDIR/.log"
cat >"$MODDIR/cli" <<'EOF'
#!/bin/sh
sleep 5
EOF
chmod +x "$MODDIR/cli"
detached_started=$(date +%s%N)
magicnet_supervisors_start_detached
detached_pid=$!
detached_elapsed_ms=$((($(date +%s%N) - detached_started) / 1000000))
if [ "$detached_elapsed_ms" -ge 1000 ]; then
    printf 'detached supervisor launch blocked for %s ms\n' "$detached_elapsed_ms" >&2
    exit 1
fi
kill "$detached_pid" 2>/dev/null || true
wait "$detached_pid" 2>/dev/null || true

# The Android Toybox flock command exists but does not implement the
# util-linux-style -o form. A known incompatible implementation should be
# reported clearly and must not reach the generic fswatch launcher.
mkdir -p "$MODDIR/.config" "$MODDIR/.log"
: >"$MODDIR/cli"
incompatible_bin="$fixture/incompatible-bin"
mkdir -p "$incompatible_bin"
cat >"$incompatible_bin/flock" <<'EOF'
#!/bin/sh
exit 64
EOF
chmod +x "$incompatible_bin/flock"
incompatible_output="$fixture/incompatible-flock.output"
magicnet_module_disabled() { return 1; }
magicnet_trim_log_file() { :; }
magicnet_warn() { printf '%s\n' "$*" >"$incompatible_output"; }
fswatch() {
    if [ "${1:-}" = status ]; then
        return 1
    fi
    printf '%s\n' 'fswatch launcher should not run' >&2
    return 99
}
if PATH="$incompatible_bin:/usr/bin:/bin" KAM_FSWATCH_BUSYBOX_BIN='' \
    magicnet_fswatch_start; then
    printf '%s\n' 'incompatible flock unexpectedly allowed fswatch start' >&2
    exit 1
fi
grep -F 'MAGICNET_FSWATCH_FLOCK_INCOMPATIBLE' "$incompatible_output" >/dev/null

# An explicitly supplied root-tool BusyBox takes precedence over the
# incompatible system flock and is passed to the fswatch implementation.
busybox_bin="$fixture/busybox"
cat >"$busybox_bin" <<'EOF'
#!/bin/sh
if [ "${1:-}" = flock ] && [ "${2:-}" = --help ]; then
    exit 0
fi
exit 1
EOF
chmod +x "$busybox_bin"
busybox_output="$fixture/busybox.output"
magicnet_warn() { :; }
fswatch() {
    if [ "${1:-}" = status ]; then
        return 1
    fi
    printf '%s\n' "${KAM_FSWATCH_BUSYBOX_BIN:-}" >"$busybox_output"
    return 0
}
PATH="$incompatible_bin:/usr/bin:/bin" KAM_FSWATCH_BUSYBOX_BIN="$busybox_bin" \
    magicnet_fswatch_start
grep -Fx "$busybox_bin" "$busybox_output" >/dev/null

printf '%s\n' 'supervisor start policy test passed'

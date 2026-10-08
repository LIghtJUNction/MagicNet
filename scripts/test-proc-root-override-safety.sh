#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-proc-root.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

MODDIR="$WORKDIR/module"
export MODDIR
mkdir -p "$MODDIR/lib/magicnet" "$MODDIR/bin" "$MODDIR/.config" "$MODDIR/.log"

# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"

[ "$(magicnet_trusted_proc_root /tmp/evil-proc)" = /tmp/evil-proc ] ||
    fail "host fixtures must still honor an explicit proc root"
[ "$(magicnet_trusted_proc_root)" = /proc ] || fail "default trusted proc root is not /proc"

export MAGICNET_TEST_FORCE_ANDROID=1
[ "$(magicnet_trusted_proc_root /tmp/evil-proc)" = /proc ] ||
    fail "Android runtime honored a foreign proc root"
export MAGICNET_TEST_ALLOW_PROC_ROOT=1
[ "$(magicnet_trusted_proc_root /tmp/evil-proc)" = /tmp/evil-proc ] ||
    fail "explicit Android fixture escape hatch was ignored"
unset MAGICNET_TEST_ALLOW_PROC_ROOT MAGICNET_TEST_FORCE_ANDROID

proc_root="$WORKDIR/proc"
fake_pid=424242
mkdir -p "$proc_root/$fake_pid"
printf 'sing-box\n' >"$proc_root/$fake_pid/comm"
printf '%s (sing-box) S 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 %s 0\n' \
    "$fake_pid" "$fake_pid" >"$proc_root/$fake_pid/stat"
printf '#!/bin/sh\nexit 0\n' >"$MODDIR/bin/sing-box"
chmod +x "$MODDIR/bin/sing-box"

# shellcheck disable=SC1091
. "$ROOT/scripts/test-lib/proc-reader-hook.sh"
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"

MAGICNET_SINGBOX_PROC_ROOT="$proc_root" magicnet_singbox_pid_live "$fake_pid" ||
    fail "host fixtures must still observe a fake proc tree"

export MAGICNET_TEST_FORCE_ANDROID=1
if MAGICNET_SINGBOX_PROC_ROOT="$proc_root" magicnet_singbox_pid_live "$fake_pid"; then
    fail "Android runtime treated a forged proc tree as a live sing-box"
fi
unset MAGICNET_TEST_FORCE_ANDROID

mkdir -p "$proc_root/$fake_pid" "$WORKDIR/evil-cgroup"
: >"$WORKDIR/evil-cgroup/cgroup.procs"
printf '0::/apps/uid_10346/pid_27334\n' >"$proc_root/$fake_pid/cgroup"
export MAGICNET_PROC_ROOT="$proc_root"
export MAGICNET_PROCESS_CGROUP_ROOTS="$WORKDIR/evil-cgroup"
magicnet_detach_pid_from_app_cgroup "$fake_pid"
grep -qx "$fake_pid" "$WORKDIR/evil-cgroup/cgroup.procs" ||
    fail "host fixtures must still honor a custom cgroup root"
: >"$WORKDIR/evil-cgroup/cgroup.procs"

export MAGICNET_TEST_FORCE_ANDROID=1
if magicnet_detach_pid_from_app_cgroup "$fake_pid"; then
    fail "Android runtime detached through a caller-injected cgroup root"
fi
if grep -qx "$fake_pid" "$WORKDIR/evil-cgroup/cgroup.procs"; then
    fail "Android runtime wrote a PID into a caller-injected cgroup root"
fi
unset MAGICNET_TEST_FORCE_ANDROID MAGICNET_PROC_ROOT MAGICNET_PROCESS_CGROUP_ROOTS

set_i18n() { :; }
i18n() { printf '%s\n' "$1"; }
t() { cat; }
import() { :; }
magicnet_json_escape() { printf '%s' "$1"; }
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/supervisors.sh"

evil_busybox="$WORKDIR/evil-busybox"
cat >"$evil_busybox" <<'EOF'
#!/bin/sh
if [ "${1:-}" = flock ] && [ "${2:-}" = --help ]; then
    exit 0
fi
exit 1
EOF
chmod +x "$evil_busybox"

[ "$(KAM_FSWATCH_BUSYBOX_BIN="$evil_busybox" magicnet_fswatch_busybox_bin)" = "$evil_busybox" ] ||
    fail "host fixtures must still honor an explicit BusyBox override"

export MAGICNET_TEST_FORCE_ANDROID=1
if KAM_FSWATCH_BUSYBOX_BIN="$evil_busybox" magicnet_fswatch_busybox_bin >/dev/null; then
    fail "Android runtime honored a caller-injected BusyBox"
fi
unset MAGICNET_TEST_FORCE_ANDROID

# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/kamfw-web/launcher.sh"

evil_launch="$WORKDIR/evil-launch-busybox"
mark="$WORKDIR/launch-mark"
cat >"$evil_launch" <<EOF
#!/bin/sh
printf 'used-evil-busybox\n' >"$mark"
exit 0
EOF
chmod +x "$evil_launch"

rm -f "$mark"
KAM_LAUNCH_BUSYBOX="$evil_launch" _launch_run true
[ -f "$mark" ] || fail "host fixtures must still honor an explicit launch BusyBox"

rm -f "$mark"
export MAGICNET_TEST_FORCE_ANDROID=1
KAM_LAUNCH_BUSYBOX="$evil_launch" _launch_run true
if [ -f "$mark" ]; then
    fail "Android runtime honored a caller-injected launch BusyBox"
fi
unset MAGICNET_TEST_FORCE_ANDROID

printf '%s\n' 'proc root override safety test passed'

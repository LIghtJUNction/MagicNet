#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

module="$fixture/module"
proc_root="$fixture/proc"
bin_dir="$fixture/bin"
mkdir -p "$module/bin" "$proc_root/101" "$proc_root/202" "$proc_root/303" "$proc_root/404" "$proc_root/505" "$bin_dir"
printf '#!/bin/sh\nexit 0\n' >"$module/bin/sing-box"
chmod +x "$module/bin/sing-box"
ln -s "$module/bin/sing-box" "$proc_root/101/exe"
ln -s "$(command -v sh)" "$proc_root/202/exe"
ln -s "$module/bin/sing-box" "$proc_root/303/exe"
printf 'sing-box\n' >"$proc_root/101/comm"
printf 'sing-box\n' >"$proc_root/202/comm"
printf 'sing-box\n' >"$proc_root/303/comm"
printf 'sing-box\n' >"$proc_root/404/comm"
printf 'sing-box\n' >"$proc_root/505/comm"
printf '101 (sing-box) S 1 2 3 4 5 6\n' >"$proc_root/101/stat"
printf '202 (sing-box) S 1 2 3 4 5 6\n' >"$proc_root/202/stat"
printf '303 (sing-box) S 1 2 3 4 5 6\n' >"$proc_root/303/stat"
printf '404 (sing-box) Z 1 2 3 4 5 6\n' >"$proc_root/404/stat"
printf 'sing-box\0run\0-c\0%s\0-D\0%s\0\0' \
    "$module/.config/sing-box/config.json" "$module/.config/sing-box" \
    >"$proc_root/101/cmdline"
printf 'sing-box\0run\0-c\0%s\0-D\0%s\0\0' \
    "$module/.config/sing-box/config.json" "$module/.config/sing-box" \
    >"$proc_root/202/cmdline"
# Same executable but a different config must not be treated as MagicNet-owned.
printf 'sing-box\0run\0-c\0%s\0-D\0%s\0\0' \
    "$fixture/other/config.json" "$fixture/other" >"$proc_root/303/cmdline"
# A zombie with the exact command line is still not a live core.
printf 'sing-box\0run\0-c\0%s\0-D\0%s\0\0' \
    "$module/.config/sing-box/config.json" "$module/.config/sing-box" \
    >"$proc_root/404/cmdline"

cat >"$bin_dir/pidof" <<'SH'
#!/bin/sh
printf '%s\n' "${PIDOF_OUTPUT:-101 202 303 404 505}"
SH
chmod +x "$bin_dir/pidof"

export MODDIR="$module"
export MAGICNET_SINGBOX_PROC_ROOT="$proc_root"
export PATH="$bin_dir:$PATH"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"

if magicnet_singbox_pid_live 505; then
    printf 'magicnet_singbox_pid_live accepted a PID with unreadable proc stat\n' >&2
    exit 1
fi

owned="$(magicnet_singbox_owned_pids "$module/.config/sing-box/config.json")"
test "$owned" = '101'

# Core lifecycle checks must use the same executable+config ownership tuple,
# not KAM's process-name-only pidof fast path.
# shellcheck source=/dev/null
. "$ROOT/src/MagicNet/lib/magicnet/core.sh"
magicnet_singbox_subscription_config_file() {
    printf '%s\n' "$module/.config/sing-box/config.json"
}
magicnet_cmd_exists() { [ "${1:-}" = sing-box ]; }
export PIDOF_OUTPUT='202 303 404 505'
if magicnet_kernel_running; then
    printf 'foreign sing-box satisfied MagicNet core readiness\n' >&2
    exit 1
fi
start_marker="$fixture/owned-start-attempted"
magicnet_module_disabled() { return 1; }
magicnet_prepare_singbox_nodes_unlocked() { return 0; }
magicnet_apply_runtime_config_unlocked() { return 0; }
magicnet_tailscale_inject_auth_key() { return 0; }
magicnet_tailscale_scrub_auth_key() { return 0; }
magicnet_singbox_ensure_start_owned() {
    : >"$start_marker"
    return 1
}
if magicnet_start_singbox_unlocked; then
    printf 'foreign sing-box incorrectly skipped owned startup\n' >&2
    exit 1
fi
test -f "$start_marker"
kill_log="$fixture/kill.log"
kill() { printf '%s\n' "$*" >>"$kill_log"; }
magicnet_stop_owned_singbox_after_failure
if [ -s "$kill_log" ]; then
    printf 'foreign sing-box was signalled by MagicNet cleanup\n' >&2
    exit 1
fi

printf '%s\n' 'sing-box ownership test passed'

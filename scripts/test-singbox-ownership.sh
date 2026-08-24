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
write_proc_stat() {
    local pid="$1" state="$2" start="$3"
    printf '%s (sing-box) %s 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 %s 0\n' \
        "$pid" "$state" "$start" >"$proc_root/$pid/stat"
}
write_proc_stat 101 S 10101
write_proc_stat 202 S 20202
write_proc_stat 303 S 30303
write_proc_stat 404 Z 40404
printf 'sing-box\0run\0-c\0%s\0-D\0%s\0' \
    "$module/.config/sing-box/config.json" "$module/.config/sing-box" \
    >"$proc_root/101/cmdline"
printf 'sing-box\0run\0-c\0%s\0-D\0%s\0' \
    "$module/.config/sing-box/config.json" "$module/.config/sing-box" \
    >"$proc_root/202/cmdline"
# Same executable but a different config must not be treated as MagicNet-owned.
printf 'sing-box\0run\0-c\0%s\0-D\0%s\0' \
    "$fixture/other/config.json" "$fixture/other" >"$proc_root/303/cmdline"
# A zombie with the exact command line is still not a live core.
printf 'sing-box\0run\0-c\0%s\0-D\0%s\0' \
    "$module/.config/sing-box/config.json" "$module/.config/sing-box" \
    >"$proc_root/404/cmdline"

cat >"$bin_dir/pidof" <<'SH'
#!/bin/sh
printf '%s\n' "${PIDOF_RESULT:-101 202 303 404}"
SH
chmod +x "$bin_dir/pidof"

export MODDIR="$module"
export MAGICNET_SINGBOX_PROC_ROOT="$proc_root"
export PATH="$bin_dir:$PATH"
. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"
. "$ROOT/scripts/test-lib/proc-reader-hook.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"

set +e
magicnet_singbox_pid_live 505
unreadable_rc=$?
set -e
test "$unreadable_rc" -eq 2

owned="$(PIDOF_RESULT='101 202 303 404' \
    magicnet_singbox_owned_pids "$module/.config/sing-box/config.json")"
test "$owned" = '101'

# A still-present candidate whose identity cannot be read makes the complete
# ownership set indeterminate; it must not be silently skipped as unowned.
set +e
owned="$(PIDOF_RESULT='101 505' \
    magicnet_singbox_owned_pids "$module/.config/sing-box/config.json")"
owned_rc=$?
set -e
test "$owned_rc" -eq 2
test -z "$owned"

printf '%s\n' 'sing-box ownership test passed'

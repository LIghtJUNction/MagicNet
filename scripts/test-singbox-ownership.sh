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
printf '%s\n' '101 202 303 404 505'
SH
chmod +x "$bin_dir/pidof"

export MODDIR="$module"
export MAGICNET_SINGBOX_PROC_ROOT="$proc_root"
export PATH="$bin_dir:$PATH"
import() { :; }
set_i18n() { :; }
config() { :; }
i18n() { printf '%s' "$1"; }
info() { :; }
warn() { :; }
success() { :; }
. "$ROOT/src/MagicNet/lib/kamfw/__singbox__.sh"

if singbox_pid_live 505; then
    printf 'singbox_pid_live accepted a PID with unreadable proc stat\n' >&2
    exit 1
fi

owned="$(singbox_owned_pids)"
test "$owned" = '101'
is_singbox_running

kill_log="$fixture/kill.log"
kill() {
    printf '%s\n' "$*" >>"$kill_log"
    for pid in "$@"; do
        case "$pid" in
            -*) continue ;;
        esac
        rm -rf "${proc_root:?}/$pid"
    done
}
sleep() { :; }
singbox_stop
test "$(cat "$kill_log")" = '101'
test -d "$proc_root/202"
test -d "$proc_root/303"
test -d "$proc_root/404"

printf '%s\n' 'sing-box ownership test passed'

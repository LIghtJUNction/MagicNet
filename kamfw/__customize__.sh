# shellcheck shell=ash
# Minimal customize shim: root-safe module env, module perms, and installer helper import
# Keep this file tiny — heavy lifting lives in src/MagicNet/lib/kamfw/__installer__.sh

import __at_exit__   # provides install-on-exit handler
import __installer__ # compact installer API (install/include/exclude/check/run/schedule)

# Root lifecycle must not inherit executable or library search paths from an
# app-owned Termux environment. Keep the installer harness and MagicNet files
# available through a fixed module/system-only environment.
export PATH="$MODDIR/bin:/data/adb/magisk:/data/adb/ksu/bin:/system/bin:/system/xbin:/sbin"
export LD_LIBRARY_PATH="$MODDIR/lib"

# i18n for permission messages (user-visible)
set_i18n "SET_PERM_BINARIES" "zh" "设置本地可执行文件权限" "en" "Setting permissions for local binaries"
set_i18n "SET_PERM_LIBRARIES" "zh" "设置本地库文件权限" "en" "Setting permissions for local libraries"

# Apply private-mode permissions (best-effort; do not fail if helper missing)
[ -d "$MODDIR/bin" ] && {
    info "$(i18n 'SET_PERM_BINARIES')"
    type set_perm_recursive >/dev/null 2>&1 && set_perm_recursive "$MODDIR/bin" 0 0 0700 0700 "u:object_r:system_file:s0"
}
[ -d "$MODDIR/lib" ] && {
    info "$(i18n 'SET_PERM_LIBRARIES')"
    type set_perm_recursive >/dev/null 2>&1 && set_perm_recursive "$MODDIR/lib" 0 0 0700 0700 "u:object_r:system_file:s0"
}

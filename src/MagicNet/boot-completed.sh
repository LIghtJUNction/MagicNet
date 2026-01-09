# shellcheck shell=ash

MODDIR=${0%/*}
[ -f "${MODDIR}/lib/kamfw/.kamfwrc" ] && . "$MODDIR/lib/kamfw/.kamfwrc" || abort '! File ".kamfwrc" does not exist!'

import __runtime__
import wait

# Initialize runtime environment (sets PATH, LD_LIBRARY_PATH, KAM_HOME)
kamfw_init_home
kamfw_init_paths

# Wait for device to be ready
wait_boot_if_magisk
wait_unlock 3

# Conditionally start the available kernel
if has_command "sing-box"; then
    import __singbox__
    singbox_start
elif has_command "mihomo"; then
    import __mihomo__
    mihomo_start
else
    print "MagicNet: No supported kernel found (mihomo or sing-box)."
fi

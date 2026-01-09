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

# Allow toggling kernel start via env vars (default: enabled)
MAGIC_MIHOMO=${MAGIC_MIHOMO:-1}
MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}

# Conditionally start the available kernel (respect env flags and fallback)
if [ "${MAGIC_SINGBOX}" -ne 0 ] && has_command "sing-box"; then
    import __singbox__
    if singbox_start; then
        :
    else
        print "MagicNet: sing-box failed to start; attempting mihomo fallback..."
        if [ "${MAGIC_MIHOMO}" -ne 0 ] && has_command "mihomo"; then
            import __mihomo__
            mihomo_start
        fi
    fi
elif [ "${MAGIC_MIHOMO}" -ne 0 ] && has_command "mihomo"; then
    import __mihomo__
    mihomo_start
else
    print "MagicNet: No supported kernel found or starting disabled (mihomo or sing-box)."
fi

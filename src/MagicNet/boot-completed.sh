# shellcheck shell=ash

MODDIR=${0%/*}
[ -f "${MODDIR}/lib/kamfw/.kamfwrc" ] && . "$MODDIR/lib/kamfw/.kamfwrc" || abort '! File ".kamfwrc" does not exist!'
import __mihomo__
import wait

wait_boot_if_magisk

wait_unlock 10

mihomo_start


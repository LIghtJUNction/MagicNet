#!/system/bin/sh
# shellcheck shell=ash

case "$0" in
    */*) MODDIR=${MODDIR:-${0%/*}} ;;
    *) MODDIR=${MODDIR:-$(pwd)} ;;
esac
. "${MODDIR}/lib/kamfw/.kamfwrc" || exit 1
. "${MODDIR}/lib/magicnet.sh"

magicnet_enable_hotspot_forward "$@"

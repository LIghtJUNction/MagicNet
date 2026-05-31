#!/system/bin/sh
# shellcheck shell=ash

MODDIR=${MODDIR:-${0%/*}}
. "${MODDIR}/lib/kamfw/.kamfwrc" || exit 1
. "${MODDIR}/lib/magicnet.sh"

magicnet_enable_vpn_coexist "$@"

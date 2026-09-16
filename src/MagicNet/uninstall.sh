#!/system/bin/sh
# shellcheck shell=ash
MODDIR=${0%/*}
export MODDIR
# Keep cleanup independent of the installer's interactive framework.
. "$MODDIR/lib/magicnet/uninstall.sh" || exit 1
magicnet_uninstall_main

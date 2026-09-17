#!/system/bin/sh
# shellcheck shell=ash
MODDIR=${0%/*}
export MODDIR
# Keep cleanup independent of the installer's interactive framework.
. "$MODDIR/lib/magicnet/uninstall.sh" || exit 1
magicnet_uninstall_main
# Legacy versions appended unconditional rollback commands here. The locked
# lifecycle above owns cleanup; never fall through to a second blind deleter.
exit "$?"

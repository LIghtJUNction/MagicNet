#!/system/bin/sh
# shellcheck shell=ash
MODDIR=${0%/*}
exec "$MODDIR/bin/magicnet-cli" --root "$MODDIR" --hook boot-completed

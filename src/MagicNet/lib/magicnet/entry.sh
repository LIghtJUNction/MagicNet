# shellcheck shell=ash
#
# Shared Kamfw bootstrap for MagicNet entry scripts.

case "$0" in
    */*) MODDIR=${0%/*} ;;
    *) MODDIR=${MODDIR:-$(pwd)} ;;
esac
if [ -f "${MODDIR}/lib/kamfw/.kamfwrc" ]; then
    . "$MODDIR/lib/kamfw/.kamfwrc"
else
    abort '! File ".kamfwrc" does not exist!'
fi

import __runtime__
. "${MODDIR}/lib/magicnet.sh"
magicnet_clear_untrusted_inherited_env

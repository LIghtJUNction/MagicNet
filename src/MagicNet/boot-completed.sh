# shellcheck shell=ash

MODDIR=${0%/*}
if [ -f "${MODDIR}/lib/kamfw/.kamfwrc" ]; then
    . "$MODDIR/lib/kamfw/.kamfwrc"
else
    abort '! File ".kamfwrc" does not exist!'
fi

import __runtime__
. "${MODDIR}/lib/magicnet.sh"

kamfw run boot-completed -- "$@"

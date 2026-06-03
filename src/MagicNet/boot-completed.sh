# shellcheck shell=ash

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

kamfw run boot-completed -- "$@"

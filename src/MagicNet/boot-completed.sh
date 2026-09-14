#!/system/bin/sh
# shellcheck shell=ash

case "$0" in
    */*) . "${0%/*}/lib/magicnet/entry.sh" || exit 1 ;;
    *) . "${MODDIR:-$(pwd)}/lib/magicnet/entry.sh" || exit 1 ;;
esac

kamfw run boot-completed -- "$@"

# shellcheck shell=ash

case "$0" in
    */*) . "${0%/*}/lib/magicnet/entry.sh" ;;
    *) . "${MODDIR:-$(pwd)}/lib/magicnet/entry.sh" ;;
esac

kamfw run boot-completed -- "$@"

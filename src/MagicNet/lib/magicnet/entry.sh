# shellcheck shell=ash
#
# Shared Kamfw bootstrap for MagicNet entry scripts.

case "$0" in
    */*) MODDIR=${0%/*} ;;
    *) MODDIR=${MODDIR:-$(pwd)} ;;
esac

_kamfw_rc="${MODDIR}/lib/kamfw/.kamfwrc"
if [ ! -f "$_kamfw_rc" ]; then
    printf '%s\n' "MagicNet: required framework file is missing: $_kamfw_rc" >&2
    unset _kamfw_rc
    return 1
fi
. "$_kamfw_rc"
unset _kamfw_rc

import __runtime__
. "${MODDIR}/lib/magicnet.sh"

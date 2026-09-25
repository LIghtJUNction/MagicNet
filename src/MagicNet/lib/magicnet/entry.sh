# shellcheck shell=ash
#
# Shared Kamfw bootstrap for MagicNet entry scripts.

# Inherited loader and shell hooks can execute attacker-controlled code
# before MagicNet validates its runtime. Strip them at bootstrap.
unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG LD_DYNAMIC_WEAK
unset LD_ORIGIN_PATH LD_PROFILE LD_SHOW_AUXV LD_TRACE_LOADED_OBJECTS
unset LD_USE_LOAD_BIAS LD_VERBOSE LD_WARN
unset ENV BASH_ENV CDPATH

case "$0" in
    */*) MODDIR=${0%/*} ;;
    *) MODDIR=${MODDIR:-$(pwd)} ;;
esac

_kamfw_rc="${MODDIR}/lib/kamfw/.kamfwrc"
if [ ! -f "$_kamfw_rc" ]; then
    printf '%s\n' "MagicNet: required framework file is missing: $_kamfw_rc" >&2
    unset _kamfw_rc
    # `command return` exits a sourced bootstrap immediately. When this file is
    # executed directly, return is invalid and the explicit exit preserves the
    # same failure status without an unreachable `return || exit` construct.
    if ! command return 1 2>/dev/null; then
        exit 1
    fi
fi
. "$_kamfw_rc"
unset _kamfw_rc

import __runtime__
. "${MODDIR}/lib/magicnet.sh"

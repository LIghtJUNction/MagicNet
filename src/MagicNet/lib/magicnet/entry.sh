# shellcheck shell=ash
#
# Shared Kamfw bootstrap for MagicNet entry scripts.

# Inherited loader and shell hooks can execute attacker-controlled code
# before MagicNet validates its runtime. Strip them at bootstrap.
unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG LD_DYNAMIC_WEAK
unset LD_ORIGIN_PATH LD_PROFILE LD_SHOW_AUXV LD_TRACE_LOADED_OBJECTS
unset LD_USE_LOAD_BIAS LD_VERBOSE LD_WARN
unset ENV BASH_ENV CDPATH
# Magisk/service entries must not honor a caller-injected library or
# subscription path. The module re-exports transaction variables later.
unset MAGICNET_LIB_DIR
unset MAGICNET_SUB_CANDIDATE_URL_FILE MAGICNET_SUB_CANDIDATE_SOURCE_FILE
unset MAGICNET_SUB_CONFIG_FILE MAGICNET_SUB_FILTER_FILE
unset MAGICNET_SUB_SOURCE_FILE MAGICNET_SUB_URL_FILE MAGICNET_SUB_USER_AGENT_FILE
unset MAGICNET_SUB_FAULT MAGICNET_SUB_FAULT_EXIT137 MAGICNET_SUB_FAULT_TERM
unset MAGICNET_SUB_REFRESH_OWNER_WRITE_FAIL MAGICNET_SUB_REFRESH_PROC_ROOT
unset MAGICNET_SUB_DEFER_FSWATCH_RESTORE MAGICNET_SUB_FSWATCH_RESTORE_PENDING
unset MAGICNET_SUB_FSWATCH_WAS_ACTIVE MAGICNET_SUB_PRESERVE_REFRESH

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

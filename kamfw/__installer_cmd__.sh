# shellcheck shell=ash
#
# CLI entry for installer operations
#
# This module provides the `installer` command (small surface) so the main
# installer helper file can remain compact and single-responsibility.
#
# Usage:
#   installer <exclude|include|show|check|run|schedule> [args]
#
# Note: This function delegates to the core helpers in `__install_core__`
# (file listing, extraction, install-on-exit). It assumes those helpers are
# already available in the runtime environment (via `import __install_core__`).
#
installer() {
    cmd="$1"
    [ $# -gt 0 ] && shift

    case "$cmd" in
    exclude)
        install_exclude "$@"
        return 0
        ;;
    include)
        install_include "$@"
        return 0
        ;;
    show)
        install_show_filters
        return 0
        ;;
    check)
        install_check "$1"
        return $?
        ;;
    run)
        src="$1"
        files="$(install_check "$src" 2>/dev/null)"
        cnt="$(__inst__count_lines "$files")"

        [ "$cnt" -eq 0 ] && {
            info "$(__inst__msg 'INSTALL_NO_FILES' 'No files to install')"
            return 0
        }

        info "$(__inst__msg1 'INSTALL_RUNNING_NOW' "Installing $cnt files now" "$cnt")"
        __inst__invoke_install "$src"
        info "$(__inst__msg 'INSTALL_DONE' 'Install completed')"
        return 0
        ;;
    schedule)
        src="$1"
        files="$(install_check "$src" 2>/dev/null)"
        cnt="$(__inst__count_lines "$files")"

        [ "$cnt" -eq 0 ] && {
            info "$(__inst__msg 'INSTALL_NO_FILES' 'No files to install')"
            return 0
        }

        __inst__register_hook
        info "$(__inst__msg1 'INSTALL_WILL_ON_EXIT' "Will install $cnt files on exit" "$cnt")"
        return 0
        ;;
    "" | help | -h | --help)
        print "installer: usage: installer <exclude|include|show|check|run|schedule> [args]"
        return 0
        ;;
    *)
        # Backwards-compatible behavior: treat unrecognized argument as <src> to schedule.
        installer schedule "$cmd"
        return $?
        ;;
    esac
}

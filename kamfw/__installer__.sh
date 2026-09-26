# shellcheck shell=ash
# Compact installer helper for kamfw
# - Provides install_exclude/include/show/check/run/schedule
# - Small, reusable, and keeps runtime i18n/at-exit integration
#
# Usage (after import):
#   install_exclude 'test/*'
#   install_include 'bin/*'
#   installer check [<src>]
#   installer run [<src>]
#   installer schedule [<src>]
#
# Notes:
# - All user-visible strings are i18n keys.
# - Critical external deps (zip tools) fail-fast with i18n key ZIPTOOLS_MISSING.
# - This helper intentionally keeps a minimal surface to be imported by customize.sh.
#
# (Keep this file compact and under 200 lines.)
import __at_exit__      # provides at-exit helper utilities
import __install_core__ # install core helpers (file listing & install-on-exit)

# i18n (user-facing)
set_i18n "INSTALL_NO_FILES" "zh" "没有需要安装的文件" "en" "No files to install"
set_i18n "INSTALL_WILL_ON_EXIT" "zh" "将在退出时自动安装 \$_1 个文件" "en" "Will install \$_1 files on exit"
set_i18n "INSTALL_RUNNING_NOW" "zh" "正在立即安装 \$_1 个文件" "en" "Installing \$_1 files now"
set_i18n "INSTALL_DONE" "zh" "自动安装完成" "en" "Install completed"

# Internal pattern storage (newline-separated)
__install_exclude_patterns=""
__install_include_patterns=""

# Helpers moved to __install_core__ (keeps __installer__ focused and small)

__inst__invoke_install() {
    src="$1"
    if [ -n "$src" ]; then
        if [ -d "$src" ]; then
            KAM_MODULE_ROOT="$src"
            __installer_install_from_filters
            unset KAM_MODULE_ROOT
            return 0
        fi
        if [ -f "$src" ]; then
            ZIPFILE="$src"
            __installer_install_from_filters
            unset ZIPFILE
            return 0
        fi
    fi
    __installer_install_from_filters
}

# install-on-exit handler moved to __install_core__ (callers should register it explicitly)

__inst__register_hook() {
    at_exit_register_trap
    at_exit_add '__installer_install_from_filters'
}

__inst__show_patterns() {
    var="$1"
    label="$2"
    print "$label"
    eval "val=\${$var:-}"
    if [ -z "${val:-}" ]; then
        print "  <none>"
        return 0
    fi
    OLDIFS=$IFS
    IFS='
'
    for p in $val; do
        print "  $p"
    done
    IFS=$OLDIFS
}

# Public API: filters
install_reset_filters() {
    unset __install_exclude_patterns __install_include_patterns
    return 0
}

install_show_filters() {
    __inst__show_patterns __install_exclude_patterns "Exclude patterns:"
    __inst__show_patterns __install_include_patterns "Include patterns:"
    return 0
}

install_exclude() {
    [ $# -eq 0 ] && return 0
    for pat in "$@"; do
        pat="${pat#./}"
        pat="${pat#/}"
        __inst__add_unique __install_exclude_patterns "$pat"
    done
    return 0
}

install_include() {
    [ $# -eq 0 ] && return 0
    for pat in "$@"; do
        pat="${pat#./}"
        pat="${pat#/}"
        __inst__add_unique __install_include_patterns "$pat"
    done
    return 0
}

# install_check: (all_files - excludes) U includes
install_check() {
    src="$1"
    if [ -z "$src" ]; then
        if [ -n "${KAM_MODULE_ROOT:-}" ] && [ -d "${KAM_MODULE_ROOT}" ]; then
            src="${KAM_MODULE_ROOT}"
        elif [ -n "${ZIPFILE:-}" ] && [ -f "${ZIPFILE}" ]; then
            src="${ZIPFILE}"
        else
            src="."
        fi
    fi

    files=""
    if [ -d "$src" ]; then
        files="$(__list_files_from_dir "$src")"
    elif [ -f "$src" ]; then
        files="$(__list_files_from_zip "$src")" || __inst__abort_ziptools_missing
    else
        files="$(__list_files_from_dir ".")"
    fi

    selected=""
    OLDIFS=$IFS
    IFS='
'
    for f in $files; do
        [ -z "$f" ] && continue
        __inst__matches_any "$f" "__install_exclude_patterns" && continue
        __inst__add_unique selected "$f"
    done
    if [ -n "${__install_include_patterns:-}" ]; then
        for f in $files; do
            [ -z "$f" ] && continue
            __inst__matches_any "$f" "__install_include_patterns" && __inst__add_unique selected "$f"
        done
    fi
    IFS=$OLDIFS

    OLDIFS=$IFS
    IFS='
'
    for f in $selected; do
        [ -n "$f" ] && print "$f"
    done
    IFS=$OLDIFS
    return 0
}

# Keep `import __installer__` as the complete public installer entrypoint.
import __installer_cmd__

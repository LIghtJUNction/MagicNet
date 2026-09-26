# shellcheck shell=ash
#
# __install_core__.sh
#
# Core helpers for installer features (file listing, zip helpers, and
# install-on-exit handler).
#
# Purpose:
# - Keep installer responsibilities focused and small.
# - Provide a single place for zip/list utilities and the install-on-exit
#   implementation so __installer__.sh can stay tiny and SRP-compliant.
#
# Principles:
# - Fail fast on missing critical tools (no silent fallbacks for extraction).
# - Use framework logging helpers (info/warn/success) and i18n keys.
# - Keep functions small and testable.
#

# -----------------------------------------------------------------------------
# i18n: messages used by installer-core
# -----------------------------------------------------------------------------
set_i18n "AUTO_EXTRACT_NO_MODPATH" \
    "zh" "没有指定 MODPATH，跳过自动安装" \
    "en" "No MODPATH set, skipping install"

set_i18n "AUTO_EXTRACT_NO_FILES" \
    "zh" "没有找到任何需要自动安装的文件" \
    "en" "No files to install on exit"

set_i18n "AUTO_EXTRACT_START" \
    "zh" "开始在退出时安装文件..." \
    "en" "Starting install-on-exit..."

set_i18n "AUTO_EXTRACT_INSTALL_OK" \
    "zh" "已安装：\$_1" \
    "en" "Installed: \$_1"

set_i18n "AUTO_EXTRACT_INSTALL_FAILED" \
    "zh" "安装失败：\$_1" \
    "en" "Failed to install: \$_1"

set_i18n "AUTO_EXTRACT_SKIP_EXISTING_NONINTERACTIVE" \
    "zh" "文件已存在，非交互模式下跳过：\$_1" \
    "en" "Skipping existing file in non-interactive mode: \$_1"

set_i18n "AUTO_EXTRACT_DONE" \
    "zh" "自动安装完成（\$_1 个文件）" \
    "en" "Install completed (\$_1 files)"

# -----------------------------------------------------------------------------
# Small helpers used by installer
# -----------------------------------------------------------------------------
__inst__msg() {
    key="$1"
    fallback="$2"
    _msg="$(i18n "$key" 2>/dev/null)"
    [ -n "$_msg" ] || _msg="$fallback"
    printf '%s' "$_msg"
}

__inst__msg1() {
    key="$1"
    fallback="$2"
    arg="$3"
    _msg="$(i18n "$key" 2>/dev/null | t "$arg" 2>/dev/null)"
    [ -n "$_msg" ] || _msg="$fallback"
    printf '%s' "$_msg"
}

__inst__add_unique() {
    # add newline-separated unique entry to variable named by $1 (var), value $2
    var="$1"
    val="$2"
    eval "cur=\${$var}"
    if [ -n "${cur:-}" ]; then
        printf '%s\n' "$cur" | grep -F -x -- "$val" >/dev/null 2>&1 && return 0
        eval "$var=\"\$(printf '%s\n%s' \"\$cur\" \"$val\")\""
    else
        eval "$var=\$val"
    fi
    return 0
}

__inst__matches_any() {
    # returns 0 if $1 matches any newline-separated pattern in variable named by $2
    path="$1"
    patterns_var="$2"
    eval "pats=\${$patterns_var}"
    [ -z "${pats:-}" ] && return 1
    OLDIFS=$IFS
    IFS='
'
    for pat in $pats; do
        # shellcheck disable=SC2254
        case "$path" in
        $pat)
            IFS=$OLDIFS
            return 0
            ;;
        esac
    done
    IFS=$OLDIFS
    return 1
}

__inst__count_lines() {
    # returns number of non-empty lines in $1 (0 for empty)
    printf '%s\n' "$1" | awk 'NF{c++} END{print c+0}'
}

__inst__cleanup_dir() {
    [ -n "${1:-}" ] && rm -rf "$1" 2>/dev/null
}

__inst__ensure_parent_dir() {
    _parent="$(dirname "$1")"
    mkdir -p "$_parent" 2>/dev/null || abort "mkdir failed: $_parent"
}

__inst__mark_script_executable() {
    _path="$1"
    if head -n1 "$_path" 2>/dev/null | grep -q '^#!'; then
        chmod +x "$_path" 2>/dev/null || warn "chmod failed: $_path"
    fi
}

__inst__copy_file() {
    src="$1"
    dst="$2"
    rel="$3"

    __inst__ensure_parent_dir "$dst"
    if cp -a "$src" "$dst" 2>/dev/null; then
        __inst__mark_script_executable "$dst"
        success "$(__inst__msg1 'AUTO_EXTRACT_INSTALL_OK' "Installed: $rel" "$rel")"
        return 0
    fi

    warn "$(__inst__msg1 'AUTO_EXTRACT_INSTALL_FAILED' "Failed to install: $rel" "$rel")"
    return 1
}

__inst__warn_existing_noninteractive() {
    rel="$1"
    warn "$(__inst__msg1 'AUTO_EXTRACT_SKIP_EXISTING_NONINTERACTIVE' "Skipping existing file: $rel" "$rel")"
}

__inst__warn_install_failed() {
    rel="$1"
    warn "$(__inst__msg1 'AUTO_EXTRACT_INSTALL_FAILED' "Failed to install: $rel" "$rel")"
}

__inst__abort_ziptools_missing() {
    abort "$(__inst__msg 'ZIPTOOLS_MISSING' 'zip tools missing')"
}

# -----------------------------------------------------------------------------
# File listing helpers
# -----------------------------------------------------------------------------
__list_files_from_dir() {
    root="$1"
    if [ -z "$root" ] || [ "$root" = "." ]; then
        find . -type f 2>/dev/null | sed 's|^\./||'
        return 0
    fi
    if [ -d "$root" ]; then
        (cd "$root" 2>/dev/null && find . -type f 2>/dev/null | sed 's|^\./||')
        return 0
    fi
    return 1
}

__list_files_from_zip() {
    zipfile="$1"
    # Prefer zipinfo, then try 'unzip -Z1', else fail fast
    if command -v zipinfo >/dev/null 2>&1; then
        zipinfo -1 "$zipfile" 2>/dev/null | sed '/\/$/d'
        return 0
    fi
    if command -v unzip >/dev/null 2>&1; then
        if unzip -Z1 "$zipfile" >/dev/null 2>&1; then
            unzip -Z1 "$zipfile" 2>/dev/null | sed '/\/$/d'
            return 0
        fi
        # Last resort: use unzip -l (structured output parsing)
        unzip -l "$zipfile" 2>/dev/null | awk '{print $4}' | sed '/\/$/d' | sed '/^$/d'
        return 0
    fi
    __inst__abort_ziptools_missing
}

__install__get_files_from_zip() {
    # compatibility wrapper for callers that expect the file list
    __list_files_from_zip "$1"
}

# -----------------------------------------------------------------------------
# Install-on-exit: explicit handler to be registered by installer (via at_exit_add)
# -----------------------------------------------------------------------------
__installer_install_from_filters() {
    # Only meaningful during an installation (MODPATH present)
    [ -z "${MODPATH:-}" ] && {
        info "$(__inst__msg 'AUTO_EXTRACT_NO_MODPATH' 'No MODPATH set')"
        return 0
    }

    # Determine files to install (caller provides context via install_check)
    files="$(install_check 2>/dev/null)"
    if [ -z "${files:-}" ]; then
        info "$(__inst__msg 'AUTO_EXTRACT_NO_FILES' 'No files to install on exit')"
        return 0
    fi

    info "$(__inst__msg 'AUTO_EXTRACT_START' 'Starting install-on-exit...')"

    OLDIFS=$IFS
    IFS='
'
    for rel in $files; do
        [ -z "$rel" ] && continue

        dst="$MODPATH/$rel"

        # Prefer source in module root
        if [ -n "${KAM_MODULE_ROOT:-}" ] && [ -f "${KAM_MODULE_ROOT}/$rel" ]; then
            src="${KAM_MODULE_ROOT}/$rel"
            if [ -f "$dst" ]; then
                # Existing; in interactive mode prompt helper may handle it
                if [ -t 0 ] && type "__confirm_install_file_do" >/dev/null 2>&1; then
                    __confirm_install_file_do "$src" "$rel"
                else
                    __inst__warn_existing_noninteractive "$rel"
                fi
            else
                __inst__copy_file "$src" "$dst" "$rel"
            fi
            continue
        fi

        # Try to extract from ZIPFILE if available (we require 'unzip' for extraction)
        if [ -n "${ZIPFILE:-}" ] && [ -f "${ZIPFILE}" ]; then
            # ensure we have listing support (zipinfo/unzip) earlier; extraction requires 'unzip'
            entry=""
            if type "__find_zip_entry" >/dev/null 2>&1; then
                entry="$(__find_zip_entry "${ZIPFILE}" "$rel" 2>/dev/null)"
            else
                entry="$(__install__get_files_from_zip "${ZIPFILE}" 2>/dev/null | awk -v r="$rel" '{ if ($0==r){print; exit} if (length($0)>=length(r) && substr($0,length($0)-length(r)+1)==r){print; exit} }')"
            fi

            if [ -n "$entry" ]; then
                if [ -t 0 ] && type "__confirm_install_file_do_from_zip" >/dev/null 2>&1; then
                    __confirm_install_file_do_from_zip "${ZIPFILE}" "$entry" "$rel"
                else
                    TMPDIR="${TMPDIR:-/tmp}"
                    tmpdir="$(mktemp -d "${TMPDIR}/kamfw.extract.XXXXXX" 2>/dev/null || mktemp -d 2>/dev/null)"
                    [ -n "$tmpdir" ] || {
                        __inst__warn_install_failed "$rel"
                        continue
                    }

                    # We require 'unzip' to perform extraction; fail fast otherwise
                    if ! command -v unzip >/dev/null 2>&1; then
                        __inst__cleanup_dir "$tmpdir"
                        __inst__abort_ziptools_missing
                    fi

                    # Extract entry (preserve metadata as much as possible)
                    if ! unzip -o -j "${ZIPFILE}" "$entry" -d "$tmpdir" >/dev/null 2>&1; then
                        __inst__cleanup_dir "$tmpdir"
                        __inst__warn_install_failed "$rel"
                        continue
                    fi

                    srcfile="$tmpdir/$(basename "$entry")"
                    if [ -f "$dst" ]; then
                        __inst__warn_existing_noninteractive "$rel"
                    else
                        __inst__copy_file "$srcfile" "$dst" "$rel"
                    fi
                    __inst__cleanup_dir "$tmpdir"
                fi
            else
                # entry not found in zip
                __inst__warn_install_failed "$rel"
            fi
        fi
    done
    IFS=$OLDIFS

    cnt="$(__inst__count_lines "$files")"
    success "$(__inst__msg1 'AUTO_EXTRACT_DONE' "Install completed ($cnt files)" "$cnt")"
    return 0
}

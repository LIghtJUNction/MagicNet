# shellcheck shell=ash
confirm_update_file() {
    _relative_path="$1"

    # 检查MODPATH环境变量
    [ -z "${MODPATH:-}" ] && return 0

    # 检查参数
    [ -z "$_relative_path" ] && return 0

    # 获取模块ID
    _module_id=""
    if [ -f "$MODPATH/module.prop" ]; then
        _module_id=$(sed -n 's/^id=//p' "$MODPATH/module.prop" | head -n1)
    fi
    [ -z "$_module_id" ] && return 0

    # 检查模块是否已安装
    _installed_module_path="/data/adb/modules/$_module_id"
    [ ! -d "$_installed_module_path" ] && return 0

    # 直接使用ask函数，默认选择否(1)
    # 使用t函数动态构建标题
    _final_title="$(i18n 'FORCE_UPDATE_FILE' | t "$_relative_path")"
    ask "$_final_title" \
        "$(i18n 'YES')" \
        'unset _relative_path _module_id _installed_module_path; return 0' \
        "$(i18n 'NO')" \
        '_do_update_file' \
        1

    # 这个函数不会执行到这里，因为ask会处理返回
}

# i18n keys
set_i18n "SELECT_INSTALL_FILE" \
    "zh" "选择要安装的文件" \
    "en" "Select file to install" \
    "ja" "インストールするファイルを選択" \
    "ko" "설치할 파일 선택"

set_i18n "FILE_INSTALLED" \
    "zh" "已安装: " \
    "en" "Installed: " \
    "ja" "インストール済: " \
    "ko" "설치됨: "

set_i18n "NO_FILES_AVAILABLE" \
    "zh" "没有可安装的文件" \
    "en" "No files available to install" \
    "ja" "インストール可能なファイルがありません" \
    "ko" "설치할 파일이 없습니다"

set_i18n "CANCEL" \
    "zh" "取消" \
    "en" "Cancel" \
    "ja" "キャンセル" \
    "ko" "취소"

set_i18n "INSTALLED" \
    "zh" "已安装" \
    "en" "installed" \
    "ja" "インストール済" \
    "ko" "설치됨"

# __confirm_install_file_do - helper to perform the actual copy
__confirm_install_file_do() {
    _src="$1"
    _rel="$2"

    if [ -z "$_src" ] || [ ! -f "$_src" ]; then
        error "Source not found: $_src"
        return 1
    fi

    _dst="$MODPATH/$_rel"
    _dstdir="${_dst%/*}"
    [ "$_dstdir" != "$_dst" ] && mkdir -p "$_dstdir"

    if [ -f "$_dst" ]; then
        _final_title="$(i18n 'FORCE_UPDATE_FILE' 2>/dev/null | t "$_rel")"
        if confirm "$_final_title" 1; then
            cp -a "$_src" "$_dst"
            success "$({ _m="$(i18n 'FILE_INSTALLED' 2>/dev/null)"; [ -n "$_m" ] || _m='Installed: '; printf '%s' "$_m"; })$_rel"
            __confirm_install_file_installed="$_rel"
        else
            __confirm_install_file_cancel=1
        fi
    else
        cp -a "$_src" "$_dst"
        success "$({ _m="$(i18n 'FILE_INSTALLED' 2>/dev/null)"; [ -n "$_m" ] || _m='Installed: '; printf '%s' "$_m"; })$_rel"
        __confirm_install_file_installed="$_rel"
    fi

    unset _src _rel _dst _dstdir _final_title
}

# confirm_install_file - 多选一安装文件（支持 SKIPUNZIP 的场景）
# Usage: confirm_install_file <rel_path1> [rel_path2 ...]
# 参数为相对于项目模块根目录的路径（多个），交互式选择其中一个进行安装到 $MODPATH
# 兼容两种来源：
#  - 源码目录 $KAM_MODULE_ROOT/<rel>（在构建/本地测试时常见）
#  - 安装包 $ZIPFILE 中的条目（当 SKIPUNZIP=1 时，包未解压到 $MODPATH）
confirm_install_file() {
    # 运行环境检查：必须在模块打包/安装阶段有 MODPATH
    [ -z "${MODPATH:-}" ] && return 0
    [ "$#" -eq 0 ] && return 0

    SRCDIR="${KAM_MODULE_ROOT:-.}"

    # 如果 ZIPFILE 存在（可能因为 SKIPUNZIP=1），但系统缺少 unzip（基础工具），直接中止安装
    if [ -n "${ZIPFILE:-}" ] && [ -f "${ZIPFILE:-}" ] && ! command -v unzip >/dev/null 2>&1; then
        _msg="$(i18n 'ZIPTOOLS_MISSING' 2>/dev/null)"; [ -n "$_msg" ] || _msg="Required unzip utility not found; aborting installation."; abort "$_msg"
    fi

    # 构建选项对 (text,cmd) - POSIX-safe (avoid bash arrays)
    _pairs_count=0
    for _rel in "$@"; do
        _src="$SRCDIR/$_rel"
        _cmd=""

        # 优先：如果源码目录中有该文件，直接使用
        if [ -f "$_src" ]; then
            _cmd="__confirm_install_file_do \"$_src\" \"$_rel\""
        else
            # 回退：如果启用了 SKIPUNZIP 或源码不可用，尝试从 ZIPFILE 中查找（支持 SKIPUNZIP=1 的情况）
            if [ -n "${ZIPFILE:-}" ] && [ -f "${ZIPFILE:-}" ]; then
                if entry=$(__find_zip_entry "${ZIPFILE}" "$_rel" 2>/dev/null) && [ -n "$entry" ]; then
                    _cmd="__confirm_install_file_do_from_zip \"${ZIPFILE}\" \"$entry\" \"$_rel\""
                fi
            fi
        fi

        if [ -n "$_cmd" ]; then
            if [ -f "$MODPATH/$_rel" ]; then
                _label="$_rel ($({ _m="$(i18n 'INSTALLED' 2>/dev/null)"; [ -n "$_m" ] || _m='installed'; printf '%s' "$_m"; }))"
            else
                if [ -f "$_src" ]; then
                    _label="$_rel"
                else
                    _label="$_rel ($(i18n 'IN_ZIP' 2>/dev/null || echo 'in zip'))"
                fi
            fi
            # Store as dynamic variables to avoid bash arrays
            __tmp="$_label"
            eval "pair_text_${_pairs_count}=\"\$__tmp\""
            __tmp="$_cmd"
            eval "pair_cmd_${_pairs_count}=\"\$__tmp\""
            _pairs_count=$((_pairs_count + 1))
        fi
    done

    if [ "${_pairs_count:-0}" -eq 0 ]; then
        warn "$(i18n 'NO_FILES_AVAILABLE' 2>/dev/null || echo 'No files available to install')"
        return 0
    fi

    # 增加取消选项
    __tmp="$(i18n 'CANCEL' 2>/dev/null || echo 'Cancel')"
    eval "pair_text_${_pairs_count}=\"\$__tmp\""
    __tmp='unset __confirm_install_file_installed; __confirm_install_file_cancel=1; return 0'
    eval "pair_cmd_${_pairs_count}=\"\$__tmp\""
    _pairs_count=$((_pairs_count + 1))

    # Build and escape argument list for ask by iterating dynamic pairs
    _escape_dq() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    _escape_sq() { printf '%s' "$1" | sed "s/'/'\"'\"'/g"; }
    _pair_args=""
    _i=0
    while [ "$_i" -lt "${_pairs_count}" ]; do
        eval "_label=\$pair_text_${_i}"
        eval "_cmd=\$pair_cmd_${_i}"
        # Escape label for double-quoted context and command for single-quoted context
        _label_esc=$(_escape_dq "$_label")
        _cmd_esc=$(_escape_sq "$_cmd")
        _pair_args="${_pair_args} \"${_label_esc}\" '${_cmd_esc}'"
        _i=$((_i + 1))
    done

    # Invoke ask with constructed (escaped) arguments
    eval "ask \"$(_escape_dq "$(i18n 'SELECT_INSTALL_FILE' 2>/dev/null || echo 'Select file to install')")\" ${_pair_args} 0"

    # 检查结果变量
    if [ -n "${__confirm_install_file_installed:-}" ]; then
        # 安装已在 helper 中打印成功信息，这里只清理状态并返回成功
        unset __confirm_install_file_installed __confirm_install_file_cancel
        return 0
    fi

    unset __confirm_install_file_installed __confirm_install_file_cancel
    return 1
}

# Helper: 在 ZIP 中查找与相对路径匹配的条目（返回 ZIP 内的 entry path）
# 使用固定字符串匹配（避免对 rel 做复杂正则转义），尽量兼容 unzip -Z1 / unzip -l / zipinfo -1 三种实现
__find_zip_entry() {
    zipfile="$1"
    rel="$2"

    # Try unzip -Z1 (one-file-per-line listing) and use fixed-string suffix/equals match
    if command -v unzip >/dev/null 2>&1; then
        if unzip -Z1 "$zipfile" >/dev/null 2>&1; then
            unzip -Z1 "$zipfile" 2>/dev/null | awk -v r="$rel" '
                { if ($0 == r) { print; exit } }
                END { if (NR==0) exit 1 }' | grep -F -x -q "$rel" >/dev/null 2>&1 && {
                printf '%s' "$rel"
                return 0
            }
            # fallback to suffix match using awk (match exact or ending-with /rel)
            unzip -Z1 "$zipfile" 2>/dev/null | awk -v r="$rel" '
                { if ($0 == r) { print; exit }
                  if (length($0) >= length(r) && substr($0, length($0)-length(r)+1) == r) { print; exit } }' | head -n1 || true
            return 0
        fi
        # fallback: parse unzip -l output (4th column is filename)
        entry=$(unzip -l "$zipfile" 2>/dev/null | awk '{print $4}' | awk -v r="$rel" '
            { if ($0 == r) { print; exit }
              if (length($0) >= length(r) && substr($0, length($0)-length(r)+1) == r) { print; exit } }' || true)
        if [ -n "$entry" ]; then
            printf '%s' "$entry"
            return 0
        fi
    fi

    # Try zipinfo -1 as another listing method
    if command -v zipinfo >/dev/null 2>&1; then
        entry=$(zipinfo -1 "$zipfile" 2>/dev/null | awk -v r="$rel" '
            { if ($0 == r) { print; exit }
              if (length($0) >= length(r) && substr($0, length($0)-length(r)+1) == r) { print; exit } }' || true)
        if [ -n "$entry" ]; then
            printf '%s' "$entry"
            return 0
        fi
    fi

    return 1
}

# Helper: 从 ZIP 提取指定 entry 并安装到 $MODPATH/<rel>
__confirm_install_file_do_from_zip() {
    zipfile="$1"
    entry="$2"
    rel="$3"

    # TMPDIR 可由安装器提供； fallback 到 /tmp
    TMPDIR="${TMPDIR:-/tmp}"
    tmpdir=$(mktemp -d "${TMPDIR}/kamfw.extract.XXXXXX" 2>/dev/null || mktemp -d)

    # 优先尝试 unzip（保留元数据），没有则回落 unzip -p
    if command -v unzip >/dev/null 2>&1; then
        if ! unzip -o -j "$zipfile" "$entry" -d "$tmpdir" >/dev/null 2>&1; then
            error "Failed to extract $entry from $zipfile"
            rm -rf "$tmpdir"
            return 1
        fi
    else
        if ! unzip -p "$zipfile" "$entry" >"$tmpdir/$(basename "$entry")" 2>/dev/null; then
            error "Failed to extract $entry from $zipfile (unzip missing)"
            rm -rf "$tmpdir"
            return 1
        fi
    fi

    srcfile="$tmpdir/$(basename "$entry")"
    dst="$MODPATH/$rel"
    dstdir="${dst%/*}"
    [ "$dstdir" != "$dst" ] && mkdir -p "$dstdir"

    if [ -f "$dst" ]; then
        _final_title="$(i18n 'FORCE_UPDATE_FILE' 2>/dev/null | t "$rel")"
        if confirm "$_final_title" 1; then
            cp -a "$srcfile" "$dst"
            success "$({ _m="$(i18n 'FILE_INSTALLED' 2>/dev/null)"; [ -n "$_m" ] || _m='Installed: '; printf '%s' "$_m"; })$rel"
            __confirm_install_file_installed="$rel"
        else
            __confirm_install_file_cancel=1
        fi
    else
        cp -a "$srcfile" "$dst"
        success "$({ _m="$(i18n 'FILE_INSTALLED' 2>/dev/null)"; [ -n "$_m" ] || _m='Installed: '; printf '%s' "$_m"; })$rel"
        __confirm_install_file_installed="$rel"
    fi

    # 如果文件以 shebang 开头，赋予可执行权限（常见二进制情况）
    if head -n1 "$dst" 2>/dev/null | grep -q '^#!'; then
        chmod +x "$dst" 2>/dev/null || true
    fi

    rm -rf "$tmpdir"
    unset zipfile entry rel srcfile dst dstdir tmpdir
    return 0
}

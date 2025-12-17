# shellcheck shell=ash
# =============================================================================
# 模块安装（内部实现）
# =============================================================================
#
# 提供内部实现函数，用于在不同 Root 管理器下安装模块 zip。
# 这是内部实现文件（不直接暴露为公共 API），公共 API 可在
# `install.sh` 中以 `_install_module_impl` 为后端实现对外包装。
#
# 提供函数：
#   _detect_module_installer    -> 检测可用的安装器，并设置变量 `_KAM_INSTALLER`
#   _run_installer_install      -> 根据检测到的安装器执行安装命令
#   _install_module_impl <zip>  -> 安装单个模块 zip（返回状态）
#   _install_modules_impl ...   -> 批量安装多个模块（逐个安装，遇错停止）
#
# 返回值约定（仅供参考）：
#   0 - 安装成功
#   1 - 参数无效或 zip 文件不存在
#   2 - 未检测到可用安装器（无法安装）
#   >=3 - 安装命令本身返回的错误码（直接透传）
#
# 设计原则：
# - 优先支持 magisk（`magisk --install-module`）
# - 其次支持 apd / ksud（`apd module install ZIP` / `ksud module install ZIP`）
# - 支持从 PATH 或者具体路径 `/data/adb/{apd,ksud,magisk}` 检测
#
# 使用示例（公共包装应当调用这些内部函数）：
#   _install_module_impl "/tmp/my-module.zip" || echo "安装失败"
#
# =============================================================================

# 检测可用的安装器，优先级：magisk -> apd -> ksud
# 成功时返回 0，并设置 `_KAM_INSTALLER` 变量为可执行命令或路径
# 失败时返回 1，并清除 `_KAM_INSTALLER`
_detect_module_installer() {
    # 不要覆盖外部定义（除非为空）
    unset _KAM_INSTALLER

    # magisk（优先）
    if command -v magisk >/dev/null 2>&1; then
        _KAM_INSTALLER="$(command -v magisk 2>/dev/null)"
        return 0
    fi
    if [ -x "/data/adb/magisk" ] || [ -f "/data/adb/magisk" ]; then
        _KAM_INSTALLER="/data/adb/magisk"
        return 0
    fi

    # apd / ksud
    for _ins in apd ksud; do
        if command -v "${_ins}" >/dev/null 2>&1; then
            _KAM_INSTALLER="$(command -v "${_ins}" 2>/dev/null)"
            return 0
        fi
        if [ -x "/data/adb/${_ins}" ] || [ -f "/data/adb/${_ins}" ]; then
            _KAM_INSTALLER="/data/adb/${_ins}"
            return 0
        fi
    done

    # 没有找到安装器
    unset _KAM_INSTALLER
    return 1
}

# 根据 _KAM_INSTALLER 执行安装命令
# 参数：$1 = zip 文件路径
# 返回：安装命令的退出码（失败则返回非零）
_run_installer_install() {
    [ -n "$1" ] || return 1
    zip="$1"

    case "${_KAM_INSTALLER:-}" in
        "" )
            return 2
            ;;
        *magisk* )
            # magisk：使用 --install-module
            "${_KAM_INSTALLER}" --install-module "$zip"
            return $?
            ;;
        *apd* | *ksud* )
            # apd / ksud：使用 module install 子命令
            "${_KAM_INSTALLER}" module install "$zip"
            return $?
            ;;
        * )
            # 通用回退：尝试以 `--install-module` 方式（兼容未来）
            "${_KAM_INSTALLER}" --install-module "$zip" >/dev/null 2>&1 && return 0 || return 3
            ;;
    esac
}

# 安装单个模块（内部实现）
# 用法：_install_module_impl "/path/to/module.zip"
# 返回码：
#   0 - 成功
#   1 - 参数/文件错误
#   2 - 找不到安装器
#   >=3 - 安装器返回的错误码
_install_module_impl() {
    [ -n "$1" ] || return 1
    zip="$1"

    # 检查文件是否存在
    if [ ! -f "$zip" ]; then
        # 错误：zip 文件不存在
        return 1
    fi

    # 检测安装器
    if ! _detect_module_installer; then
        return 2
    fi

    # 执行安装
    _run_installer_install "$zip"
    return $?
}

# 批量安装（遇到错误即停止并返回错误码）
# 用法：_install_modules_impl "/a.zip" "/b.zip" ...
_install_modules_impl() {
    [ $# -gt 0 ] || return 1
    _install_modules_impl_zip=""
    _install_modules_impl_ret=0
    for _install_modules_impl_zip in "$@"; do
        _install_module_impl "$_install_modules_impl_zip"
        _install_modules_impl_ret=$?
        if [ "$_install_modules_impl_ret" -ne 0 ]; then
            return "$_install_modules_impl_ret"
        fi
    done
    return 0
}

# 仅导出内部函数名称，不在文件加载时执行任何操作
# (公共接口请在 kam_utils/install.sh 中实现对外包装)

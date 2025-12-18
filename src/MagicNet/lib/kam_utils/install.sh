# shellcheck shell=ash
# =============================================================================
# 模块安装 - 公开API
# =============================================================================
#
# 公开包装 install 模块的内部实现（_install.sh 中提供的内部 API）。
# - `module_install <zip>`: 安装单个模块 zip，返回内部实现的退出码。
# - `install_modules <zip> [<zip> ...]`: 批量安装，遇错停止并返回错误码。
# - `detect_installer`: 检测并输出可用的安装器路径（eg. /usr/bin/magisk 或 /data/adb/apd），检测到返回 0。
# - `get_installer`: `detect_installer` 的别名。
#
# 使用示例:
#   module_install "/tmp/my-module.zip" || echo "安装失败"
#
# 返回码约定（参照内部实现）:
#   0 - 成功
#   1 - 参数/文件错误
#   2 - 未检测到可用安装器
#   >=3 - 安装器返回的错误码
#
# =============================================================================

# 加载内部实现
_kam_utils_dir="${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}"
# shellcheck source=_install.sh
if [ -f "${_kam_utils_dir}/_install.sh" ]; then
    . "${_kam_utils_dir}/_install.sh"
else
    echo "错误: 无法找到 _install.sh: ${_kam_utils_dir}/_install.sh" >&2
    return 1
fi

# 安装单个模块（公开 API）
# 用法: module_install "/path/to/module.zip"
module_install() {
    _install_module_impl "$@"
}
# 批量安装（逐个安装，遇到错误即停止并返回错误码）
# 用法: install_modules "/a.zip" "/b.zip" ...
install_modules() {
    _install_modules_impl "$@"
}

# 检测可用安装器并输出路径（如果找到）
# 用法: detect_installer && echo "installer: $(detect_installer)"
detect_installer() {
    _detect_module_installer || return $?
    [ -n "${_KAM_INSTALLER:-}" ] || return 1
    echo -n "${_KAM_INSTALLER}"
}

# shellcheck shell=ash
##########################################################################################
#
# KAM - Cross-Root Manager Utility Library
# 跨 Root 管理器统一工具库
#
##########################################################################################

# =============================================================================
# kam_load 按需加载系统
# =============================================================================

# 按需加载模块
# 用法: kam_load "模块名" [更多模块名...]
kam_load() {
    [ $# -eq 0 ] && {
        echo "请指定要加载的模块" >&2
        return 1
    }

    # 获取 kam_utils 目录（脚本当前目录）
    _kam_load_kam_utils_dir="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)/kam_utils"

    # 加载指定模块
    for module in "$@"; do
        module_file="${_kam_load_kam_utils_dir}/${module}.sh"
        if [ -f "$module_file" ]; then
            . "$module_file" || {
                echo "加载模块失败: $module" >&2
                return 1
            }
        else
            echo "模块不存在: $module" >&2
            return 1
        fi
    done
}

# =============================================================================
# 初始化函数
# =============================================================================

# 通用初始化
# 从 .kam 文件夹提取合适架构的二进制文件到对应目录
kam_init() {
    moddir="${MODDIR:-$(pwd)}"
    kam_dir="${moddir}/.kam"

    # 检查 .kam 目录是否存在
    [ ! -d "$kam_dir" ] && return 0

    # 检测架构（使用检测模块）
    kam_load detect >/dev/null 2>&1 || true
    detect_arch >/dev/null 2>&1
    arch="${ARCH:-unknown}"

    # 复制对应架构的二进制文件
    if [ "$arch" != "unknown" ] && [ -f "${kam_dir}/${arch}" ]; then
        cp "${kam_dir}/${arch}" "${moddir}/system/bin/" 2>/dev/null || true
        chmod 755 "${moddir}/system/bin/$(basename "${kam_dir}/${arch}")" 2>/dev/null || true
    fi


}

# 通用结束函数
# 删除 .kam 文件夹
kam_end() {
    moddir="${MODDIR:-$(pwd)}"
    kam_dir="${moddir}/.kam"

    # 删除 .kam 目录
    [ -d "$kam_dir" ] && rm -rf "$kam_dir" 2>/dev/null
}

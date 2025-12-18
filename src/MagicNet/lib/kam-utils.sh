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

    # 获取 kam_utils 目录
    # 优先使用 MODPATH，如果不存在则使用脚本自身路径
    _kam_load_kam_utils_dir=""
    if [ -n "${MODPATH:-}" ] && [ -d "${MODPATH}/lib/kam_utils" ]; then
        _kam_load_kam_utils_dir="${MODPATH}/lib/kam_utils"
    else
        # 获取当前脚本所在目录
        _kam_load_script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _kam_load_script_dir="$(pwd)"
        if [ -d "${_kam_load_script_dir}/kam_utils" ]; then
            _kam_load_kam_utils_dir="${_kam_load_script_dir}/kam_utils"
        elif [ -d "${_kam_load_script_dir}/lib/kam_utils" ]; then
            _kam_load_kam_utils_dir="${_kam_load_script_dir}/lib/kam_utils"
        else
            echo "错误: 无法找到 kam_utils 目录" >&2
            return 1
        fi
    fi

    # 设置全局变量供模块使用
    export _KAM_UTILS_DIR="${_kam_load_kam_utils_dir}"

    # 加载指定模块
    for module in "$@"; do
        # 检查是否已加载（防止重复加载）
        _kam_load_var_name="_KAM_MODULE_LOADED_$(echo "$module" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
        eval "_kam_load_is_loaded=\${${_kam_load_var_name}:-0}"
        if [ "$_kam_load_is_loaded" = "1" ]; then
            continue
        fi

        module_file="${_kam_load_kam_utils_dir}/${module}.sh"
        if [ -f "$module_file" ]; then
            . "$module_file" || {
                echo "加载模块失败: $module" >&2
                return 1
            }
            # 标记为已加载
            eval "${_kam_load_var_name}=1"
        else
            echo "模块不存在: $module (${module_file})" >&2
            return 1
        fi
    done
}

# Source internal implementation helper
# 用法: kam_source_impl <module>
# 示例: kam_source_impl navigation
kam_source_impl() {
    module="$1"
    _kam_utils_dir="${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}"
    impl_file="${_kam_utils_dir}/_${module}.sh"

    if [ -f "$impl_file" ]; then
        . "$impl_file" || { echo "错误: 无法加载内部实现: $impl_file" >&2; return 1; }
        return 0
    else
        echo "错误: 无法找到内部实现: $impl_file" >&2
        return 1
    fi
}

# =============================================================================
# 初始化函数
# =============================================================================

# 通用初始化
# 从 .kam 文件夹提取合适架构的二进制文件到对应目录
kam_init() {
    moddir="${MODPATH:-$(pwd)}"
    kam_dir="${moddir}/.kam"

    # 加载必需的基础模块
    # base 必须最先加载，因为其他模块依赖它
    kam_load base ui depends install detect || {
        echo "! Failed to load required modules" >&2
        return 1
    }

    # 检查 .kam 目录是否存在
    [ ! -d "$kam_dir" ] && return 0

    # 检测架构（使用检测模块）
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
    moddir="${MODPATH:-$(pwd)}"
    kam_dir="${moddir}/.kam"

    # 删除 .kam 目录
    [ -d "$kam_dir" ] && rm -rf "$kam_dir" 2>/dev/null
}

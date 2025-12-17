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

# 获取 kam-utils.sh 所在目录
_get_kam_utils_path() {
    # 检查是否设置了 KAM_UTILS_DIR 环境变量
    if [ -n "${KAM_UTILS_DIR:-}" ]; then
        echo "${KAM_UTILS_DIR%/*}"
    else
        # 使用 MODDIR 或当前目录
        echo "${MODDIR:-$(pwd)}/lib"
    fi
}

# 按需加载模块
# 用法: kam_load "模块名" [更多模块名...]
kam_load() {
    [ $# -eq 0 ] && {
        echo "请指定要加载的模块" >&2
        return 1
    }
    
    # 获取 kam_utils 目录
    local kam_utils_dir
    kam_utils_dir="$(_get_kam_utils_path)/kam_utils"
    
    # 加载指定模块
    for module in "$@"; do
        local module_file="${kam_utils_dir}/${module}.sh"
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
    local moddir="${MODDIR:-$(pwd)}"
    local kam_dir="${moddir}/.kam"
    
    # 检查 .kam 目录是否存在
    [ ! -d "$kam_dir" ] && return 0
    
    # 检测架构
    local arch="${ARCH:-}"
    [ -z "$arch" ] && {
        case "$(getprop ro.product.cpu.abi 2>/dev/null)" in
            arm64-v8a) arch="arm64" ;;
            armeabi-v7a|armeabi) arch="arm" ;;
            x86_64) arch="x64" ;;
            x86) arch="x86" ;;
            riscv64) arch="riscv64" ;;
            *) arch="unknown" ;;
        esac
    }
    
    # 复制对应架构的二进制文件
    if [ "$arch" != "unknown" ] && [ -f "${kam_dir}/${arch}" ]; then
        cp "${kam_dir}/${arch}" "${moddir}/system/bin/" 2>/dev/null || true
        chmod 755 "${moddir}/system/bin/$(basename "${kam_dir}/${arch}")" 2>/dev/null || true
    fi
    
    # 复制通用文件
    if [ -f "${kam_dir}/config.yaml" ]; then
        cp "${kam_dir}/config.yaml" "${moddir}/mihomo/" 2>/dev/null || true
    fi
}

# 通用结束函数
# 删除 .kam 文件夹
kam_end() {
    local moddir="${MODDIR:-$(pwd)}"
    local kam_dir="${moddir}/.kam"
    
    # 删除 .kam 目录
    [ -d "$kam_dir" ] && rm -rf "$kam_dir" 2>/dev/null
}

# =============================================================================
# 检查命令
# =============================================================================

# 检查命令
check() {
    local mode="text"
    [ "$1" = "--json" ] && mode="json"
    
    # 运行 shellcheck
    local kam_utils_path
    kam_utils_path="$(_get_kam_utils_path)"
    
    # 检查是否有错误
    if shellcheck "${kam_utils_path}/kam-utils.sh" 2>/dev/null | grep -q "error"; then
        if [ "$mode" = "json" ]; then
            echo '{"status":"error","message":"语法错误"}'
        else
            echo "发现语法错误"
        fi
        return 1
    else
        if [ "$mode" = "json" ]; then
            echo '{"status":"ok"}'
        else
            echo "检查通过，没有发现错误"
        fi
        return 0
    fi
}

# =============================================================================
# 兼容性别名
# =============================================================================

# 兼容旧版本
ui_print() {
    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$1"
    else
        echo "$1"
    fi
}

abort() {
    echo "错误: $1" >&2
    exit 1
}

# =============================================================================
# 自动执行初始化
# =============================================================================

# 如果不是被 source 加载，则自动初始化
if [ "${0##*/}" != "kam-utils.sh" ] || [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    kam_init
fi
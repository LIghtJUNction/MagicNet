#!/bin/sh
# shellcheck shell=ash
# kam_utils 模块按需加载器

# =============================================================================
# 内部模块自动加载
# =============================================================================

# 自动加载所有内部函数模块（_xxx.sh）
_load_internal_modules() {
    local kam_utils_dir="${KAM_UTILS_DIR:-}"
    
    # 如果未设置，尝试确定目录
    if [ -z "$kam_utils_dir" ]; then
        # 使用 $0 的路径
        kam_utils_dir="$(dirname "$0")"
        # 如果 $0 是相对路径，尝试使用当前目录
        [ "$kam_utils_dir" = "." ] && kam_utils_dir="$(pwd)"
    fi
    
    # 加载所有 _xxx.sh 文件（内部函数，非公开API）
    for internal_file in "${kam_utils_dir}"/_*.sh; do
        [ -f "$internal_file" ] || continue
        . "$internal_file"
    done
}

# 执行自动加载
_load_internal_modules

# =============================================================================
# 模块注册表
# =============================================================================

# 注册所有可用模块
KAM_MODULES=""

# 注册模块
# 用法: register_module "模块名" "描述"
register_module() {
    local module="$1"
    local desc="$2"
    eval "KAM_MODULE_DESC_${module}=\"${desc}\""
    KAM_MODULES="${KAM_MODULES} ${module}"
}

# =============================================================================
# 核心模块定义
# =============================================================================

# 基础工具模块
register_module "base" "基础工具函数：msg、err、rmrf等"

# 系统检测模块
register_module "detect" "系统检测：架构、Root类型、启动模式等"

# 属性操作模块
register_module "prop" "系统属性操作：prop、getprop、delprop等"

# 模块管理模块
register_module "module" "模块管理：desc、enable、disable等"

# 配置管理模块
register_module "config" "配置管理：config_get、config_set等"

# 网络应用模块
register_module "net" "网络应用：open_url、app、port等"

# 用户交互模块
register_module "ui" "用户交互：ask、choice、confirm等"

# 文件保护模块
register_module "protect" "文件保护：fprotect、funprotect等"

# 系统等待模块
register_module "wait" "系统等待：wait_boot、wait_unlock等"

# 应用库模块
register_module "app_lib" "应用库：get_app_lib等"

# 二进制处理模块
register_module "binary" "二进制处理：pre_bin、run_bin等"

# 清理函数模块
register_module "cleanup" "清理函数：install_done等"

# 版本检查模块
register_module "version" "版本检查：require_version等"

# i18n 国际化模块
register_module "i18n" "国际化：i18n、set_i18n等"

# Mihomo 网络管理模块
register_module "mihomo" "Mihomo 代理管理：create_tun、mihomo_run、mihomo_stop等"

# =============================================================================
# 自动发现并注册自定义拓展模块
# =============================================================================

# 自动扫描并注册 kam_utils 目录中的所有 .sh 文件（排除内部模块）
_discover_custom_modules() {
    local kam_utils_dir
    kam_utils_dir="$(dirname "${BASH_SOURCE[0]}")"
    
    # 扫描所有 .sh 文件（排除 _ 开头的内部文件）
    for module_file in "${kam_utils_dir}"/*.sh; do
        [ -f "$module_file" ] || continue
        
        # 获取文件名（不含路径和扩展名）
        local module_name
        module_name=$(basename "$module_file" .sh)
        
        # 跳过内部模块（_开头）和已注册的核心模块
        case "$module_name" in
            _*|base|detect|prop|module|config|net|ui|protect|wait|app_lib|binary|cleanup|version|i18n)
                continue
                ;;
        esac
        
        # 尝试从文件中提取模块描述
        local desc=""
        if [ -r "$module_file" ]; then
            # 查找文件开头的描述注释
            desc=$(head -n 10 "$module_file" | grep -E "^#.*模块.*：" | head -n 1 | sed 's/^#[[:space:]]*//')
            [ -z "$desc" ] && desc="自定义模块：${module_name}"
        fi
        
        # 注册模块
        register_module "$module_name" "$desc"
    done
}

# 执行自动发现
_discover_custom_modules
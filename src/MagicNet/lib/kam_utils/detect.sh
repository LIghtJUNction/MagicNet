#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 系统检测模块 - 公开API
# =============================================================================

# 加载内部模块
_kam_utils_dir="${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}"
# shellcheck source=_detect.sh
kam_source_impl detect || { echo "错误: 无法加载内部实现: ${_kam_utils_dir}/_detect.sh" >&2; return 1; }

# 检测系统架构
detect_arch() {
    _detect_arch_impl
}

# 检测 Root 管理器
detect_root_type() {
    _detect_root_type_impl
}

# 设置模块目录
setup_mod_dir() {
    _setup_mod_dir_impl
}

# 检测启动模式
detect_boot_mode() {
    _detect_boot_mode_impl
}

# 检查是否为 KernelSU
is_ksu() {
    _is_ksu
}

# 检查是否为 Magisk
is_magisk() {
    _is_magisk
}

# 检查是否为 APatch
is_apatch() {
    _is_apatch
}

# Root 管理器检测函数
ksu() { [ "$ROOT_TYPE" = "ksu" ]; }
magisk() { [ "$ROOT_TYPE" = "magisk" ]; }
apatch() { [ "$ROOT_TYPE" = "apatch" ]; }
nomagisk() { ! magisk; }

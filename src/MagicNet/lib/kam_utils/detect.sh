#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 系统检测模块 - 公开API
# =============================================================================

# 加载内部模块
_kam_utils_dir="$(dirname "${0}")"
# shellcheck source=_detect.sh
[ -f "${_kam_utils_dir}/_detect.sh" ] && . "${_kam_utils_dir}/_detect.sh"

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

# 检查是否为 KernelPatch
is_kernelpatch() {
    _is_kernelpatch
}

# Root 管理器检测函数
ksu() { [ "$ROOT_TYPE" = "ksu" ]; }
magisk() { [ "$ROOT_TYPE" = "magisk" ]; }
apatch() { [ "$ROOT_TYPE" = "apatch" ]; }
kpatch() { [ "$ROOT_TYPE" = "kernelpatch" ]; }
nomagisk() { ! magisk; }

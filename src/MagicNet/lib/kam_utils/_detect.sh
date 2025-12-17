#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 系统检测模块 - 内部函数（非公开API）
# =============================================================================

# 检测系统架构（内部实现）
_detect_arch_impl() {
    [ -n "$ARCH" ] && return 0
    
    local abi
    abi="$(getprop ro.product.cpu.abi)"
    
    case "$abi" in
        arm64-v8a)
            export ARCH="arm64"
            export ABI32="armeabi-v7a"
            export IS64BIT=true
            ;;
        armeabi-v7a)
            export ARCH="arm"
            export ABI32="armeabi-v7a"
            export IS64BIT=false
            ;;
        armeabi)
            export ARCH="arm"
            export ABI32="armeabi"
            export IS64BIT=false
            ;;
        x86_64)
            export ARCH="x64"
            export ABI32="x86"
            export IS64BIT=true
            ;;
        x86)
            export ARCH="x86"
            export ABI32="x86"
            export IS64BIT=false
            ;;
        riscv64)
            export ARCH="riscv64"
            export ABI32="riscv32"
            export IS64BIT=true
            ;;
        mips64)
            export ARCH="mips64"
            export ABI32="mips"
            export IS64BIT=true
            ;;
        mips)
            export ARCH="mips"
            export ABI32="mips"
            export IS64BIT=false
            ;;
        *)
            export ARCH="unknown"
            export ABI32="unknown"
            export IS64BIT=false
            ;;
    esac
    export ABI="$abi"
}

# 检测 Root 管理器（内部实现）
_detect_root_type_impl() {
    [ -n "$ROOT_TYPE" ] && return 0
    
    [ "$KSU" = "true" ] || [ -n "$KSU_VER" ] && export ROOT_TYPE="ksu"
    [ "$MAGISK_VER" != "" ] && [ "$BOOTMODE" = "true" ] && export ROOT_TYPE="magisk"
    [ "$APATCH" = "true" ] || [ -n "$APATCH_VER" ] && export ROOT_TYPE="apatch"
    [ "$KERNELPATCH" = "true" ] || [ -n "$KERNELPATCH_VERSION" ] && export ROOT_TYPE="kernelpatch"
    [ -z "$ROOT_TYPE" ] && export ROOT_TYPE="unknown"
}

# 设置模块目录（内部实现）
_setup_mod_dir_impl() {
    [ -n "$MOD_DIR" ] && return 0
    
    [ -n "$MODPATH" ] && export MOD_DIR="$MODPATH"
    [ -n "$KSU_MODULE" ] && export MOD_DIR="/data/adb/modules/$KSU_MODULE"
    [ -z "$MOD_DIR" ] && export MOD_DIR="/data/adb/modules/$(basename "$0")"
}

# 检测启动模式（内部实现）
_detect_boot_mode_impl() {
    [ -n "$BOOTMODE" ] && return 0
    
    pgrep zygote >/dev/null 2>&1 && export BOOTMODE=true || export BOOTMODE=false
}

# 检查是否为 KernelSU（内部使用）
_is_ksu() {
    [ "$ROOT_TYPE" = "ksu" ]
}

# 检查是否为 Magisk（内部使用）
_is_magisk() {
    [ "$ROOT_TYPE" = "magisk" ]
}

# 检查是否为 APatch（内部使用）
_is_apatch() {
    [ "$ROOT_TYPE" = "apatch" ]
}

# 检查是否为 KernelPatch（内部使用）
_is_kernelpatch() {
    [ "$ROOT_TYPE" = "kernelpatch" ]
}
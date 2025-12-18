# shellcheck shell=ash
# =============================================================================
# 系统检测模块 - 内部函数（非公开API）
# =============================================================================

# 检测系统架构（内部实现）
_detect_arch_impl() {
    [ -n "$ARCH" ] && return 0

    abi=""
    abi=$(getprop ro.product.cpu.abi)

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

    if [ "$KSU" = "true" ] || [ -n "$KSU_VER" ]; then
        export ROOT_TYPE="ksu"
    elif [ -n "$MAGISK_VER" ] && [ "$BOOTMODE" = "true" ]; then
        export ROOT_TYPE="magisk"
    elif [ "$APATCH" = "true" ] || [ -n "$APATCH_VER" ]; then
        export ROOT_TYPE="apatch"
    else
        export ROOT_TYPE="unknown"
    fi
}

# 设置模块目录（内部实现）
_setup_mod_dir_impl() {
    [ -n "$MOD_DIR" ] && return 0

    # 1) 优先使用安装环境提供的 MODPATH（Magisk / 部分安装器会设置）
    if [ -n "${MODPATH:-}" ]; then
        export MOD_DIR="${MODPATH}"
        return 0
    fi

    # 2) 如果外部显式提供了 MODDIR，使用它
    if [ -n "${MODDIR:-}" ]; then
        export MOD_DIR="${MODDIR}"
        return 0
    fi

    # 3) 如果 $0 看起来像路径（包含 '/'），尝试使用其父目录（并验证是否为模块）
    case "$0" in
        */*)
            if dir=$(cd "$(dirname -- "$0")" 2>/dev/null && pwd); then
                if [ -n "$dir" ] && [ -f "$dir/lib/kam-utils.sh" ] ; then
                    export MOD_DIR="$dir"
                    return 0
                fi
            fi
            ;;
    esac

    # 4) 从当前工作目录向上查找模块标志（lib/kam-utils.sh / kam.toml / module.prop）
    cur="$PWD"
    while [ -n "$cur" ] && [ "$cur" != "/" ]; do
        if [ -f "$cur/lib/kam-utils.sh" ] || [ -f "$cur/kam.toml" ] || [ -f "$cur/module.prop" ]; then
            export MOD_DIR="$cur"
            return 0
        fi
        cur=$(dirname -- "$cur")
    done

    # 5) 如果存在 KSU 模块名，则使用标准模块路径
    if [ -n "$KSU_MODULE" ]; then
        export MOD_DIR="/data/adb/modules/$KSU_MODULE"
        return 0
    fi

    # 6) 最后退回到基于脚本名的猜测（最后手段）
    export MOD_DIR="/data/adb/modules/$(basename "$0")"
}

# 检测启动模式（内部实现）
_detect_boot_mode_impl() {
    # magisk 由于可以从rec安装模块，这里可以为0.
    # 其余管理器永远是1
    [ -n "$BOOTMODE" ] && return 0

    if pgrep zygote >/dev/null 2>&1; then
        export BOOTMODE=true
    else
        export BOOTMODE=false
    fi
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

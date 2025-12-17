#!/bin/bash
set -e

# copy from https://github.com/KernelSU-Modules-Repo/meta-overlayfs/blob/main/build.sh

# license：GPL-3.0

# Detect build tool
# 检测并设置Rust交叉编译工具（cross/cargo-ndk）

detect_build_tool() {
    _detect_build_tool_BUILD_TOOL=""
    if command -v cross >/dev/null 2>&1; then
        _detect_build_tool_BUILD_TOOL="cross"
        echo "Using cross for compilation"
    else
        _detect_build_tool_BUILD_TOOL="cargo-ndk"
        echo "Using cargo ndk for compilation"
        if ! command -v cargo-ndk >/dev/null 2>&1; then
            echo "Error: Neither cross nor cargo-ndk found!" >&2
            echo "Please install one of them:" >&2
            echo "  - cross: cargo install cross" >&2
            echo "  - cargo-ndk: cargo install cargo-ndk" >&2
            return 1
        fi
    fi

    echo "${_detect_build_tool_BUILD_TOOL}"
    return 0
}

build_multi_arch() {
     _build_multi_arch_BUILD_TOOL=$1
     # 检查传入的工具是否有效
     if [ -z "${_build_multi_arch_BUILD_TOOL}" ]; then
         echo "Error: Build tool not specified!" >&2
         return 1
     fi
     # 编译aarch64架构
     echo ""
     echo "Building for aarch64-linux-android..."
     if [ "${_build_multi_arch_BUILD_TOOL}" = "cross" ]; then
         cross build --release --target aarch64-linux-android
     else
         cargo ndk build -t arm64-v8a --release
     fi
     # 编译x86_64架构
     echo ""
     echo "Building for x86_64-linux-android..."
     if [ "${_build_multi_arch_BUILD_TOOL}" = "cross" ]; then
         cross build --release --target x86_64-linux-android
     else
         cargo ndk build -t x86_64 --release
     fi
     return $?
 }

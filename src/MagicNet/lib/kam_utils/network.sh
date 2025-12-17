#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 网络工具模块 - 自定义拓展模块示例
# =============================================================================

# 检查网络连接
check_network() {
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        msg "网络连接正常"
        return 0
    else
        err "网络连接失败"
        return 1
    fi
}

# 获取本机IP地址
get_local_ip() {
    local ip
    ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    [ -n "$ip" ] && echo "$ip" || echo "未知"
}

# 下载文件
download_file() {
    local url="$1" output="$2"
    [ -z "$output" ] && output="$(basename "$url")"
    
    if cmd curl; then
        curl -L -o "$output" "$url"
    elif cmd wget; then
        wget -O "$output" "$url"
    else
        err "未找到下载工具（curl 或 wget）"
        return 1
    fi
}
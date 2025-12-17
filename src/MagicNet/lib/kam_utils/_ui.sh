#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 用户交互模块 - 内部函数（非公开API）
# =============================================================================

# 获取按键事件（内部实现）
_get_key_impl() {
    getevent -qlc 1 2>/dev/null | awk '$2=="EV_KEY" && $4=="DOWN" {print $3; exit}'
}

# 等待任意按键（内部实现）
_wait_key_any_impl() { 
    null _get_key_impl
}

# 等待上下键（内部实现）
_wait_key_up_down_impl() {
    local key
    while :; do
        key=$(_get_key_impl)
        case "$key" in
            KEY_VOLUMEUP|KEY_VOLUMEDOWN) 
                echo "$key" | sed 's/KEY_VOLUME//' | tr '[:upper:]' '[:lower:]'
                return 
                ;;
        esac
    done
}

# 等待上下键+电源键（内部实现）
_wait_key_up_down_power_impl() {
    local key
    while :; do
        key=$(_get_key_impl)
        case "$key" in
            KEY_VOLUMEUP|KEY_VOLUMEDOWN|KEY_POWER) 
                case "$key" in
                    KEY_VOLUMEUP) echo "up" ;;
                    KEY_VOLUMEDOWN) echo "down" ;;
                    KEY_POWER) echo "power" ;;
                esac
                return 
                ;;
        esac
    done
}

# 等待上键（内部实现）
_wait_key_up_impl() {
    local key
    while :; do
        key=$(_get_key_impl)
        [ "$key" = "KEY_VOLUMEUP" ] && return
    done
}

# 等待下键（内部实现）
_wait_key_down_impl() {
    local key
    while :; do
        key=$(_get_key_impl)
        [ "$key" = "KEY_VOLUMEDOWN" ] && return
    done
}

# 等待电源键（内部实现）
_wait_key_power_impl() {
    local key
    while :; do
        key=$(_get_key_impl)
        [ "$key" = "KEY_POWER" ] && return
    done
}

# 显示音量键提示（内部实现）
_show_volume_key_hint() {
    msg "$(i18n "volume_key_hint")"
}
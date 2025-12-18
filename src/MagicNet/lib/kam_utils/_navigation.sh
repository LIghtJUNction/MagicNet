#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 导航跳转模块 - 内部实现（私有函数，单下划线命名）
# =============================================================================

_run2null() {
    "$@" >/dev/null 2>&1
}

_open_url_impl() {
    [ -n "$1" ] || return
    _run2null am start -a android.intent.action.VIEW -d "$1"
}

_launch_app_impl() {
    [ -n "$1" ] || return
    _run2null am start "$1"
}

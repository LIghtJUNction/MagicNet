#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# Mihomo 模块 - 管理和运行 Mihomo 代理服务
# =============================================================================

# 加载内部模块
_kam_utils_dir="$(dirname "${0}")"
# shellcheck source=_mihomo.sh
[ -f "${_kam_utils_dir}/_mihomo.sh" ] && . "${_kam_utils_dir}/_mihomo.sh"

# 创建 TUN 设备
create_tun() {
    _create_tun_impl
}

# 运行 mihomo
mihomo_run() {
    _mihomo_run_impl
}

# 停止 mihomo
mihomo_stop() {
    _mihomo_stop_impl
}

# 重启 mihomo
mihomo_restart() {
    _mihomo_stop_impl
    sleep 1
    _mihomo_run_impl
}

# 检查 mihomo 状态
mihomo_status() {
    _mihomo_status_impl
}

# 切换前端界面
mihomo_toggle_ui() {
    _mihomo_toggle_ui_impl
}

# 设置模块描述
set_module_description() {
    _set_module_description_impl "$1"
}

# 日志记录
log() {
    _log_impl "$@"
}

# 格式化日期
formatted_date() {
    _formatted_date_impl
}

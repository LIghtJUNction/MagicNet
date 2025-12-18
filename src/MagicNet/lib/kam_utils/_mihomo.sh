#!/bin/sh
# shellcheck shell=ash

_get_mihomo_moddir() {
    if [ -n "$MODDIR" ]; then
        echo "$MODDIR"
    else
        _get_mihomo_moddir_dir=$(dirname "$0")
        _get_mihomo_moddir_dir=$(dirname "$_get_mihomo_moddir_dir")
        dirname "$_get_mihomo_moddir_dir"
    fi
}

_get_mihomo_logfile() {
    _get_mihomo_logfile_moddir=$(_get_mihomo_moddir)
    echo "${_get_mihomo_logfile_moddir}/MagicNet.log"
}

_create_tun_impl() {
    mkdir -p /dev/net
    log INFO "Create /dev/net directory"
    [ ! -L /dev/net/tun ] && ln -s /dev/tun /dev/net/tun
    log INFO "Create /dev/net/tun symlink"
    if [ ! -c "/dev/net/tun" ]; then
        log ERROR "Cannot create /dev/net/tun"
        log WARNING "System does not support TUN/TAP driver"
        exit 1
    fi
    log INFO "/dev/net/tun is character device, check passed"
}

_mihomo_run_impl() {
    _mihomo_run_impl_moddir=$(_get_mihomo_moddir)
    _mihomo_run_impl_mihomo_dir="${_mihomo_run_impl_moddir}/mihomo/"
    _mihomo_run_impl_mihomo_config="${_mihomo_run_impl_moddir}/mihomo/config.yaml"
    _mihomo_run_impl_mihomo="${_mihomo_run_impl_moddir}/system/bin/mihomo"
    _mihomo_run_impl_logfile=$(_get_mihomo_logfile)

    _mihomo_toggle_ui_impl

    log INFO "Starting mihomo"
    if [ -x "${_mihomo_run_impl_mihomo}" ]; then
        "${_mihomo_run_impl_mihomo}" -d "${_mihomo_run_impl_mihomo_dir}" -f "${_mihomo_run_impl_mihomo_config}" >> "${_mihomo_run_impl_logfile}" 2>&1 &
        set_module_description "mihomo started! $(date '+%Y-%m-%d %H:%M:%S')"
    else
        log ERROR "mihomo not found or not executable: ${_mihomo_run_impl_mihomo}"
        exit 1
    fi
}

_mihomo_stop_impl() {
    # Find all PIDs matching the mihomo process and kill them one by one to avoid
    # issues when pgrep returns multiple lines and to avoid relying on pkill/xargs.
    pids=$(pgrep -f mihomo 2>/dev/null || true)
    if [ -n "$pids" ]; then
        for pid in $pids; do
            # Ensure pid is numeric
            case "$pid" in
                ''|*[!0-9]*) continue ;;
            esac
            kill "$pid" 2>/dev/null || true
        done
        log INFO "mihomo stopped"
    else
        log INFO "mihomo not running"
    fi
}

_mihomo_status_impl() {
    if pgrep -f mihomo >/dev/null 2>&1; then
        echo "running"
    else
        echo "stopped"
    fi
}

_mihomo_toggle_ui_impl() {
    _mihomo_toggle_ui_impl_moddir=$(_get_mihomo_moddir)

    if [ -f "${_mihomo_toggle_ui_impl_moddir}/yacd" ]; then
        rm "${_mihomo_toggle_ui_impl_moddir}/yacd"
        msg "Switched to default frontend"
    else
        touch "${_mihomo_toggle_ui_impl_moddir}/yacd"
        msg "Switched to yacd frontend"
    fi
}

_set_module_description_impl() {
    _set_module_description_impl_description="$1"
    _set_module_description_impl_moddir=$(_get_mihomo_moddir)
    _set_module_description_impl_module_prop="${_set_module_description_impl_moddir}/module.prop"

    if command -v ksud >/dev/null 2>&1 && ksud module config set override.description "$_set_module_description_impl_description" >/dev/null 2>&1; then
        return 0
    fi

    if [ -f "${_set_module_description_impl_module_prop}" ]; then
        sed -i "s|^description=.*|description=$_set_module_description_impl_description|" "${_set_module_description_impl_module_prop}"
    fi
}

_log_impl() {
    _log_impl_logfile=$(_get_mihomo_logfile)
    _log_impl_old_logfile="$LOG_FILE"
    LOG_FILE="$_log_impl_logfile"
    log "$1" "$2"
    LOG_FILE="$_log_impl_old_logfile"
}

# 格式化日期实现（使用 base 模块的 fdate 函数）
_fdate_impl() {
    fdate
}

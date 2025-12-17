#!/bin/sh
# shellcheck shell=ash

_get_mihomo_moddir() {
    if [ -n "$MODDIR" ]; then
        echo "$MODDIR"
    else
        local dir
        dir=$(dirname "$0")
        dir=$(dirname "$dir")
        dirname "$dir"
    fi
}

_get_mihomo_logfile() {
    local moddir
    moddir=$(_get_mihomo_moddir)
    echo "${moddir}/MagicNet.log"
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
    local moddir
    moddir=$(_get_mihomo_moddir)
    local mihomo_dir="${moddir}/mihomo/"
    local mihomo_config="${moddir}/mihomo/config.yaml"
    local mihomo="${moddir}/system/bin/mihomo"
    local logfile
    logfile=$(_get_mihomo_logfile)
    
    if [ -f "$moddir/yacd" ]; then
        log INFO "Using yacd"
        sed -i 's|http://127.0.0.1:9090/ui/|https://yacd.haishan.me/|' "${moddir}/webroot/index.html" || log ERROR "Failed to replace URL"
    else
        log INFO "Using default frontend"
        sed -i 's|https://yacd.haishan.me/|http://127.0.0.1:9090/ui/|' "${moddir}/webroot/index.html" || log ERROR "Failed to replace URL"
    fi

    log INFO "Starting mihomo"
    if [ -x "${mihomo}" ]; then
        "${mihomo}" -d "${mihomo_dir}" -f "${mihomo_config}" >> "${logfile}" 2>&1 &
        set_module_description "mihomo started! $(date '+%Y-%m-%d %H:%M:%S')"
    else
        log ERROR "mihomo not found or not executable: ${mihomo}"
        exit 1
    fi
}

_mihomo_stop_impl() {
    if pgrep -f mihomo >/dev/null 2>&1; then
        kill "$(pgrep -f mihomo)" 2>/dev/null
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
    local moddir
    moddir=$(_get_mihomo_moddir)
    
    if [ -f "$moddir/yacd" ]; then
        rm "$moddir/yacd"
        msg "Switched to default frontend"
    else
        touch "$moddir/yacd"
        msg "Switched to yacd frontend"
    fi
}

_set_module_description_impl() {
    local description="$1"
    local moddir
    moddir=$(_get_mihomo_moddir)
    local module_prop="${moddir}/module.prop"
    
    if command -v ksud >/dev/null 2>&1 && ksud module config set override.description "$description" >/dev/null 2>&1; then
        return 0
    fi
    
    if [ -f "$module_prop" ]; then
        sed -i "s|^description=.*|description=$description|" "$module_prop"
    fi
}

_log_impl() {
    local logfile
    logfile=$(_get_mihomo_logfile)
    local old_logfile="$LOG_FILE"
    LOG_FILE="$logfile"
    log "$1" "$2"
    LOG_FILE="$old_logfile"
}

# 格式化日期实现（使用 base 模块的 fdate 函数）
_fdate_impl() {
    fdate
}
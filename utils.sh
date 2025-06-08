MODDIR=${0%/*}

LOG_FILE="${MODDIR}/MagicNet.log"
mihomo_dir="${MODDIR}/mihomo/"
mihomo_config="${MODDIR}/mihomo/config.yaml"
mihomo="/system/bin/mihomo"
MODULE_PROP="$MODDIR/module.prop"

normal="\033[0m" # No Color
orange="\033[1;38;5;208m"
red="\033[1;31m"
green="\033[1;32m"
yellow="\033[1;33m"
blue="\033[1;34m"

config_file="magicnet.yaml"

set_module_description(){
    local new_description="$1"
    sed -i "s/^description=.*/description=$(printf '%s' "${new_description//\//\\/}")/" "${MODULE_PROP}"
}

formatted_date() {
    date +"%Y-%m-%d %H:%M:%S.%3N"
}


log() {
    [ ! -f "${LOG_FILE}" ] && touch "${LOG_FILE}" && chmod 600 "${LOG_FILE}"
    case $1 in
        INFO) color="${blue}" ;;
        ERROR) color="${red}" ;;
        WARNING) color="${yellow}" ;;
        *) color="${green}" ;;
    esac
    current_time=$(formatted_date)
    message="${current_time} [$1]: $2"
    if [ -t 1 ]; then
        echo -e "${color}${message}${normal}"
    else
        echo "${message}" >> "${LOG_FILE}" 2>&1
    fi
}

create_tun() {
    mkdir -p /dev/net
    log INFO "创建/dev/net/目录"

    [ ! -L /dev/net/tun ] && ln -s /dev/tun /dev/net/tun
    log INFO "创建/dev/net/tun符号链接"
    
    if [ ! -c "/dev/net/tun" ]; then
        log ERROR "无法创建 /dev/net/tun，可能的原因："
        log WARNING "系统不支持 TUN/TAP 驱动或内核不兼容"
        exit 1
    fi
    log INFO "/dev/net/tun 为字符设备，检查通过"
}


mihomo_run() {
    if [ -x "${mihomo}" ]; then
        # 启动 mihomo 内核，并将日志记录到指定文件
        "${mihomo}" -d "${mihomo_dir}" -f "${mihomo_config}" >> "${LOG_FILE}" 2>&1 &
        set_module_description "mihomo启动!🛡️[内核启动时间🕓]-$(date '+%Y-%m-%d %H:%M:%S') [mihomo]-$(${mihomo} -v | tr -d '\n') 请注意查看日志!"
    else
        log ERROR "未找到或不可执行的 ${mihomo}"
        exit 1
    fi
}

sync_config() {
    # 执行同步脚本
    sh $MODDIR/sync_configs.sh || sleep 10 && sh $MODDIR/sync_configs.sh || log ERROR "同步配置文件失败!!!!" 

}
# 这个脚本将在 Android 系统启动完毕后以服务模式运行
#!/bin/sh
# boot-completed.sh
#
# 这个脚本会在 Android 系统完全启动并发送 ACTION_BOOT_COMPLETED 广播后执行。
# 它在 late_start 服务模式下运行，这意味着它与启动过程的其余部分并行操作。
#
# 用法:
# - 将此脚本放置在模块的目录中，以便在系统启动完成后自动执行。
# - 通过运行 `chmod +x boot-completed.sh` 确保脚本是可执行的。
#
# 环境变量:
# - MODDIR: 模块的基本目录路径。使用此变量引用模块的文件。
# - KSU: 表示脚本在 KernelSU 环境中运行。此值设置为 `true`。
#
# 示例:
# - 使用此脚本执行系统完全启动后需要执行的任务，例如启动服务或执行清理任务。
#
# 注意:
# - 避免使用可能阻塞或显著延迟启动过程的命令。
# - 确保此脚本启动的任何后台任务都得到妥善管理，以避免资源泄漏。
#
# 有关更多信息，请参阅 KernelSU 文档中的启动脚本部分。


# 注意这个sh文件是ksu新增的,因此不支持magisk(apu的系统模块功能借鉴的ksu)

MODDIR=${0%/*}
source $MODDIR/utils.sh # 导入工具函数

if [ -f $MODDIR/magisk ]; then
    echo "检测到 Magisk，等待系统开机完毕..."
    if [ -f $MODDIR/boot_completed.sh ]; then
        mv $MODDIR/boot_completed.sh $MODDIR/service.sh
    fi
    # 等待系统开机完毕
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 1
    done
fi

if [ -f $LOG_FILE ]; then
    echo > $LOG_FILE # 每次重启清空日志
fi



if [ -f yacd ]; then
    log INFO "使用yacd"
    # 使用 sed 替换 URL 链接
    sed -i 's|http://127.0.0.1:9090/ui/|https://yacd.haishan.me/|' ./webroot/index.html || log ERROR "替换 URL 链接失败。"
else
    log INFO "使用默认前端"
    sed -i 's|https://yacd.haishan.me/|http://127.0.0.1:9090/ui/|' ./webroot/index.html || log ERROR "替换 URL 链接失败。"
fi

log INFO "脚本执行完毕"

while true; do
    sleep 30
        # 读取配置文件中的 URL
    url=$(yq '.proxy-providers.myclash.url' 'clickme.yaml')

    # 检测 URL 是否可访问
    if curl --output /dev/null --silent --head --fail "$url"; then
        log INFO "链接有效"
        sync_config
        break
    else
        log ERROR "链接无效"
        log INFO "等待 30 秒后重试..."
        log INFO "请在clickme.yaml中修改url"
        sync_config
    fi
done

# 运行mihomo内核

create_tun
mihomo_run


exit 0
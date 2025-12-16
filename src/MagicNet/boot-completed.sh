# shellcheck shell=ash
# boot-completed.sh
#
# 🚨这是ksu新增的，开机后执行，常规做法是service.sh里面等待开机。
# This script runs when the Android system has finished booting.
# Specifically, it triggers when the "ACTION_BOOT_COMPLETED" broadcast is sent.
#
# ---------------------------------------------------------------------------------------
# EXECUTION CONTEXT
# ---------------------------------------------------------------------------------------
# - TRIGGER:      Runs when `sys.boot_completed` property becomes "1".
# - TIMING:       The UI is usually up (lock screen or launcher).
# - ENV:          Runs in KernelSU's BusyBox ash shell (Standalone Mode).
#                 $MODDIR is set to the module's directory.
#                 $KSU_MODULE is set to the module ID.
#
# ---------------------------------------------------------------------------------------
# USE CASES
# ---------------------------------------------------------------------------------------
# - Tasks that strictly require the Android framework/UI to be fully initialized.
# - Showing notifications or toasts (via `cmd notification` or similar).
# - Final cleanup tasks.
# - Interacting with system services that might not be ready during `service.sh`.
#
# ---------------------------------------------------------------------------------------

MODDIR=${0%/*}
source $MODPATH/utils.sh
[ -f "$MODPATH/lib/nga-utils.sh" ] && . "$MODPATH/lib/nga-utils.sh" || abort '! File "nga-utils.sh" does not exist!'

until_unlock 10

if [ -f $LOG_FILE ]; then
    echo > $LOG_FILE # 每次重启清空日志
fi


# 运行mihomo内核

create_tun
mihomo_run

exit 0




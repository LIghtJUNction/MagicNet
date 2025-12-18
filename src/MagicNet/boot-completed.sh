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
[ -f "$MODDIR/lib/kam-utils.sh" ] && . "$MODDIR/lib/kam-utils.sh" || abort '! File "kam-utils.sh" does not exist!'

# 按需加载
kam_load wait mihomo

wait_unlock 10

# 清空日志
LOG_FILE="${MODDIR}/MagicNet.log"
[ -f "$LOG_FILE" ] && echo > "$LOG_FILE"

$MODDIR/subscribe.sh

# 运行 mihomo 内核
create_tun
mihomo_run

exit 0




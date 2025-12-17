#!/system/bin/sh
# shellcheck shell=ash
#
# service.sh
#
# This script runs in the "late_start service" stage of the boot process.
#
# ---------------------------------------------------------------------------------------
# EXECUTION CONTEXT
# ---------------------------------------------------------------------------------------
# - NON-BLOCKING: Runs in parallel with the rest of the boot process.
# - TIMING:       Runs after the system is up and modules are mounted.
# - ENV:          Runs in KernelSU's BusyBox ash shell (Standalone Mode).
#                 $MODDIR is set to the module's directory.
#                 $KSU_MODULE is set to the module ID.
#
# ---------------------------------------------------------------------------------------
# USE CASES
# ---------------------------------------------------------------------------------------
# - Starting background daemons or services.
# - Running tasks that take a long time and shouldn't delay boot.
# - Operations that require the system to be fully initialized.
# - Waiting for specific system properties (like sys.boot_completed).
#
# ---------------------------------------------------------------------------------------

MODDIR=${0%/*}

# Example: Log execution
# echo "Executing service.sh for $KSU_MODULE" > /dev/kmsg

# Example: Wait for boot to complete
# until [ "$(getprop sys.boot_completed)" = "1" ]; do
#     sleep 1
# done

# Example: Start a background process
# nohup "$MODDIR/my_daemon" > /dev/null 2>&1 &

# Example: Apply settings that need to happen late
# resetprop my.late.prop value

[ -f "$MODDIR/lib/kam-utils.sh" ] && . "$MODDIR/lib/kam-utils.sh" || abort '! File "kam-utils.sh" does not exist!'

# 按需加载基础模块
kam_load base

# 注释掉避免与 boot-completed.sh 冲突
# kam_boot_completed $MODDIR
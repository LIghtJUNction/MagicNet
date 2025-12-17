# shellcheck shell=ash
# MagicNet customize.sh
#
# This script is sourced by the module installer script after all files are extracted
# and default permissions/secontext are applied.
#
# Useful for:
# - Checking device compatibility (ARCH, API)
# - Setting special permissions
# - Customizing installation based on user environment
#
# ---------------------------------------------------------------------------------------
# AVAILABLE VARIABLES
# ---------------------------------------------------------------------------------------
# (KernelSU-only) KSU (bool):           true if running in KernelSU environment
# (KernelSU-only) KSU_VER (string):     KernelSU version string (e.g. v0.9.5)
# (KernelSU-only) KSU_VER_CODE (int):   KernelSU version code (userspace)
# (KernelSU-only) KSU_KERNEL_VER_CODE (int): KernelSU version code (kernel space)
# NOTE: KernelSU variables are only provided by KernelSU (not guaranteed on stock Magisk).
# Guard usage example:
#    if [ "$KSU" = "true" ]; then
#        # KernelSU-only logic
#    else
#        # Fallback for Magisk/APatch or other environments
#    fi
#
# KernelPatch/KernelSU/APatch related variables
# (KernelPatch-only) KERNELPATCH (bool):   true if running in KernelPatch environment
# (KernelPatch-only) KERNEL_VERSION (hex): Kernel version inherited from KernelPatch (e.g. 50a01 -> 5.10.1)
# (KernelPatch-only) KERNELPATCH_VERSION (hex): KernelPatch version identifier (e.g. a05 -> 0.10.5)
# (KernelPatch-only) SUPERKEY (string):    Value provided by KernelPatch for invoking kpatch/supercall
# NOTE: The KernelPatch variables above are provided by KernelPatch and may NOT exist on a stock Magisk installation.
#       If your module must work on both, check for their presence before using them:
#         if [ -n "$KERNELPATCH" ] && [ "$KERNELPATCH" = "true" ]; then
#           # KernelPatch-specific handling
#         fi
#
# APatch related variables
# (APatch-only) APATCH (bool):        true if running in APatch environment
# (APatch-only) APATCH_VER_CODE (int): APatch current version code (e.g. 10672)
# (APatch-only) APATCH_VER (string):  APatch version string (e.g. "10672")
# NOTE: The APatch variables above are specific to APatch (a Magisk fork). They are NOT guaranteed to exist on stock Magisk.
#       Guard your scripts like:
#         if [ "$APATCH" = "true" ]; then
#           # APatch-specific logic
#         fi
#
# Common environment variables (present across environments)
# BOOTMODE (bool):      always true in KernelSU and APatch (recovery / boot mode)
# MODPATH (path):       Path where module files are installed (e.g. /data/adb/modules/MagicNet)
# TMPDIR (path):        Path to temporary directory
# ZIPFILE (path):       Path to the installation ZIP
# ARCH (string):        Device architecture: arm, arm64, x86, x64
# IS64BIT (bool):       true if ARCH is arm64 or x64
# API (int):            Android API level (e.g. 33 for Android 13)
#
# WARNING:
# - In APatch, MAGISK_VER_CODE is typically 27000 and MAGISK_VER is 27.0 (so some Magisk-related checks behave differently).
# - Many KernelPatch/APatch features are not present on stock Magisk. When writing portable installation code,
#   explicitly check for variable presence and provide sensible fallbacks:
#     if [ -n "$APATCH" ] && [ "$APATCH" = "true" ]; then
#         # APatch-only handling
#     else
#         # Stock Magisk fallback handling (or skip)
#     fi
#
# ---------------------------------------------------------------------------------------
# AVAILABLE FUNCTIONS
# ---------------------------------------------------------------------------------------
# ui_print <msg>
#     Print message to console. Avoid 'echo'.
#
# abort <msg>
#     Print error message and terminate installation.
#
# set_perm <target> <owner> <group> <permission> [context]
#     Set permissions for a file.
#     Default context: "u:object_r:system_file:s0"
#
# set_perm_recursive <dir> <owner> <group> <dirperm> <fileperm> [context]
#     Recursively set permissions for a directory.
#     Default context: "u:object_r:system_file:s0"
#
# ---------------------------------------------------------------------------------------
# KERNELSU FEATURES
# ---------------------------------------------------------------------------------------
#
# REMOVE (Whiteout):
# List directories/files to be "removed" from the system (overlaid with whiteout).
# KernelSU executes: mknod <TARGET> c 0 0
#
# REMOVE="
# /system/app/BloatwareApp
# /system/priv-app/AnotherApp
# "
#
# REPLACE (Opaque):
# List directories to be replaced by an empty directory (or your module's version).
# KernelSU executes: setfattr -n trusted.overlay.opaque -v y <TARGET>
#
# REPLACE="
# /system/app/YouTube
# "
#
# ---------------------------------------------------------------------------------------
# CUSTOM INSTALLATION LOGIC
# ---------------------------------------------------------------------------------------
# ---------------------------------------------------------------------------------
# Use KAM utils 👇
# -----------------------------------------------------------------------------------
[ -f "$MODPATH/lib/kam-utils.sh" ] && . "$MODPATH/lib/kam-utils.sh" || abort '! File "kam-utils.sh" does not exist!'

# 初始化 KAM 环境
kam_init

ui_print "- Checking version requirements..."
require_version "magisk:>=28000" "ksu:>=11986" --mode=abort --message="MagicNet Abort: version requirements not met!"

ui_print "- Installing MagicNet..."

# 设置项目特定的 i18n 文本
set_i18n "toggle_service" "zh" "停止或启动服务？" "en" "Stop or start service?" "ja" "サービスを停止または開始しますか？" "ko" "서비스를 중지하거나 시작하시겠습니까?"
set_i18n "toggle_yacd" "zh" "启用或禁用 yacd？（下次运行生效）" "en" "Enable or disable yacd? (Effective on next run)" "ja" "yacdを有効または無効にしますか？(次回の実行時に有効)" "ko" "yacd를 활성화 또는 비활성화하시겠습니까?(다음 실행 시 적용)"
set_i18n "use_yacd" "zh" "是否使用 yacd？" "en" "Use yacd or default?" "ja" "yacdを使用しますか？" "ko" "yacd를 사용하시겠습니까?"
set_i18n "give_star" "zh" "给个星星吧！" "en" "Give me a star!" "ja" "スターをくれ！" "ko" "별을 주세요!"
set_i18n "feed_star" "zh" "投喂星光" "en" "Feed star" "ja" "星を餌付け" "ko" "별에게 먹이를 주세요"
set_i18n "refuse" "zh" "残忍拒绝" "en" "Refuse" "ja" "拒否" "ko" "거절"

set_perm_recursive $MODPATH 0 0 0755 0755

ask "use_yacd" "enable" "default" \
    'touch $MODPATH/yacd' \
    'ui_print "default"'
newline


ask "give_star" "feed_star" "refuse" \
    'open_url "https://github.com/LIghtJUNction/MagicNet"' \
    'ui_print "All right"'
newline

# ---------------------------------------------------------------------------------
# 安装完成

# 如果在 Magisk 环境中，将 boot 脚本改名为 service（便于 Magisk 识别）
# 用法: boot2serviceif "magisk"
# Load compat module (provides compatibility helpers like boot2serviceif)
kam_load compat || ui_print "- Warning: failed to load compat module"

# 如果为 Magisk 环境，则用兼容模块把 boot 脚本转为 service 以兼容 Magisk
boot2serviceif "magisk"

# 清理并显示摘要信息
kam_end

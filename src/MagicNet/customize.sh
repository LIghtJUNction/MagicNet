# shellcheck shell=ash
# MagicNet customize.sh
#
# -----------------------------------------------------------------------------------

[ -f "${MODPATH}/lib/kamfw/.kamfwrc" ] && . "$MODPATH/lib/kamfw/.kamfwrc" || abort '! File ".kamfwrc" does not exist!'

import i18n
import lang
import rich

# customize menu entries
set_i18n "CUSTOMIZE_MENU" "zh" "模块设置" "en" "Module settings" "ja" "モジュール設定" "ko" "모듈 설정"
set_i18n "SERVICE_CONTROL" "zh" "服务控制" "en" "Service control" "ja" "サービス制御" "ko" "서비스 제어"
set_i18n "SUBSCRIPTION_CONFIG" "zh" "订阅链接配置" "en" "Subscription configuration" "ja" "サブスクリプション設定" "ko" "구독 설정"
set_i18n "CUSTOMIZE_EXIT" "zh" "退出" "en" "Exit" "ja" "終了" "ko" "종료"

# 询问用户是否使用 yacd（提供交互式选择：默认 / Yacd / 自定义 URL）
import __mihomo__

ask_webui

# 设置system/bin/mihomo - 700权限
set_perm "${MODPATH}/system/bin/mihomo" 0 0 0755 u:object_r:magisk_file:s0

# 设置.local/bin/yq - 700权限
set_perm "${MODPATH}/.local/bin/yq" 0 0 0755 u:object_r:magisk_file:s0

# 询问用户是否前往github/求star

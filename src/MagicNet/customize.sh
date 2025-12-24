# shellcheck shell=ash
# MagicNet customize.sh
#
# -----------------------------------------------------------------------------------

[ -f "${MODPATH}/lib/kamfw/.kamfwrc" ] && . "$MODPATH/lib/kamfw/.kamfwrc" || abort '! File ".kamfwrc" does not exist!'

import i18n
import lang
import rich
import launcher
select_lang

# 询问用户是否使用 yacd（提供交互式选择：默认 / Yacd / 自定义 URL）
import __mihomo__

ask_webui

# 设置system/bin/mihomo - 700权限
set_perm "${MODPATH}/system/bin/mihomo" 0 0 0755 u:object_r:magisk_file:s0

launch url "https://github.com/LIghtJUNction/MagicNet"

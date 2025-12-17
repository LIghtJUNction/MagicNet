# shellcheck shell=ash
MODDIR=${0%/*}
[ -f "$MODDIR/lib/kam-utils.sh" ] && . "$MODDIR/lib/kam-utils.sh" || abort '! File "kam-utils.sh" does not exist!'

# 按需加载模块
kam_load ui mihomo

ask "toggle_service" "stop" "start" \
    'mihomo_stop; set_module_description "[mihomo]:Stopped🚫"' \
    'if [ "$(mihomo_status)" = "running" ]; then ui_print "mihomo 正在运行中。"; else ui_print "mihomo 没有在运行。"; mihomo_run; fi'
newline

ask "toggle_yacd" "disable" "enable" \
    'mihomo_toggle_ui' \
    'mihomo_toggle_ui'
newline


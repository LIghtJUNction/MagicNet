# shellcheck shell=ash
MODDIR=${0%/*}
[ -f "$MODDIR/lib/nga-utils.sh" ] && . "$MODDIR/lib/nga-utils.sh" || abort '! File "nga-utils.sh" does not exist!'

source $MODDIR/utils.sh

print_lines "Stop or start? " "停止还是启动？"
print_lines "👆:stop" "👇:start"
if [ $(until_key_up_down) = "KEY_VOLUMEUP" ]; then
    kill $(pgrep -f mihomo)
    set_module_description "[mihomo]:Stopped🚫"
else
    ui_print "If it has already stopped, try starting it."
    if pgrep -f mihomo >/dev/null; then
        ui_print "mihomo 正在运行中。"
        
    else
        ui_print "mihomo 没有在运行。"
        mihomo_run
    fi
fi
newline

print_lines "Enable or disable yacd？" "启用还是禁用yacd？"
print_lines "Effective on next run" "下一次运行时生效"
print_lines "👆:enable" "👇:disable"
if [ $(until_key_up_down) = "KEY_VOLUMEUP" ]; then
    touch $MODDIR/yacd || ui_print "skip."
else
    rm $MODDIR/yacd || ui_print "yacd not found."
fi
newline


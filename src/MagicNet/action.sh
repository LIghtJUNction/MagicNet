# shellcheck shell=ash
MODDIR=${0%/*}
. "$MODDIR/lib/kam-utils.sh" || { printf '%s\n' '! File "kam-utils.sh" does not exist!' >&2; exit 1; }

kam_load ui mihomo

ask "toggle_service" "stop" "start" \
    'mihomo_stop; set_module_description "[mihomo]:Stopped🚫"' \
    'mihomo_run; set_module_description "[mihomo]:Running✅"'
newline

ask "toggle_yacd" "disable" "enable" \
    'mihomo_toggle_ui' \
    'mihomo_toggle_ui'
newline

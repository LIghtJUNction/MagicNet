# shellcheck shell=ash
MODDIR=${0%/*}
. "$MODDIR/lib/kam-utils.sh" || { printf '%s\n' '! File "kam-utils.sh" does not exist!' >&2; exit 1; }

kam_load ui mihomo

# i18n for action labels and feedback
set_i18n "toggle_service" "zh" "服务控制" "en" "Service control" "ja" "サービス制御" "ko" "서비스 제어"
set_i18n "stop" "zh" "停止" "en" "Stop" "ja" "停止" "ko" "중지"
set_i18n "start" "zh" "启动" "en" "Start" "ja" "起動" "ko" "시작"
set_i18n "toggle_yacd" "zh" "切换 Yacd 前端" "en" "Toggle Yacd UI" "ja" "Yacd UI 切替" "ko" "Yacd UI 전환"
set_i18n "disable" "zh" "禁用" "en" "Disable" "ja" "無効" "ko" "비활성화"
set_i18n "enable" "zh" "启用" "en" "Enable" "ja" "有効" "ko" "활성화"
set_i18n "mihomo_stopped" "zh" "mihomo 已停止 🚫" "en" "mihomo stopped 🚫" "ja" "mihomo 停止 🚫" "ko" "mihomo 중지 🚫"
set_i18n "mihomo_running" "zh" "mihomo 正在运行 ✅" "en" "mihomo running ✅" "ja" "mihomo 起動中 ✅" "ko" "mihomo 실행 중 ✅"
set_i18n "yacd_toggled" "zh" "已切换 Yacd 前端" "en" "Yacd UI toggled" "ja" "Yacd UI を切り替えました" "ko" "Yacd UI 전환됨"

ask "toggle_service" "stop" "start" \
    'mihomo_stop; set_module_description "$(i18n \"mihomo_stopped\")"' \
    'mihomo_run; set_module_description "$(i18n \"mihomo_running\")"'
newline

ask "toggle_yacd" "disable" "enable" \
    'mihomo_toggle_ui; msg "$(i18n \"yacd_toggled\")"' \
    'mihomo_toggle_ui; msg "$(i18n \"yacd_toggled\")"'
newline

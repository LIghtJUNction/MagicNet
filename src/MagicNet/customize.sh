# shellcheck shell=ash
# MagicNet customize.sh
#
# -----------------------------------------------------------------------------------

export SKIPUNZIP=1
if unzip -o "$ZIPFILE" "lib/kamfw/*" -d "$MODPATH" >&2 && [ -f "$MODPATH/lib/kamfw/.kamfwrc" ]; then
  . "$MODPATH/lib/kamfw/.kamfwrc"
else
  abort "! .kamfwrc missing"
fi

import __customize__

import i18n
import lang
if [ "${MAGICNET_NONINTERACTIVE:-0}" != "1" ]; then
  select_lang
fi

import rich

import this

# Usage & installation messages
set_i18n "INSTALL_TITLE" \
  "zh" "MagicNet 安装向导" \
  "en" "MagicNet Setup" \
  "ja" "MagicNet セットアップ" \
  "ko" "MagicNet 설치"

set_i18n "INSTALL_PROFILE" \
  "zh" "系统级 TUN 代理模块，内置 mihomo / sing-box 双内核与 Clash API 兼容 WebUI。" \
  "en" "System-level TUN proxy module with mihomo / sing-box cores and Clash API compatible WebUI." \
  "ja" "mihomo / sing-box コアと Clash API 互換 WebUI を備えたシステム TUN プロキシモジュールです。" \
  "ko" "mihomo / sing-box 코어와 Clash API 호환 WebUI를 포함한 시스템 TUN 프록시 모듈입니다."

set_i18n "INSTALL_ROW_PROFILE" \
  "zh" "模块定位" \
  "en" "Profile" \
  "ja" "概要" \
  "ko" "개요"

set_i18n "INSTALL_DEFAULTS" \
  "zh" "默认启用：sing-box、TUN 自动路由、热点转发修复、VPN 共存保护。" \
  "en" "Enabled by default: sing-box, TUN auto-route, hotspot forwarding fix, VPN coexistence protection." \
  "ja" "既定で有効: sing-box、TUN 自動ルート、ホットスポット転送修正、VPN 共存保護。" \
  "ko" "기본 활성화: sing-box, TUN 자동 라우팅, 핫스팟 포워딩 수정, VPN 공존 보호."

set_i18n "INSTALL_ROW_DEFAULTS" \
  "zh" "默认行为" \
  "en" "Defaults" \
  "ja" "既定動作" \
  "ko" "기본 동작"

set_i18n "INSTALL_CONFIG_TITLE" \
  "zh" "配置与下一步" \
  "en" "Configuration and Next Steps" \
  "ja" "設定と次の手順" \
  "ko" "설정 및 다음 단계"

set_i18n "INSTALL_CONFIG_PATHS" \
  "zh" "配置文件：
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json
mihomo:   /data/adb/modules/MagicNet/.config/mihomo/config.yaml" \
  "en" "Configuration files:
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json
mihomo:   /data/adb/modules/MagicNet/.config/mihomo/config.yaml" \
  "ja" "設定ファイル:
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json
mihomo:   /data/adb/modules/MagicNet/.config/mihomo/config.yaml" \
  "ko" "설정 파일:
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json
mihomo:   /data/adb/modules/MagicNet/.config/mihomo/config.yaml"

set_i18n "INSTALL_NEXT_STEPS" \
  "zh" "安装后操作：
1. 写入订阅链接或 outbound 节点。
2. 重启设备，或在模块操作页启动内核。
3. 打开模块 WebUI 的“内核面板”，或在终端执行 cli api ui 查看当前核心入口。
mihomo 默认: http://127.0.0.1:9090/ui/cubex/
sing-box 默认: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "en" "After installation:
1. Add a subscription URL or outbound nodes.
2. Reboot, or start the core from the module action page.
3. Open Kernel Panel in the module WebUI, or run cli api ui to print the current core entry.
mihomo default: http://127.0.0.1:9090/ui/cubex/
sing-box default: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "ja" "インストール後:
1. 購読 URL または outbound ノードを追加します。
2. 再起動するか、モジュール操作画面からコアを起動します。
3. モジュール WebUI の Kernel Panel を開くか、cli api ui で現在のコア入口を確認します。
mihomo 既定: http://127.0.0.1:9090/ui/cubex/
sing-box 既定: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "ko" "설치 후:
1. 구독 URL 또는 outbound 노드를 추가하세요.
2. 재부팅하거나 모듈 작업 화면에서 코어를 시작하세요.
3. 모듈 WebUI의 Kernel Panel을 열거나 cli api ui로 현재 코어 진입점을 확인하세요.
mihomo 기본값: http://127.0.0.1:9090/ui/cubex/
sing-box 기본값: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090"

set_i18n "INSTALL_FLAGS" \
  "zh" "可选开关：
MAGIC_HOTSPOT_FORWARD=0 关闭热点转发修复
MAGIC_VPN_COEXIST=0 关闭 VPN 共存保护
MAGIC_SINGBOX=0 / MAGIC_MIHOMO=0 禁用指定内核" \
  "en" "Optional switches:
MAGIC_HOTSPOT_FORWARD=0 disables hotspot forwarding fix
MAGIC_VPN_COEXIST=0 disables VPN coexistence protection
MAGIC_SINGBOX=0 / MAGIC_MIHOMO=0 disables a selected core" \
  "ja" "任意スイッチ:
MAGIC_HOTSPOT_FORWARD=0 でホットスポット転送修正を無効化
MAGIC_VPN_COEXIST=0 で VPN 共存保護を無効化
MAGIC_SINGBOX=0 / MAGIC_MIHOMO=0 で指定コアを無効化" \
  "ko" "선택 스위치:
MAGIC_HOTSPOT_FORWARD=0 핫스팟 포워딩 수정 비활성화
MAGIC_VPN_COEXIST=0 VPN 공존 보호 비활성화
MAGIC_SINGBOX=0 / MAGIC_MIHOMO=0 선택한 코어 비활성화"

set_i18n "TERM_INSTALL_MSG" \
  "zh" "当前为终端安装：会显示完整交互菜单和状态信息。" \
  "en" "Terminal install detected: full interactive menus and status output are available." \
  "ja" "端末インストールを検出しました。完全な対話メニューと状態表示を利用できます。" \
  "ko" "터미널 설치가 감지되었습니다. 전체 대화형 메뉴와 상태 출력을 사용할 수 있습니다."

set_i18n "GUI_INSTALL_MSG" \
  "zh" "当前为管理器安装：若交互显示异常，可改用终端安装同一个 zip。" \
  "en" "Manager install detected: if interaction looks broken, install the same zip from a terminal." \
  "ja" "管理アプリでのインストールを検出しました。表示が崩れる場合は同じ zip を端末からインストールしてください。" \
  "ko" "관리자 설치가 감지되었습니다. 상호작용 표시가 이상하면 같은 zip을 터미널에서 설치하세요."

set_i18n "HOTSPOT_FORWARD_MSG" \
  "zh" "热点转发修复已启用：热点设备可跟随 MagicNet TUN 出口转发。" \
  "en" "Hotspot forwarding fix is enabled: tethered devices can route through the MagicNet TUN outlet." \
  "ja" "ホットスポット転送修正が有効です。接続端末は MagicNet TUN 経由で転送できます。" \
  "ko" "핫스팟 포워딩 수정이 활성화되었습니다. 연결된 기기는 MagicNet TUN 출구로 라우팅될 수 있습니다."

set_i18n "VPN_COEXIST_MSG" \
  "zh" "VPN 共存保护已启用：尽量避免 Tailscale、WireGuard 等外部 VPN 被 MagicNet 回环。" \
  "en" "VPN coexistence protection is enabled: MagicNet avoids looping external VPNs such as Tailscale or WireGuard." \
  "ja" "VPN 共存保護が有効です。Tailscale や WireGuard などの外部 VPN のループを回避します。" \
  "ko" "VPN 공존 보호가 활성화되었습니다. Tailscale, WireGuard 같은 외부 VPN 루프를 피합니다."

set_i18n "SET_MODULE_ENTRY_PERMS" \
  "zh" "设置模块入口脚本权限" \
  "en" "Setting permissions for module entry scripts" \
  "ja" "モジュール入口スクリプトの権限を設定しています" \
  "ko" "모듈 진입 스크립트 권한 설정 중"

set_i18n "DISABLE_SINGBOX_ON_INSTALL" \
  "zh" "选择默认代理内核" \
  "en" "Choose the default proxy core" \
  "ja" "既定のプロキシコアを選択" \
  "ko" "기본 프록시 코어 선택"

set_i18n "USE_SINGBOX_CORE" \
  "zh" "使用 sing-box（推荐）" \
  "en" "Use sing-box (recommended)" \
  "ja" "sing-box を使用（推奨）" \
  "ko" "sing-box 사용(권장)"

set_i18n "DISABLE_SINGBOX_CORE" \
  "zh" "禁用 sing-box，改用 mihomo" \
  "en" "Disable sing-box and use mihomo" \
  "ja" "sing-box を無効化し mihomo を使用" \
  "ko" "sing-box 비활성화 후 mihomo 사용"

set_i18n "KEEP_SINGBOX_FILES" \
  "zh" "禁用 sing-box 后如何处理文件？" \
  "en" "What should happen to sing-box files after disabling it?" \
  "ja" "sing-box 無効化後のファイル処理" \
  "ko" "sing-box 비활성화 후 파일 처리"

set_i18n "KEEP_SINGBOX_FILES_OPTION" \
  "zh" "保留文件，之后可快速恢复" \
  "en" "Keep files for quick re-enable later" \
  "ja" "後で再有効化できるようファイルを保持" \
  "ko" "나중에 빠르게 다시 활성화할 수 있도록 파일 유지"

set_i18n "REMOVE_SINGBOX_FILES_OPTION" \
  "zh" "移除文件，节省空间" \
  "en" "Remove files to save space" \
  "ja" "容量節約のためファイルを削除" \
  "ko" "공간 절약을 위해 파일 제거"

set_i18n "SINGBOX_DISABLED_KEEP" \
  "zh" "sing-box 已禁用，文件已保留。删除 .disable_sing_box 可重新启用。" \
  "en" "sing-box is disabled and files were kept. Remove .disable_sing_box to enable it again." \
  "ja" "sing-box は無効化され、ファイルは保持されました。.disable_sing_box を削除すると再有効化できます。" \
  "ko" "sing-box가 비활성화되었고 파일은 유지되었습니다. .disable_sing_box를 삭제하면 다시 활성화됩니다."

set_i18n "SINGBOX_DISABLED_REMOVE" \
  "zh" "已禁用 sing-box，并移除 sing-box 内核文件。" \
  "en" "sing-box is disabled and its core files were removed." \
  "ja" "sing-box は無効化され、コアファイルは削除されました。" \
  "ko" "sing-box가 비활성화되었고 코어 파일이 제거되었습니다."

magicnet_disable_singbox_keep() {
  touch "${MODPATH}/.disable_sing_box"
  print "$(i18n "SINGBOX_DISABLED_KEEP")"
}

magicnet_disable_singbox_remove() {
  touch "${MODPATH}/.disable_sing_box"
  rm -f "${MODPATH}/system/bin/sing-box" "${MODPATH}/.local/bin/sing-box" 2>/dev/null || true
  print "$(i18n "SINGBOX_DISABLED_REMOVE")"
}

magicnet_enable_singbox() {
  rm -f "${MODPATH}/.disable_sing_box" 2>/dev/null || true
}

magicnet_ask_disable_singbox() {
  [ "${MAGIC_SINGBOX:-1}" != "0" ] || return 0
  [ -x "${MODPATH}/system/bin/sing-box" ] || [ -x "${MODPATH}/.local/bin/sing-box" ] || return 0

  ask "DISABLE_SINGBOX_ON_INSTALL" \
    "USE_SINGBOX_CORE" \
    'magicnet_enable_singbox' \
    "DISABLE_SINGBOX_CORE" \
    'ask "KEEP_SINGBOX_FILES" "KEEP_SINGBOX_FILES_OPTION" "magicnet_disable_singbox_keep" "REMOVE_SINGBOX_FILES_OPTION" "magicnet_disable_singbox_remove" 0' \
    0
}

magicnet_print_install_summary() {
  panel "$(i18n "INSTALL_TITLE")"
  panel_row "$(i18n "INSTALL_ROW_PROFILE")" "$(i18n "INSTALL_PROFILE")"
  panel_row "$(i18n "INSTALL_ROW_DEFAULTS")" "$(i18n "INSTALL_DEFAULTS")"
  panel_note "$(i18n "HOTSPOT_FORWARD_MSG")"
  panel_note "$(i18n "VPN_COEXIST_MSG")"
  panel_end

  panel "$(i18n "INSTALL_CONFIG_TITLE")"
  panel_note "$(i18n "INSTALL_CONFIG_PATHS")"
  panel_note "$(i18n "INSTALL_NEXT_STEPS")"
  panel_note "$(i18n "INSTALL_FLAGS")"
  tprint "$(i18n "TERM_INSTALL_MSG")"
  gprint "$(i18n "GUI_INSTALL_MSG")"
  panel_end
}

magicnet_print_install_summary

MAGIC_MIHOMO=${MAGIC_MIHOMO:-1}
MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}

if [ "${MAGICNET_NONINTERACTIVE:-0}" = "1" ]; then
  :
else
  magicnet_ask_disable_singbox
fi

if [ "${MAGICNET_NONINTERACTIVE:-0}" = "1" ]; then
  :
elif [ "$MAGIC_SINGBOX" != "0" ] && [ ! -f "${MODPATH}/.disable_sing_box" ] && [ -x "${MODPATH}/system/bin/sing-box" ]; then
  import __singbox__
  singbox_ask_webui
elif [ "$MAGIC_MIHOMO" != "0" ] && [ -x "${MODPATH}/system/bin/mihomo" ]; then
  import __mihomo__
  ask_webui
fi

# 设置权限
[ -f "${MODPATH}/system/bin/mihomo" ] && set_perm "${MODPATH}/system/bin/mihomo" 0 0 0700 u:object_r:magisk_file:s0
[ -f "${MODPATH}/system/bin/sing-box" ] && set_perm "${MODPATH}/system/bin/sing-box" 0 0 0700 u:object_r:magisk_file:s0

[ -f "${MODPATH}/.local/bin/mihomo" ] && set_perm "${MODPATH}/.local/bin/mihomo" 0 0 0700 u:object_r:magisk_file:s0
[ -f "${MODPATH}/.local/bin/sing-box" ] && set_perm "${MODPATH}/.local/bin/sing-box" 0 0 0700 u:object_r:magisk_file:s0
[ -f "${MODPATH}/.local/bin/magicnet-cli" ] && set_perm "${MODPATH}/.local/bin/magicnet-cli" 0 0 0700 u:object_r:magisk_file:s0
[ -f "${MODPATH}/.local/bin/magicnet-mcp-server" ] && set_perm "${MODPATH}/.local/bin/magicnet-mcp-server" 0 0 0700 u:object_r:magisk_file:s0

rm -f "${MODPATH}/cli" 2>/dev/null || true
ln -s ".local/bin/magicnet-cli" "${MODPATH}/cli" 2>/dev/null || true

info "$(i18n "SET_MODULE_ENTRY_PERMS")"
for _magicnet_entry in cli.legacy.sh action.sh service.sh boot-completed.sh uninstall.sh hotspot-forward.sh vpn-coexist.sh; do
  [ -f "${MODPATH}/${_magicnet_entry}" ] || continue
  set_perm "${MODPATH}/${_magicnet_entry}" 0 0 0700 u:object_r:magisk_file:s0
done
unset _magicnet_entry

if [ "${MAGICNET_NONINTERACTIVE:-0}" != "1" ]; then
  [ -f "${MODPATH}/.config/mihomo/config.yaml" ] && confirm_update_file ".config/mihomo/config.yaml"
  [ -f "${MODPATH}/.config/sing-box/config.json" ] && confirm_update_file ".config/sing-box/config.json"
fi

import launcher
launch url "https://github.com/LIghtJUNction/MagicNet"

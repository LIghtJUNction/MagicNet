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

MAGICNET_PREV_DIR="${MAGICNET_PREV_DIR:-/data/adb/modules/MagicNet}"
MAGICNET_BACKUP_DIR="${MAGICNET_BACKUP_DIR:-${TMPDIR:-/dev/tmp}/magicnet-install-backup}"
if [ -d "$MAGICNET_PREV_DIR" ] && [ "$MAGICNET_PREV_DIR" != "$MODPATH" ]; then
  rm -rf "$MAGICNET_BACKUP_DIR" 2>/dev/null || true
  mkdir -p "$MAGICNET_BACKUP_DIR"
  for _item in \
    ".config/sing-box/subscription.url" \
    ".config/sing-box/subscription-1.yaml" \
    ".config/sing-box/.subscription-work" \
    ".config/mihomo/subscription.url" \
    ".config/mihomo/proxies" \
    ".config/magicnet"; do
    if [ -e "${MAGICNET_PREV_DIR}/${_item}" ]; then
      mkdir -p "${MAGICNET_BACKUP_DIR}/${_item%/*}"
      cp -a "${MAGICNET_PREV_DIR}/${_item}" "${MAGICNET_BACKUP_DIR}/${_item}" 2>/dev/null || true
    fi
  done
  unset _item
fi

# Usage & installation messages
set_i18n "INSTALL_TITLE" \
  "zh" "MagicNet 安装向导" \
  "en" "MagicNet Setup" \
  "ja" "MagicNet セットアップ" \
  "ko" "MagicNet 설치"

set_i18n "INSTALL_PROFILE" \
  "zh" "系统级戒网瘾模块，内置 mihomo / sing-box 双内核、域名封锁、TUN/TProxy 与 Clash API 兼容 WebUI。" \
  "en" "System-level digital detox module with mihomo / sing-box cores, domain blocking, TUN/TProxy, and Clash API compatible WebUI." \
  "ja" "mihomo / sing-box コア、ドメインブロック、TUN/TProxy、Clash API 互換 WebUI を備えたシステム級デジタルデトックスモジュールです。" \
  "ko" "mihomo / sing-box 코어, 도메인 차단, TUN/TProxy, Clash API 호환 WebUI를 포함한 시스템 수준 디지털 디톡스 모듈입니다."

set_i18n "INSTALL_ROW_PROFILE" \
  "zh" "模块定位" \
  "en" "Profile" \
  "ja" "概要" \
  "ko" "개요"

set_i18n "INSTALL_DEFAULTS" \
  "zh" "默认启用：sing-box、TUN 自动路由、戒网瘾封锁列表、热点转发修复、VPN 共存保护。" \
  "en" "Enabled by default: sing-box, TUN auto-route, detox blocklist, hotspot forwarding fix, VPN coexistence protection." \
  "ja" "既定で有効: sing-box、TUN 自動ルート、デトックスブロックリスト、ホットスポット転送修正、VPN 共存保護。" \
  "ko" "기본 활성화: sing-box, TUN 자동 라우팅, 디지털 디톡스 차단 목록, 핫스팟 포워딩 수정, VPN 공존 보호."

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
1. 执行 cli setup <合法订阅链接>，会同时初始化 sing-box 和 mihomo premium_a。
2. 重启设备，或在模块操作页启动内核。
3. 若只配置 mihomo，请执行 cli sub set mihomo premium_a <合法订阅链接> 后再启动 mihomo。
4. 打开模块 WebUI 的内核面板，或在终端执行 cli api ui 查看当前核心入口。
5. 把想戒掉的网站、规则组或域名指向 REJECT / block。
mihomo 默认: https://metacubex.github.io/metacubexd/#/setup?hostname=127.0.0.1&port=9090&secret=
sing-box 默认: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "en" "After installation:
1. Run cli setup <legal-subscription-url>; it initializes sing-box and mihomo premium_a together.
2. Reboot, or start the core from the module action page.
3. For mihomo-only setup, run cli sub set mihomo premium_a <legal-subscription-url> before starting mihomo.
4. Open Kernel Panel in the module WebUI, or run cli api ui to print the current core entry.
5. Point distracting sites, groups, or domains to REJECT / block.
mihomo default: https://metacubex.github.io/metacubexd/#/setup?hostname=127.0.0.1&port=9090&secret=
sing-box default: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "ja" "インストール後:
1. cli setup <合法な購読 URL> を実行します。sing-box と mihomo premium_a を同時に初期化します。
2. 再起動するか、モジュール操作画面からコアを起動します。
3. mihomo のみ設定する場合は、起動前に cli sub set mihomo premium_a <合法な購読 URL> を実行します。
4. モジュール WebUI の Kernel Panel を開くか、cli api ui で現在のコア入口を確認します。
5. 見たくないサイト、グループ、ドメインを REJECT / block に向けます。
mihomo 既定: https://metacubex.github.io/metacubexd/#/setup?hostname=127.0.0.1&port=9090&secret=
sing-box 既定: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "ko" "설치 후:
1. cli setup <합법 구독 URL>을 실행하세요. sing-box와 mihomo premium_a를 함께 초기화합니다.
2. 재부팅하거나 모듈 작업 화면에서 코어를 시작하세요.
3. mihomo만 설정하려면 시작 전에 cli sub set mihomo premium_a <합법 구독 URL>을 실행하세요.
4. 모듈 WebUI의 Kernel Panel을 열거나 cli api ui로 현재 코어 진입점을 확인하세요.
5. 끊고 싶은 사이트, 그룹, 도메인을 REJECT / block으로 지정하세요.
mihomo 기본값: https://metacubex.github.io/metacubexd/#/setup?hostname=127.0.0.1&port=9090&secret=
sing-box 기본값: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090"

set_i18n "INSTALL_FLAGS" \
  "zh" "可选开关：
MAGIC_HOTSPOT_FORWARD=0 关闭热点转发修复
MAGIC_VPN_COEXIST=0 关闭 VPN 共存保护
MAGIC_SINGBOX=0 / MAGIC_MIHOMO=0 禁用指定核心" \
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

set_i18n "DEFAULT_CORE_ON_INSTALL" \
  "zh" "选择默认代理核心" \
  "en" "Choose the default proxy core" \
  "ja" "既定のプロキシコアを選択" \
  "ko" "기본 프록시 코어 선택"

set_i18n "USE_SINGBOX_CORE" \
  "zh" "使用 sing-box（推荐）" \
  "en" "Use sing-box (recommended)" \
  "ja" "sing-box を使用（推奨）" \
  "ko" "sing-box 사용(권장)"

set_i18n "USE_MIHOMO_CORE" \
  "zh" "使用 mihomo" \
  "en" "Use mihomo" \
  "ja" "mihomo を使用" \
  "ko" "mihomo 사용"

magicnet_set_default_core() {
  case "$1" in
    sing-box|mihomo) ;;
    *) return 1 ;;
  esac
  mkdir -p "${MODPATH}/.config/magicnet" || return 1
  printf 'MAGICNET_DEFAULT_CORE=%s\n' "$1" >"${MODPATH}/.config/magicnet/current-core.conf"
}

magicnet_ask_default_core() {
  [ "${MAGIC_SINGBOX:-1}" != "0" ] || [ "${MAGIC_MIHOMO:-1}" != "0" ] || return 0

  ask "DEFAULT_CORE_ON_INSTALL" \
    "USE_SINGBOX_CORE" \
    'magicnet_set_default_core sing-box' \
    "USE_MIHOMO_CORE" \
    'magicnet_set_default_core mihomo' \
    0
}

magicnet_install_selected_core() {
  _magicnet_install_core="auto"
  if [ -f "${MODPATH}/.config/magicnet/current-core.conf" ]; then
    . "${MODPATH}/.config/magicnet/current-core.conf"
  elif [ -f "${MODPATH}/.config/magicnet/core.conf" ]; then
    . "${MODPATH}/.config/magicnet/core.conf"
  fi
  case "${MAGICNET_DEFAULT_CORE:-auto}" in
    sing-box|mihomo) _magicnet_install_core="$MAGICNET_DEFAULT_CORE" ;;
  esac

  if [ "$_magicnet_install_core" = "sing-box" ] && [ "$MAGIC_SINGBOX" != "0" ] && { [ -x "${MODPATH}/bin/sing-box" ] || [ -x "${MODPATH}/system/bin/sing-box" ]; }; then
    printf '%s\n' sing-box
  elif [ "$_magicnet_install_core" = "mihomo" ] && [ "$MAGIC_MIHOMO" != "0" ] && { [ -x "${MODPATH}/bin/mihomo" ] || [ -x "${MODPATH}/system/bin/mihomo" ]; }; then
    printf '%s\n' mihomo
  elif [ "$MAGIC_SINGBOX" != "0" ] && { [ -x "${MODPATH}/bin/sing-box" ] || [ -x "${MODPATH}/system/bin/sing-box" ]; }; then
    printf '%s\n' sing-box
  elif [ "$MAGIC_MIHOMO" != "0" ] && { [ -x "${MODPATH}/bin/mihomo" ] || [ -x "${MODPATH}/system/bin/mihomo" ]; }; then
    printf '%s\n' mihomo
  fi
  unset _magicnet_install_core
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
  magicnet_ask_default_core
fi

if [ -d "$MAGICNET_BACKUP_DIR" ]; then
  for _item in \
    ".config/sing-box/subscription.url" \
    ".config/sing-box/subscription-1.yaml" \
    ".config/sing-box/.subscription-work" \
    ".config/mihomo/subscription.url" \
    ".config/mihomo/proxies" \
    ".config/magicnet"; do
    if [ -e "${MAGICNET_BACKUP_DIR}/${_item}" ]; then
      mkdir -p "${MODPATH}/${_item%/*}"
      rm -rf "${MODPATH:?}/${_item}" 2>/dev/null || true
      cp -a "${MAGICNET_BACKUP_DIR}/${_item}" "${MODPATH}/${_item}" 2>/dev/null || true
    fi
  done
  rm -rf "$MAGICNET_BACKUP_DIR" 2>/dev/null || true
  unset _item
fi

if [ "${MAGICNET_NONINTERACTIVE:-0}" = "1" ]; then
  :
else
  case "$(magicnet_install_selected_core)" in
    sing-box)
      import __singbox__
      singbox_ask_webui
      ;;
    mihomo)
      import __mihomo__
      ask_webui
      ;;
  esac
fi

# 设置权限
rm -f "${MODPATH}/kam.log" "${MODPATH}/cli.legacy.sh" "${MODPATH}/mcp-server.sh" 2>/dev/null || true

[ -f "${MODPATH}/system/bin/mihomo" ] && set_perm "${MODPATH}/system/bin/mihomo" 0 0 0755 u:object_r:system_file:s0
[ -f "${MODPATH}/system/bin/sing-box" ] && set_perm "${MODPATH}/system/bin/sing-box" 0 0 0755 u:object_r:system_file:s0

[ -d "${MODPATH}/bin" ] && set_perm_recursive "${MODPATH}/bin" 0 0 0755 0755 u:object_r:system_file:s0
[ -d "${MODPATH}/webroot" ] && set_perm_recursive "${MODPATH}/webroot" 0 0 0755 0644 u:object_r:system_file:s0

rm -f "${MODPATH}/cli" 2>/dev/null || true
ln -s "bin/magicnet-cli" "${MODPATH}/cli" 2>/dev/null || true

info "$(i18n "SET_MODULE_ENTRY_PERMS")"
for _magicnet_entry in action.sh post-fs-data.sh service.sh boot-completed.sh uninstall.sh; do
  [ -f "${MODPATH}/${_magicnet_entry}" ] || continue
  set_perm "${MODPATH}/${_magicnet_entry}" 0 0 0755 u:object_r:system_file:s0
done
unset _magicnet_entry

if [ "${MAGICNET_NONINTERACTIVE:-0}" != "1" ]; then
  [ -f "${MODPATH}/.config/mihomo/config.yaml" ] && confirm_update_file ".config/mihomo/config.yaml"
  [ -f "${MODPATH}/.config/sing-box/config.json" ] && confirm_update_file ".config/sing-box/config.json"
fi

import launcher
launch url "https://github.com/LIghtJUNction/MagicNet"

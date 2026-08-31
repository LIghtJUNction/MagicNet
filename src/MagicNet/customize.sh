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

magicnet_install_is_interactive() {
  [ "${MAGICNET_NONINTERACTIVE:-0}" != "1" ] && [ "${IS_TTY:-false}" = "true" ]
}

if magicnet_install_is_interactive; then
  select_lang
fi

import rich

import this

MAGICNET_PREV_DIR="${MAGICNET_PREV_DIR:-/data/adb/modules/MagicNet}"
# Keep migration data in a private, per-installer sibling directory. Never
# accept a caller-selected deletion path: module-manager environments are not a
# trust boundary, and this directory temporarily contains subscription secrets.
MAGICNET_BACKUP_DIR="${MODPATH}.install-backup.$$"
MAGICNET_BACKUP_MARKER=".magicnet-install-backup-v1"
MAGICNET_BACKUP_ACTIVE=0
MAGICNET_BACKUP_READY=0

magicnet_install_backup_marker_valid() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  _magicnet_backup_marker=""
  _magicnet_backup_extra=""
  {
    IFS= read -r _magicnet_backup_marker || return 1
    if IFS= read -r _magicnet_backup_extra || [ -n "$_magicnet_backup_extra" ]; then
      return 1
    fi
  } <"$1"
  [ "$_magicnet_backup_marker" = "magicnet-install-backup-v1" ]
}

magicnet_cleanup_install_backup() {
  [ "${MAGICNET_BACKUP_ACTIVE:-0}" = 1 ] || return 0
  if [ -d "$MAGICNET_BACKUP_DIR" ] && [ ! -L "$MAGICNET_BACKUP_DIR" ] &&
    magicnet_install_backup_marker_valid "$MAGICNET_BACKUP_DIR/$MAGICNET_BACKUP_MARKER"; then
    # cp -a preserves directory modes. Make only this validated, active backup's
    # directories traversable/removable; find's default physical walk does not
    # follow symlinks, and regular files do not need permission changes for rm.
    find "$MAGICNET_BACKUP_DIR" -type d -exec chmod u+rwx '{}' \; || return 1
    # Revalidate after the permission walk before deleting the sibling path.
    [ -d "$MAGICNET_BACKUP_DIR" ] && [ ! -L "$MAGICNET_BACKUP_DIR" ] &&
      magicnet_install_backup_marker_valid "$MAGICNET_BACKUP_DIR/$MAGICNET_BACKUP_MARKER" || return 1
    rm -rf "$MAGICNET_BACKUP_DIR" || return 1
  else
    return 1
  fi
  MAGICNET_BACKUP_ACTIVE=0
  MAGICNET_BACKUP_READY=0
}

# A SIGKILL cannot run EXIT handlers. Remove only prior MagicNet-owned sibling
# directories bearing the exact marker; never restore them into a later run.
for _stale_backup in "${MODPATH}.install-backup."*; do
  [ -e "$_stale_backup" ] || [ -L "$_stale_backup" ] || continue
  case "$_stale_backup" in
  "${MODPATH}.install-backup."*[!0-9]*) continue ;;
  esac
  if [ -d "$_stale_backup" ] && [ ! -L "$_stale_backup" ] &&
    magicnet_install_backup_marker_valid "$_stale_backup/$MAGICNET_BACKUP_MARKER"; then
    rm -rf "$_stale_backup" || abort "! failed to remove stale MagicNet migration data"
  fi
done
unset _stale_backup

at_exit_register_trap
at_exit_add 'magicnet_cleanup_install_backup'

if [ -d "$MAGICNET_PREV_DIR" ]; then
  if [ -e "$MAGICNET_BACKUP_DIR" ] || [ -L "$MAGICNET_BACKUP_DIR" ]; then
    abort "! MagicNet migration backup path already exists"
  fi
  (
    umask 077
    mkdir "$MAGICNET_BACKUP_DIR" &&
      printf '%s\n' 'magicnet-install-backup-v1' >"$MAGICNET_BACKUP_DIR/$MAGICNET_BACKUP_MARKER"
  ) || abort "! failed to create the MagicNet migration backup"
  MAGICNET_BACKUP_ACTIVE=1
  for _item in \
    ".config/sing-box/subscription.url" \
    ".config/sing-box/subscription.local" \
    ".config/sing-box/subscription.user-agent" \
    ".config/sing-box/subscription-filter.list" \
    ".config/sing-box/subscription-1.yaml" \
    ".state/sing-box/subscription-work" \
    ".state/sing-box/selector-selections.json" \
    ".config/magicnet"; do
    if [ -L "${MAGICNET_PREV_DIR}/${_item}" ]; then
      abort "! refusing unsafe symlink in MagicNet migration data: $_item"
    fi
    if [ -e "${MAGICNET_PREV_DIR}/${_item}" ]; then
      mkdir -p "${MAGICNET_BACKUP_DIR}/${_item%/*}" || abort "! failed to prepare MagicNet migration data: $_item"
      cp -a "${MAGICNET_PREV_DIR}/${_item}" "${MAGICNET_BACKUP_DIR}/${_item}" || abort "! failed to back up MagicNet migration data: $_item"
    fi
  done
  MAGICNET_BACKUP_READY=1
  unset _item
fi

# Usage & installation messages
set_i18n "INSTALL_TITLE" \
  "zh" "MagicNet 安装向导" \
  "en" "MagicNet Setup" \
  "ja" "MagicNet セットアップ" \
  "ko" "MagicNet 설치"

set_i18n "INSTALL_PROFILE" \
  "zh" "系统级戒网瘾模块，内置 sing-box、域名封锁、TUN/eBPF 透明治理与 WebUI 控制面。" \
  "en" "System-level digital detox module with sing-box, domain blocking, explicit TUN/eBPF transparent routing, and WebUI control surfaces." \
  "ja" "sing-box、ドメインブロック、TUN/eBPF 透過制御、WebUI 制御面を備えたシステム級デジタルデトックスモジュールです。" \
  "ko" "sing-box, 도메인 차단, TUN/eBPF 투명 제어, WebUI 제어면을 포함한 시스템 수준 디지털 디톡스 모듈입니다."

set_i18n "INSTALL_ROW_PROFILE" \
  "zh" "模块定位" \
  "en" "Profile" \
  "ja" "概要" \
  "ko" "개요"

set_i18n "INSTALL_DEFAULTS" \
  "zh" "默认启用：sing-box、TUN 自动路由、戒网瘾封锁列表、WebUI 与 CLI 控制面；可显式切换 eBPF。" \
  "en" "Enabled by default: sing-box, TUN auto-route, detox blocklist, WebUI and CLI control surfaces; eBPF is an explicit opt-in." \
  "ja" "既定で有効: sing-box、TUN 自動ルート、デジタルデトックスブロックリスト、WebUI と CLI 制御面。eBPF は明示的に切り替えます。" \
  "ko" "기본 활성화: sing-box, TUN 자동 라우팅, 디지털 디톡스 차단 목록, WebUI 및 CLI 제어면. eBPF는 명시적으로 전환합니다."

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
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json" \
  "en" "Configuration files:
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json" \
  "ja" "設定ファイル:
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json" \
  "ko" "설정 파일:
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json"

set_i18n "INSTALL_NEXT_STEPS" \
  "zh" "安装后操作：
1. 执行 cli setup <合法订阅链接> 初始化 sing-box 订阅。
2. 重启设备，或在模块操作页启动内核。
3. 打开模块 WebUI 的内核面板，或在终端执行 cli api ui 查看当前核心入口。
4. 把想戒掉的网站、规则组或域名指向 REJECT / block。
sing-box 默认: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "en" "After installation:
1. Run cli setup <legal-subscription-url> to initialize the sing-box subscription.
2. Reboot, or start the core from the module action page.
3. Open Kernel Panel in the module WebUI, or run cli api ui to print the current core entry.
4. Point distracting sites, groups, or domains to REJECT / block.
sing-box default: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "ja" "インストール後:
1. cli setup <合法な購読 URL> を実行して sing-box 購読を初期化します。
2. 再起動するか、モジュール操作画面からコアを起動します。
3. モジュール WebUI の Kernel Panel を開くか、cli api ui で現在のコア入口を確認します。
4. 見たくないサイト、グループ、ドメインを REJECT / block に向けます。
sing-box 既定: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "ko" "설치 후:
1. cli setup <합법 구독 URL>로 sing-box 구독을 초기화하세요.
2. 재부팅하거나 모듈 작업 화면에서 코어를 시작하세요.
3. 모듈 WebUI의 Kernel Panel을 열거나 cli api ui로 현재 코어 진입점을 확인하세요.
4. 끊고 싶은 사이트, 그룹, 도메인을 REJECT / block으로 지정하세요.
sing-box 기본값: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090"

set_i18n "INSTALL_FLAGS" \
  "zh" "可选开关：
MAGIC_SINGBOX=0 禁用 sing-box 内核" \
  "en" "Optional switches:
MAGIC_SINGBOX=0 disables the sing-box core" \
  "ja" "任意スイッチ:
MAGIC_SINGBOX=0 で sing-box コアを無効化" \
  "ko" "선택 스위치:
MAGIC_SINGBOX=0 sing-box 코어 비활성화"

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

set_i18n "SET_MODULE_ENTRY_PERMS" \
  "zh" "设置模块入口脚本权限" \
  "en" "Setting permissions for module entry scripts" \
  "ja" "モジュール入口スクリプトの権限を設定しています" \
  "ko" "모듈 진입 스크립트 권한 설정 중"

magicnet_set_default_core() {
  case "$1" in
  sing-box) ;;
  *) return 1 ;;
  esac
  mkdir -p "${MODPATH}/.config/magicnet" || return 1
  printf 'MAGICNET_DEFAULT_CORE=%s\n' "$1" >"${MODPATH}/.config/magicnet/current-core.conf"
}

magicnet_ask_default_core() {
  magicnet_set_default_core sing-box
}

magicnet_install_selected_core() {
  if [ "$MAGIC_SINGBOX" != "0" ] &&
    { [ -x "${MODPATH}/bin/sing-box" ] || [ -x "${MODPATH}/system/bin/sing-box" ]; }; then
    printf '%s\n' sing-box
  fi
}

magicnet_print_install_summary() {
  panel "$(i18n "INSTALL_TITLE")"
  panel_row "$(i18n "INSTALL_ROW_PROFILE")" "$(i18n "INSTALL_PROFILE")"
  panel_row "$(i18n "INSTALL_ROW_DEFAULTS")" "$(i18n "INSTALL_DEFAULTS")"
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

MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}

magicnet_seed_subscription_filters() {
  _magicnet_filter_file="${MODPATH}/.config/sing-box/subscription-filter.list"
  [ -e "$_magicnet_filter_file" ] || {
    mkdir -p "${_magicnet_filter_file%/*}" || return 1
    printf '%s\n' "免费" "free" "HK" "香港" "TW" "台湾" >"$_magicnet_filter_file"
  }
  unset _magicnet_filter_file
}

magicnet_seed_subscription_filters || abort "! failed to initialize subscription filters"

if ! magicnet_install_is_interactive; then
  :
else
  magicnet_ask_default_core
fi

if [ "$MAGICNET_BACKUP_READY" = 1 ]; then
  for _item in \
    ".config/sing-box/subscription.url" \
    ".config/sing-box/subscription.local" \
    ".config/sing-box/subscription.user-agent" \
    ".config/sing-box/subscription-filter.list" \
    ".config/sing-box/subscription-1.yaml" \
    ".state/sing-box/subscription-work" \
    ".state/sing-box/selector-selections.json" \
    ".config/magicnet"; do
    if [ -e "${MAGICNET_BACKUP_DIR}/${_item}" ]; then
      mkdir -p "${MODPATH}/${_item%/*}" || abort "! failed to prepare restored MagicNet migration data: $_item"
      rm -rf "${MODPATH:?}/${_item}" || abort "! failed to replace MagicNet migration data: $_item"
      cp -a "${MAGICNET_BACKUP_DIR}/${_item}" "${MODPATH}/${_item}" || abort "! failed to restore MagicNet migration data: $_item"
    fi
  done
  magicnet_cleanup_install_backup || abort "! failed to remove the MagicNet migration backup"
  unset _item
fi

# Older releases shipped a domestic-app bypass catalog.  Keep only packages that
# are still Android VPN services during the one-time migration; ordinary app
# opt-outs can be added again explicitly after the migration completes.
magicnet_migrate_legacy_app_bypass() {
  _bypass_dir="${MODPATH}/.config/magicnet"
  _bypass_file="${_bypass_dir}/app-bypass.list"
  _migration_marker="${_bypass_dir}/app-policy-migration-vpn-only"
  [ -f "$_migration_marker" ] || [ -f "$_bypass_file" ] || return 0
  [ -f "$_migration_marker" ] && return 0
  command -v cmd >/dev/null 2>&1 || return 0

  _migration_state_dir="${MODPATH}/.state/app-policy"
  _vpn_packages="${_migration_state_dir}/vpn-packages.$$"
  _filtered_bypass="${_bypass_file}.migration.$$"
  mkdir -p "$_migration_state_dir" || return 1
  cmd package query-services --brief -a android.net.VpnService 2>/dev/null |
    sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_.]*\)\/.*/\1/p' >"$_vpn_packages"
  if [ ! -s "$_vpn_packages" ]; then
    rm -f "$_vpn_packages" 2>/dev/null || true
    unset _bypass_dir _bypass_file _migration_marker _migration_state_dir _vpn_packages _filtered_bypass
    return 0
  fi

  if [ -f "$_bypass_file" ]; then
    : >"$_filtered_bypass" || return 1
    while IFS= read -r _bypass_line || [ -n "$_bypass_line" ]; do
      _bypass_package=$(printf '%s\n' "$_bypass_line" |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      if [ -z "$_bypass_package" ] || [ "${_bypass_package#\#}" != "$_bypass_package" ] ||
        grep -Fqx "$_bypass_package" "$_vpn_packages"; then
        printf '%s\n' "$_bypass_line" >>"$_filtered_bypass" || {
          rm -f "$_filtered_bypass" "$_vpn_packages" 2>/dev/null || true
          unset _bypass_dir _bypass_file _migration_marker _migration_state_dir _vpn_packages _filtered_bypass
          unset _bypass_line _bypass_package
          return 1
        }
      fi
    done <"$_bypass_file"
    if [ ! -f "$_filtered_bypass" ]; then
      rm -f "$_filtered_bypass" "$_vpn_packages" 2>/dev/null || true
      unset _bypass_dir _bypass_file _migration_marker _migration_state_dir _vpn_packages _filtered_bypass
      unset _bypass_line _bypass_package
      return 1
    fi
    if ! cp -f "$_filtered_bypass" "$_bypass_file"; then
      rm -f "$_filtered_bypass" "$_vpn_packages" 2>/dev/null || true
      unset _bypass_dir _bypass_file _migration_marker _migration_state_dir _vpn_packages _filtered_bypass
      unset _bypass_line _bypass_package
      return 1
    fi
    rm -f "$_filtered_bypass" 2>/dev/null || true
  fi

  printf '%s\n' 'vpn-only bypass migration completed' >"$_migration_marker"
  rm -f "$_vpn_packages" 2>/dev/null || true
  unset _bypass_dir _bypass_file _migration_marker _migration_state_dir _vpn_packages _filtered_bypass
  unset _bypass_line _bypass_package
}

magicnet_migrate_legacy_app_bypass || abort "! failed to migrate legacy app bypass policy"

magicnet_prune_legacy_capture_residue() {
  rm -rf \
    "${MODPATH}/.config/magicnet/capture.conf" \
    "${MODPATH}/.config/magicnet/capture" \
    "${MODPATH}/.config/magicnet/capture.d" \
    "${MODPATH}/system/etc/security/cacerts" \
    "${MODPATH}/post-fs-data.sh" \
    "${MODPATH}/sepolice.rule" \
    "${MODPATH}/lib/magicnet/capture_common.sh" \
    "${MODPATH}/lib/magicnet/capture_mihomo.sh" \
    "${MODPATH}/lib/magicnet/capture_singbox.sh" \
    2>/dev/null || true
}

magicnet_prune_legacy_capture_residue
magicnet_set_default_core sing-box

# Set permissions.
rm -f "${MODPATH}/kam.log" "${MODPATH}/cli.legacy.sh" "${MODPATH}/mcp-server.sh" 2>/dev/null || true

[ -f "${MODPATH}/system/bin/sing-box" ] && set_perm "${MODPATH}/system/bin/sing-box" 0 0 0755 u:object_r:system_file:s0

[ -d "${MODPATH}/bin" ] && set_perm_recursive "${MODPATH}/bin" 0 0 0755 0755 u:object_r:system_file:s0
[ -d "${MODPATH}/webroot" ] && set_perm_recursive "${MODPATH}/webroot" 0 0 0755 0644 u:object_r:system_file:s0

# sing-box configs contain subscription credentials and node secrets.  Atomic
# runtime writers enforce this too, but set the permission before the first
# boot so a packaged or restored config never starts world-readable.
if [ -f "${MODPATH}/.config/sing-box/config.json" ]; then
  chmod 600 "${MODPATH}/.config/sing-box/config.json" || abort "! failed to protect sing-box config"
fi

rm -f "${MODPATH}/cli" 2>/dev/null || true
ln -s "bin/magicnet-cli" "${MODPATH}/cli" 2>/dev/null || true

info "$(i18n "SET_MODULE_ENTRY_PERMS")"
for _magicnet_entry in action.sh service.sh boot-completed.sh; do
  [ -f "${MODPATH}/${_magicnet_entry}" ] || continue
  set_perm "${MODPATH}/${_magicnet_entry}" 0 0 0755 u:object_r:system_file:s0
done
unset _magicnet_entry

if magicnet_install_is_interactive; then
  [ -f "${MODPATH}/.config/sing-box/config.json" ] && confirm_update_file ".config/sing-box/config.json"
fi

import launcher
launch url "https://github.com/LIghtJUNction/MagicNet/blob/main/src/MagicNet/README.md"

# shellcheck shell=ash
# MagicNet customize.sh
#
# -----------------------------------------------------------------------------------

export SKIPUNZIP=1
for _magicnet_binary_path in "$MODPATH/bin" "$MODPATH/bin/jq" "$MODPATH/bin/sing-box"; do
  [ ! -L "$_magicnet_binary_path" ] || abort "! unsafe installer binary path"
done
unset _magicnet_binary_path
# KernelSU/Magisk may point MODPATH at an empty `modules_update` directory
# while SKIPUNZIP is set. Extract every install-time helper before migration;
# the upgrade path sources install_config.sh and its subscription dependencies
# before the manager has copied the rest of the payload.
if unzip -o "$ZIPFILE" \
  ".config/kamfw/.envrc" \
  "lib/kamfw/*" "lib/kamfw-web/*" "lib/magicnet/*" \
  "lib/magicnet_singbox_subscribe.sh" -d "$MODPATH" >&2 &&
  [ -f "$MODPATH/lib/kamfw/.kamfwrc" ]; then
  for _magicnet_log_path in "$MODPATH" "$MODPATH/.log" "$MODPATH/.log/kam.log"; do
    [ ! -L "$_magicnet_log_path" ] || abort "! unsafe installer log path"
  done
  (umask 077; mkdir -p "$MODPATH/.log" && : >>"$MODPATH/.log/kam.log") ||
    abort "! failed to prepare MagicNet install log"
  chmod 600 "$MODPATH/.log/kam.log" || abort "! failed to protect MagicNet install log"
  # Prefer an open log so EXIT handlers can finish after the manager removes
  # a failed staging tree. Preserve every inherited FD, including recovery's
  # arbitrary OUTFD; if none is free, retain normal module-local file logging.
  KAM_LOGFILE="$MODPATH/.log/kam.log"
  for _magicnet_log_fd in 9 8 7 6 5 4 3; do
    [ "$_magicnet_log_fd" != "${OUTFD:-}" ] || continue
    if [ -e "/proc/self/fd/$_magicnet_log_fd" ] || [ -L "/proc/self/fd/$_magicnet_log_fd" ]; then
      continue
    fi
    # The descriptor comes only from the numeric list; the path stays quoted.
    eval "exec ${_magicnet_log_fd}>>\"\$MODPATH/.log/kam.log\"" ||
      abort "! failed to open MagicNet install log"
    KAM_LOGFILE="/proc/self/fd/$_magicnet_log_fd"
    break
  done
  export KAM_LOGFILE
  unset _magicnet_log_path _magicnet_log_fd
  . "$MODPATH/lib/kamfw/.kamfwrc"
else
  abort "! .kamfwrc missing"
fi

import __customize__

import i18n
import lang
. "$MODPATH/lib/magicnet/i18n.sh"
import rich

magicnet_install_is_interactive() {
  [ "${MAGICNET_NONINTERACTIVE:-0}" != "1" ] && [ "${IS_TTY:-false}" = "true" ]
}

if magicnet_install_is_interactive; then
  magicnet_select_lang
fi

MAGICNET_PREV_DIR="${MAGICNET_PREV_DIR:-/data/adb/modules/MagicNet}"
# Keep migration data in the private module directory. Never
# accept a caller-selected deletion path: module-manager environments are not a
# trust boundary, and this directory temporarily contains subscription secrets.
MAGICNET_BACKUP_DIR="${MODPATH}/.install-backup.$$"
MAGICNET_BACKUP_MARKER=".magicnet-install-backup-v1"
MAGICNET_BACKUP_MARKER_VALUE="magicnet-install-backup-v1"
MAGICNET_BACKUP_ACTIVE=0
MAGICNET_BACKUP_READY=0

# One allowlist drives both snapshot and restore. Add new migration state here
# so a successful upgrade cannot silently omit it from the restore phase.
MAGICNET_INSTALL_MIGRATION_ITEMS='.config/sing-box/config.json
.config/sing-box/subscription.url
.config/sing-box/subscription.local
.config/sing-box/subscription.user-agent
.config/sing-box/standalone-config
.config/sing-box/subscription-filter.list
.config/sing-box/subscription-1.yaml
.state/sing-box/subscription-work
.state/sing-box/selector-selections.json
.state/transparent-mode
.state/network-access-recovery
.config/magicnet'
# The old full config supplies user nodes and a private rollback copy only.
# install_config.sh rebuilds and validates the active file from the new template.
MAGICNET_INSTALL_BACKUP_ONLY_ITEM='.config/sing-box/config.json'

magicnet_install_backup_marker_is_exact() (
  _magicnet_marker_dir="$1"
  _magicnet_marker_file="$_magicnet_marker_dir/$MAGICNET_BACKUP_MARKER"
  [ -d "$_magicnet_marker_dir" ] && [ ! -L "$_magicnet_marker_dir" ] &&
    [ -f "$_magicnet_marker_file" ] && [ ! -L "$_magicnet_marker_file" ] || exit 1
  exec 3<"$_magicnet_marker_file" || exit 1
  _magicnet_marker_first=
  IFS= read -r _magicnet_marker_first <&3 || exit 1
  [ "$_magicnet_marker_first" = "$MAGICNET_BACKUP_MARKER_VALUE" ] || exit 1
  _magicnet_marker_extra=
  if IFS= read -r _magicnet_marker_extra <&3; then
    exit 1
  fi
  [ -z "$_magicnet_marker_extra" ]
)

magicnet_prepare_install_backup_removal() {
  magicnet_install_backup_marker_is_exact "$1" || return 1
  # cp -a preserves directory modes. Make only this validated backup's
  # directories traversable/removable; find's default physical walk does not
  # follow symlinks, and regular files do not need permission changes for rm.
  find "$1" -type d -exec chmod u+rwx '{}' \; || return 1
  # Revalidate after the permission walk before deleting the backup.
  magicnet_install_backup_marker_is_exact "$1"
}

magicnet_cleanup_install_backup() {
  [ "${MAGICNET_BACKUP_ACTIVE:-0}" = 1 ] || return 0
  # A failed install's manager may already have removed the entire module.
  if [ ! -e "$MAGICNET_BACKUP_DIR" ] && [ ! -L "$MAGICNET_BACKUP_DIR" ]; then
    MAGICNET_BACKUP_ACTIVE=0
    MAGICNET_BACKUP_READY=0
    return 0
  fi
  magicnet_prepare_install_backup_removal "$MAGICNET_BACKUP_DIR" || return 1
  rm -rf "$MAGICNET_BACKUP_DIR" || return 1
  MAGICNET_BACKUP_ACTIVE=0
  MAGICNET_BACKUP_READY=0
}

# A SIGKILL cannot run EXIT handlers. Remove only prior MagicNet-owned
# directories bearing the exact marker; never restore them into a later run.
for _stale_backup in "${MODPATH}/.install-backup."*; do
  [ -e "$_stale_backup" ] || [ -L "$_stale_backup" ] || continue
  case "$_stale_backup" in
  "${MODPATH}/.install-backup."*[!0-9]*) continue ;;
  esac
  _stale_owner=${_stale_backup##*.}
  # kill can fail with permission denied even when the owner is alive.
  [ -n "$_stale_owner" ] && [ ! -d "/proc/$_stale_owner" ] &&
    ! kill -0 "$_stale_owner" 2>/dev/null || continue
  if magicnet_install_backup_marker_is_exact "$_stale_backup"; then
    magicnet_prepare_install_backup_removal "$_stale_backup" ||
      abort "! failed to prepare stale MagicNet migration data for removal"
    rm -rf "$_stale_backup" || abort "! failed to remove stale MagicNet migration data"
  fi
done
unset _stale_backup _stale_owner

at_exit_register_trap
at_exit_add 'magicnet_cleanup_install_backup'

if [ -d "$MAGICNET_PREV_DIR" ]; then
  if [ -e "$MAGICNET_BACKUP_DIR" ] || [ -L "$MAGICNET_BACKUP_DIR" ]; then
    abort "! MagicNet migration backup path already exists"
  fi
  (
    umask 077
    mkdir "$MAGICNET_BACKUP_DIR" &&
      printf '%s\n' "$MAGICNET_BACKUP_MARKER_VALUE" >"$MAGICNET_BACKUP_DIR/$MAGICNET_BACKUP_MARKER"
  ) || abort "! failed to create the MagicNet migration backup"
  MAGICNET_BACKUP_ACTIVE=1
  # Snapshot the old full file for node recovery and a private rollback copy.
  while IFS= read -r _item; do
    case "$_item" in *[![:space:]]*) ;; *) continue ;; esac
    if [ -L "${MAGICNET_PREV_DIR}/${_item}" ]; then
      abort "! refusing unsafe symlink in MagicNet migration data: $_item"
    fi
    if [ -e "${MAGICNET_PREV_DIR}/${_item}" ]; then
      mkdir -p "${MAGICNET_BACKUP_DIR}/${_item%/*}" || abort "! failed to prepare MagicNet migration data: $_item"
      cp -a "${MAGICNET_PREV_DIR}/${_item}" "${MAGICNET_BACKUP_DIR}/${_item}" || abort "! failed to back up MagicNet migration data: $_item"
    fi
  done <<EOF_MAGICNET_MIGRATION_ITEMS
$MAGICNET_INSTALL_MIGRATION_ITEMS
EOF_MAGICNET_MIGRATION_ITEMS
  MAGICNET_BACKUP_READY=1
  unset _item
fi

# Usage & installation messages
set_i18n "INSTALL_TITLE" \
  "zh" "MagicNet 安装向导" \
  "en" "MagicNet Setup" \
  "ru" "Установка MagicNet" \
  "ja" "MagicNet セットアップ" \
  "ko" "MagicNet 설치"

set_i18n "INSTALL_PROFILE" \
  "zh" "系统级戒网瘾模块，内置 sing-box、域名封锁、TUN/eBPF 透明治理与 WebUI 控制面。" \
  "en" "System-level digital detox module with sing-box, domain blocking, explicit TUN/eBPF transparent routing, and WebUI control surfaces." \
  "ru" "Системный модуль с sing-box, блокировкой отвлекающих сайтов, прозрачной маршрутизацией TUN/eBPF и управлением через WebUI." \
  "ja" "sing-box、ドメインブロック、TUN/eBPF 透過制御、WebUI 制御面を備えたシステム級デジタルデトックスモジュールです。" \
  "ko" "sing-box, 도메인 차단, TUN/eBPF 투명 제어, WebUI 제어면을 포함한 시스템 수준 디지털 디톡스 모듈입니다."

set_i18n "INSTALL_ROW_PROFILE" \
  "zh" "模块定位" \
  "en" "Profile" \
  "ru" "О модуле" \
  "ja" "概要" \
  "ko" "개요"

set_i18n "INSTALL_DEFAULTS" \
  "zh" "默认启用：sing-box、TUN 自动路由、戒网瘾封锁列表、WebUI 与 CLI 控制面；可显式切换 eBPF。" \
  "en" "Enabled by default: sing-box, TUN auto-route, detox blocklist, WebUI and CLI control surfaces; eBPF is an explicit opt-in." \
  "ru" "По умолчанию включены sing-box, автоматическая маршрутизация TUN, список блокировки, WebUI и CLI. Режим eBPF включается отдельно." \
  "ja" "既定で有効: sing-box、TUN 自動ルート、デジタルデトックスブロックリスト、WebUI と CLI 制御面。eBPF は明示的に切り替えます。" \
  "ko" "기본 활성화: sing-box, TUN 자동 라우팅, 디지털 디톡스 차단 목록, WebUI 및 CLI 제어면. eBPF는 명시적으로 전환합니다."

set_i18n "INSTALL_ROW_DEFAULTS" \
  "zh" "默认行为" \
  "en" "Defaults" \
  "ru" "По умолчанию" \
  "ja" "既定動作" \
  "ko" "기본 동작"

set_i18n "INSTALL_CONFIG_TITLE" \
  "zh" "配置与下一步" \
  "en" "Configuration and Next Steps" \
  "ru" "Настройка и дальнейшие действия" \
  "ja" "設定と次の手順" \
  "ko" "설정 및 다음 단계"

set_i18n "INSTALL_CONFIG_PATHS" \
  "zh" "配置文件：
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json" \
  "en" "Configuration files:
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json" \
  "ru" "Файлы конфигурации:
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json" \
  "ja" "設定ファイル:
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json" \
  "ko" "설정 파일:
sing-box: /data/adb/modules/MagicNet/.config/sing-box/config.json"

set_i18n "INSTALL_NEXT_STEPS" \
  "zh" "安装后操作：
1. 首次安装在自动打开的网页填写订阅，也可稍后通过 WebUI 配置；升级自动保留订阅并更新完整配置模板。
2. 重启设备，或在模块操作页启动内核。
3. 打开模块 WebUI 的内核面板，或在终端执行 cli api ui 查看当前核心入口。
4. 把想戒掉的网站、规则组或域名指向 REJECT / block。
sing-box 默认: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "en" "After installation:
1. After installation, review subscriptions in the browser or use WebUI later. Upgrades prefill saved URLs for replacement or addition and replace the full config template.
2. Reboot, or start the core from the module action page.
3. Open Kernel Panel in the module WebUI, or run cli api ui to print the current core entry.
4. Point distracting sites, groups, or domains to REJECT / block.
sing-box default: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "ru" "После установки:
1. Добавьте подписку на открывшейся странице или позже в WebUI. При обновлении подписка сохраняется.
2. Перезагрузите устройство или запустите ядро из меню действий модуля.
3. Откройте панель ядра в WebUI модуля или выполните cli api ui, чтобы узнать адрес панели.
4. Назначьте отвлекающим сайтам, группам правил или доменам REJECT / block.
Адрес sing-box по умолчанию: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "ja" "インストール後:
1. 開いたページで購読を追加するか、後で WebUI から設定します。更新時は既存の購読を保持します。
2. 再起動するか、モジュール操作画面からコアを起動します。
3. モジュール WebUI の Kernel Panel を開くか、cli api ui で現在のコア入口を確認します。
4. 見たくないサイト、グループ、ドメインを REJECT / block に向けます。
sing-box 既定: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090" \
  "ko" "설치 후:
1. 열린 페이지에서 구독을 추가하거나 나중에 WebUI에서 설정하세요. 업데이트 시 기존 구독은 유지됩니다.
2. 재부팅하거나 모듈 작업 화면에서 코어를 시작하세요.
3. 모듈 WebUI의 Kernel Panel을 열거나 cli api ui로 현재 코어 진입점을 확인하세요.
4. 끊고 싶은 사이트, 그룹, 도메인을 REJECT / block으로 지정하세요.
sing-box 기본값: http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090"

set_i18n "INSTALL_FLAGS" \
  "zh" "可选开关：
MAGIC_SINGBOX=0 禁用 sing-box 内核" \
  "en" "Optional switches:
MAGIC_SINGBOX=0 disables the sing-box core" \
  "ru" "Дополнительные параметры:
MAGIC_SINGBOX=0 отключает ядро sing-box" \
  "ja" "任意スイッチ:
MAGIC_SINGBOX=0 で sing-box コアを無効化" \
  "ko" "선택 스위치:
MAGIC_SINGBOX=0 sing-box 코어 비활성화"

set_i18n "TERM_INSTALL_MSG" \
  "zh" "当前为终端安装：会显示完整交互菜单和状态信息。" \
  "en" "Terminal install detected: full interactive menus and status output are available." \
  "ru" "Установка из терминала: доступны интерактивные меню и сведения о состоянии." \
  "ja" "端末インストールを検出しました。完全な対話メニューと状態表示を利用できます。" \
  "ko" "터미널 설치가 감지되었습니다. 전체 대화형 메뉴와 상태 출력을 사용할 수 있습니다."

set_i18n "GUI_INSTALL_MSG" \
  "zh" "当前为管理器安装：若交互显示异常，可改用终端安装同一个 zip。" \
  "en" "Manager install detected: if interaction looks broken, install the same zip from a terminal." \
  "ru" "Установка через менеджер модулей: при проблемах с интерфейсом установите тот же ZIP из терминала." \
  "ja" "管理アプリでのインストールを検出しました。表示が崩れる場合は同じ zip を端末からインストールしてください。" \
  "ko" "관리자 설치가 감지되었습니다. 상호작용 표시가 이상하면 같은 zip을 터미널에서 설치하세요."

set_i18n "SET_MODULE_ENTRY_PERMS" \
  "zh" "设置模块入口脚本权限" \
  "en" "Setting permissions for module entry scripts" \
  "ru" "Настройка прав доступа для скриптов запуска модуля" \
  "ja" "モジュール入口スクリプトの権限を設定しています" \
  "ko" "모듈 진입 스크립트 권한 설정 중"

set_i18n "INSTALL_NEW_SUMMARY" \
  "zh" "首次安装：校验配置模板后安装；订阅可在安装引导或 WebUI 中填写。" \
  "en" "New installation: validate the template before installing; add subscriptions in setup or WebUI." \
  "ru" "Первая установка: шаблон будет проверен; добавьте подписку в мастере или WebUI." \
  "ja" "初回インストール: テンプレートを検証します。購読はセットアップまたは WebUI で追加できます。" \
  "ko" "최초 설치: 템플릿 검증 후 설치합니다. 구독은 설정 안내 또는 WebUI에서 추가하세요."
set_i18n "INSTALL_UPGRADE_SUMMARY" \
  "zh" "升级：保留订阅来源和用户选项，使用新模板重建并校验配置；校验失败将停止安装。" \
  "en" "Upgrade: keep subscription sources and user settings, rebuild and validate with the new template; validation failure stops installation." \
  "ru" "Обновление сохранит источники и настройки, пересоберёт конфигурацию по новому шаблону; ошибка проверки остановит установку." \
  "ja" "更新: 購読元とユーザー設定を保持し、新テンプレートで再構築・検証します。検証失敗時はインストールを停止します。" \
  "ko" "업그레이드: 구독 소스와 사용자 설정을 유지하고 새 템플릿으로 재구성 및 검증합니다. 검증 실패 시 설치를 중단합니다."

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

magicnet_print_install_summary() {
  newline
  print "MagicNet"
  print "sing-box · TUN / eBPF · WebUI"
  if [ "${MAGICNET_BACKUP_READY:-0}" = 1 ]; then
    print "$(i18n INSTALL_UPGRADE_SUMMARY)"
  else
    print "$(i18n INSTALL_NEW_SUMMARY)"
  fi
  newline
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
  while IFS= read -r _item; do
    case "$_item" in *[![:space:]]*) ;; *) continue ;; esac
    [ "$_item" != "$MAGICNET_INSTALL_BACKUP_ONLY_ITEM" ] || continue
    if [ -e "${MAGICNET_BACKUP_DIR}/${_item}" ]; then
      mkdir -p "${MODPATH}/${_item%/*}" || abort "! failed to prepare restored MagicNet migration data: $_item"
      rm -rf "${MODPATH:?}/${_item}" || abort "! failed to replace MagicNet migration data: $_item"
      cp -a "${MAGICNET_BACKUP_DIR}/${_item}" "${MODPATH}/${_item}" || abort "! failed to restore MagicNet migration data: $_item"
    fi
  done <<EOF_MAGICNET_MIGRATION_ITEMS
$MAGICNET_INSTALL_MIGRATION_ITEMS
EOF_MAGICNET_MIGRATION_ITEMS
  unset _item
fi

# The repository selector is a new managed setting. Seed it after migration so
# restoring an older .config/magicnet directory cannot remove the default.
magicnet_seed_config_repository() {
  _repository_file="${MODPATH}/.config/magicnet/singbox-config-repo.conf"
  _repository_parent="${_repository_file%/*}"
  if [ -L "${MODPATH}/.config" ] || [ -L "$_repository_parent" ] || [ -L "$_repository_file" ]; then
    unset _repository_file _repository_parent
    return 1
  fi
  if [ -e "$_repository_file" ]; then
    [ -f "$_repository_file" ] || {
      unset _repository_file _repository_parent
      return 1
    }
    unset _repository_file _repository_parent
    return 0
  fi
  mkdir -p "$_repository_parent" || {
    unset _repository_file _repository_parent
    return 1
  }
  printf '%s\n' \
    '# Managed by MagicNet; edit through the config repository controls.' \
    'MAGICNET_SINGBOX_CONFIG_REPO_URL=https://github.com/LIghtJUNction/MagicSingBox.git' \
    'MAGICNET_SINGBOX_CONFIG_REPO_REF=e4ecf47499c35bf25e10d04257a21a4f7975ebad' \
    'MAGICNET_SINGBOX_CONFIG_REPO_PATH=config.json' \
    'MAGICNET_SINGBOX_CONFIG_REPO_SHA256=eeffe5b7540c6a2f92629ba95a2488efcbcde553d9f70035d3e2ae8ecb65edbf' >"$_repository_file" || {
    unset _repository_file _repository_parent
    return 1
  }
  chmod 600 "$_repository_file" || {
    unset _repository_file _repository_parent
    return 1
  }
  unset _repository_file _repository_parent
}

magicnet_seed_config_repository || abort "! failed to initialize the sing-box config repository"

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

# Subscription inputs/cache were restored above; the generated config is not
# user state. Always take the whole template from this release, even when the
# manager pre-extracted the ZIP over an existing directory. Upgrades rebuild
# saved nodes before replacing the active file; fresh installs use the template.
# Neither path fetches subscriptions or starts the core inside the installer.
magicnet_install_config_template() (
  . "${MODPATH}/lib/magicnet/install_config.sh" || return 1
  if [ "${MAGICNET_BACKUP_READY:-0}" = 1 ]; then
    magicnet_refresh_install_config || return 1
    return 0
  fi
  _config_dir="${MODPATH}/.config/sing-box"
  for _path in "${MODPATH}/.config" "$_config_dir" "$_config_dir/config.json"; do
    [ ! -L "$_path" ] || return 1
  done
  mkdir -p "$_config_dir" || return 1
  _stage="$_config_dir/.install-template.$$"
  (umask 077; mkdir "$_stage") || return 1
  trap 'rm -rf "$_stage"' 0
  trap 'exit 1' 1 2 3 15
  magicnet_stage_install_config "$_stage" || return 1
  _candidate_root="$_stage/.config/sing-box"
  # First installs need the same validation boundary as upgrades. Use the
  # shipped executables rather than an unrelated core from the manager PATH.
  magicnet_validate_install_config "$_candidate_root/config.json" || return 1
  chmod 600 "$_candidate_root/config.json" || return 1
  [ ! -e "$_config_dir/config.json" ] || [ -f "$_config_dir/config.json" ] || return 1
  mv -f "$_candidate_root/config.json" "$_config_dir/config.json" || return 1
  # A stale standalone marker would bypass subscription/cache replay entirely.
  if [ -s "$_config_dir/subscription.url" ] || [ -s "$_config_dir/subscription.local" ]; then
    rm -f "$_config_dir/standalone-config" || return 1
  fi
  rm -f "$_config_dir/config.json.update"
)

magicnet_install_config_template || abort "! failed to install the new sing-box config template"

rm -f "${MODPATH}/cli" 2>/dev/null || true
ln -s "bin/magicnet-cli" "${MODPATH}/cli" 2>/dev/null || true

info "$(i18n "SET_MODULE_ENTRY_PERMS")"
for _magicnet_entry in action.sh service.sh boot-completed.sh; do
  [ -f "${MODPATH}/${_magicnet_entry}" ] || continue
  set_perm "${MODPATH}/${_magicnet_entry}" 0 0 0755 u:object_r:system_file:s0
done
unset _magicnet_entry

magicnet_cleanup_install_backup || abort "! failed to remove the MagicNet migration backup"

# Offer browser input only after migration and all permission/template writes.
# Otherwise chmod/template installation could
# overwrite the just-collected private state. This does not require a TTY.
. "$MODPATH/lib/magicnet/install_onboarding.sh" || abort "! subscription setup helper missing"
if magicnet_install_onboarding; then
  :
else
  _setup_status=$?
  [ "$_setup_status" -ne 4 ] || abort "! Installation cancelled: no subscription selected or user requested stop"
  warn "! subscription setup interrupted; configure it later in WebUI"
fi

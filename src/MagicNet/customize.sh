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
select_lang

import rich

import this

# Usage & installation messages
set_i18n "USAGE_GUIDE" \
  "zh" "使用教程：
这是一个支持 mihomo / sing-box 的代理模块
1. 只支持tun模式
2. 内置大量规则
3. 支持 Clash API 兼容 WebUI
安装后：
你需要前往 /data/adb/modules/MagicNet/.config/mihomo/config.yaml 或 /data/adb/modules/MagicNet/.config/sing-box/config.json
填写订阅链接
如果能成功访问webui,即代表启动成功" \
  "en" "Usage guide:
This is a proxy module with mihomo / sing-box core support
1. Only supports TUN mode
2. Includes many built-in rules
3. Supports Clash API compatible WebUIs
After installation:
You need to edit /data/adb/modules/MagicNet/.config/mihomo/config.yaml or /data/adb/modules/MagicNet/.config/sing-box/config.json
and fill in the subscription URL or outbound configuration
If you can successfully access the web UI, it means it started successfully" \
  "ja" "使用方法：
これは mihomo / sing-box コアに対応したプロキシモジュールです
1. tun モードのみサポートします
2. 多くの組み込みルールを含みます
3. Clash API 互換 Web UI をサポートします
インストール後：
/data/adb/modules/MagicNet/.config/mihomo/config.yaml または /data/adb/modules/MagicNet/.config/sing-box/config.json を編集して
購読リンクまたはアウトバウンド設定を記入してください
Web UI にアクセスできれば起動成功です" \
  "ko" "사용 안내:
이것은 mihomo / sing-box 코어를 지원하는 프록시 모듈입니다
1. tun 모드만 지원합니다
2. 많은 내장 규칙을 포함합니다
3. Clash API 호환 WebUI를 지원합니다
설치 후:
/data/adb/modules/MagicNet/.config/mihomo/config.yaml 또는 /data/adb/modules/MagicNet/.config/sing-box/config.json 파일을 열어
구독 링크 또는 outbound 설정을 입력하세요
웹 UI에 정상적으로 접속되면 시작이 성공한 것입니다"

set_i18n "TERM_INSTALL_MSG" \
  "zh" "终端安装体验比通过管理器安装体验更好，能正确显示颜色，并且支持刷新显示" \
  "en" "Installing via terminal provides a better experience than using the manager: colors display correctly and screen refresh is supported" \
  "ja" "端末からのインストールは管理アプリでのインストールよりも快適です。色表示が正しく、画面のリフレッシュがサポートされます" \
  "ko" "터미널에서 설치하면 관리자 앱보다 더 나은 사용 경험을 제공합니다. 색상이 올바르게 표시되고 화면 갱신을 지원합니다"

set_i18n "GUI_INSTALL_MSG" \
  "zh" "如果想获得更好的使用体验，请从终端安装" \
  "en" "For a better experience, please install from the terminal" \
  "ja" "より良い体験のために、端末からインストールしてください" \
  "ko" "더 나은 사용 경험을 원하면 터미널에서 설치하세요"

set_i18n "HOTSPOT_FORWARD_MSG" \
  "zh" "已启用热点转发修复。可设置 MAGIC_HOTSPOT_FORWARD=0 关闭；特殊机型可用 MAGIC_HOTSPOT_IFACES / MAGIC_TUN_IFACES 指定网卡。" \
  "en" "Hotspot forwarding fix is enabled. Set MAGIC_HOTSPOT_FORWARD=0 to disable it; use MAGIC_HOTSPOT_IFACES / MAGIC_TUN_IFACES for device-specific interfaces." \
  "ja" "ホットスポット転送修正が有効です。MAGIC_HOTSPOT_FORWARD=0 で無効化できます。特殊な端末では MAGIC_HOTSPOT_IFACES / MAGIC_TUN_IFACES でインターフェースを指定してください。" \
  "ko" "핫스팟 포워딩 수정이 활성화되었습니다. MAGIC_HOTSPOT_FORWARD=0 으로 비활성화할 수 있으며, 특수 기기는 MAGIC_HOTSPOT_IFACES / MAGIC_TUN_IFACES 로 인터페이스를 지정하세요."

set_i18n "VPN_COEXIST_MSG" \
  "zh" "VPN 共存模式默认关闭。需要与其它 root/VPN 隧道共存时可设置 MAGIC_VPN_COEXIST=1；特殊机型可用 MAGIC_VPN_COEXIST_IFACES 指定外部 VPN 网卡。" \
  "en" "VPN coexistence mode is disabled by default. Set MAGIC_VPN_COEXIST=1 when sharing routes with other root/VPN tunnels; use MAGIC_VPN_COEXIST_IFACES for device-specific external VPN interfaces." \
  "ja" "VPN 共存モードは既定で無効です。他の root/VPN トンネルと経路を共有する場合は MAGIC_VPN_COEXIST=1 を設定してください。特殊な端末では MAGIC_VPN_COEXIST_IFACES で外部 VPN インターフェースを指定できます。" \
  "ko" "VPN 공존 모드는 기본적으로 비활성화되어 있습니다. 다른 root/VPN 터널과 라우팅을 공유하려면 MAGIC_VPN_COEXIST=1 을 설정하세요. 특수 기기는 MAGIC_VPN_COEXIST_IFACES 로 외부 VPN 인터페이스를 지정할 수 있습니다."
# print
print "$(i18n "USAGE_GUIDE")"

# if terminal , print
tprint "$(i18n "TERM_INSTALL_MSG")"

# if gui , print
gprint "$(i18n "GUI_INSTALL_MSG")"
print "$(i18n "HOTSPOT_FORWARD_MSG")"
print "$(i18n "VPN_COEXIST_MSG")"

MAGIC_MIHOMO=${MAGIC_MIHOMO:-1}
MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}

if [ "$MAGIC_SINGBOX" != "0" ] && [ ! -f "${MODPATH}/.disable_sing_box" ] && [ -x "${MODPATH}/system/bin/sing-box" ]; then
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

[ -f "${MODPATH}/.config/mihomo/config.yaml" ] && confirm_update_file ".config/mihomo/config.yaml"
[ -f "${MODPATH}/.config/sing-box/config.json" ] && confirm_update_file ".config/sing-box/config.json"

import launcher
launch url "https://github.com/LIghtJUNction/MagicNet"

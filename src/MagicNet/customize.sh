# shellcheck shell=ash
# MagicNet customize.sh
#
# -----------------------------------------------------------------------------------

SKIPUNZIP=1
unzip -o "$ZIPFILE" "lib/kamfw/*" -d "$MODPATH" >&2 && . "$MODPATH/lib/kamfw/.kamfwrc" || abort "! .kamfwrc missing"
# 作者注：导入以上工具库，会自动依据ROOT管理器
# 进行一些特殊处理
# 比如，如果是magisk.补全META-INF
# boot-completed --> service
# 记得在boot-completed调用：
# wait_boot_if_magisk
# 详见 lib/kamfw/magisk.sh
# lib/kamfw/ksu.sh
# lib/kamfw/ap.sh
import __customize__

import i18n
import lang
select_lang

import rich

import this
import __mihomo__



# Usage & installation messages
set_i18n "USAGE_GUIDE" \
    "zh" "使用教程：
这是一个基于mihomo内核的代理模块
1. 只支持tun模式
2. 内置大量规则
3. 支持两套webui
安装后：
你需要前往/data/adb/modules/MagicNet/.config/mihomo/config.yaml
填写订阅链接
如果能成功访问webui,即代表启动成功" \
    "en" "Usage guide:
This is a proxy module based on the mihomo core
1. Only supports TUN mode
2. Includes many built-in rules
3. Supports two web UIs
After installation:
You need to edit /data/adb/modules/MagicNet/.config/mihomo/config.yaml
and fill in the subscription URL
If you can successfully access the web UI, it means it started successfully" \
    "ja" "使用方法：
これは mihomo コアをベースにしたプロキシモジュールです
1. tun モードのみサポートします
2. 多くの組み込みルールを含みます
3. 2種類の Web UI をサポートします
インストール後：
/data/adb/modules/MagicNet/.config/mihomo/config.yaml を編集して
購読リンクを記入してください
Web UI にアクセスできれば起動成功です" \
    "ko" "사용 안내:
이것은 mihomo 코어 기반의 프록시 모듈입니다
1. tun 모드만 지원합니다
2. 많은 내장 규칙을 포함합니다
3. 두 종류의 웹 UI를 지원합니다
설치 후:
/data/adb/modules/MagicNet/.config/mihomo/config.yaml 파일을 열어
구독 링크를 입력하세요
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
# print
print "$(i18n "USAGE_GUIDE")"

# if terminal , print
tprint "$(i18n "TERM_INSTALL_MSG")"

# if gui , print
gprint "$(i18n "GUI_INSTALL_MSG")"

ask_webui

# 设置权限
set_perm "${MODPATH}/system/bin/mihomo" 0 0 0700 u:object_r:magisk_file:s0

set_perm "${MODPATH}/.local/bin/mihomo" 0 0 0700 u:object_r:magisk_file:s0

confirm_update_file ".config/mihomo/config.yaml"

import launcher
launch url "https://github.com/LIghtJUNction/MagicNet"

# shellcheck shell=ash
# MagicNet customize.sh
#
# 简洁版安装自定义脚本（返回到精简风格、移除过度防御逻辑）
# -----------------------------------------------------------------------------------
MODDIR=${0%/*}
[ -f "$MODDIR/lib/kam-utils.sh" ] && . "$MODDIR/lib/kam-utils.sh" || abort '! File "kam-utils.sh" does not exist!'

# 初始化 KAM 环境
kam_init

# 加载导航模块
kam_load navigation

# status helper - use tput to print inline statuses elegantly
status_msg() {
    STATUS_MSG="$1"
    if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
        # print message without newline and save cursor
        printf '%s' "$STATUS_MSG"
        tput sc 2>/dev/null || true
    else
        printf '%s' "$STATUS_MSG"
    fi
}

status_ok() {
    if [ -z "${STATUS_MSG:-}" ]; then
        if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
            tput bold 2>/dev/null || true
            tput setaf 2 2>/dev/null || true
            printf '%s\n' "[OK]"
            tput sgr0 2>/dev/null || true
        else
            printf '%s\n' "[OK]"
        fi
    else
        if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
            tput rc 2>/dev/null || true
            tput el 2>/dev/null || true
            tput bold 2>/dev/null || true
            tput setaf 2 2>/dev/null || true
            printf '%s %s\n' "$STATUS_MSG" "[OK]"
            tput sgr0 2>/dev/null || true
        else
            printf '%s %s\n' "$STATUS_MSG" "[OK]"
        fi
        unset STATUS_MSG
    fi
}

status_fail() {
    if [ -z "${STATUS_MSG:-}" ]; then
        if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
            tput bold 2>/dev/null || true
            tput setaf 1 2>/dev/null || true
            printf '%s\n' "[FAILED]"
            tput sgr0 2>/dev/null || true
        else
            printf '%s\n' "[FAILED]"
        fi
    else
        if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
            tput rc 2>/dev/null || true
            tput el 2>/dev/null || true
            tput bold 2>/dev/null || true
            tput setaf 1 2>/dev/null || true
            printf '%s %s\n' "$STATUS_MSG" "[FAILED]"
            tput sgr0 2>/dev/null || true
        else
            printf '%s %s\n' "$STATUS_MSG" "[FAILED]"
        fi
        unset STATUS_MSG
    fi
}

# 项目 i18n 文本（保留）
set_i18n "mihomo_config" "zh" "Mihomo 配置选项" "en" "Mihomo Configuration" "ja" "Mihomo設定" "ko" "Mihomo 구성"
set_i18n "yacd_ui" "zh" "Yacd UI" "en" "Yacd UI" "ja" "Yacd UI" "ko" "Yacd UI"
set_i18n "subscription_url" "zh" "订阅链接配置" "en" "Subscription URL" "ja" "サブスクリプションURL" "ko" "구독 URL"
set_i18n "ipv6_support" "zh" "IPv6支持" "en" "IPv6 Support" "ja" "IPv6サポート" "ko" "IPv6 지원"
set_i18n "allow_lan" "zh" "局域网访问" "en" "Allow LAN" "ja" "LANアクセス" "ko" "LAN 액세스"
set_i18n "geo_auto_update" "zh" "自动更新地理数据" "en" "Auto Geo Update" "ja" "地理データ自動更新" "ko" "지리 데이터 자동 업데이트"
set_i18n "give_star" "zh" "给个星星吧！" "en" "Give me a star!" "ja" "スターをくれ！" "ko" "별을 주세요!"
set_i18n "feed_star" "zh" "投喂星光" "en" "Feed star" "ja" "星を餌付け" "ko" "별에게 먹이를 주세요"
set_i18n "refuse" "zh" "残忍拒绝" "en" "Refuse" "ja" "拒否" "ko" "거절"
set_i18n "debug_mode" "zh" "是否开启调试模式？" "en" "Enable debug mode?" "ja" "デバッグモードを有効にしますか？" "ko" "디버그 모드를 활성화하시겠습니까?"
set_i18n "enable_debug" "zh" "开启调试" "en" "Enable Debug" "ja" "デバッグ有効" "ko" "디버그 활성화"
set_i18n "disable_debug" "zh" "关闭调试" "en" "Disable Debug" "ja" "デバッグ無効" "ko" "디버그 비활성화"
set_i18n "using_default_url" "zh" "使用默认订阅链接，请稍后手动编辑配置文件" "en" "Using default subscription URL, please edit config file manually later" "ja" "デフォルトのサブスクリプションURLを使用、後で手動で設定ファイルを編集してください" "ko" "기본 구독 URL 사용, 나중에 수동으로 설정 파일을 편집하세요"
set_i18n "config_file_path" "zh" "配置文件路径" "en" "Config file path" "ja" "設定ファイルパス" "ko" "설정 파일 경로"
set_i18n "manual_edit_hint" "zh" "请在订阅链接位置填入您的实际订阅地址" "en" "Please fill in your actual subscription URL at the subscription link location" "ja" "サブスクリプションリンクの場所に実際のサブスクリプションアドレスを入力してください" "ko" "구독 링크 위치에 실제 구독 주소를 입력하세요"
set_i18n "input_failed" "zh" "自动输入失败，请手动编辑配置文件：" "en" "Auto input failed, please edit config file manually:" "ja" "自動入力に失敗しました。設定ファイルを手動で編集してください：" "ko" "자동 입력 실패, 구성 파일을 수동으로 편집하세요:"
set_i18n "find_url_line" "zh" "找到 'url: 订阅链接' 并替换为您的订阅地址" "en" "Find 'url: 订阅链接' and replace with your subscription URL" "ja" "'url: 記事リンク' を見つけて、あなたの購読URLに置き換えてください" "ko" "'url: 구독 링크'를 찾아 구독 URL로 바꾸세요"
set_i18n "opening_dialog" "zh" "正在打开输入对话框..." "en" "Opening input dialog..." "ja" "入力ダイアログを開いています..." "ko" "입력 대화상자를 여는 중..."
set_i18n "dialog_help1" "zh" "如果无法自动获取结果，请：" "en" "If unable to get result automatically, please:" "ja" "自動的に結果を取得できない場合：" "ko" "자동으로 결과를 가져올 수 없으면:"
set_i18n "dialog_help2" "zh" "1. 输入您的订阅链接" "en" "1. Enter your subscription URL" "ja" "1. 購読URLを入力" "ko" "1. 구독 URL 입력"
set_i18n "dialog_help3" "zh" "2. 复制输入的内容（长按文本选择）" "en" "2. Copy the input (long press to select)" "ja" "2. 入力内容をコピー（長押しで選択）" "ko" "2. 입력 내용 복사（길게 눌러 선택）"
set_i18n "dialog_help4" "zh" "3. 对话框关闭后，我们将尝试从剪贴板获取" "en" "3. After dialog closes, we'll try to get from clipboard" "ja" "3. ダイアログ閉じ後、クリップボードから取得を試みます" "ko" "3. 대화상자 닫힌 후, 클립보드에서 가져오기를 시도합니다"
set_i18n "termux_dialog_unavailable" "zh" "termux-dialog 不可用，使用默认值" "en" "termux-dialog unavailable, using default value" "ja" "termux-dialog が利用できません。デフォルト値を使用します" "ko" "termux-dialog를 사용할 수 없습니다. 기본값을 사용합니다"
set_i18n "debug_enabled" "zh" "调试模式已开启" "en" "Debug mode enabled" "ja" "デバッグモードが有効になりました" "ko" "디버그 모드가 활성화되었습니다"
set_i18n "debug_disabled" "zh" "调试模式已关闭" "en" "Debug mode disabled" "ja" "デバッグモードが無効になりました" "ko" "디버그 모드가 비활성화되었습니다"
set_i18n "debug_status_on" "zh" "调试模式：开启 (KAM_DEBUG=1)" "en" "Debug mode: ON (KAM_DEBUG=1)" "ja" "デバッグモード：オン (KAM_DEBUG=1)" "ko" "디버그 모드: 켜짐 (KAM_DEBUG=1)"
set_i18n "debug_status_off" "zh" "调试模式：关闭 (KAM_DEBUG=0)" "en" "Debug mode: OFF (KAM_DEBUG=0)" "ja" "デバッグモード：オフ (KAM_DEBUG=0)" "ko" "디버그 모드: 꺼짐 (KAM_DEBUG=0)"

# 语言选择
divider
select_language
divider
divider
msg ""

# 加载调试模块
kam_load debug

divider
ask "debug_mode" "disable_debug" "enable_debug" \
        'debug_off' \
        'debug_on' \
        0
divider
debug_status
divider

status_msg "- Checking version requirements..."
if require_version "magisk:>=28000" "ksu:>=11986" --mode=abort --message="MagicNet Abort: version requirements not met!"; then
    status_ok
else
    status_fail
fi

msg "- Installing MagicNet..."
status_msg "- [DEBUG] 准备加载 UI 模块..."
if kam_load ui; then
    status_ok
else
    status_fail
fi

status_msg "- [DEBUG] 加载 Termux 模块..."
if kam_load termux; then
    status_ok
else
    status_fail
fi

status_msg "Setting permissions for module..."
if set_perm_recursive "$MODDIR" 0 0 0755 0755; then
    status_ok
else
    status_fail
fi

# 设置启动脚本用于订阅配置
divider
status_msg "- 设置订阅配置脚本..."
if chmod 755 "$MODDIR/boot-completed.sh"; then
    status_ok
    msg "- 订阅链接将在设备重启后配置"
else
    status_fail
fi
divider

# 配置 Mihomo 选项
divider
msg "$(i18n "mihomo_config")"
divider

# 默认指定配置文件路径（可被外部覆盖）
config_file="${config_file:-$MODDIR/mihomo/config.yaml}"

# 固定启用 TUN 模式
msg "- 固定启用 TUN 模式"
sed -i 's/enable: false/enable: true/g' "$config_file"

# 使用二进制配置
# 位定义: 1=yacd, 2=IPv6, 3=LAN, 4=GeoUpdate
# 默认值: 1111 (全部启用)
config_bits=$(binary_prompt "1111" "$(i18n "yacd_ui")" "$(i18n "ipv6_support")" "$(i18n "allow_lan")" "$(i18n "geo_auto_update")")

# 应用配置

# 第1位: Yacd UI
if [ "${config_bits:0:1}" = "1" ]; then
    status_msg "- 启用 Yacd UI"
    if touch "$MODDIR/yacd"; then
        status_ok
    else
        status_fail
    fi
else
    status_msg "- 禁用 Yacd UI"
    if rm -f "$MODDIR/yacd"; then
        status_ok
    else
        status_fail
    fi
fi

# 第2位: IPv6 支持
if [ "${config_bits:1:1}" = "1" ]; then
    msg "- 启用 IPv6 支持"
    sed -i 's/ipv6: false/ipv6: true/g' "$config_file"
else
    msg "- 禁用 IPv6 支持"
    sed -i 's/ipv6: true/ipv6: false/g' "$config_file"
fi

# 第3位: 局域网访问
if [ "${config_bits:2:1}" = "1" ]; then
    msg "- 允许局域网访问"
    sed -i 's/allow-lan: false/allow-lan: true/g' "$config_file"
else
    msg "- 禁止局域网访问"
    sed -i 's/allow-lan: true/allow-lan: false/g' "$config_file"
fi

# 第4位: 自动更新地理数据
if [ "${config_bits:3:1}" = "1" ]; then
    msg "- 启用自动更新地理数据"
    sed -i 's/geo-auto-update: false/geo-auto-update: true/g' "$config_file"
else
    msg "- 禁用自动更新地理数据"
    sed -i 's/geo-auto-update: true/geo-auto-update: false/g' "$config_file"
fi

divider

ask "give_star" "feed_star" "refuse" \
    'open_url "https://github.com/LIghtJUNction/MagicNet"' \
    'msg "All right"'
newline


# ---------------------------------------------------------------------------------
# 安装完成

# Load compat module (provides compatibility helpers like boot2serviceif)
kam_load compat || ui_print "- Warning: failed to load compat module"

# 如果为 Magisk 环境，则用兼容模块把 boot 脚本转为 service 以兼容 Magisk
boot2serviceif "magisk"

# 清理并显示摘要信息
kam_end

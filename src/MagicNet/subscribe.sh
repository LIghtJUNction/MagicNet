# shellcheck shell=ash
# =============================================================================
# MagicNet 启动脚本 - 订阅链接配置
# =============================================================================

# 加载 KAM 工具
MODDIR="${0%/*}"
. "$MODDIR/lib/kam-utils.sh"

# 加载必要模块
kam_load ui termux debug config

# 设置 i18n
set_i18n "subscription_config" "zh" "订阅链接配置" "en" "Subscription Configuration" "ja" "サブスクリプション設定" "ko" "구독 설정"
set_i18n "input_subscription" "zh" "请输入您的订阅链接" "en" "Please enter your subscription URL" "ja" "サブスクリプションURLを入力してください" "ko" "구독 URL을 입력하세요"
set_i18n "config_saved" "zh" "配置已保存" "en" "Configuration saved" "ja" "設定を保存しました" "ko" "구성이 저장되었습니다"
set_i18n "using_default" "zh" "使用默认配置" "en" "Using default configuration" "ja" "デフォルト設定を使用" "ko" "기본 구성 사용"
set_i18n "input_failed" "zh" "自动输入失败，请手动编辑配置文件：" "en" "Auto input failed, please edit config file manually:" "ja" "自動入力に失敗しました。設定ファイルを手動で編集してください：" "ko" "자동 입력 실패, 구성 파일을 수동으로 편집하세요:"
set_i18n "manual_edit_hint" "zh" "请在订阅链接位置填入您的实际订阅地址" "en" "Please fill in your actual subscription URL at the subscription link location" "ja" "サブスクリプションリンクの場所に実際のサブスクリプションアドレスを入力してください" "ko" "구독 링크 위치에 실제 구독 주소를 입력하세요"

# 检查是否已经配置过
config_file="$MODDIR/mihomo/config.yaml"

if grep -q "url: https://example.com/api" "$config_file" 2>/dev/null; then
    divider
    msg "$(i18n "subscription_config")"
    divider

    # 使用通用的 UI 文本输入接口（termux/text/回退由库统一处理）
    subscription_url=$(text_input "$(i18n "subscription_config")" "$(i18n "input_subscription")" "https://example.com/api")

    case "$subscription_url" in
        ""|"https://example.com/api")
            msg "$(i18n "using_default")"
            ;;
        *)
            # 尝试写入订阅 URL：成功显示保存提示，否则提示手动编辑
            if config_set_subscription_url "$config_file" "$subscription_url"; then
                msg "$(i18n "config_saved")"
            else
                msg "$(i18n "input_failed") $config_file"
                msg "$(i18n "manual_edit_hint")"
            fi
            ;;
    esac

    divider
fi

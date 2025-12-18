#!/system/bin/sh
# shellcheck shell=ash
# =============================================================================
# MagicNet 启动脚本 - 订阅链接配置
# =============================================================================

# 加载 KAM 工具
MODDIR="${0%/*}"
. "$MODDIR/lib/kam-utils.sh"

# 加载必要模块
kam_load ui termux debug

# 设置 i18n
set_i18n "subscription_config" "zh" "订阅链接配置" "en" "Subscription Configuration" "ja" "サブスクリプション設定" "ko" "구독 설정"
set_i18n "input_subscription" "zh" "请输入您的订阅链接" "en" "Please enter your subscription URL" "ja" "サブスクリプションURLを入力してください" "ko" "구독 URL을 입력하세요"
set_i18n "config_saved" "zh" "配置已保存" "en" "Configuration saved" "ja" "設定を保存しました" "ko" "구성이 저장되었습니다"
set_i18n "using_default" "zh" "使用默认配置" "en" "Using default configuration" "ja" "デフォルト設定を使用" "ko" "기본 구성 사용"

# 检查是否已经配置过
config_file="$MODDIR/mihomo/config.yaml"
if grep -q "url: https://example.com/api" "$config_file" 2>/dev/null; then
    # 还未配置，显示配置界面
    divider
    msg "$(i18n "subscription_config")"
    divider
    
    # 尝试使用 Termux API 获取订阅链接
    if command -v termux-dialog >/dev/null 2>&1; then
        # 检查 Termux API 是否可用
        if timeout 2 termux-battery-status >/dev/null 2>&1; then
            # Termux API 可用，弹出输入框
            subscription_url=$(termux_text_input "$(i18n "subscription_config")" "$(i18n "input_subscription")" "https://example.com/api")
            
            if [ -n "$subscription_url" ] && [ "$subscription_url" != "https://example.com/api" ]; then
                # 使用 yq 更新配置文件
                if command -v yq >/dev/null 2>&1; then
                    yq e ".proxy-providers.myclash.url = \"$subscription_url\"" -i "$config_file"
                    msg "$(i18n "config_saved")"
                else
                    # 备用方案：使用 sed
                    sed -i "s|url: https://example.com/api|url: $subscription_url|g" "$config_file"
                    msg "$(i18n "config_saved")"
                fi
            else
                msg "$(i18n "using_default")"
            fi
        else
            msg "⚠️ Termux:API 未运行，使用默认配置"
            msg "请稍后手动编辑配置文件：$config_file"
        fi
    else
        msg "⚠️ Termux:API 未安装，使用默认配置"
        msg "请安装 Termux:API 并重启设备"
    fi
    
    divider
fi

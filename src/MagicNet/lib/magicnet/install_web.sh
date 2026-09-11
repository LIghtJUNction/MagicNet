# shellcheck shell=ash
# Installation-only adapter. No subscription download or network-rule changes.
set_i18n INSTALL_WEB_OPEN \
    zh '正在打开订阅配置页；保存后继续安装，也可以稍后配置。' \
    en 'Opening subscription setup. Save to continue, or choose Later.' \
    ru 'Открывается настройка подписки. Сохраните ссылку или выберите «Позже».' \
    ja '購読設定を開きます。保存するか「後で」を選んでください。' \
    ko '구독 설정을 엽니다. 저장하거나 나중에 설정하세요.'
set_i18n INSTALL_WEB_SAVED \
    zh '订阅已保存。安装完成后重启设备。' \
    en 'Subscription saved. Reboot after installation.' \
    ru 'Подписка сохранена. Перезагрузите устройство после установки.' \
    ja '購読を保存しました。インストール後に再起動してください。' \
    ko '구독을 저장했습니다. 설치 후 재부팅하세요.'
set_i18n INSTALL_WEB_LATER \
    zh '已跳过或等待超时。之后可在模块 WebUI 中配置订阅。' \
    en 'Skipped or timed out. Configure a subscription later in the module WebUI.' \
    ru 'Пропущено или время истекло. Подписку можно настроить в WebUI модуля.' \
    ja 'スキップまたは時間切れです。後でモジュールの WebUI から設定できます。' \
    ko '건너뛰었거나 시간이 초과되었습니다. 모듈 WebUI에서 나중에 설정하세요.'
set_i18n INSTALL_WEB_UNAVAILABLE \
    zh '未能完成浏览器配置。安装继续；请稍后在模块 WebUI 中配置订阅。' \
    en 'Browser setup was unavailable. Installation continues; configure a subscription in the module WebUI.' \
    ru 'Настройка в браузере недоступна. Установка продолжится; используйте WebUI модуля.' \
    ja 'ブラウザー設定を完了できませんでした。インストール後に WebUI で設定してください。' \
    ko '브라우저 설정을 완료하지 못했습니다. 설치 후 모듈 WebUI에서 설정하세요.'

magicnet_install_has_subscription() (
    dir="$MODPATH/.config/sing-box"
    # Local imports and explicit standalone configurations must not be replaced.
    [ ! -s "$dir/subscription.local" ] || exit 0
    if [ -f "$dir/standalone-config" ] && [ -s "$dir/config.json" ]; then exit 0; fi
    [ -f "$dir/subscription.url" ] || exit 1
    awk '
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
        /^https:\/\/[^[:space:]]+/ { found=1; exit }
        END { exit found ? 0 : 1 }
    ' "$dir/subscription.url"
)

# Package the framework extension without depending on upstream write access.
# Apply only to the newly installed module, after the main ZIP extraction.
magicnet_install_stage_web_input() (
    dir="$MODPATH/lib/kamfw"
    for path in "$MODPATH/lib" "$dir" "$MODPATH/lib/kamfw-web"; do
        [ -d "$path" ] && [ ! -L "$path" ] || exit 1
    done
    stage=$(mktemp -d "$dir/.web-input-ext.XXXXXX") || exit 1
    trap 'rm -rf "$stage"' 0
    trap 'exit 1' 1 2 3 15
    for name in launcher web_input web_input_handler; do
        [ -f "$MODPATH/lib/kamfw-web/$name.sh" ] &&
            [ ! -L "$MODPATH/lib/kamfw-web/$name.sh" ] &&
            [ ! -L "$dir/$name.sh" ] || exit 1
        cp "$MODPATH/lib/kamfw-web/$name.sh" "$stage/$name.sh" &&
            chmod 644 "$stage/$name.sh" || exit 1
    done
    for name in launcher web_input web_input_handler; do
        mv -f "$stage/$name.sh" "$dir/$name.sh" || exit 1
    done
)

magicnet_install_collect_subscription() (
    # A module-manager install has no TTY. Do not gate browser setup on IS_TTY.
    [ "${BOOTMODE:-true}" != false ] || exit 0
    [ "${MAGICNET_NONINTERACTIVE:-0}" != 1 ] || exit 0
    [ "${MAGIC_SINGBOX:-1}" != 0 ] || exit 0
    magicnet_install_has_subscription && exit 0
    # Recovery/headless environments must never wait for a browser.
    command -v am >/dev/null 2>&1 || exit 0
    for path in "$MODPATH/.config" "$MODPATH/.config/sing-box"; do
        [ ! -L "$path" ] || exit 1
    done
    mkdir -p "$MODPATH/.config/sing-box" || exit 1
    magicnet_install_stage_web_input || exit 1
    import web_input || exit 1
    print "$(i18n INSTALL_WEB_OPEN)"
    rc=0
    web_input_collect "$MODPATH/setup" "$MODPATH/.config/sing-box/subscription.url" \
        "${MAGICNET_SETUP_TIMEOUT:-180}" "$MODPATH/lib/magicnet/install_subscription_validate.sh" || rc=$?
    case "$rc" in
        0) print "$(i18n INSTALL_WEB_SAVED)" ;;
        2 | 3) print "$(i18n INSTALL_WEB_LATER)" ;;
        *) exit 1 ;;
    esac
)

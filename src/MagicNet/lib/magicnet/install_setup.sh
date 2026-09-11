# shellcheck shell=ash
# Called only after migration and the release template have been installed.
set_i18n INSTALL_SETUP_OPEN \
    zh '首次配置：正在打开系统默认浏览器。' \
    en 'First-time setup: opening your default browser.' \
    ru 'Первичная настройка: открываем браузер по умолчанию.' \
    ja '初回設定：既定のブラウザーを開いています。' \
    ko '첫 설정: 기본 브라우저를 여는 중입니다.'
set_i18n INSTALL_SETUP_WAIT \
    zh '请填写订阅或选择稍后配置，最多等待 $_1 秒。未打开时可手动访问下方完整地址，不要分享。' \
    en 'Add a subscription or choose Later within $_1 seconds. If needed, open the complete address below manually; do not share it.' \
    ru 'Добавьте подписку или выберите «Позже» в течение $_1 сек. При необходимости откройте полный адрес ниже. Не делитесь им.' \
    ja '$_1 秒以内に購読を入力するか、あとで設定を選んでください。必要なら下の完全な URL を開いてください。共有しないでください。' \
    ko '$_1초 안에 구독을 입력하거나 나중에 설정을 선택하세요. 필요하면 아래 전체 주소를 여세요. 공유하지 마세요.'
set_i18n INSTALL_SETUP_SAVED \
    zh '订阅链接已保存；完成安装并重启后导入。' \
    en 'Subscription saved. Finish installation and reboot to import it.' \
    ru 'Подписка сохранена. Завершите установку и перезагрузите устройство для импорта.' \
    ja '購読を保存しました。インストール完了後、再起動すると取り込みます。' \
    ko '구독을 저장했습니다. 설치를 마치고 재부팅하면 가져옵니다.'
set_i18n INSTALL_SETUP_LATER \
    zh '继续安装。稍后可在模块 WebUI 配置订阅，或执行 cli setup <订阅链接>。' \
    en 'Installation continues. Configure the subscription later in the module WebUI or with cli setup <subscription-url>.' \
    ru 'Установка продолжается. Настройте подписку позже в WebUI модуля или командой cli setup <URL-подписки>.' \
    ja 'インストールを続行します。あとで WebUI または cli setup <購読URL> から設定できます。' \
    ko '설치를 계속합니다. 나중에 모듈 WebUI 또는 cli setup <구독URL>로 설정하세요.'
set_i18n INSTALL_SETUP_UNAVAILABLE \
    zh '本地配置页不可用（浏览器、BusyBox CGI 或系统权限）。未更改现有配置，也未放宽系统安全策略。' \
    en 'Local setup is unavailable (browser, BusyBox CGI, or system permissions). Existing configuration and security policies were not changed.' \
    ru 'Локальная настройка недоступна: браузер, BusyBox CGI или разрешения системы. Конфигурация и политики безопасности не изменены.' \
    ja 'ローカル設定ページを利用できません（ブラウザー、BusyBox CGI、または権限）。既存設定やセキュリティーポリシーは変更していません。' \
    ko '로컬 설정 페이지를 사용할 수 없습니다(브라우저, BusyBox CGI 또는 권한). 기존 설정이나 보안 정책은 변경하지 않았습니다.'
set_i18n INSTALL_SETUP_NOTICE \
    zh '点击填写订阅链接' en 'Tap to add your subscription' \
    ru 'Нажмите, чтобы добавить подписку' ja 'タップして購読リンクを入力' ko '눌러서 구독 링크 입력'
set_i18n INSTALL_SETUP_CLOSED \
    zh '本次配置入口已关闭，请返回安装器查看结果。' \
    en 'This setup link has closed. Return to the installer for the result.' \
    ru 'Сеанс настройки завершён. Посмотрите результат в установщике.' \
    ja '設定ページを終了しました。インストーラーで結果を確認してください。' \
    ko '설정 페이지가 종료되었습니다. 설치 프로그램에서 결과를 확인하세요.'

magicnet_install_setup() (
    set +x
    # GUI installs normally have no TTY. Only explicit unattended mode, recovery,
    # and a disabled core suppress this browser-based interaction.
    [ "${BOOTMODE:-false}" = true ] || return 0
    [ "${MAGICNET_NONINTERACTIVE:-0}" != 1 ] || return 0
    [ "${MAGICNET_SETUP:-1}" != 0 ] || return 0
    [ "${MAGIC_SINGBOX:-1}" != 0 ] || return 0
    _setup_dir="${MODPATH}/.config/sing-box"
    # Local imports and standalone configurations are valid alternatives to URLs.
    for _setup_input in subscription.url subscription.local; do
        [ ! -s "$_setup_dir/$_setup_input" ] || return 0
    done
    [ ! -f "$_setup_dir/standalone-config" ] || return 0
    if ! command -v am >/dev/null 2>&1 || ! import web_form; then
        warn "$(i18n INSTALL_SETUP_UNAVAILABLE)"
        info "$(i18n INSTALL_SETUP_LATER)"
        return 0
    fi
    web_form_ready() {
        info "$(i18n INSTALL_SETUP_WAIT | t "$2")"
        # print is console-only; do not put this temporary capability in kam.log.
        print "$1"
    }
    KAM_WEB_FORM_HTTPS_ONLY=1
    KAM_WEB_FORM_NOTICE_TITLE=MagicNet
    KAM_WEB_FORM_NOTICE_TEXT=$(i18n INSTALL_SETUP_NOTICE)
    KAM_WEB_FORM_NOTICE_DONE=$(i18n INSTALL_SETUP_CLOSED)
    info "$(i18n INSTALL_SETUP_OPEN)"
    _setup_rc=0
    web_form_collect_url "${MODPATH}/lib/magicnet/setup" \
        "$_setup_dir/subscription.url" "${MAGICNET_SETUP_TIMEOUT:-180}" || _setup_rc=$?
    case "$_setup_rc" in
        0) success "$(i18n INSTALL_SETUP_SAVED)" ;;
        5) : ;; # A concurrently supplied subscription also wins over the form.
        2|3) info "$(i18n INSTALL_SETUP_LATER)" ;;
        *) warn "$(i18n INSTALL_SETUP_UNAVAILABLE)"; info "$(i18n INSTALL_SETUP_LATER)" ;;
    esac
    return 0
)

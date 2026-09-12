# shellcheck shell=ash
# Registered through kamfw, using the installer's already selected language.
set_i18n MN_SETUP_READY \
    zh '一切就绪：订阅设置已确认，可以完成安装。' en 'All ready: subscription setup confirmed; installation can finish.' \
    ru 'Всё готово: настройки подписки подтверждены.' ja '準備完了：購読設定を確認しました。' ko '준비 완료: 구독 설정을 확인했습니다.'
set_i18n MN_SETUP_CANCELLED \
    zh '用户已停止安装。' en 'Installation stopped by the user.' \
    ru 'Установка остановлена пользователем.' ja 'インストールを中止しました。' ko '설치를 중단했습니다.'
set_i18n MN_SETUP_WAIT \
    zh '正在打开订阅配置页…' en 'Opening subscription setup…' \
    ru 'Открываем настройку подписки…' ja '購読設定を開いています…' ko '구독 설정을 여는 중…'
set_i18n MN_SETUP_OPEN \
    zh '点击填写订阅链接' en 'Tap to add your subscription' ru 'Нажмите, чтобы добавить подписку' \
    ja 'タップして購読を追加' ko '눌러서 구독 추가'
set_i18n MN_SETUP_SAVED \
    zh '订阅链接已保存。完成安装并重启后，MagicNet 会按正常启动流程加载订阅。' \
    en 'Subscription saved. Finish installing and reboot; MagicNet will load it during normal startup.' \
    ru 'Подписка сохранена. Завершите установку и перезагрузите устройство; MagicNet загрузит её при запуске.' \
    ja '購読を保存しました。インストールを完了して再起動すると、通常の起動処理で読み込みます。' \
    ko '구독을 저장했습니다. 설치를 완료하고 재부팅하면 정상 시작 과정에서 불러옵니다.'
set_i18n MN_SETUP_CLOSED \
    zh '配置入口已关闭，可在安装后通过 WebUI 配置订阅。' \
    en 'Setup link closed. You can configure the subscription in the module WebUI after installation.' \
    ru 'Временная страница закрыта. Подписку можно настроить в WebUI после установки.' \
    ja '設定リンクを閉じました。インストール後に WebUI から購読を設定できます。' \
    ko '설정 링크가 닫혔습니다. 설치 후 WebUI에서 구독을 설정할 수 있습니다.'
set_i18n MN_SETUP_UNAVAILABLE \
    zh '本地配置页不可用，安装继续；请在安装后通过 WebUI 配置订阅。未更改 SELinux 或防火墙。' \
    en 'Local setup is unavailable. Installation continues; configure the subscription in WebUI afterwards. SELinux and firewall settings are unchanged.' \
    ru 'Локальная страница недоступна. Установка продолжится; настройте подписку в WebUI. SELinux и брандмауэр не изменены.' \
    ja 'ローカル設定ページを利用できません。インストール後に WebUI で設定してください。SELinux やファイアウォールは変更していません。' \
    ko '로컬 설정 페이지를 사용할 수 없습니다. 설치 후 WebUI에서 설정하세요. SELinux와 방화벽은 변경하지 않았습니다.'

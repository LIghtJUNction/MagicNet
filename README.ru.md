# MagicNet

[简体中文](README.md) · [English](README.en.md) · [Русский](README.ru.md)

MagicNet управляет сетевым трафиком Android через [собственную версию sing-box](sing-box) с root-доступом, не занимая системное VPN-подключение. Доступны режимы `tun` и `ebpf`; по умолчанию используется `tun`.

## Возможности

- Импорт подписок по публичным HTTPS-ссылкам или из локальных файлов: Clash/Mihomo YAML, base64, ссылки на узлы, sing-box JSON и обычный текст. Поддерживается до пяти источников URL.
- Настройка политик Proxy, Direct и Bypass для приложений, а также правил Wi-Fi и точки доступа.
- Управление подписками и группами прокси, проверка задержки узлов, просмотр трафика и диагностики через WebUI.
- Явное переключение между TUN и eBPF с откатом при ошибке. TUN использует `magicnet0`; eBPF сообщает о доступных возможностях, cgroup и подключениях TC.
- Управление через CLI и дополнительный MCP-сервер с аутентификацией.

## Установка и настройка

1. Скачайте ZIP модуля из раздела [Releases](https://github.com/LIghtJUNction/MagicNet/releases), установите его через Magisk, KernelSU или APatch и перезагрузите устройство.
2. Отключите **Частный DNS / Private DNS** в настройках Android. Не оставляйте режим «Автоматически».
3. Откройте WebUI модуля в менеджере root-доступа. На странице подписок добавьте разрешённую вам ссылку или импортируйте локальный файл подписки.
4. Сохраните и активируйте подписку. На странице состояния убедитесь, что sing-box и выбранный режим сети работают.

Настройку и проверку также можно выполнить в терминале с root-доступом:

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
```

В режиме TUN должен появиться интерфейс `magicnet0`. В режиме eBPF проверяйте состояние local cgroup и shared TC/interface; наличие `magicnet0` не требуется. Обработка трафика точки доступа может оставаться в состоянии pending, пока не появится подходящий интерфейс.

MagicNet не предоставляет подписки, прокси-узлы или внешний доступ к сети. Используйте ресурсы, к которым у вас есть разрешённый доступ.

## Языки

WebUI поддерживает упрощённый китайский, английский и русский языки. Выберите язык в интерфейсе; выбор сохраняется в браузере.

Руководство по установке и меню действий модуля поддерживают русский и английский языки, а также сохраняют имеющиеся переводы на китайский, японский и корейский. По умолчанию используется язык Android. При интерактивной установке из терминала доступен выбор языка. Для однократного запуска меню на русском:

```bash
su -c 'KAM_UI_LANGUAGE=ru sh /data/adb/modules/MagicNet/action.sh'
```

Для английского используйте `en`. Это меняет язык интерфейса MagicNet, сохраняя системный язык Android. Команды CLI, поля состояния для программ, значения конфигурации и исходные журналы сохраняют прежний формат. Встроенная сторонняя панель ядра использует собственные языковые настройки.

## Основные команды

```bash
su -c /data/adb/modules/MagicNet/cli sub status
su -c /data/adb/modules/MagicNet/cli sub update sing-box
su -c /data/adb/modules/MagicNet/cli node test-all
su -c /data/adb/modules/MagicNet/cli service restart sing-box
su -c /data/adb/modules/MagicNet/cli transparent set tun
su -c /data/adb/modules/MagicNet/cli transparent set ebpf
su -c /data/adb/modules/MagicNet/cli diagnose
su -c /data/adb/modules/MagicNet/cli support bundle
```

Примеры политик приложений:

```bash
su -c '/data/adb/modules/MagicNet/cli app add com.example.app proxy'
su -c '/data/adb/modules/MagicNet/cli app add com.example.browser direct'
su -c '/data/adb/modules/MagicNet/cli app add com.example.vpn bypass'
```

## Разработка и документация

```bash
git clone https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init
kam build
```

Для сборки требуется [kam](https://github.com/MemDeco-WG/kamfw). Подробная документация пока доступна на китайском: [руководство пользователя](docs/user-guide.md), [MCP](docs/mcp.md) и [Tailscale](docs/tailscale.md).

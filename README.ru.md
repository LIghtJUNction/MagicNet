# MagicNet

[简体中文](README.md) · [English](README.en.md) · [Русский](README.ru.md)

<a href="https://donate.lmm.best/?project=magicnet"><img src="https://donate.lmm.best/badge.svg?project=magicnet&amp;currency=CNY&amp;lang=en&amp;period=all&amp;layout=compact&amp;theme=dark&amp;width=360&amp;title=MagicNet" alt="Поддержать проект" width="360" /></a>

**Простой и надёжный прозрачный прокси на sing-box для Android с root-доступом.**

Надоело, что прокси-приложение занимает единственный VPN-слот Android? MagicNet работает на уровне системы через Magisk, KernelSU или APatch и использует [нашу собственную версию sing-box](sing-box), поэтому VPN-слот остаётся свободным. Вы сами решаете, какие приложения идут через прокси, какие напрямую, что делать в домашней Wi-Fi-сети и как обрабатывать клиентов точки доступа.

Есть два прозрачных режима, и переключаете их вы сами:

- **`tun` (по умолчанию)** создаёт виртуальный интерфейс `magicnet0`. Надёжный и совместимый вариант, которого хватает большинству пользователей.
- **`ebpf`** направляет трафик с помощью хуков в ядре. Для тех, кто любит экспериментировать и чьё ядро это поддерживает.

Переключение атомарное и при ошибке откатывается, так что вы не останетесь без сети на полпути.

## Что вы получаете

- **Подходит ваша текущая подписка.** Публичные HTTPS-ссылки (до пяти источников) или локальные файлы: Clash/Mihomo YAML, base64, ссылки на узлы, sing-box JSON и обычный текст. Искать отдельную «подписку для sing-box» не нужно.
- **Политики для приложений, Wi-Fi и точки доступа.** Для каждого приложения можно выбрать Proxy, Direct или Bypass, автоматически менять политику в зависимости от Wi-Fi-сети и выбрать Direct или Proxy для клиентов точки доступа.
- **Понятный WebUI.** Подписки, группы прокси, задержка узлов, трафик и диагностика собраны в одном месте. На обзорной странице живое «созвездие» показывает путь трафика (устройство → плоскость данных → sing-box → выход), причём только по подтверждённому состоянию. `Ctrl/⌘ + K` или `/` открывает быстрый переход.
- **Честное состояние.** TUN проверяется по `magicnet0`, eBPF — по доступным возможностям, cgroup и подключениям TC. Если что-то не удаётся подтвердить, MagicNet так и сообщает, а не делает вид, что всё в порядке.
- **Автоматизация по желанию.** CLI и дополнительный MCP-сервер с аутентификацией выполняют те же операции, что и WebUI.

## Запуск за пять минут

1. Скачайте ZIP модуля из раздела [Releases](https://github.com/LIghtJUNction/MagicNet/releases), установите его через Magisk, KernelSU или APatch и перезагрузите устройство.
2. Отключите **Частный DNS / Private DNS** в настройках Android. Режим «Автоматически» не подходит: DNS нужно именно выключить.
3. Откройте WebUI модуля в менеджере root-доступа. На странице подписок добавьте ссылку, которой вам разрешено пользоваться, или импортируйте локальный файл подписки.
4. Сохраните и активируйте подписку, затем загляните на страницу состояния. Если sing-box и выбранный режим сети работают, всё готово.

Предпочитаете терминал? Достаточно трёх строк в root-оболочке:

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
```

В режиме TUN должен появиться интерфейс `magicnet0`. В режиме eBPF этого интерфейса не бывает, поэтому проверяйте состояние local cgroup и shared TC/interface. Обработка трафика точки доступа может оставаться в состоянии pending, пока не появится подходящий интерфейс, и это нормально.

> MagicNet — всего лишь инструмент. Он не предоставляет подписки, прокси-узлы или внешний доступ к сети. Используйте только те ресурсы, к которым у вас есть разрешённый доступ.

## Языки

WebUI поддерживает упрощённый китайский, английский и русский языки. Выберите язык в интерфейсе, и браузер его запомнит.

Руководство по установке и меню действий модуля поддерживают русский и английский языки, а также имеющиеся переводы на китайский, японский и корейский. По умолчанию используется язык Android, а при интерактивной установке из терминала можно выбрать язык вручную. Для однократного запуска меню на русском:

```bash
su -c 'KAM_UI_LANGUAGE=ru sh /data/adb/modules/MagicNet/action.sh'
```

Для английского используйте `en`. Меняется только язык интерфейса MagicNet, системный язык Android остаётся прежним. Команды CLI, поля состояния для программ, значения конфигурации и исходные журналы сохраняют исходный формат, чтобы скрипты не ломались. Встроенная сторонняя панель ядра использует собственные языковые настройки.

## Полезные команды

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

Примеры политик приложений. Если нужно просто «не проксировать», выбирайте `direct`; `bypass` оставьте для приложений, которые должны работать вместе с другим VPN:

```bash
su -c '/data/adb/modules/MagicNet/cli app add com.example.app proxy'
su -c '/data/adb/modules/MagicNet/cli app add com.example.browser direct'
su -c '/data/adb/modules/MagicNet/cli app add com.example.vpn bypass'
```

## Сборка из исходников

```bash
git clone https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init
kam build
```

Для сборки требуется [kam](https://github.com/MemDeco-WG/kamfw). Подробная документация пока есть только на китайском, извините: [руководство пользователя](docs/user-guide.md), [MCP](docs/mcp.md) и [Tailscale](docs/tailscale.md).

Есть вопросы или просто хотите пообщаться? Заходите в наш [Discord](https://discord.gg/asRwgK9FpA).

export default {
  "连接状态未确认": ["Connection state unconfirmed", "Состояние подключения не подтверждено"],
  "已禁用，登出待完成": ["Disabled · logout incomplete", "Отключено · выход не завершён"],
  "Tailscale 已启用": ["Tailscale enabled", "Tailscale включён"],
  "Tailscale 已暂停": ["Tailscale paused", "Tailscale приостановлен"],
  "Tailscale 未启用": ["Tailscale not enabled", "Tailscale не включён"],
  "读取连接状态": ["Refresh connection", "Обновить состояние"],
  "更新 Tailscale 连接": ["Update Tailscale connection", "Изменить подключение Tailscale"],
  "操作未完整完成，已重新读取状态。请检查诊断后重试。": ["The operation did not fully complete. State has been refreshed; check diagnostics before retrying.", "Операция завершена не полностью. Состояние обновлено; проверьте диагностику перед повтором."],
  "已登出此设备。再次连接需要重新授权。": ["Signed out of this device. Connecting again requires authorization.", "Вы вышли на этом устройстве. Для нового подключения потребуется авторизация."],
  "已禁用 Tailscale，登录信息保留。": ["Tailscale disabled. Your login is preserved.", "Tailscale отключён. Данные входа сохранены."],
  "已恢复配置，核心保持关闭。": ["Configuration restored; the core remains stopped.", "Настройки восстановлены; ядро остаётся остановленным."],
  "已恢复配置，正在检查连接。": ["Configuration restored. Checking the connection.", "Настройки восстановлены. Проверяем подключение."],
  "未能确认操作结果，请重新读取状态。不要重复授权。": ["The result could not be confirmed. Refresh the state instead of authorizing again.", "Не удалось подтвердить результат. Обновите состояние, не выполняя повторную авторизацию."],
  "登录信息保留，随时可以恢复。": ["Your login is preserved. Resume any time.", "Данные входа сохранены. Можно возобновить подключение."],
  "按需连接你的设备。": ["Connect your devices when needed.", "Подключайте свои устройства по необходимости."],
  "禁用 Tailscale": ["Disable Tailscale", "Отключить Tailscale"],
  "恢复连接": ["Resume connection", "Возобновить подключение"],
  "禁用只暂停连接，不会登出账号。": ["Disabling pauses the connection without signing out.", "Отключение приостанавливает подключение без выхода из аккаунта."],
  "核心当前关闭，修改不会自动启动核心。": ["The core is stopped. Changes will not start it automatically.", "Ядро остановлено. Изменения не запустят его автоматически."],
  "本机身份清理尚未完成，不能恢复旧登录。请重试登出。": ["Local identity cleanup is incomplete. Retry logout before reconnecting.", "Очистка локальных данных входа не завершена. Повторите выход перед подключением."],
  "登出此设备": ["Sign out of this device", "Выйти на этом устройстве"],
  "登出此设备？": ["Sign out of this device?", "Выйти на этом устройстве?"],
  "停止本机 Tailscale 并清除本机登录信息。云端设备记录保留，可在设备后台删除。": ["Stop local Tailscale and remove local login data. The cloud device record remains; remove it in the device console.", "Остановить Tailscale и удалить локальные данные входа. Запись устройства в облаке останется; её можно удалить в консоли устройств."],
  "确认登出": ["Confirm sign out", "Подтвердить выход"],
  "停止等待": ["Stop waiting", "Прекратить ожидание"],
  "Tailscale 已登录，正在等待网络上线。": ["Tailscale is logged in; waiting for the network to come online.", "Вход в Tailscale выполнен; ожидание подключения к сети."],
  "登录 Tailscale 并自动配置": ["Log in to Tailscale and configure automatically", "Войти в Tailscale и настроить автоматически"],
  "继续 Tailscale 登录": ["Continue Tailscale login", "Продолжить вход в Tailscale"],
  "刷新登录状态": ["Refresh login status", "Обновить статус входа"],
  "Tailscale 已登录，正由 sing-box 连接。配置已自动生效。": ["Tailscale is logged in and connected through sing-box. Configuration is active.", "Вход в Tailscale выполнен, подключение через sing-box. Настройки применены."],
  "等待 Tailscale 登录授权，请在浏览器完成后返回。": ["Complete Tailscale authorization in your browser, then return here.", "Завершите авторизацию Tailscale в браузере и вернитесь сюда."],
  "暂时无法读取 Tailscale 登录状态，请稍后刷新。": ["Tailscale login status is temporarily unavailable. Refresh shortly.", "Статус входа Tailscale временно недоступен. Обновите его позже."],
  "Tailscale": [
    "Tailscale",
    "Tailscale"
  ],
  "设备名称需为 1–63 位字母、数字或短横线，首尾不能是短横线。": [
    "Use 1–63 letters, digits or hyphens, with no leading or trailing hyphen.",
    "Используйте 1–63 буквы, цифры или дефисы, без дефиса в начале и конце."
  ],
  "请填写以 tskey-auth- 开头的 Tailscale Auth key。": [
    "Enter a Tailscale auth key beginning with tskey-auth-.",
    "Введите ключ Tailscale, начинающийся с tskey-auth-."
  ],
  "检测到多个 Tailscale 节点，请使用配置编辑器管理，避免修改错误的网络。": [
    "Multiple Tailscale endpoints found. Use the config editor to avoid changing the wrong network.",
    "Обнаружено несколько узлов Tailscale. Используйте редактор конфигурации, чтобы не изменить другую сеть."
  ],
  "当前节点使用自建控制服务器，此入口不会覆盖它或向它发送 Tailscale 密钥。": [
    "This endpoint uses a custom control server. This form will not overwrite it or send it a Tailscale key.",
    "Этот узел использует собственный сервер управления. Форма не изменит его и не отправит ему ключ Tailscale."
  ],
  "配置已在其他位置修改，请重新读取后再保存。": [
    "Configuration changed elsewhere. Reload it before saving.",
    "Конфигурация изменена в другом месте. Загрузите её заново перед сохранением."
  ],
  "无法读取有效的 sing-box 配置，请先检查核心配置。": [
    "Could not read a valid sing-box configuration. Check the core configuration first.",
    "Не удалось прочитать корректную конфигурацию sing-box. Проверьте конфигурацию ядра."
  ],
  "配置已保存，核心已重启。请在设备后台确认授权和在线状态。": [
    "Configuration saved and core restarted. Confirm authorization and online status in the device console.",
    "Конфигурация сохранена, ядро перезапущено. Проверьте авторизацию и состояние устройства в консоли."
  ],
  "配置已保存，但核心重启失败。可重试重启，无需再次填写密钥。": [
    "Configuration saved, but the core restart failed. Retry restarting without entering the key again.",
    "Конфигурация сохранена, но перезапуск ядра не удался. Повторите перезапуск без повторного ввода ключа."
  ],
  "配置已保存，但私密临时文件清理未确认，未重启核心。": [
    "Configuration saved, but private temporary-file cleanup was not confirmed. The core was not restarted.",
    "Конфигурация сохранена, но удаление приватного временного файла не подтверждено. Ядро не перезапущено."
  ],
  "私密临时文件清理未确认，请检查设备状态后重试。": [
    "Private temporary-file cleanup was not confirmed. Check the device before retrying.",
    "Удаление приватного временного файла не подтверждено. Проверьте устройство перед повторной попыткой."
  ],
  "私密数据传输失败，配置未保存。": [
    "Private payload transfer failed. Configuration was not saved.",
    "Не удалось передать приватные данные. Конфигурация не сохранена."
  ],
  "配置保存未确认，未重启。请检查内核是否支持 Tailscale。": [
    "Saving was not confirmed; no restart was attempted. Check whether the core supports Tailscale.",
    "Сохранение не подтверждено; перезапуск не выполнялся. Проверьте поддержку Tailscale в ядре."
  ],
  "读取 Tailscale 配置": [
    "Read Tailscale configuration",
    "Чтение конфигурации Tailscale"
  ],
  "正在校验并接入 Tailscale…": [
    "Validating and setting up Tailscale…",
    "Проверка и настройка Tailscale…"
  ],
  "配置 Tailscale": [
    "Configure Tailscale",
    "Настройка Tailscale"
  ],
  "Tailscale 私密配置": [
    "Private Tailscale configuration",
    "Приватная конфигурация Tailscale"
  ],
  "Tailscale 已更新，请重新加载配置。": [
    "Tailscale updated. Reload the configuration.",
    "Tailscale обновлён. Загрузите конфигурацию заново."
  ],
  "请在支持 KernelSU 异步接口的真机 WebUI 中接入。": [
    "Connect from the device WebUI with KernelSU asynchronous bridge support.",
    "Подключайтесь через WebUI устройства с поддержкой асинхронного интерфейса KernelSU."
  ],
  "连接你的设备": [
    "Connect your devices",
    "Подключите свои устройства"
  ],
  "使用自己的 Tailscale 账号": [
    "Use your own Tailscale account",
    "Используйте свой аккаунт Tailscale"
  ],
  "配置编辑器还有未保存的修改，请先处理后再接入。": [
    "Resolve unsaved changes in the configuration editor before connecting.",
    "Сначала сохраните или отмените изменения в редакторе конфигурации."
  ],
  "设备名称": [
    "Device name",
    "Имя устройства"
  ],
  "获取密钥": [
    "Get an auth key",
    "Получить ключ"
  ],
  "留空保留当前登录。新密钥不会自动切换已登录账号。": [
    "Leave blank to keep the existing login. A new key does not switch an already signed-in account.",
    "Оставьте пустым для сохранения текущего входа. Новый ключ не переключает уже авторизованный аккаунт."
  ],
  "使用你账号生成的 Auth key，不要使用 API access token。": [
    "Use an auth key from your account, not an API access token.",
    "Используйте ключ авторизации своего аккаунта, а не токен доступа API."
  ],
  "节点标识": [
    "Endpoint tag",
    "Метка узла"
  ],
  "控制服务器": [
    "Control server",
    "Сервер управления"
  ],
  "接入并重启": [
    "Connect and restart",
    "Подключить и перезапустить"
  ],
  "放弃修改并重新读取": [
    "Discard changes and reload",
    "Отменить изменения и загрузить заново"
  ],
  "重启会短暂中断现有连接。配置保留在本机。": [
    "Restarting briefly interrupts existing connections. Configuration stays on this device.",
    "Перезапуск ненадолго прервёт текущие соединения. Конфигурация остаётся на устройстве."
  ],
  "设备后台": [
    "Device console",
    "Консоль устройств"
  ],
  "重试重启核心": [
    "Retry core restart",
    "Повторить перезапуск ядра"
  ],
  "重启核心": [
    "Restart core",
    "Перезапустить ядро"
  ],
  "已配置": [
    "Configured",
    "Настроено"
  ],
  "未配置": [
    "Not configured",
    "Не настроено"
  ],
  "高级选项": [
    "Advanced",
    "Дополнительно"
  ],
  "网页授权登录（推荐）": [
    "Web authorization login (Recommended)",
    "Авторизация через веб (Рекомендуется)"
  ],
  "Auth Key 密钥接入": [
    "Auth key connection",
    "Подключение по Auth key"
  ],
  "使用手机或其他设备扫码即可完成授权": [
    "Scan the QR code with your phone or another device to authorize",
    "Отсканируйте QR-код телефоном или другим устройством для авторизации"
  ],
  "复制授权链接": [
    "Copy auth link",
    "Скопировать ссылку авторизации"
  ],
  "已复制授权链接": [
    "Auth link copied",
    "Ссылка авторизации скопирована"
  ],
  "取消授权": [
    "Cancel authorization",
    "Отменить авторизацию"
  ],
  "已取消登录等待。": [
    "Login authorization cancelled.",
    "Ожидание авторизации отменено."
  ],
  "断开并移除节点": [
    "Disconnect and remove endpoint",
    "Отключить и удалить узел"
  ],
  "正在移除 Tailscale 节点并重启核心…": [
    "Removing Tailscale endpoint and restarting core…",
    "Удаление узла Tailscale и перезапуск ядра…"
  ],
  "Tailscale 节点已移除，核心已重启。": [
    "Tailscale endpoint removed and core restarted.",
    "Узел Tailscale удалён, ядро перезапущено."
  ],
  "移除 Tailscale": [
    "Remove Tailscale",
    "Удалить Tailscale"
  ],
  "节点状态": [
    "Node status",
    "Статус узла"
  ],
  "已连接并在线": [
    "Connected and online",
    "Подключено и в сети"
  ],
  "等待网页授权": [
    "Waiting for web authorization",
    "Ожидание веб-авторизации"
  ],
  "支持一键网页登录或使用其他设备扫码快速授权上线。": [
    "Supports one-click browser login or QR code scanning from another device.",
    "Поддержка входа через браузер в один клик или сканирования QR-кода."
  ],
  "也可以直接填入从 Tailscale 控制台生成的预授权 Auth key。": [
    "Or provide a pre-authenticated Auth key from your Tailscale console.",
    "Или укажите ключ Auth key из панели управления Tailscale."
  ]
} satisfies Record<string, readonly string[]>;

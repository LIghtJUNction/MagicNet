export default {
  "覆写已生成，服务保持停止状态。": ["Overrides materialized. The service remains stopped.", "Переопределения подготовлены. Сервис остаётся остановленным."],
  "覆写已生成，运行状态待确认。": ["Overrides materialized. Runtime status is unconfirmed.", "Переопределения подготовлены. Состояние сервиса не подтверждено."],
  "已复制草稿": ["Draft copied", "Черновик скопирован"],
  "复制草稿": ["Copy draft", "Скопировать черновик"],
  "复制失败，请手动选择并复制编辑器内容。": ["Copy failed. Select and copy the editor text manually.", "Не удалось скопировать. Выделите и скопируйте текст редактора вручную."],
  "重新读取会丢弃未保存的草稿。": ["Reloading will discard your unsaved draft.", "Повторная загрузка удалит несохранённый черновик."],
  "保留草稿": ["Keep draft", "Сохранить черновик"],
  "放弃草稿并重新读取": ["Discard draft and reload", "Удалить черновик и загрузить заново"],
  "配置编辑方式": ["Configuration editor mode", "Режим редактора конфигурации"],
  "完整配置": ["Full configuration", "Полная конфигурация"],
  "配置覆写": [
    "Configuration overrides",
    "Переопределение конфигурации"
  ],
  "配置已被其他操作修改。请先复制你的草稿，再重新读取。": [
    "The configuration changed elsewhere. Copy your draft, then reload.",
    "Конфигурация изменена другим действием. Скопируйте черновик и загрузите её заново."
  ],
  "操作失败：{value}": [
    "Operation failed: {value}",
    "Ошибка операции: {value}"
  ],
  "已读取覆写配置": [
    "Overrides loaded",
    "Переопределения загружены"
  ],
  "校验通过，影响 {value} 个配置分区。": [
    "Validation passed; {value} configuration sections change.",
    "Проверка пройдена. Изменяется разделов конфигурации: {value}."
  ],
  "覆写已保存，等待应用。": [
    "Overrides saved; activation is pending.",
    "Переопределения сохранены и ожидают применения."
  ],
  "覆写已应用": [
    "Overrides applied",
    "Переопределения применены"
  ],
  "覆写已重置，订阅和其他设置已保留。": [
    "Overrides reset. Subscriptions and other settings were preserved.",
    "Переопределения сброшены. Подписки и остальные настройки сохранены."
  ],
  "订阅更新后仍保留你的 JSON 修改。": [
    "Keep your JSON changes across subscription updates.",
    "Сохраняйте изменения JSON при обновлении подписок."
  ],
  "等待应用": [
    "Pending activation",
    "Ожидает применения"
  ],
  "对象按字段合并，数组整体替换，null 删除字段。透明代理入口、热点策略和本地管理接口由 MagicNet 管理。": [
    "Objects merge by field, arrays are replaced, and null deletes a field. MagicNet manages transparent inbounds, hotspot policy and the local control API.",
    "Объекты объединяются по полям, массивы заменяются целиком, null удаляет поле. Прозрачные входы, политика точки доступа и локальный API управляются MagicNet."
  ],
  "覆写 JSON 编辑器": [
    "Override JSON editor",
    "Редактор JSON переопределений"
  ],
  "应用中…": [
    "Applying…",
    "Применение…"
  ],
  "校验预览": [
    "Validate preview",
    "Проверить изменения"
  ],
  "仅保存": [
    "Save only",
    "Только сохранить"
  ],
  "一键重置覆写": [
    "Reset overrides",
    "Сбросить переопределения"
  ],
  "命令输出": [
    "Command output",
    "Вывод команды"
  ],
  "从一条命令开始": [
    "Start with a command",
    "Начните с команды"
  ],
  "输入命令，或选择下方的快捷命令。": [
    "Enter a command or choose a shortcut below.",
    "Введите команду или выберите быструю команду ниже."
  ],
  "复制输出": [
    "Copy output",
    "Скопировать вывод"
  ],
  "命令执行中，正在等待输出…": [
    "Command running. Waiting for output…",
    "Команда выполняется. Ожидание вывода…"
  ],
  "命令": [
    "Command",
    "Команда"
  ],
  "输入命令…": [
    "Enter a command…",
    "Введите команду…"
  ],
  "执行": [
    "Run",
    "Выполнить"
  ],
  "补全命令": [
    "Complete command",
    "Дополнить команду"
  ],
  "上一条命令": [
    "Previous command",
    "Предыдущая команда"
  ],
  "下一条命令": [
    "Next command",
    "Следующая команда"
  ]
} satisfies Record<string, readonly string[]>;

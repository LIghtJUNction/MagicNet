# MagicNet

Управление сетью на Android с root/arm64: подписки, маршрутизация приложений и доменов, DNS, TUN/eBPF и многоязычный веб-интерфейс.

[Основное руководство](README.md) · [English](README.en.md) · [Исходники](https://github.com/LIghtJUNction/magicnet-android)

Версия рецепта: 0.3.33; текущий gitlink: `c2ccbd3e03e4757a88fc342018449676a22ca224`; текущий выпуск Android: [v1.9.1 / 10619](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.9.1). [Установка и изменения](docs/releases/v1.9.1.md).

Основной репозиторий хранит Markdown-контракты продукта; `generated/magicnet-android/` закрепляет реализацию отдельным Git-подмодулем. Начните с [требований](recipes/magicnet/BUILD_PROMPT.md), [приёмки](recipes/magicnet/ACCEPTANCE.md) и [проверок](recipes/magicnet/VERIFICATION.md). Независимое восстановление начинается в пустом каталоге и использует полный набор рецептов. Исходники, секреты и данные устройства не входят в архив рецептов.

Клонирование: `git clone --recurse-submodules https://github.com/LIghtJUNction/MagicNet.git`. В существующей копии выполните `git submodule update --init --recursive generated/magicnet-android`. Подготовьте инструменты по [руководству сборки](generated/magicnet-android/docs/build.md), затем выполните `kam build -j 2` в подмодуле. Команды проверки рецепта и создания инструкции приведены в [основном руководстве](README.md#rebuild-from-the-recipe).

[Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml) поддерживает `build`, `verify` и `publish`, повышение `patch/minor/major`, точную версию и `source_ref`. Сборка и приёмка Android используют один фиксированный коммит и версию. Стабильный индекс обновляется после проверки опубликованных файлов; предварительный выпуск его сохраняет. См. [публикацию и восстановление](docs/releasing.md).

Локальная сборка-кандидат `v1.9.1 / 10619` из исходников [`5169e071`](https://github.com/LIghtJUNction/magicnet-android/commit/5169e07155a47d16f3c5e610a8aa368cc2d08b02) проверена на одном физическом ARM64-смартфоне: обновление с сохранением настроек, HTTPS-запросы от обычного UID приложения с реальной подпиской, переходы по 14 страницам нажатие на кнопку Zashboard с загрузкой локальных узлов, а также отключение сотовой сети на 10 секунд и последующее наблюдение 180 секунд. HTTPS приложения восстановился; строгая проверка прокси сохранила endpoint_specific / degraded. Эти результаты относятся к данной сборке; более новый gitlink выше имеет отдельные результаты CI.

Более широкий охват OEM, минимальные версии Android/WebView и длительная нагрузка остаются непроверенными. [Проверки](recipes/magicnet/VERIFICATION.md) отделяют эти ограничения от завершённых тестов исходников, эмулятора и устройства. История импорта v1.8.0 и выпуска v1.8.1 сохранена в [источниках](recipes/magicnet/PROVENANCE.md).

Лицензия MagicNet — [MIT](LICENSE); сторонние компоненты сохраняют свои лицензии.

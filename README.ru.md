# MagicNet

Управление сетью на Android с root/arm64: подписки, маршрутизация приложений и доменов, DNS, TUN/eBPF и многоязычный веб-интерфейс.

[Основное руководство](README.md) · [English](README.en.md) · [Исходники](https://github.com/LIghtJUNction/magicnet-android)

Версия рецепта: 0.3.20; текущий gitlink: `47d55d2636de2a386ec5c73c63c5e8b0498c8b88`; текущий выпуск Android: [v1.8.5 / 10613](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.5). [Установка и изменения](docs/releases/v1.8.5.md).

Основной репозиторий хранит Markdown-контракты продукта; `generated/magicnet-android/` закрепляет реализацию отдельным Git-подмодулем. Начните с [требований](recipes/magicnet/BUILD_PROMPT.md), [приёмки](recipes/magicnet/ACCEPTANCE.md) и [проверок](recipes/magicnet/VERIFICATION.md). Независимое восстановление начинается в пустом каталоге и использует полный набор рецептов. Исходники, секреты и данные устройства не входят в архив рецептов.

Клонирование: `git clone --recurse-submodules https://github.com/LIghtJUNction/MagicNet.git`. В существующей копии выполните `git submodule update --init --recursive generated/magicnet-android`. Подготовьте инструменты по [руководству сборки](generated/magicnet-android/docs/build.md), затем выполните `kam build -j 2` в подмодуле. Команды проверки рецепта и создания инструкции приведены в [основном руководстве](README.md#rebuild-from-the-recipe).

[Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml) поддерживает `build`, `verify` и `publish`, повышение `patch/minor/major`, точную версию и `source_ref`. Сборка и приёмка Android используют один фиксированный коммит и версию. Стабильный индекс обновляется после проверки опубликованных файлов; предварительный выпуск его сохраняет. См. [публикацию и восстановление](docs/releasing.md).

Проверки на физическом устройстве, реальных подписках, длительной нагрузке и минимальных версиях Android/WebView остаются открытыми. История импорта v1.8.0 и выпуска v1.8.1 сохранена в [источниках](recipes/magicnet/PROVENANCE.md) и [проверках](recipes/magicnet/VERIFICATION.md). Лицензия MagicNet — [MIT](LICENSE); сторонние компоненты сохраняют свои лицензии.

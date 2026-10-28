# MagicNet

![软件与依赖汇聚为可重建的配方](https://raw.githubusercontent.com/recipkg/recipkg/main/assets/recipkg-cover.png)

Рабочая среда прозрачной сети для Android с root, описанная воспроизводимыми программными рецептами.

[简体中文](README.md) · [English](README.en.md)

Проект и основной репозиторий сохраняют название MagicNet. Основной материал — рецепты в `recipes/`. [generated/magicnet-android/](generated/magicnet-android/) — Git-подмодуль отдельного [репозитория исходников magicnet-android](https://github.com/LIghtJUNction/magicnet-android), закреплённый на конкретном коммите. Имя репозитория и каталога совпадает и использует строчные буквы и дефисы. Исходники не входят в архив рецептов и не являются зависимостью Recipkg. Материалы наблюдения хранятся отдельно; временный каталог android-reference удалён.

Начните с [главного рецепта](recipes/magicnet/BUILD_PROMPT.md), [приёмки](recipes/magicnet/ACCEPTANCE.md), [источников](recipes/magicnet/PROVENANCE.md) и [измерений](recipes/magicnet/PERFORMANCE.md). Сохраняются возможности Android root/arm64, режимы tun|ebpf и языки; агент выбирает язык реализации и обновляет внешний вид без изменения рабочих сценариев.

`recipkg check recipes/magicnet` проверяет рецепты. `pack` создаёт во временном каталоге Markdown-архив с зависимостями; затем проверьте архив и используйте `build` для полной инструкции агенту. После проверки удалите временные файлы; постоянный архив сохраняйте только по явному запросу. Это не подтверждает независимое восстановление или работу сети на устройстве. Реализация v1.8.0 доработана по новым рецептам на основе прежнего кода. Main отслеживает подмодуль исходников; прежние теги выпусков остаются в MagicNet. Проверки пакета и устройства учитываются отдельно в VERIFICATION.

Секреты остаются локальными. При публикации сохраняйте существующие topics и добавляйте recipkg. Лицензии сторонних компонентов действуют отдельно.

Для первого получения проекта используйте `git clone --recurse-submodules https://github.com/LIghtJUNction/MagicNet.git`. В существующем каталоге выполните `git submodule update --init --recursive generated/magicnet-android`, затем `cd generated/magicnet-android` и `kam build -j 2`. Сохраняйте имеющиеся локальные изменения. Нужны Rust/cargo-ndk, Android NDK, Go, Node/npm, Java/d8 и KAM; см. [инструкцию сборки](generated/magicnet-android/docs/build.md). Путь к полному локальному пакету от корня основного репозитория: `generated/magicnet-android/dist/MagicNet.zip`.

Коммит исходников `0dca28dd984d82333707cbf4b222596934b4d847` имеет то же дерево Git и шесть вложенных подмодулей, что и исходный коммит v1.8.0 `f13ca61b9c3477aee3b1380d71815c84b3a2a6bf`. Новый репозиторий начинается с этого чистого снимка; прежняя история сохраняется в MagicNet. Сначала отправляйте разрешённые изменения исходников, затем обновляйте gitlink основного репозитория. Версия рецепта: 0.2.1; версия Android: v1.8.0. [Установка и изменения](docs/releases/v1.8.0.md).

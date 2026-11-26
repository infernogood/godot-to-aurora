# Changelog

Все заметные изменения проекта `godot-to-aurora` документируются в этом файле.

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версии — [Semantic Versioning](https://semver.org/lang/ru/).
Версия кита хранится в [`versions.env`](versions.env) (`KIT_VERSION`) и печатается
любым скриптом по флагу `--version`.

## [1.1.0] — 2026-11-26

Релиз закрывает замечания code review: безопасность и предсказуемость скриптов,
корректность сборки RPM и деплоя, доработка GDScript-модулей, единая документация,
автотесты и CI.

### Added

- `versions.env` — единый источник версий (`KIT_VERSION`, `GODOT_AURORA_TAG`,
  `GODOT_TEMPLATE_VERSION`, `SDK_DEFAULT_VERSION`, `SDK_SUPPORTED_PREFIX`,
  `SCONS_VERSION`, `XKBCOMMON_VERSION`, `XKBCOMMON_KNOWN_VERSIONS` и их SHA-256).
- Флаг `--version` во всех публичных скриптах: печатает `godot-to-aurora <KIT_VERSION>`
  без `project.godot`, SDK, сети и Docker.
- Флаг `--skip-checksum` в `fetch_engine.sh` и `build_x86_64_rpm.sh` — осознанный
  отказ от проверки SHA-256; по умолчанию проверка обязательна.
- Флаг `--strict-sdk`: блокировать сборку/деплой, если установлен не SDK 5.2.x
  (по умолчанию печатается предупреждение).
- Переменные `AURORA_TEMPLATE_X86_64` / `AURORA_TEMPLATE_AARCH64` (устаревшая
  `AURORA_TEMPLATE` работает для обеих архитектур).
- Корневой `.gdignore`: Godot не сканирует кит, лежащий внутри проекта, — исчезают
  ошибка `Class "AuroraSafeArea" hides a global script class` и двойной импорт шрифтов.
- Корневой `.gitignore` кита и идемпотентное дополнение `.gitignore` целевого проекта
  (`build/`, `*.rpm`, `export_presets.cfg.bak.*`).
- `.editorconfig`, `CHANGELOG.md`, `docs/RELEASES_GUIDE.md` в актуальном виде.
- Тесты: `tests/test_cli.sh` (CLI без сети, Godot, Docker и SDK),
  `tests/test_modules.gd` (headless GDScript) и GitHub Actions
  (`.github/workflows/ci.yml`): `shellcheck`, `bash -n`, CLI-тесты, headless-прогон.
- `%changelog` в `templates/app.spec.in` и ссылка на официальную документацию по
  профилям безопасности Sailjail в `docs/SDK_5_2_ARCHITECTURE.md`.

### Changed

- Канонический путь интеграции модулей: `modules/*.gd` → `res://scripts/aurora/`,
  шрифты → `res://assets/fonts/`, один файл лицензии `LICENSE`. Пути согласованы в
  `README.md`, `AGENTS.md` и docstring'ах модулей.
- `kit exclude_filter` пополняется только `build/*` и каталогом самого кита; `tools/*`,
  `docs/*`, `tests/*`, `addons/*` больше не исключаются принудительно. Вхождение
  проверяется точным токеном, а не подстрокой.
- Пустой `AURORA_PRESET` выбирает первый существующий пресет с `platform="AuroraOS"`
  (независимо от его имени); существующий пресет не перезаписывается.
- `AGENTS.md` сокращён до компактного плейбука (процесс, инварианты, чек-лист) без
  дублирования `README.md` и `docs/SDK_5_2_ARCHITECTURE.md`; агрессивные директивы
  (физический движок, `keep_screen_on`) смягчены — такие решения согласуются с
  пользователем.
- `README.md`: единое имя проекта, пример `var ui_scale := AuroraSafeArea.ui_scale(vp)`,
  обновлённое дерево репозитория, актуальные переменные окружения и режимы сборки.
- `--jobs` по умолчанию — `$(nproc)`; контейнер сборки шаблона запускается с
  `--user "$(id -u):$(id -g)"`, поэтому артефакты не остаются root-овыми.
- Версия `libxkbcommon` определяется из образа `aurora-build-tools`, `SCons`
  устанавливается закреплёенной версией (`scons==$SCONS_VERSION`), обе загрузки
  проверяются по SHA-256. Заголовки, `.pc` и симлинк `libxkbcommon.so` живут в
  монтируемом `/opt/extra`; контейнер запущен под `--user "$(id -u):$(id -g)"` и
  больше не пишет в `/usr/include` или `/usr/lib64` (это устраняло `Permission
  denied`).
- Диагностика `kit_find_godot` / `kit_find_template` выводится в stderr вместо
  `2>/dev/null`.

### Fixed

#### P0 — безопасность и предсказуемость

- Отсутствие Aurora SDK больше не роняет скрипты под `set -e` в режимах `--check`,
  `--pck-only`, `--write-preset`, `--sign-only`.
- `fetch_engine.sh --check` возвращает ненулевой код при неполном комплекте компонентов,
  а `--dry-run` не создаёт каталог назначения.
- Приватные ключи подписи больше не копируются в проект постоянно: используется
  `mktemp -d "$BUILD_DIR/.signing.XXXXXX"` с гарантированной очисткой по
  `trap ... EXIT INT TERM`.
- Все скрипты помечены исполняемыми и зафиксированы в индексе Git.

#### P1 — сборка, деплой, шаблоны

- Пути к артефактам считаются через `kit_to_workspace_path`, поэтому произвольный
  `BUILD_DIR` (например, `<проект>/out`) работает; проверка вложенности каталогов идёт
  после `realpath -m` со слэшем (`game-old` не считается подкаталогом `game`).
- Резервные копии `export_presets.cfg.bak.<timestamp>` складываются в
  `$BUILD_DIR/backups/`.
- Перед упаковкой проверяется ELF-архитектура шаблона (`readelf -h`): x86_64-шаблон не
  попадает в aarch64-пакет и наоборот.
- `trap cleanup_container EXIT` регистрируется только после старта контейнера, имя
  контейнера уникально (`godot-to-aurora-build-$$-<timestamp>`) — параллельные сборки
  не мешают друг другу.
- `JOBS` валидируется как `^[1-9][0-9]*$` после разбора аргументов CLI.
- Legacy-сборка sb2 вызывает `scons` / `python3 -m SCons` вместо несуществующего
  `tools/scons/scripts/scons.py`.
- PNG-иконки перегенерируются при обновлении `icon.svg` (сравнение по mtime), диагностика
  рендера стала явной.
- `fetch_engine.sh`: проверка `SHA256SUMS` обязательна, `version.txt` перезаписывается при
  смене версии шаблонов.
- `deploy_emulator.sh`: эмулятор определяется по типу устройства из `sfdk device list`,
  `StrictHostKeyChecking=no` и `UserKnownHostsFile=/dev/null` применяются только к
  локальному эмулятору, код возврата `rpmsign-external dump` проверяется, `--wait` и
  `--install-wait` валидируются как целые неотрицательные числа, удалённый каталог
  загрузок строится от `$SSH_USER`, имя пакета берётся из `rpm -qp --queryformat`.
- Экранирование шаблонов: `%` → `%%` и удаление управляющих символов для `.spec`,
  переводы строк — для `.desktop`, `"` и `\` — для `export_presets.cfg`.
- Из генератора пресета убрана невалидная секция `[runnable_presets]`; `runnable=true`
  остаётся внутри `[preset.N]`.
- Нормализация ориентации приведена к единому виду в коде и документации:
  `0/2/4` → `Landscape`, `1/3/5` → `Portrait`, `6` → `Dynamic`.
- Устранены все предупреждения `shellcheck` (включая SC2046, SC2155, SC2015) и удалён
  мёртвый код (`kit_sdk_sysroot`, `kit_require_python_free_tools`, `KIT_MODULES`).
- Из `templates/app.spec.in` удалён устаревший тег `Group:`/`RPM_GROUP`, список иконок
  заменён одним glob'ом без дублирования.

#### GDScript-модули

- `SaveService`: настоящая атомарность (`tmp` + `flush` + `close` + `rename_absolute` без
  предварительного удаления цели), автоматическое восстановление из `.tmp` при
  отсутствующем или повреждённом основном файле, `false` вместо маскировки неатомарной
  записи; добавлен хук миграции версий
  `load_slot(slot, expected_version, migrate)`; docstring описывает особенности
  JSON-сериализации Godot; `list_slots()` возвращает исходные имена слотов, которые
  можно передать обратно в `load_slot()`/`has_slot()`/`erase_slot()`.
- `SaveService.normalize_slot` теперь транслитерирует кириллицу в латиницу и добавляет к
  читаемому slug детерминированный суффикс `sha256(8)` исходного имени слота — это
  исключает коллизии (`сохранить` / `sokhranit` / имя из одних спецсимволов).
  **Осознанное несовместимое изменение:** сохранения, созданные старой версией кита
  (простой slug без суффикса), автоматически не находятся — старые файлы нужно
  переименовать вручную либо перенести через хук миграции.
- `AuroraSafeArea`: `ui_scale` считается через `minf`, `touch_target` учитывает
  DPI/масштаб экрана (48 dp — физические dp), ориентация нормализуется перед проверкой
  «оконный режим на ПК».
- `AuroraLifecycle`: пауза по потере фокуса окна на десктопе вынесена в
  `@export var pause_on_desktop_focus_loss` (по умолчанию `false`), при уходе в фон
  включается энергосбережение с восстановлением прежних значений при возврате.

### Removed

- Дубликат лицензии шрифтов `modules/fonts/LICENSE-LiberationSans` (остался один
  `modules/fonts/LICENSE`).
- Поддержка `RPM_GROUP` и тега `Group:` в `.spec`.
- Следы конкретной игры в документации и примерах.

### Documentation

- Единое имя проекта — `godot-to-aurora` во всех файлах.
- `docs/RELEASES_GUIDE.md`: версии берутся из `versions.env`, отмечены обязательный
  `SHA256SUMS` и флаг `--skip-checksum`.
- `docs/SDK_5_2_ARCHITECTURE.md`: временный staging ключей подписи, закреплённые версии
  SCons/xkbcommon с проверкой SHA-256, определение версии `libxkbcommon` из образа,
  правило `exclude_filter` (только `build/*` и каталог кита), строгая нормализация
  ориентации, ссылка на официальную документацию Sailjail.

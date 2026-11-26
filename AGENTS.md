# AGENTS.md — плейбук портирования Godot-игры на ОС Аврора

Ты работаешь в Godot 4 проекте, в корень которого скопирован кит **`godot-to-aurora`**.
Задача кита — довести игру до подписанного RPM для эмулятора `x86_64` и, при наличии
устройства, для `aarch64`.

Разделение документов (не дублируй их здесь): [`README.md`](README.md) — установка,
команды, параметры; [`docs/SDK_5_2_ARCHITECTURE.md`](docs/SDK_5_2_ARCHITECTURE.md) —
устройство SDK 5.2, RPM, Sailjail, грабли; [`docs/RELEASES_GUIDE.md`](docs/RELEASES_GUIDE.md) —
публикация движка; [`CHANGELOG.md`](CHANGELOG.md) — история изменений.
Этот файл — **процесс и инварианты**, а не справочник по флагам.

---

## 1. Канонический путь интеграции модулей

Способ ровно один: **скопировать** нужные файлы в игру. Если каталог кита лежит
внутри проекта, создай в нём пустой `.gdignore` **до** первого открытия Godot, иначе
движок просканирует `modules/*.gd` и выдаст `Class "AuroraSafeArea" hides a global
script class`. Автозагрузки обязаны лежать в проекте.

```bash
mkdir -p scripts/aurora assets/fonts
cp godot-to-aurora/modules/*.gd          scripts/aurora/
cp godot-to-aurora/modules/fonts/*.ttf   assets/fonts/
cp godot-to-aurora/modules/fonts/LICENSE assets/fonts/
```

Итоговые пути (только они упоминаются в коде, docstring'ах и доках):

```
res://scripts/aurora/aurora_lifecycle.gd
res://scripts/aurora/save_service.gd
res://scripts/aurora/safe_area_helper.gd
res://assets/fonts/LiberationSans-Regular.ttf
res://assets/fonts/LiberationSans-Bold.ttf
res://assets/fonts/LiberationMono-Regular.ttf
```

Автозагрузки в `project.godot`:

```ini
[autoload]
AuroraLifecycle="*res://scripts/aurora/aurora_lifecycle.gd"
SaveService="*res://scripts/aurora/save_service.gd"
```

`AuroraSafeArea` — статический хелпер, автозагрузка ему не нужна.

Ссылаться на `res://godot-to-aurora/modules/...` нельзя: движок импортирует шрифты
дважды, а `class_name` даст `Class "AuroraSafeArea" hides a global script class`.
Из лицензий шрифтов копируется один файл — `LICENSE` (SIL OFL 1.1).

---

## 2. Рабочий процесс

1. **Аудит.** Прочитай `project.godot`, `export_presets.cfg`, сцены, UI-скрипты.
   Зафиксируй рендерер, разрешение, ориентацию, шрифты, сохранения, ввод, паузу, сеть,
   плагины.
2. **План.** Создай `PLAN.md`: таблица «проблема → правка → файл → риск». Пункты из §6
   вынеси в список «требует решения пользователя».
3. **Правки.** Минимально достаточные: не рефактори геймплей, не «улучшай» графику,
   не переименовывай сцены и автозагрузки без необходимости.
4. **Сборка и проверка.** По шагам, от дешёвого к дорогому:

   ```bash
   ./godot-to-aurora/scripts/build_x86_64_rpm.sh --check      # окружение
   ./godot-to-aurora/scripts/build_x86_64_rpm.sh --pck-only   # PCK + иконки
   ./godot-to-aurora/scripts/build_x86_64_rpm.sh              # RPM для эмулятора
   ./godot-to-aurora/scripts/deploy_emulator.sh --check       # что видит деплой
   ./godot-to-aurora/scripts/deploy_emulator.sh               # подпись + установка
   ```

   Запускай игру **с иконки меню** эмулятора и смотри `journalctl -f -t <org>.<app>`.
5. **Отчёт.** Что изменено, чем проверено, что осталось открытым.

Проверки репозитория кита (если правишь сам кит): `bash tests/test_cli.sh` и
`GODOT_BIN=/path/to/Godot bash tests/run_modules.sh` (см. `.github/workflows/ci.yml`).

---

## 3. Жёсткие технические инварианты

Нарушение любого пункта = неработающий пакет, а не «стилистическая придирка».

**Рендерер.** `gl_compatibility`, экспорт с `--rendering-driver opengl3`, текстуры
ETC2/ASTC. Vulkan на устройстве недоступен.

**PCK exclude.** В пресет автоматически попадают только `build/*` и каталог кита
относительно проекта (`godot-to-aurora/*`), если кит лежит внутри игры. Ничего другого
кит не исключает: `tools/`, `addons/`, `docs/` могут быть нужны игре. Правя фильтр
руками, сравнивай точный токен: `mybuild/*` — не `build/*`.

**Шрифты.** Шаблоны собраны с `fontconfig=no`: `SystemFont` и системные шрифты на
устройстве не работают. Только `.ttf` внутри проекта (§1).

**Сохранения.** Только `user://` → `~/.local/share/<org>/<app>/`, `res://` read-only.
Пиши через `SaveService` (атомарный `tmp` + `rename`).

**Safe area.** Вырезы и скругления — через `AuroraSafeArea.compute_insets()`, без
хардкода пикселей и без safe area монитора на ПК. `ui_scale` считай через `minf`,
иначе UI вылезает за края на другом соотношении сторон.

**Ориентация.** Согласуй три уровня: `display/window/handheld/orientation` в
`project.godot`, `Orientation=` в `.desktop`, `DisplayServer.screen_set_orientation()`
в `aurora_lifecycle.gd`. Нормализация значений (`kit_normalize_orientation`):

| Значение | Итог |
|---|---|
| `0`, `2`, `4`, `landscape`, `reverse_landscape`, `sensor_landscape` | `Landscape` |
| `1`, `3`, `5`, `portrait`, `reverse_portrait`, `sensor_portrait` | `Portrait` |
| `6`, `dynamic`, `sensor` | `Dynamic` |

**Sailjail.** `OrganizationName` + `ApplicationName` из `.desktop` задают песочницу и
`user://`. `Permissions` — только реально нужные; права «читать весь FS» нет. Эффект
даёт только запуск с иконки меню.

**Архитектура пакета.** Шаблон обязан совпадать с целевой арх. (`readelf -h`:
`x86_64` vs `AArch64`); скрипты проверяют это сами, не обходи проверку.

**Секреты.** Ключи подписи не попадают в Git: деплой кладёт их во временный
`$BUILD_DIR/.signing.XXXXXX` и удаляет.

**Версии.** `KIT_VERSION`, теги движка и SDK, `SCONS_VERSION` — только в
[`versions.env`](versions.env). Кит рассчитан на SDK 5.2.x
(`SDK_SUPPORTED_PREFIX`); другая серия даёт предупреждение, а `--strict-sdk` —
ошибку. Неизвестная версия `libxkbcommon` требует записи в
`XKBCOMMON_KNOWN_VERSIONS` либо явного `--skip-checksum`.

---

## 4. Минимум команд, которые надо помнить

```bash
# диагностика
./godot-to-aurora/scripts/build_x86_64_rpm.sh --check
./godot-to-aurora/scripts/fetch_engine.sh --check --print-paths
./godot-to-aurora/scripts/deploy_emulator.sh --check

# сборка
./godot-to-aurora/scripts/fetch_engine.sh                 # движок и шаблоны
./godot-to-aurora/scripts/build_x86_64_rpm.sh             # x86_64 (эмулятор)
./godot-to-aurora/scripts/build_aarch64_rpm.sh            # aarch64 (устройство)

# проверка гипотез без полной сборки
./godot-to-aurora/scripts/build_x86_64_rpm.sh --pck-only
./godot-to-aurora/scripts/deploy_emulator.sh --sign-only  # только подпись
```

Версия кита: `./scripts/build_x86_64_rpm.sh --version` → `godot-to-aurora 1.1.0`.
Все флаги и переменные — в `README.md` и `--help`.

---

## 5. Траблшутинг

| Симптом | Что проверить |
|---|---|
| Пакет не ставится APM | подпись (`rpmsign-external dump`), совпадение арх. пакета и устройства |
| Игра вертикальная | `Orientation=` в `.desktop`, `project.godot`, запуск с иконки меню |
| Пустые глифы | `fontconfig=no`, шрифт не в `res://assets/fonts/`, `SystemFont` в теме |
| HUD вылез за экран | `AuroraSafeArea`, `minf` в `ui_scale`, safe area монитора на ПК |
| Сохранения не пишутся | путь не `user://`, нет каталога, `SaveService` вернул `false` |
| В PCK попал кит | `exclude_filter`, точные токены `build/*`, `godot-to-aurora/*` |
| `sfdk: Неизвестная команда 'engine'` | в SDK 5.2 нет sb2 — это норма, `tools/run` + Docker |
| `/dev/kvm` недоступен | модуль `kvm`, группа `kvm`, `setfacl` |

Подробности с командами и причинами — [`docs/SDK_5_2_ARCHITECTURE.md`](docs/SDK_5_2_ARCHITECTURE.md).

---

## 6. Границы: сначала спроси, потом правь

Кит портирует игру, а не переделывает её. Меняй перечисленное **только** после анализа
проекта, а при архитектурной вилке — с подтверждением пользователя:

* **физический движок** (`physics/3d/physics_engine`, Jolt и т.п.) — смена ломает
  геймплей; трогать, только если движок реально недоступен в шаблоне;
* **`keep_screen_on` / `low_processor_usage_mode`** — влияют на батарею и поведение игры;
* **рендерер и качество** — если проект уже совместим с GLES3, не переводи «на всякий»;
* **геймплей, баланс, структура сцен, удаление ассетов и плагинов** — вне зоны кита;
* **версия движка/шаблонов** — синхронно с `versions.env` и `RELEASES_GUIDE.md`;
* **переименование автозагрузок и путей** — ломает ссылки в проекте.

Если данных не хватает (нет `project.godot`, непонятна ориентация, неизвестно, нужна ли
сеть) — **спроси**, не угадывай. Открытые вопросы фиксируй в `PLAN.md`.

---

## 7. Чек-лист перед сдачей

- [ ] модули и шрифты лежат по каноническим путям (§1), автозагрузки прописаны;
- [ ] `SystemFont` не используется в рабочем пути UI;
- [ ] все записи — в `user://`, `SaveService` возвращает `true`;
- [ ] safe area/масштаб — через `AuroraSafeArea`, без хардкода пикселей;
- [ ] ориентация согласована на трёх уровнях, в `Permissions` нет лишних прав;
- [ ] `build_x86_64_rpm.sh --check` без предупреждений;
- [ ] в PCK нет файлов кита и `build/`;
- [ ] RPM собирается, подписывается и ставится в эмулятор;
- [ ] игра запускается с иконки меню и выживает сворачивание/разворачивание;
- [ ] `PLAN.md` и итоговый отчёт обновлены.

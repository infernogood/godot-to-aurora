# godot-to-aurora

[English summary](#english-summary) · [Быстрый старт](#быстрый-старт) · [Документация](#документация)

**Кит для агентного портирования игр на Godot 4 в ОС Аврора 5.2+.** Скопируй каталог в
корень своего Godot-проекта, дай своему ИИ-агенту `AGENTS.md` — и получи аудит, адаптацию
UI/шрифтов/жизненного цикла, `.pck`, подписанный RPM для эмулятора `x86_64` и (при наличии
устройства) `aarch64`.

Собран из реального опыта переноса игры: все «грабли» Аврора SDK 5.2, Wayland/GLES3,
Sailjail, `fontconfig=no`, подписи RPM и QEMU-эмулятора уже зашиты в скрипты и шаблоны.

---

## English summary

An agent-first porting kit for Godot 4 games on Aurora OS (Russian mobile Linux).
Drop `godot-to-aurora/` into your project, point your coding agent at `AGENTS.md`,
and it will audit the game, adapt UI/fonts/input/lifecycle, build a signed x86_64 RPM for
the QEMU emulator, and a signed aarch64 RPM for devices. It encodes the real-world SDK 5.2
constraints: no sb2/mb2, Docker `tools/run` build environment, Wayland-only engine fork,
GLES3 renderer, embedded fonts instead of `SystemFont`, Sailjail-compliant `user://`
saves, `rpmsign-external` with SDK test keys, and APM installation over D-Bus.

---

## Быстрый старт

### 1. Скопируй кит в проект

```bash
cd /path/to/your-godot-game
git clone <этот-репозиторий> godot-to-aurora
# или распакуй архив в godot-to-aurora/
```

Не переименовывай каталог без необходимости: агентские команды и подсказки в документации
используют имя `godot-to-aurora/`. Скрипты работают и при копировании содержимого
прямо в корень проекта.

### 2. Подготовь движок

```bash
./godot-to-aurora/scripts/fetch_engine.sh --from-dir /path/to/engine
```

Нужны Aurora-сборка Godot (`Godot_v4.7.2-auroraos1_linux.x86_64`) и шаблоны
`auroraos_release.arm64`, `auroraos_debug.arm64`, `auroraos_release.x86_64`. Если они уже
опубликованы в GitHub Releases кита:

```bash
AURORA_KIT_REPO=<owner>/godot-to-aurora ./godot-to-aurora/scripts/fetch_engine.sh
```

Подробности публикации — в [docs/RELEASES_GUIDE.md](docs/RELEASES_GUIDE.md).

### 3. Позови агента

```text
Изучи godot-to-aurora/AGENTS.md и портируй мою игру на ОС Аврора.
```

Агент создаст `PLAN.md`, внесёт правки, соберёт RPM и проверит игру в эмуляторе.
Если хочешь пройти вручную — см. раздел «Сборка» ниже.

---

## Требования

| Компонент | Зачем | Проверка |
|---|---|---|
| Linux (Fedora/Ubuntu), Docker | сборка RPM в образе `aurora-build-tools-*` | `docker --version` |
| Аврора SDK 5.2+ | эмулятор QEMU, sysroot, `tools/run`, ключи подписи | `~/AuroraOS/bin/sfdk --version` |
| Aurora-редактор Godot | экспорт `.pck` и `aarch64` RPM | `fetch_engine.sh --check` |
| `patchelf` | RPATH бинарника на приватную `libxkbcommon` (x86_64) | `patchelf --version` |
| ImageMagick или `rsvg-convert` | иконки `86/108/128/172` из `icon.svg` | `magick -version` |
| `python3` + `pip` | только при сборке x86_64-шаблона (SCons/заголовки) | `python3 --version` |
| KVM (`/dev/kvm`) | запуск эмулятора | `ls -l /dev/kvm` |

Эмулятор в SDK 5.2 — **QEMU/KVM**, а не VirtualBox. X11-обвязка не нужна: Godot-шаблон
собирается с `auroraos=yes` (Wayland-only).

Проверить окружение целиком:

```bash
./godot-to-aurora/scripts/build_x86_64_rpm.sh --check
```

---

## Что делает кит

```
godot-to-aurora/
├── AGENTS.md                     плейбук для ИИ-агента: аудит → PLAN.md → код → RPM → проверка
├── README.md
├── .gitignore                    build/, *.rpm, движок, ключи — вне Git
├── scripts/
│   ├── fetch_engine.sh           Aurora-редактор + шаблоны + export_templates
│   ├── build_x86_64_rpm.sh       пресет, PCK, иконки, RPM (--arch x86_64|aarch64; RPATH — x86_64)
│   ├── build_aarch64_rpm.sh      обёртка для aarch64 (реальное устройство)
│   ├── deploy_emulator.sh        KVM, подпись, APM, установка, journalctl
│   └── lib/common.sh             общий слой: параметры пакета, поиск SDK, рендер шаблонов
├── templates/
│   ├── export_presets.aurora.cfg пресет AuroraOS (GLES3, ETC2/ASTC, arm64)
│   ├── app.desktop.in            .desktop: Sailjail Permissions + Orientation
│   └── app.spec.in               .spec без BuildRequires: patchelf/xkbcommon
├── modules/
│   ├── aurora_lifecycle.gd       ориентация, пауза, мьют, автосохранение (autoload)
│   ├── safe_area_helper.gd       safe area + ui_scale + 48dp touch-цели
│   ├── save_service.gd           атомарный JSON в user:// (autoload)
│   └── fonts/                    Liberation Mono/Sans/Bold + лицензии
└── docs/
    ├── SDK_5_2_ARCHITECTURE.md   как устроен SDK 5.2 и что ломается
    └── RELEASES_GUIDE.md         публикация бинарников движка в GitHub Releases
```

### Что кит НЕ делает

* не переписывает геймплей и не «улучшает» графику;
* не гарантирует поддержку Godot 3.x, C#/.NET и GDExtension без нативной сборки;
* не собирает `aarch64`-шаблон: готовые `auroraos_*.arm64` берутся из релиза движка;
* не заменяет ручную проверку на реальном устройстве.

---

## Сборка вручную

```bash
# 1. параметры пакета (или задай их в export_presets.cfg)
export ORG_NAME=ru.example
export APP_NAME=mygame
export APP_TITLE="Моя игра"
export PERMISSIONS="Audio,Internet"
export ORIENTATION=Landscape

# 2. диагностика
./godot-to-aurora/scripts/build_x86_64_rpm.sh --check

# 3. PCK + RPM для эмулятора (первый запуск переимпортирует ресурсы)
./godot-to-aurora/scripts/build_x86_64_rpm.sh

# 3b. RPM для реального устройства
./godot-to-aurora/scripts/build_aarch64_rpm.sh

# 4. подпись и установка в эмулятор
./godot-to-aurora/scripts/deploy_emulator.sh

# 5. запусти игру с иконки в меню эмулятора и смотри логи
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec journalctl -f -t ru.example.mygame
```

Результаты:

```
build/<org>.<app>.pck
build/rpmbuild/RPMS/x86_64/<org>.<app>-<version>-<release>.x86_64.rpm
```

### Полезные режимы

```bash
./scripts/build_x86_64_rpm.sh --help
./scripts/build_x86_64_rpm.sh --pck-only        # быстро проверить упаковку
./scripts/build_x86_64_rpm.sh --skip-template   # шаблон уже собран
./scripts/build_x86_64_rpm.sh --force-preset    # пересоздать AuroraOS-пресет
./scripts/fetch_engine.sh --check --print-paths
./scripts/deploy_emulator.sh --check            # что скрипт видит
./scripts/deploy_emulator.sh --sign-only        # только подпись
```

### Параметры пакета

Приоритет: переменные окружения → `export_presets.cfg` → `project.godot` → дефолт.

| Переменная | Обязательность | Пример |
|---|---|---|
| `ORG_NAME` | рекомендуется | `ru.example` (dotted, lowercase) |
| `APP_NAME` | рекомендуется | `mygame` (`[a-z0-9_]`) |
| `APP_TITLE` | нет | `Моя игра` |
| `APP_VERSION` / `APP_RELEASE` | нет | `0.1.0` / `1` |
| `PERMISSIONS` | нет | `Audio,Internet,Camera` |
| `ORIENTATION` | нет | `Landscape`, `Portrait`, `Dynamic` |
| `APP_COMMENT` | нет | `Системный симулятор` |
| `RPM_LICENSE` | нет | `Proprietary`, `MIT` |
| `GODOT_BIN`, `AURORA_TEMPLATE` | нет | явные пути к движку |
| `AURORA_KIT_ENGINE_DIR` | нет | куда `fetch_engine.sh` положил бинарники |
| `AURORA_SDK_HOME` | нет | `~/AuroraOS` |

Полное имя пакета = `<ORG_NAME>.<APP_NAME>`. Оно попадает в RPM, `.desktop`, `Exec`,
иконки и путь песочницы `~/.local/share/<org>/<app>/`.

---

## Модули

### `modules/safe_area_helper.gd`

Чистый статический хелпер. Возвращает `{"l","t","r","b","valid"}`, игнорируя нулевую
safe area и оконный режим на ПК, масштабирует отступы в координаты вьюпорта и считает
`ui_scale` c ограничением `0.85…1.5`.

```gdscript
var vp := get_viewport().get_visible_rect().size
var insets := AuroraSafeArea.insets(vp)
var scale := AuroraSafeArea.ui_scale(vp)
panel.offset_left = float(insets["l"]) + 24.0 * scale
button.custom_minimum_size = Vector2.ONE * AuroraSafeArea.touch_target(scale)
```

### `modules/aurora_lifecycle.gd`

Автозагрузка `AuroraLifecycle`: фиксирует ориентацию, по сворачиванию ставит дерево на
паузу, мьютит `Master`, эмитит `autosave_requested`; игнорирует `FOCUS_OUT` до первого
`FOCUS_IN`; не размораживает игру сама — это делает `resume_game()` из кнопки «Продолжить».

### `modules/save_service.gd`

Автозагрузка `SaveService`: атомарная запись JSON в `user://` (`tmp` + `rename`), версия
формата, нормализация имён слотов, `save/load_slot/has_slot/erase_slot/list_slots/clear_all`.
Совместим с `--headless --script` тестами.

Подключение:

```ini
[autoload]
AuroraLifecycle="*res://scripts/aurora/aurora_lifecycle.gd"
SaveService="*res://scripts/aurora/save_service.gd"
```

---

## Сборка для реального устройства (aarch64)

Штатный экспортёр Авроры в форке Godot вызывает `sfdk engine exec sb2`, а в SDK 5.2
этого API больше нет. Поэтому кит собирает aarch64-RPM нативно — тем же способом, что и
x86_64, но с шаблоном `auroraos_release.arm64` и `rpmbuild --target aarch64-meego-linux-gnu`:

```bash
./godot-to-aurora/scripts/build_aarch64_rpm.sh
# = build_x86_64_rpm.sh --arch aarch64

./godot-to-aurora/scripts/deploy_emulator.sh \
  --rpm build/rpmbuild/RPMS/aarch64/<pkg>-*.aarch64.rpm --device "<имя>"
```

`fetch_engine.sh` уже ставит arm64-шаблоны в `~/.local/share/godot/export_templates/`,
поэтому они же доступны Aurora-редактору для отладки на устройстве. Пакет по умолчанию
не несёт приватную `libxkbcommon` (на устройстве она системная); при необходимости задай
`AURORA_ARM64_LIB_DIR=/path/to/arm64/lib`.

Телефон должен быть в режиме разработчика. Проверить архитектуру пакета:

```bash
docker run --rm -v "$PWD/build:/build:ro" --entrypoint /bin/bash \
  aurora-build-tools-deus:5.2.1.200 -lc \
  "rpm -qp --qf '%{ARCH}\n' /build/rpmbuild/RPMS/aarch64/<pkg>.aarch64.rpm"
```

---

## Частые проблемы

Коротко; полная таблица — в [AGENTS.md](AGENTS.md#7-траблшутинг-проверенные-грабли) и
[docs/SDK_5_2_ARCHITECTURE.md](docs/SDK_5_2_ARCHITECTURE.md).

* **`sfdk: Неизвестная команда 'engine'`** — в SDK 5.2 нет sb2; сборка идёт через
  `<sdk>/tools/run` и Docker-образ `aurora-build-tools-*`.
* **`/dev/kvm` недоступен** — `sudo modprobe kvm kvm_amd` (или `kvm_intel`) и
  `sudo setfacl -m u:$USER:rw /dev/kvm`.
* **APM не ставит пакет** — RPM не подписан или подписан самоподписанным сертификатом;
  используй `regular_key.pem`/`regular_cert.pem` из SDK.
* **Игра вертикальная** — `window/handheld/orientation=0` и `Orientation=Landscape`
  в `.desktop`; запускать с иконки меню.
* **HUD схлопнулся на ПК** — не считай отступы от «мониторной» safe area; используй
  `AuroraSafeArea`.
* **Шрифты не те** — `fontconfig=no`; встраивай `.ttf` из `modules/fonts`.

---

## Документация

* [AGENTS.md](AGENTS.md) — полный плейбук агента и таблица грабель.
* [docs/SDK_5_2_ARCHITECTURE.md](docs/SDK_5_2_ARCHITECTURE.md) — SDK 5.2, QEMU/KVM,
  `tools/run`, `rpmsign-external`, APM, Sailjail.
* [docs/RELEASES_GUIDE.md](docs/RELEASES_GUIDE.md) — как опубликовать бинарники движка.

---

## Лицензия

Код кита, скрипты и шаблоны — MIT (см. [LICENSE](LICENSE)).
Шрифты Liberation в `modules/fonts/` распространяются по SIL Open Font License 1.1
(см. `LICENSE` и `LICENSE-LiberationSans` в том же каталоге).

Aurora-сборка Godot (`savegame/godot`, тег `4.7.2-auroraos1`) — MIT; бинарники движка
распространяются через Releases и не входят в Git-репозиторий.

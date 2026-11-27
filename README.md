# godot-to-aurora

[English summary](#english-summary) · [Быстрый старт](#быстрый-старт) · [Документация](#документация)

**Кит для агентного портирования игр на Godot 4 в ОС Аврора 5.2+.** Скопируй каталог в
корень своего Godot-проекта, дай своему ИИ-агенту `AGENTS.md` — и получи аудит, адаптацию
UI/шрифтов/жизненного цикла, `.pck`, подписанный RPM для эмулятора `x86_64` и (при наличии
устройства) `aarch64`.

Собран из реального опыта переноса игр: все «грабли» Аврора SDK 5.2, Wayland/GLES3,
Sailjail, `fontconfig=no`, подписи RPM и QEMU-эмулятора уже зашиты в скрипты и шаблоны.
История изменений — в [CHANGELOG.md](CHANGELOG.md).

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

## Первый запуск с нуля

Этот раздел — для чистой машины. Если `build_x86_64_rpm.sh --check` уже проходит,
переходи к «Быстрому старту».

### 1. Aurora SDK 5.2.1.200

Установи SDK через установщик Aurora SDK (`SDKMaintenanceTool`) и проверь:

```bash
~/AuroraOS/bin/sfdk --version
~/AuroraOS/bin/sfdk device list
```

Если SDK установлен в другой каталог, задай `AURORA_SDK_HOME=/path/to/AuroraOS`.
Кит проверяет серию SDK: `5.2.x` поддерживается, на `5.1.x`/`5.3.x` будет
предупреждение, а с `--strict-sdk` — ошибка.

### 2. Docker и образ сборки

Установщик SDK загружает `sdk-build-tools-5.2.1.200-x86_64.tar` и тегирует образ
как `aurora-build-tools-<user>:5.2.1.200`. Проверь, что образ виден Docker:

```bash
docker images --format '{{.Repository}}:{{.Tag}}' | grep '^aurora-build-tools'
```

Если образ отсутствует, переустанови компонент Build Tools в SDK. Другой образ
можно указать явно: `AURORA_BUILD_IMAGE=registry/aurora-build-tools:tag`.

### 3. Инструменты хоста

Нужны `git`, `curl`, `python3`, `patchelf`, `readelf` и один из рендереров иконок —
`magick` (ImageMagick) или `rsvg-convert`. Например, на Fedora:

```bash
sudo dnf install -y git curl python3 patchelf binutils ImageMagick
```

`patchelf` нужен только для x86_64: он прописывает RPATH на приватную
`libxkbcommon` внутри пакета.

### 4. KVM и эмулятор

Проверь `/dev/kvm` и доступ к нему:

```bash
ls -l /dev/kvm
sudo modprobe kvm_intel   # или kvm_amd
sudo setfacl -m u:$USER:rw /dev/kvm
```

Запусти эмулятор из SDK. `sfdk device list` должен показать устройство
`Aurora OS эмулятор 5.2.1.200` (`defaultuser@127.0.0.1:2223`).

### 5. Ключи подписи

SDK кладёт тестовые ключи в `~/AuroraOS/package-signing/regular_key.pem` и
`regular_cert.pem`; `deploy_emulator.sh` находит их сам. Не копируй ключи в
репозиторий. Для своих ключей есть `AURORA_SIGN_KEY` и `AURORA_SIGN_CERT`.

### 6. Проверка окружения

После установки движка (шаг 3 «Быстрого старта») выполни:

```bash
./godot-to-aurora/scripts/build_x86_64_rpm.sh --check
```

Команда `--check` должна сообщить, что окружение готово. Если чего-то не хватает,
она перечислит компоненты и подскажет, что установить.

---

## Быстрый старт

> Если Aurora SDK и Docker ещё не настроены, сначала выполни раздел
> [«Первый запуск с нуля»](#первый-запуск-с-нуля).

### 1. Скопируй кит в проект

```bash
cd /path/to/your-godot-game
git clone <этот-репозиторий> godot-to-aurora
# или распакуй архив в godot-to-aurora/
```

Не переименовывай каталог без необходимости: агентские команды и подсказки в документации
используют имя `godot-to-aurora/`. Скрипты работают и при копировании содержимого
прямо в корень проекта. Если каталог кита лежит **внутри** проекта, создай в нём
пустой `godot-to-aurora/.gdignore` до первого открытия Godot: иначе движок
просканирует `modules/*.gd` и выдаст `Class "AuroraSafeArea" hides a global script class`.
Модули и шрифты всё равно нужно скопировать в проект (шаг 2).

### 2. Подключи модули (единственный канонический путь)

```bash
mkdir -p scripts/aurora assets/fonts
cp godot-to-aurora/modules/*.gd          scripts/aurora/
cp godot-to-aurora/modules/fonts/*.ttf   assets/fonts/
cp godot-to-aurora/modules/fonts/LICENSE assets/fonts/
```

Автозагрузки в `project.godot`:

```ini
[autoload]
AuroraLifecycle="*res://scripts/aurora/aurora_lifecycle.gd"
SaveService="*res://scripts/aurora/save_service.gd"
```

Ссылки на `res://godot-to-aurora/modules/...` не используй: движок импортирует шрифты
дважды, а `class_name` даст ошибку `Class "AuroraSafeArea" hides a global script class`.

### 3. Подготовь движок

```bash
./godot-to-aurora/scripts/fetch_engine.sh --from-dir /path/to/engine
```

Нужны Aurora-сборка Godot (`Godot_v4.7.2-auroraos1_linux.x86_64`) и шаблоны
`auroraos_release.x86_64`, `auroraos_release.arm64`, `auroraos_debug.arm64`. Если они уже
опубликованы в GitHub Releases кита:

```bash
./godot-to-aurora/scripts/fetch_engine.sh
```

Проверка `SHA256SUMS` обязательна для любого источника (`--from-dir` тоже): без файла
сумм или с несовпавшим хэшем скрипт завершается с ошибкой. Для локального каталога либо
положи `SHA256SUMS` рядом с бинарниками, либо отключи проверку явно —
`--skip-checksum`. Свои суммы можно сгенерировать через `--skip-checksum --write-sums`
(подробности — в [docs/RELEASES_GUIDE.md](docs/RELEASES_GUIDE.md)).

### 4. Позови агента

```text
Изучи godot-to-aurora/AGENTS.md и портируй мою игру на ОС Аврора.
```

Агент создаст `PLAN.md`, внесёт правки, соберёт RPM и проверит игру в эмуляторе.
Если хочешь пройти вручную — см. раздел «Сборка вручную» ниже.

---

## Требования

| Компонент | Зачем | Проверка |
|---|---|---|
| Linux (Fedora/Ubuntu), Docker | сборка RPM в образе `aurora-build-tools-*` | `docker --version` |
| Аврора SDK 5.2.x | эмулятор QEMU, sysroot, `tools/run`, ключи подписи | `~/AuroraOS/bin/sfdk --version` |
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
├── CHANGELOG.md                  история изменений (Keep a Changelog)
├── LICENSE                       MIT кита
├── THIRD_PARTY_NOTICES.md        MIT Godot Engine и уведомления об авторских правах
├── versions.env                  KIT_VERSION, теги движка и SDK, версии SCons/xkbcommon
├── .gitignore                    build/, *.rpm, движок, ключи — вне Git
├── .editorconfig                 utf-8, LF, отступы для sh/gd/yml
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
│   ├── aurora_lifecycle.gd       ориентация, пауза, мьют, энергосбережение (autoload)
│   ├── safe_area_helper.gd       safe area + ui_scale + 48dp touch-цели
│   ├── save_service.gd           атомарный JSON в user:// (autoload)
│   └── fonts/                    Liberation Mono/Sans/Bold + LICENSE (SIL OFL 1.1)
├── tests/
│   ├── test_cli.sh               CLI: --help/--version/--check, пресеты, экранирование
│   ├── test_modules.gd           headless-тесты GDScript-модулей
│   └── run_modules.sh            временная Godot-фикстура + headless-прогон
├── .github/workflows/ci.yml      shellcheck + bash -n + CLI- и headless-тесты
└── docs/
    ├── SDK_5_2_ARCHITECTURE.md   как устроен SDK 5.2 и что ломается
    ├── RELEASES_GUIDE.md         публикация бинарников движка в GitHub Releases
    └── ENGINE_RELEASE_4.7.2-auroraos1.md  состав и суммы релиза движка
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
build/backups/export_presets.cfg.bak.<timestamp>     # если пресет создавался/менялся
```

Ключи подписи копируются во временный `$BUILD_DIR/.signing.XXXXXX` и удаляются после
подписи — в проекте и в Git их не остаётся.

### Полезные режимы

```bash
./scripts/build_x86_64_rpm.sh --help
./scripts/build_x86_64_rpm.sh --version         # godot-to-aurora <KIT_VERSION>
./scripts/build_x86_64_rpm.sh --pck-only        # быстро проверить упаковку
./scripts/build_x86_64_rpm.sh --skip-template   # шаблон уже собран
./scripts/build_x86_64_rpm.sh --force-preset    # пересоздать AuroraOS-пресет
./scripts/build_x86_64_rpm.sh --strict-sdk      # ошибка, если SDK не 5.2.x
./scripts/build_x86_64_rpm.sh --skip-checksum   # отказ от SHA-256 xkbcommon/SCons
./scripts/fetch_engine.sh --check --print-paths
./scripts/fetch_engine.sh --skip-checksum       # явный отказ от SHA256SUMS
./scripts/deploy_emulator.sh --check            # что скрипт видит
./scripts/deploy_emulator.sh --sign-only        # только подпись
```

`--version` печатает одну строку `godot-to-aurora <KIT_VERSION>` и работает без
`project.godot`, SDK, сети и Docker.

### Что попадает в `.pck`

В `exclude_filter` кит добавляет только `build/*` и каталог кита относительно проекта
(например, `godot-to-aurora/*`). Каталоги вроде `tools/`, `addons/`, `docs/` **не**
исключаются автоматически: они могут быть нужны игре. Вхождение проверяется точным
токеном (`mybuild/*` не считается `build/*`).

### Пресет `AuroraOS`

Если `AURORA_PRESET` не задан и `--preset` не передан, кит берёт **первый существующий
пресет с `platform="AuroraOS"`** (как бы он ни назывался, например `Aurora Phone`) и
читает из него `package/organization` и `package/name`. Существующий пресет не
перезаписывается: новый создаётся только когда пресетов `AuroraOS` нет, а
`--force-preset` пересоздаёт его осознанно.

### Параметры пакета

Приоритет: переменные окружения → `export_presets.cfg` → `project.godot` → дефолт.

| Переменная | Обязательность | Пример |
|---|---|---|
| `ORG_NAME` | рекомендуется | `ru.example` (dotted, lowercase) |
| `APP_NAME` | рекомендуется | `mygame` (`[a-z0-9_]`) |
| `APP_TITLE` | нет | `Моя игра` |
| `APP_VERSION` / `APP_RELEASE` | нет | `0.1.0` / `1` |
| `PERMISSIONS` | нет | `Audio,Internet,Camera` |
| `ORIENTATION` | нет | `Landscape`, `Portrait`, `Dynamic` (или `0/2/4`, `1/3/5`, `6`) |
| `APP_COMMENT` | нет | `Моя игра` (Comment в `.desktop`) |
| `RPM_LICENSE` | нет | `Proprietary`, `MIT` |
| `AURORA_PRESET` | нет | имя пресета; пусто = первый `platform="AuroraOS"` |
| `BUILD_DIR` | нет | каталог сборки (по умолчанию `<проект>/build`) |
| `GODOT_BIN` | нет | явный путь к Aurora-редактору |
| `AURORA_TEMPLATE_X86_64` / `AURORA_TEMPLATE_AARCH64` | нет | явные пути к шаблонам (устаревшая `AURORA_TEMPLATE` работает для обеих арх.) |
| `AURORA_KIT_ENGINE_DIR` | нет | куда `fetch_engine.sh` положил бинарники |
| `AURORA_SDK_HOME` | нет | `~/AuroraOS` |
| `AURORA_BUILD_IMAGE` | нет | образ `aurora-build-tools-*`, если имя нестандартное |

Полное имя пакета = `<ORG_NAME>.<APP_NAME>`. Оно попадает в RPM, `.desktop`, `Exec`,
иконки и путь песочницы `~/.local/share/<org>/<app>/`.

Версии (кит, движок, SDK, SCons, xkbcommon) вынесены в [versions.env](versions.env) —
правь их там, а не в скриптах.

Кит рассчитан на Aurora SDK **5.2.x** (`SDK_SUPPORTED_PREFIX`). Если установлена
другая серия (`5.1.x`, `5.3.x`, …), сборка и деплой печатают предупреждение и
продолжают; `--strict-sdk` превращает это в ошибку. Версия `libxkbcommon`
определяется из образа; известные версии перечислены в `XKBCOMMON_KNOWN_VERSIONS`.
Для неизвестной версии сборка подскажет добавить её в `versions.env` или передать
`build_x86_64_rpm.sh --skip-checksum` (явный отказ от проверки SHA-256).

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

Перед упаковкой скрипт проверяет ELF-архитектуру шаблона (`readelf -h`): шаблон
`x86_64` не попадёт в `aarch64`-пакет и наоборот.

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

Коротко; полная таблица — в [AGENTS.md](AGENTS.md#5-траблшутинг) и
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
* **Шрифты не те** — `fontconfig=no`; встраивай `.ttf` в `res://assets/fonts/`.

---

## Тесты и CI

```bash
bash tests/test_cli.sh        # CLI без сети, Godot, Docker и SDK
GODOT_BIN=/path/to/Godot bash tests/run_modules.sh   # headless-модули
```

`tests/test_cli.sh` проверяет `--help`/`--version`, `--check` без SDK, обязательность
`SHA256SUMS` в `fetch_engine.sh --check`, сохранение существующего пресета `AuroraOS`,
экранирование `%`/`"`/переводов строк, точное сравнение токенов `exclude_filter` и
работу с кастомным `BUILD_DIR`.
`tests/test_modules.gd` (через `tests/run_modules.sh`) — safe area, атомарная запись
и восстановление сохранений, коллизии кириллических слотов, миграция версий и
жизненный цикл.

---

## Документация

* [AGENTS.md](AGENTS.md) — плейбук агента: процесс, инварианты, чек-лист.
* [docs/SDK_5_2_ARCHITECTURE.md](docs/SDK_5_2_ARCHITECTURE.md) — SDK 5.2, QEMU/KVM,
  `tools/run`, `rpmsign-external`, APM, Sailjail.
* [docs/RELEASES_GUIDE.md](docs/RELEASES_GUIDE.md) — как опубликовать бинарники движка.
* [docs/ENGINE_RELEASE_4.7.2-auroraos1.md](docs/ENGINE_RELEASE_4.7.2-auroraos1.md) — состав,
  контрольные суммы и происхождение релиза движка.
* [CHANGELOG.md](CHANGELOG.md) — что изменилось между версиями кита.

---

## Лицензия

Код кита, скрипты и шаблоны — MIT (см. [LICENSE](LICENSE)).
Шрифты Liberation в `modules/fonts/` распространяются по SIL Open Font License 1.1 —
один файл `modules/fonts/LICENSE` на все три начертания.

Aurora-сборка Godot (`savegame/godot`, тег `4.7.2-auroraos1`) — MIT; бинарники движка
распространяются через Releases и не входят в Git-репозиторий. Уведомления об авторских
правах Godot Engine (`2014-present Godot Engine contributors`, `2007-2014 Juan Linietsky,
Ariel Manzur`) и полный текст MIT — в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md);
оба файла приложены к релизу движка.

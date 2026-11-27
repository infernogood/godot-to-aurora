# godot-to-aurora

[English summary](#english-summary) · [Требования](#требования) · [Быстрый старт](#быстрый-старт) · [Параметры пакета](#параметры-пакета) · [Документация](#документация)

**Кит для портирования игр на Godot 4 в ОС Аврора 5.2+.** Скопируй каталог в корень
своего Godot-проекта — и получи аудит, адаптацию UI/шрифтов/жизненного цикла, `.pck`,
подписанный RPM для эмулятора `x86_64` и (при наличии устройства) `aarch64`.

В скриптах и шаблонах зашит опыт реальных переносов: Wayland/GLES3, Sailjail,
`fontconfig=no`, подпись RPM и QEMU/KVM-эмулятор. Процесс, инварианты и устройство SDK
5.2 — в разделе [«Документация»](#документация).

---

## English summary

An agent-first porting kit for Godot 4 games on Aurora OS (Russian mobile Linux). Point your
coding agent at `AGENTS.md` and it will adapt the game's UI/fonts/lifecycle, build a signed
x86_64 RPM for the QEMU emulator and a signed aarch64 RPM for devices. It encodes real SDK
5.2 constraints: Docker `tools/run` build environment (no sb2/mb2), Wayland-only engine fork,
GLES3, embedded fonts instead of `SystemFont`, Sailjail `user://` saves, `rpmsign-external`
with SDK test keys and APM installation over D-Bus.

---

## Требования

Linux-хост `x86_64` (проверялось на Fedora и Ubuntu) с доступом к `/dev/kvm`.

| Компонент | Зачем | Проверка |
|---|---|---|
| Docker | сборка RPM в образе `aurora-build-tools-*` | `docker --version` |
| Аврора SDK 5.2.x | эмулятор, sysroot, `tools/run`, ключи подписи | `~/AuroraOS/bin/sfdk --version` |
| Aurora-редактор Godot 4.7.x | экспорт `.pck` и RPM | `./scripts/fetch_engine.sh --check` |
| `git`, `curl`, `unzip` | клон кита и распаковка релизов движка | `git --version` |
| `rpm` (`rpmbuild`, `rpm -qp`) | сборка и инспекция пакета на хосте | `rpm --version` |
| `ssh`, `scp` (`openssh-clients`) | доставка RPM на эмулятор или устройство | `ssh -V` |
| `timeout`, `realpath` (coreutils) | таймауты вызовов SDK, канонизация путей | `timeout --version` |
| `patchelf` | RPATH на приватную `libxkbcommon` (только x86_64) | `patchelf --version` |
| `readelf` (binutils) | проверка ELF-архитектуры шаблона и пакета | `readelf --version` |
| `magick` или `rsvg-convert` | иконки `86/108/128/172` из `icon.svg` | `magick -version` |
| `python3` + `pip` | только при сборке x86_64-шаблона | `python3 --version` |

```bash
sudo dnf install -y docker git curl unzip rpm openssh-clients coreutils \
  patchelf binutils ImageMagick python3          # Fedora
```

Эмулятор в SDK 5.2 — **QEMU/KVM**, X11-обвязка не нужна. Окружение целиком проверяет (из
корня игры) `./godot-to-aurora/scripts/build_x86_64_rpm.sh --check`: перечисляет
найденные компоненты, бракует стоковый Godot без платформы `AuroraOS` и подсказывает, чего
не хватает; с `--strict` возвращает код 1, если сборка невозможна.

---

## Быстрый старт

Окружение ставится один раз — см. [«Запуск с нуля»](#запуск-с-нуля). Дальше два
равноправных пути.

### Путь A — с агентом

```bash
cd /path/to/your-godot-game
git clone <этот-репозиторий> godot-to-aurora    # или распакуй архив в godot-to-aurora/
```

```text
Изучи godot-to-aurora/AGENTS.md и портируй мою игру на ОС Аврора.
```

Агент создаст `PLAN.md`, поправит UI, шрифты, сохранения и жизненный цикл, соберёт RPM и
проверит игру в эмуляторе. Если каталог кита лежит **внутри** проекта, создай
`godot-to-aurora/.gdignore` **до** первого открытия Godot: иначе движок просканирует
`modules/*.gd` и выдаст `Class "AuroraSafeArea" hides a global script class`. Имя каталога
`godot-to-aurora/` лучше не менять — на него ссылаются документация и команды.

### Путь B — вручную, четыре шага

**1. Скопируй кит и подключи модули** (единственный канонический путь):

```bash
mkdir -p scripts/aurora assets/fonts
cp godot-to-aurora/modules/*.gd          scripts/aurora/
cp godot-to-aurora/modules/fonts/*.ttf   assets/fonts/
cp godot-to-aurora/modules/fonts/LICENSE assets/fonts/
```

```ini
[autoload]
AuroraLifecycle="*res://scripts/aurora/aurora_lifecycle.gd"
SaveService="*res://scripts/aurora/save_service.gd"
```

Ссылки на `res://godot-to-aurora/modules/...` не используй: шрифты импортируются дважды,
а `class_name` даёт ту же ошибку про `AuroraSafeArea`.

**2. Подготовь движок** (Aurora-редактор + шаблоны):

```bash
./godot-to-aurora/scripts/fetch_engine.sh --from-dir /path/to/engine   # свои бинарники
./godot-to-aurora/scripts/fetch_engine.sh                              # из GitHub Releases
```

Проверка `SHA256SUMS` обязательна для любого источника, включая `--from-dir`: без файла
сумм или при несовпадении хэша скрипт завершается с ошибкой. Свои суммы генерируются
через `--skip-checksum --write-sums`, порядок публикации — в
[docs/RELEASES_GUIDE.md](docs/RELEASES_GUIDE.md).

**3. Собери RPM** (параметры пакета — в [таблице](#параметры-пакета) или в
`export_presets.cfg`):

```bash
export ORG_NAME=ru.example APP_NAME=mygame APP_TITLE="Моя игра"
./godot-to-aurora/scripts/build_x86_64_rpm.sh --check
./godot-to-aurora/scripts/build_x86_64_rpm.sh
```

**4. Подпиши, установи, запусти** с иконки меню эмулятора:

```bash
./godot-to-aurora/scripts/deploy_emulator.sh
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec journalctl -f -t ru.example.mygame
```

Деплой сам находит эмулятор, подписывает RPM тестовыми ключами SDK, создаёт в эмуляторе
`~/Downloads`, устанавливает пакет через APM и сверяет `VERSION-RELEASE` установленной
версии с собранной. SSH-ключ по умолчанию — `~/AuroraOS/vmshare/ssh/private_keys/sdk`,
переопределяется `AURORA_SSH_KEY`.

### Запуск с нуля

Один раз на чистой машине; если `--check` проходит — пропускай.

1. **SDK.** Установи Aurora SDK 5.2.1.200 через `SDKMaintenanceTool` и проверь
   `~/AuroraOS/bin/sfdk --version`. Другой каталог задаётся `AURORA_SDK_HOME`. Кит
   поддерживает серию `5.2.x`: на `5.1.x`/`5.3.x` печатается предупреждение, со
   `--strict-sdk` — ошибка. Раскладка SDK —
   [docs/SDK_5_2_ARCHITECTURE.md § 1](docs/SDK_5_2_ARCHITECTURE.md#1-что-установлено-и-где-лежит).
2. **Docker и образ.** Установщик SDK загружает `sdk-build-tools-5.2.1.200-x86_64.tar` и
   тегирует образ как `aurora-build-tools-<user>:5.2.1.200`. Проверка:
   `docker images --format '{{.Repository}}:{{.Tag}}' | grep '^aurora-build-tools'`. Нет
   образа — переустанови компонент Build Tools; нестандартный задаётся
   `AURORA_BUILD_IMAGE`.
3. **KVM.** `ls -l /dev/kvm`, затем `sudo modprobe kvm_intel` (или `kvm_amd`) и
   `sudo setfacl -m u:$USER:rw /dev/kvm`.
4. **Эмулятор и ключи.** Запусти эмулятор из SDK: `sfdk device list` должен показать
   `Aurora OS эмулятор 5.2.1.200` (`defaultuser@127.0.0.1:2223`). Тестовые ключи подписи
   лежат в `~/AuroraOS/package-signing/`, деплой находит их сам; копировать ключи в
   репозиторий нельзя.

---

## Параметры пакета

Приоритет: переменные окружения → `export_presets.cfg` → `project.godot` → дефолт.
Полное имя пакета = `<ORG_NAME>.<APP_NAME>`: оно попадает в RPM, `.desktop`, `Exec`,
иконки и путь песочницы `~/.local/share/<org>/<app>/`.

| Переменная | Назначение / пример |
|---|---|
| `ORG_NAME` | `ru.example` (dotted, lowercase) |
| `APP_NAME` | `mygame` (`[a-z0-9_]`) |
| `APP_TITLE` | `Моя игра` |
| `APP_VERSION` / `APP_RELEASE` | `0.1.0` / `1` |
| `PERMISSIONS` | `Audio,Internet,Camera` (Sailjail) |
| `ORIENTATION` | `Landscape`, `Portrait`, `Dynamic` (или `0/2/4`, `1/3/5`, `6`) |
| `APP_COMMENT` / `APP_CATEGORIES` | `Моя игра` / `Game` |
| `RPM_LICENSE` | `Proprietary` (по умолчанию), `MIT` |
| `ICON_SVG` | мастер-иконка (по умолчанию `<проект>/icon.svg`) |
| `AURORA_PRESET` | имя пресета; пусто = первый `platform="AuroraOS"` |
| `BUILD_DIR` | каталог сборки (по умолчанию `<проект>/build`) |
| `GODOT_BIN` | явный путь к Aurora-редактору |
| `AURORA_TEMPLATE_X86_64` / `AURORA_TEMPLATE_AARCH64` | явные пути к шаблонам (устаревшая `AURORA_TEMPLATE` — для обеих арх.) |
| `AURORA_KIT_ENGINE_DIR` | куда `fetch_engine.sh` положил бинарники |
| `AURORA_SDK_HOME` | корень SDK, по умолчанию `~/AuroraOS` |
| `AURORA_BUILD_IMAGE` | образ `aurora-build-tools-*`, если имя нестандартное |
| `AURORA_EXTRA_DIR` | готовый `extra/` для сборки x86_64-шаблона |
| `AURORA_ARM64_LIB_DIR` | arm64-библиотеки для aarch64-пакета |
| `AURORA_SSH_KEY` | приватный SSH-ключ; по умолчанию `~/AuroraOS/vmshare/ssh/private_keys/sdk` |
| `AURORA_SSH_HOST` / `AURORA_SSH_PORT` / `AURORA_SSH_USER` | SSH-доступ к устройству (по умолчанию из `sfdk`) |
| `AURORA_DEVICE` / `AURORA_EMULATOR` | то же, что `--device` / `--emulator` |
| `AURORA_SIGN_KEY` / `AURORA_SIGN_CERT` | свои ключ и сертификат подписи |

### Версии

Версии кита, движка, SDK, SCons и xkbcommon живут в [versions.env](versions.env):
`KIT_VERSION`, `GODOT_AURORA_TAG` и SHA коммита форка (`GODOT_AURORA_SHA`), SHA-256
релизных бинарников движка, `SDK_SUPPORTED_PREFIX`, `SCONS_VERSION`,
`XKBCOMMON_VERSION`. Правь их там, а не в скриптах.

При сборке x86_64-шаблона скачиваются SCons (wheel с проверкой SHA-256) и архив
`libxkbcommon` с [xkbcommon.org](https://xkbcommon.org/) — сумма тоже сверяется. Версия
`libxkbcommon` определяется из образа сборки, известные перечислены в
`XKBCOMMON_KNOWN_VERSIONS`; незнакомую добавь в список либо передай
`build_x86_64_rpm.sh --skip-checksum` (явный отказ от проверки).

---

## Что делает кит

```
godot-to-aurora/
├── AGENTS.md            плейбук агента: аудит → PLAN.md → код → RPM → проверка
├── versions.env         KIT_VERSION, теги и SHA движка и SDK, версии SCons/xkbcommon
├── scripts/             fetch_engine, build_x86_64_rpm (--arch x86_64|aarch64),
│                        build_aarch64_rpm, deploy_emulator, lib/common.sh
├── templates/           пресет AuroraOS, .desktop (Sailjail), .spec
├── modules/             aurora_lifecycle.gd, safe_area_helper.gd, save_service.gd,
│                        fonts/ (Liberation + LICENSE, SIL OFL 1.1)
├── tests/               CLI-тесты, headless-тесты модулей, фикстура
├── .github/workflows/   CI: shellcheck, bash -n, CLI- и headless-тесты
└── docs/                SDK 5.2, публикация движка, состав релиза
```

Сборочное окружение определяется автоматически: `docker` (SDK 5.2, `tools/run`) либо
`none` — если собирать нечем. `sfdk` нужен только для работы с устройствами: запуск
эмулятора, `device exec`, `journalctl`.

Кит **не** переписывает геймплей и графику, не гарантирует Godot 3.x, C#/.NET и
GDExtension без нативной сборки, не собирает `aarch64`-шаблон (готовые
`auroraos_*.arm64` берутся из релиза движка) и не заменяет проверку на живом устройстве.

---

## Режимы и артефакты

```bash
./scripts/build_x86_64_rpm.sh --version        # godot-to-aurora <KIT_VERSION>
./scripts/build_x86_64_rpm.sh --pck-only       # быстро проверить упаковку
./scripts/build_x86_64_rpm.sh --skip-template  # шаблон уже собран
./scripts/build_x86_64_rpm.sh --force-preset   # пересоздать пресет AuroraOS
./scripts/build_x86_64_rpm.sh --no-xkbcommon   # без приватной libxkbcommon
./scripts/build_x86_64_rpm.sh --strict-sdk     # ошибка, если SDK не 5.2.x
./scripts/build_x86_64_rpm.sh --skip-checksum  # отказ от SHA-256 xkbcommon/SCons
./scripts/fetch_engine.sh --check --print-paths
./scripts/deploy_emulator.sh --check           # что видит деплой: RPM, устройство, ключ
./scripts/deploy_emulator.sh --sign-only       # только подпись
```

`--version` печатает одну строку `godot-to-aurora <KIT_VERSION>` и работает без
`project.godot`, SDK, сети и Docker.

```
build/<org>.<app>.pck
build/icons/{86,108,128,172}.png                       # иконки только в build/
build/rpmbuild/RPMS/x86_64/<org>.<app>-<version>-<release>.x86_64.rpm
build/backups/export_presets.cfg.bak.<timestamp>       # если пресет создавался/менялся
```

Иконки генерируются в `$BUILD_DIR/icons/` и не мусорят в дереве игры. Ключи подписи
копируются во временный `$BUILD_DIR/.signing.XXXXXX` и удаляются после подписи — в
проекте и в Git их не остаётся.

### Пресет и `.pck`

Если `AURORA_PRESET` не задан и `--preset` не передан, кит берёт **первый существующий
пресет с `platform="AuroraOS"`** (как бы он ни назывался) и читает из него
`package/organization` и `package/name`. Существующий пресет не перезаписывается: новый
создаётся, только когда пресетов `AuroraOS` нет, `--force-preset` — осознанно.

В `exclude_filter` попадают только `build/*` и каталог кита относительно проекта
(например, `godot-to-aurora/*`); `tools/`, `addons/`, `docs/` не исключаются — они могут
быть нужны игре. Вхождение проверяется точным токеном (`mybuild/*` ≠ `build/*`).

---

## Сборка для реального устройства (aarch64)

Штатный экспортёр Авроры в форке Godot вызывает `sfdk engine exec sb2`, которого в SDK
5.2 больше нет, поэтому кит упаковывает aarch64-RPM нативно — с шаблоном
`auroraos_release.arm64` и `rpmbuild --target aarch64-meego-linux-gnu`:

```bash
./godot-to-aurora/scripts/build_aarch64_rpm.sh     # = build_x86_64_rpm.sh --arch aarch64
./godot-to-aurora/scripts/deploy_emulator.sh \
  --rpm build/rpmbuild/RPMS/aarch64/<pkg>-*.aarch64.rpm --device "<имя>"
```

Перед упаковкой проверяется ELF-архитектура шаблона (`readelf -h`). `fetch_engine.sh`
ставит arm64-шаблоны в `~/.local/share/godot/export_templates/`, поэтому они доступны
Aurora-редактору. Приватная `libxkbcommon` в пакет по умолчанию не входит (на устройстве
она системная), при необходимости задай `AURORA_ARM64_LIB_DIR`. Телефон — в режиме
разработчика.

---

## Частые проблемы

* **`sfdk: Неизвестная команда 'engine'`** — это норма: в SDK 5.2 нет sb2, сборка идёт
  через `<sdk>/tools/run` и Docker-образ `aurora-build-tools-*`.
* **`/dev/kvm` недоступен** — `sudo modprobe kvm_intel` (или `kvm_amd`) и
  `sudo setfacl -m u:$USER:rw /dev/kvm`.
* **APM не ставит пакет** — RPM не подписан либо архитектура не совпала с устройством.
* **Игра вертикальная** — согласуй `orientation` в `project.godot`, `Orientation=`
  в `.desktop` и запуск с иконки меню, а не из шелла.
* **Пустые глифы, HUD за краем экрана** — `.ttf` в `res://assets/fonts/` (на Авроре
  `fontconfig=no`) и отступы через `AuroraSafeArea`, а не от safe area монитора.

Полная таблица «симптом → что проверить» — в [AGENTS.md § 5](AGENTS.md#5-траблшутинг) и
[docs/SDK_5_2_ARCHITECTURE.md](docs/SDK_5_2_ARCHITECTURE.md).

---

## Тесты и CI

```bash
bash tests/test_cli.sh                                # без сети, Godot, Docker и SDK
GODOT_BIN=/path/to/Godot bash tests/run_modules.sh    # headless-модули
```

CLI-тесты покрывают флаги, `--check` без SDK, обязательность `SHA256SUMS`, пресет
`AuroraOS`, экранирование `%`/`"`/`\`, токены `exclude_filter` и кастомный `BUILD_DIR`;
headless-тесты — safe area, атомарную запись и восстановление сохранений, коллизии
кириллических слотов, миграцию версий и жизненный цикл. CI гоняет `shellcheck`, `bash -n`
и оба набора тестов.

---

## Документация

* [AGENTS.md](AGENTS.md) — плейбук агента: процесс, инварианты, чек-лист.
* [docs/SDK_5_2_ARCHITECTURE.md](docs/SDK_5_2_ARCHITECTURE.md) — SDK 5.2: `tools/run`,
  эмулятор, Sailjail, `rpmsign-external`, APM.
* [docs/RELEASES_GUIDE.md](docs/RELEASES_GUIDE.md) — публикация бинарников движка.
* [docs/ENGINE_RELEASE_4.7.2-auroraos1.md](docs/ENGINE_RELEASE_4.7.2-auroraos1.md) —
  состав и контрольные суммы релиза движка.
* [CHANGELOG.md](CHANGELOG.md) — что изменилось между версиями кита.

---

## Лицензия

Код кита, скрипты и шаблоны — MIT ([LICENSE](LICENSE)). Шрифты Liberation в
`modules/fonts/` — SIL OFL 1.1, один файл `modules/fonts/LICENSE` на все начертания.

Aurora-сборка Godot (`savegame/godot`, тег `4.7.2-auroraos1`) — MIT; бинарники движка
распространяются через Releases и не входят в Git. Уведомления об авторских правах и
полный текст MIT — в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

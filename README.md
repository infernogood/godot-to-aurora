<div align="center">

# godot-to-aurora

### Порт игры Godot 4 на ОС Аврора при помощи ИИ-агента

**Скопируйте каталог в проект, скажите Claude, GPT, Copilot или любому другому ИИ-агенту в любом харнесс «портируй игру на Аврору»
и получите подписанный RPM для эмулятора и устройства. Без ручного изучения Aurora SDK.**

[![CI](https://github.com/infernogood/godot-to-aurora/actions/workflows/ci.yml/badge.svg)](https://github.com/infernogood/godot-to-aurora/actions/workflows/ci.yml)
![Версия](https://img.shields.io/badge/версия-1.1.2-blue)
![Godot](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godotengine&logoColor=white)
![Aurora OS](https://img.shields.io/badge/Aurora_OS-5.2%2B-1f6feb)
![Agent-ready](https://img.shields.io/badge/AGENTS.md-agent--ready-8957e5)
[![Лицензия: MIT](https://img.shields.io/badge/лицензия-MIT-green)](LICENSE)

[Быстрый старт](#быстрый-старт) ·
[Ручная сборка](#ручная-сборка) ·
[Требования](#требования) ·
[Параметры](#параметры-пакета) ·
[Частые проблемы](#частые-проблемы) ·

</div>

---

## Одна фраза → готовый RPM

Вы кладёте кит в корень своей игры:

```bash
cd /path/to/your-godot-game
git clone https://github.com/infernogood/godot-to-aurora godot-to-aurora
touch godot-to-aurora/.gdignore
```

И говорите агенту ровно одну вещь:

```text
Изучи godot-to-aurora/AGENTS.md и портируй мою игру на ОС Аврора.
```

Дальше агент идёт по плейбуку из [`AGENTS.md`](AGENTS.md):

| # | Что делает агент | Чем проверяется |
|---|---|---|
| 1 | **Аудит** проекта: разрешение, ориентация, шрифты, сохранения, ввод, пауза, сеть, плагины | читает `project.godot`, сцены, UI-скрипты |
| 2 | Пишет **`PLAN.md`**: «проблема → правка → файл → риск»; спорные места выносит на ваше решение | вы видите план до первой правки |
| 3 | **Минимальные правки**: шрифты `.ttf`, safe area, сохранения в `user://`, жизненный цикл, ориентация | геймплей и графику не трогает |
| 4 | **Собирает** `.pck` и RPM (`x86_64` для эмулятора, `aarch64` для телефона) | `--check` → `--pck-only` → полная сборка |
| 5 | **Подписывает, ставит и запускает** в эмуляторе, читает `journalctl` | сверяет установленную `VERSION-RELEASE` |
| 6 | Отдаёт **отчёт**: что изменено, чем проверено, что осталось открытым | вы решаете, что принимать |

Сам кит проверяется так же просто, и это работает без SDK, Docker и сети:

```bash
$ ./godot-to-aurora/scripts/build_x86_64_rpm.sh --version
godot-to-aurora 1.1.2
```

Под нет рукой агента? Тогда посмотрите [ручной путь из четырёх шагов](#ручная-сборка).

---

## Почему агентный кит, а не просто шаблон сборки

Большинство «портов на Аврору» — это набор инструкций, который надо прочитать, понять и
выполнить. У **godot-to-aurora** другая идея: **рутину портирования выполняет ИИ-агент**, а
человек принимает решения.

Весь опыт реальных переносов зашит в то, что умеет читать агент:

- 📘 **`AGENTS.md`** — читаемый агентом плейбук: процесс, жёсткие инварианты, чек-лист, таблица
  «симптом → что проверить» и граница «сначала спроси, потом правь».
- 🧪 **Скрипты с `--check`** — сначала агент диагностирует окружение, потом строит. Код
  возврата и сообщения понятны и человеку, и модели.
- 🧱 **Готовые модули** — `AuroraLifecycle`, `SaveService`, `AuroraSafeArea` и встроенные
  шрифты копируются в игру, а не пишутся заново.
- 🔒 **Защита от типичных ошибок агента** — проверка SHA-256 движка, проверка ELF-архитектуры
  шаблона, критические файлы не попадают в Git.

### В отличие от ручной сборки через `sfdk`

| | Вручную через Aurora SDK | С godot-to-aurora |
|---|---|---|
| Изучение SDK 5.2 | Нужно: `tools/run`, Docker-образ, Sailjail, APM, `rpmsign-external` | Уже зашито в скрипты и `AGENTS.md` |
| Адаптация игры | Искать, почему пустые глифы, HUD за краем, не пишутся сохранения | Аудит и готовые модули: шрифты, safe area, `user://` |
| Сборка RPM | Своя цепочка экспорта, пакета и подписи | `build_x86_64_rpm.sh` / `build_aarch64_rpm.sh` |
| Установка в эмулятор | Подпись, `device exec`, D-Bus, проверка версии | `deploy_emulator.sh` делает всё и сверяет версию |
| Кто делает рутину | Вы | Ваш агент |

---

## Быстрый старт

Окружение ставится один раз — см. [«Требования»](#требования) и
[«Запуск с нуля»](#запуск-с-нуля). В дальнейшем два пути использования:

### Сборка с агентом

Подходит любой агент, который читает файлы и запускает команды: **Claude Code,
Codex/GPT, Copilot** и другие.

В начале скопируйте репозиторий в корень своего проекта. Три обязательных команды в терминале:

```bash
cd /path/to/your-godot-game
git clone https://github.com/infernogood/godot-to-aurora godot-to-aurora
touch godot-to-aurora/.gdignore
```
Далее простейший промт:

```text
Изучи godot-to-aurora/AGENTS.md и портируй мою игру на ОС Аврора.
```

Агент создаст `PLAN.md`, поправит UI, шрифты, сохранения и жизненный цикл, соберёт RPM и
проверит игру в эмуляторе.

> Создайте `godot-to-aurora/.gdignore` **до** первого открытия Godot: иначе движок
> просканирует `modules/*.gd` и выдаст `Class "AuroraSafeArea" hides a global script class`.
> Имя каталога `godot-to-aurora/` лучше не менять — на него ссылаются документация и команды.

### Ручная сборка

**1. Скопируйте модули** (единственный канонический путь):

```bash
mkdir -p scripts/aurora assets/fonts
cp godot-to-aurora/modules/*.gd          scripts/aurora/
cp godot-to-aurora/modules/fonts/*.ttf   assets/fonts/
cp godot-to-aurora/modules/fonts/LICENSE assets/fonts/
```

Подключите автозагрузки в `project.godot`:

```ini
[autoload]
AuroraLifecycle="*res://scripts/aurora/aurora_lifecycle.gd"
SaveService="*res://scripts/aurora/save_service.gd"
```

> Ссылки на `res://godot-to-aurora/modules/...` не используйте: шрифты импортируются дважды,
> а `class_name` даёт ту же ошибку про `AuroraSafeArea`. `AuroraSafeArea` — статический
> хелпер, автозагрузка ему не нужна.

**2. Подготовьте движок** (Aurora-редактор + шаблоны):

```bash
./godot-to-aurora/scripts/fetch_engine.sh --from-dir /path/to/engine   # свои бинарники
./godot-to-aurora/scripts/fetch_engine.sh                              # из GitHub Releases
```

Проверка `SHA256SUMS` обязательна для любого источника, включая `--from-dir`: без файла сумм
или при несовпадении хэша скрипт завершается с ошибкой. Порядок публикации своих сумм —
в [docs/RELEASES_GUIDE.md](docs/RELEASES_GUIDE.md).

**3. Соберите RPM:**

```bash
export ORG_NAME=ru.example APP_NAME=mygame APP_TITLE="Моя игра"
./godot-to-aurora/scripts/build_x86_64_rpm.sh --check
./godot-to-aurora/scripts/build_x86_64_rpm.sh
```

**4. Подпишите, установите, запустите** с иконки меню эмулятора:

```bash
./godot-to-aurora/scripts/deploy_emulator.sh
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec journalctl -f -t ru.example.mygame
```

Деплой сам находит эмулятор, подписывает RPM тестовыми ключами SDK, создаёт в эмуляторе
`~/Downloads`, ставит пакет через APM и сверяет `VERSION-RELEASE` установленной версии с
собранной. SSH-ключ по умолчанию — `~/AuroraOS/vmshare/ssh/private_keys/sdk`, переопределяется
через `AURORA_SSH_KEY`.

---

## Требования

Linux-хост `x86_64` с доступом к `/dev/kvm`.

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
корня игры) `./godot-to-aurora/scripts/build_x86_64_rpm.sh --check`: перечисляет найденные
компоненты, бракует стоковый Godot без платформы `AuroraOS` и подсказывает, чего не хватает;
с `--strict` возвращает код 1, если сборка невозможна.

### Запуск с нуля

Один раз на чистой машине; если `--check` проходит — пропустите.

1. **SDK.** Установите Aurora SDK 5.2.1.200 через `SDKMaintenanceTool` и проверьте
   `~/AuroraOS/bin/sfdk --version`. Другой каталог задаётся `AURORA_SDK_HOME`. Кит поддерживает
   серию `5.2.x`: на `5.1.x`/`5.3.x` печатается предупреждение, со `--strict-sdk` — ошибка.
   Раскладка SDK — [docs/SDK_5_2_ARCHITECTURE.md § 1](docs/SDK_5_2_ARCHITECTURE.md#1-что-установлено-и-где-лежит).
2. **Docker и образ.** Установщик SDK загружает `sdk-build-tools-5.2.1.200-x86_64.tar` и
   тегирует образ как `aurora-build-tools-<user>:5.2.1.200`. Проверка:
   `docker images --format '{{.Repository}}:{{.Tag}}' | grep '^aurora-build-tools'`. Нет образа —
   переустановите компонент Build Tools; нестандартный задаётся `AURORA_BUILD_IMAGE`.
3. **KVM.** `ls -l /dev/kvm`, затем `sudo modprobe kvm_intel` (или `kvm_amd`) и
   `sudo setfacl -m u:$USER:rw /dev/kvm`.
4. **Эмулятор и ключи.** Запустите эмулятор из SDK: `sfdk device list` должен показать
   `Aurora OS эмулятор 5.2.1.200` (`defaultuser@127.0.0.1:2223`). Тестовые ключи подписи лежат
   в `~/AuroraOS/package-signing/`, деплой находит их сам; копировать ключи в репозиторий нельзя.

---

## Структура проекта

```text
godot-to-aurora/
├── AGENTS.md            плейбук агента: аудит → PLAN.md → код → RPM → проверка
│
├── versions.env         KIT_VERSION, теги и SHA движка и SDK, версии SCons/xkbcommon
│
├── scripts/             fetch_engine, build_x86_64_rpm (--arch x86_64|aarch64),
│                        build_aarch64_rpm, deploy_emulator, lib/common.sh
│
├── templates/           пресет AuroraOS, .desktop (Sailjail), .spec
│
├── modules/             aurora_lifecycle.gd, safe_area_helper.gd, save_service.gd,
│                        fonts/ (Liberation + LICENSE, SIL OFL 1.1)
│
├── tests/               CLI-тесты, headless-тесты модулей, фикстура
│
├── .github/workflows/   CI: shellcheck, bash -n, CLI- и headless-тесты
│
└── docs/                SDK 5.2, публикация движка, состав релиза
```

| Модуль | Что решает |
|---|---|
| `AuroraLifecycle` | Жизненный цикл приложения, пауза, согласование ориентации |
| `SaveService` | Атомарная запись сохранений в `user://` (`tmp` + `rename`), восстановление, миграция версий |
| `AuroraSafeArea` | Отступы под вырезы и скругления экрана без хардкода пикселей |
| `fonts/` | Liberation Sans/Mono: на Авроре `fontconfig=no`, системные шрифты недоступны |

### Чего кит не делает

Кит **не** переписывает геймплей и графику, не гарантирует Godot 3.x, C#/.NET и GDExtension
без нативной сборки, не собирает `aarch64`-шаблон (готовые `auroraos_*.arm64` берутся из
релиза движка) и не заменяет проверку на живом устройстве.

---

## Параметры пакета

Приоритет: переменные окружения → `export_presets.cfg` → `project.godot` → дефолт. Полное имя
пакета = `<ORG_NAME>.<APP_NAME>`: оно попадает в RPM, `.desktop`, `Exec`, иконки и путь
песочницы `~/.local/share/<org>/<app>/`.

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

<details>
<summary><b>Расширенные переменные окружения</b></summary>

| Переменная | Назначение / пример |
|---|---|
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

</details>

### Версии

Версии кита, движка, SDK, SCons и xkbcommon живут в [`versions.env`](versions.env):
`KIT_VERSION`, `GODOT_AURORA_TAG` и SHA коммита форка (`GODOT_AURORA_SHA`), SHA-256 релизных
бинарников движка, `SDK_SUPPORTED_PREFIX`, `SCONS_VERSION`, `XKBCOMMON_VERSION`. Правьте их
там, а не в скриптах.

При сборке x86_64-шаблона скачиваются SCons (wheel с проверкой SHA-256) и архив
`libxkbcommon` с [xkbcommon.org](https://xkbcommon.org/) — сумма тоже сверяется. Версия
`libxkbcommon` определяется из образа сборки, известные перечислены в
`XKBCOMMON_KNOWN_VERSIONS`; незнакомую добавьте в список либо передайте
`build_x86_64_rpm.sh --skip-checksum` (явный отказ от проверки).

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

`--version` печатает одну строку `godot-to-aurora <KIT_VERSION>` и работает без `project.godot`,
SDK, сети и Docker.

```text
build/<org>.<app>.pck
build/icons/{86,108,128,172}.png                       # иконки только в build/
build/rpmbuild/RPMS/x86_64/<org>.<app>-<version>-<release>.x86_64.rpm
build/backups/export_presets.cfg.bak.<timestamp>       # если пресет создавался/менялся
```

Иконки генерируются в `$BUILD_DIR/icons/` и не мусорят в дереве игры. Ключи подписи копируются
во временный `$BUILD_DIR/.signing.XXXXXX` и удаляются после подписи — в проекте и в Git их не
остаётся.

### Пресет и `.pck`

Если `AURORA_PRESET` не задан и `--preset` не передан, кит берёт **первый существующий пресет
с `platform="AuroraOS"`** (как бы он ни назывался) и читает из него `package/organization` и
`package/name`. Существующий пресет не перезаписывается: новый создаётся, только когда
пресетов `AuroraOS` нет, `--force-preset` — осознанно.

В `exclude_filter` попадают только `build/*` и каталог кита относительно проекта (например,
`godot-to-aurora/*`); `tools/`, `addons/`, `docs/` не исключаются — они могут быть нужны игре.
Вхождение проверяется точным токеном (`mybuild/*` ≠ `build/*`).

---

## Сборка для реального устройства (aarch64)

Штатный экспортёр Авроры в форке Godot вызывает `sfdk engine exec sb2`, которого в SDK 5.2
больше нет, поэтому кит упаковывает aarch64-RPM нативно — с шаблоном `auroraos_release.arm64`
и `rpmbuild --target aarch64-meego-linux-gnu`:

```bash
./godot-to-aurora/scripts/build_aarch64_rpm.sh     # = build_x86_64_rpm.sh --arch aarch64
./godot-to-aurora/scripts/deploy_emulator.sh \
  --rpm build/rpmbuild/RPMS/aarch64/<pkg>-*.aarch64.rpm --device "<имя>"
```

Перед упаковкой проверяется ELF-архитектура шаблона (`readelf -h`). `fetch_engine.sh` ставит
arm64-шаблоны в `~/.local/share/godot/export_templates/`, поэтому они доступны
Aurora-редактору. Приватная `libxkbcommon` в пакет по умолчанию не входит (на устройстве она
системная), при необходимости задайте `AURORA_ARM64_LIB_DIR`. Телефон — в режиме разработчика.

---

## Частые проблемы

| Симптом | Что проверить |
|---|---|
| `sfdk: Неизвестная команда 'engine'` | Это норма: в SDK 5.2 нет sb2, сборка идёт через `<sdk>/tools/run` и Docker |
| `/dev/kvm` недоступен | `sudo modprobe kvm_intel` (или `kvm_amd`) и `sudo setfacl -m u:$USER:rw /dev/kvm` |
| APM не ставит пакет | RPM не подписан либо архитектура не совпала с устройством |
| Игра вертикальная | Согласуйте `orientation` в `project.godot`, `Orientation=` в `.desktop` и запускайте с иконки меню, а не из шелла |
| Пустые глифы | `.ttf` в `res://assets/fonts/` (на Авроре `fontconfig=no`), без `SystemFont` |
| HUD за краем экрана | Отступы через `AuroraSafeArea`, а не от safe area монитора на ПК |
| `SamePackageIsInstalled` | Поднимите `APP_RELEASE` |
| В PCK попал кит | `exclude_filter`, точные токены `build/*` и `godot-to-aurora/*` |

Полная таблица — в [AGENTS.md § 5](AGENTS.md#5-траблшутинг) и
[docs/SDK_5_2_ARCHITECTURE.md](docs/SDK_5_2_ARCHITECTURE.md).

---

## Тесты и CI

```bash
bash tests/test_cli.sh                                # без сети, Godot, Docker и SDK
GODOT_BIN=/path/to/Godot bash tests/run_modules.sh    # headless-модули
```

CLI-тесты покрывают флаги, `--check` без SDK, обязательность `SHA256SUMS`, пресет `AuroraOS`,
экранирование `%`/`"`/`\`, токены `exclude_filter` и кастомный `BUILD_DIR`; headless-тесты —
safe area, атомарную запись и восстановление сохранений, коллизии кириллических слотов,
миграцию версий и жизненный цикл. CI гоняет `shellcheck`, `bash -n` и оба набора тестов.

---

## Экосистема и документация

* [`AGENTS.md`](AGENTS.md) — плейбук агента: процесс, инварианты, чек-лист.
* [`docs/SDK_5_2_ARCHITECTURE.md`](docs/SDK_5_2_ARCHITECTURE.md) — SDK 5.2: `tools/run`,
  эмулятор, Sailjail, `rpmsign-external`, APM.
* [`docs/RELEASES_GUIDE.md`](docs/RELEASES_GUIDE.md) — публикация бинарников движка.
* [`docs/ENGINE_RELEASE_4.7.2-auroraos1.md`](docs/ENGINE_RELEASE_4.7.2-auroraos1.md) — состав и
  контрольные суммы релиза движка.
* [`CHANGELOG.md`](CHANGELOG.md) — что изменилось между версиями кита.
* [`savegame/godot`](https://github.com/savegame/godot) — Aurora-порт движка Godot
  (тег `4.7.2-auroraos1`), на котором работает кит.

---

## Лицензия

Код кита, скрипты и шаблоны — MIT ([LICENSE](LICENSE)). Шрифты Liberation в `modules/fonts/` —
SIL OFL 1.1, один файл `modules/fonts/LICENSE` на все начертания.

Aurora-сборка Godot (`savegame/godot`, тег `4.7.2-auroraos1`) — MIT; бинарники движка
распространяются через Releases и не входят в Git. Уведомления об авторских правах и полный
текст MIT — в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

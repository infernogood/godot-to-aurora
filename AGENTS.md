# AGENTS.md — агентный плейбук портирования Godot 4 → ОС Аврора

Ты — senior-инженер по портированию игр на Godot 4 и системный инженер мобильного
Linux (ОС Аврора 5.x / Sailfish-стек). Этот файл — твоя рабочая инструкция. Пользователь
один раз кладёт каталог `godot-to-aurora/` в корень своей игры и говорит:

> «Изучи `godot-to-aurora/AGENTS.md` и портируй мою игру на ОС Аврора».

Дальше ты проходишь путь сам: аудит → `PLAN.md` → правки кода/UI → сборка `.pck` →
подписанный RPM для эмулятора `x86_64` → (если есть устройство) RPM для `aarch64` →
проверка в эмуляторе → отчёт. Не задавай пользователю вопросов, ответы на которые можно
получить из репозитория, команд и этого файла.

---

## 0. Правила работы

1. **Сначала аудит, потом код.** Не меняй игру, пока не создан `PLAN.md` (раздел 2) и не
   зафиксированы блокеры.
2. **Минимальные правки.** Кит даёт готовые модули и скрипты; адаптируй существующий код
   точечно, не переписывай геймплей и не меняй художественный стиль.
3. **Ничего не выдумывай.** Если значение неизвестно (имя пакета, разрешения, заголовок),
   выведи его из `project.godot` / `export_presets.cfg`, а при отсутствии — предложи
   разумный дефолт и явно отметь его в отчёте.
4. **Бинарники — не в Git.** Движок, шаблоны, RPM и `build/` исключены через `.gitignore`.
   Не добавляй их в коммит.
5. **Проверяй каждый этап.** После правок — headless-тесты проекта (если есть), после
   сборки — запуск/`journalctl` в эмуляторе. Не отчитывайся «готово» без прогона.
6. **Секреты не коммить.** Ключи подписи лежат в SDK; `build/.signing/` уже в `.gitignore`.
7. **Разрушительные действия — только по явной просьбе.** Не удаляй ассеты, сцены и
   пользовательские сохранения. Перед правкой `project.godot`, `export_presets.cfg` и
   сцен делай резервную копию (кит делает `.bak.<timestamp>` сам).

---

## 1. Что такое ОС Аврора для игры (жёсткие ограничения)

| Требование | Что это значит для Godot-проекта |
|---|---|
| `aarch64` (устройства) и `x86_64` (эмулятор) | нативные `.so`/GDExtension пересобрать; C#/.NET не поддерживается |
| Wayland, композитор Lipstick | X11 и XWayland нет; бинарник не должен требовать `libX11`, `libxcb`, `libdecor` |
| OpenGL ES 3.0 (GLES3), Vulkan нет | рендерер строго `gl_compatibility`; шейдеры совместимы с GLES3 |
| `fontconfig=no` в шаблонах Авроры | `SystemFont` на устройстве не работает — только встроенные `.ttf` |
| Sailjail / RPM | приложение ставится как `ru.<org>.<app>`; `/usr/share/<pkg>/` read-only; запись только в `user://` |
| Мобильный жизненный цикл | сворачивание = пауза, мьют, автосохранение; запуск только с иконки меню |
| Ориентация | жёсткая фиксация (`Landscape`/`Portrait`), сенсорные режимы в эмуляторе не работают |
| Пакетный менеджер `ru.omp.APM` | RPM обязан быть подписан доверенным сертификатом |
| SDK 5.2+ | нет `sb2`/`mb2`/`sfdk engine`; сборка в Docker-образе `aurora-build-tools-*` через `<sdk>/tools/run` |

Все инструменты и точные команды уже есть в `godot-to-aurora/scripts/` и
`docs/SDK_5_2_ARCHITECTURE.md`. Не изобретай альтернативный тулчейн, пока не прочитаешь их.

---

## 2. Фаза 0 — аудит проекта и `PLAN.md`

### 2.1. Собери факты

```bash
# версия Godot и платформа проекта
grep -E 'config_version|config/features|config/name|config/version' project.godot

# рендер, физика, сжатие текстур, ориентация, растяжение
grep -nE 'rendering_method|physics_engine|import_etc2_astc|handheld/orientation|stretch' project.godot

# экспортные пресеты и «мусор» в PCK
cat export_presets.cfg 2>/dev/null || echo "preset отсутствует"

# нативные зависимости и C#
find . -name '*.cs' -o -name '*.csproj' -o -name '*.gdextension' -o -name '*.gdns' | head -50
grep -RIn --include='*.gd' -E 'OS\.execute|SystemFont|HTTPRequest|WebSocket|FileAccess|DirAccess' . | head -100

# жизненный цикл и ввод
grep -RIn --include='*.gd' -E 'NOTIFICATION_APPLICATION|NOTIFICATION_WM|_input\(|_unhandled_input\(' . | head -100
grep -nA4 '^\[input\]' project.godot

# размеры и тяжёлые ассеты
du -sh .; du -sh assets/* 2>/dev/null | sort -h | tail -15
find assets -type f \( -name '*.wav' -o -name '*.png' -o -name '*.exr' \) -size +2M -printf '%s %p\n' | sort -n | tail -20

# тесты и CI
ls -la tests 2>/dev/null; find . -maxdepth 2 -name '*.yml' -o -name '*.yaml' | head
```

Дополнительно открой:

* `project.godot` — главная сцена, автозагрузки, `gui/theme/custom_font`, `InputMap`;
* `export_presets.cfg` — `export_filter`, `exclude_filter`, `package/*`;
* `addons/` — рантайм-плагины (редакторные можно исключить из PCK);
* шейдеры — `texture()`/`SCREEN_TEXTURE`/`DEPTH_TEXTURE`/`gl_FragDepth` под GLES3;
* сцены с `SubViewport` — их количество и размеры (слабый мобильный GPU);
* `InputMap` — события должны иметь `device:-1`, а не `device:16` (последний приходит с
  джойстика и не срабатывает на телефоне).

### 2.2. Создай `PLAN.md`

Структура (обязательные разделы):

1. **Сводка и матрица совместимости** — версия Godot, рендерер, физика, ориентация, размер
   PCK; таблица: «готово» / «требует адаптации» / «блокер».
2. **Движок и шаблоны** — какой редактор/шаблоны нужны, есть ли они, как получить.
3. **Код, UI и ввод** — конкретные файлы/сцены/скрипты под правку, с оценкой объёма.
4. **Сборка RPM** — aarch64 и x86_64, подпись, установка.
5. **Чеклист миграции** — этапы с командами и критериями приёмки.
6. **Риски** — что может не завестись именно у этой игры.

Блокерами считай: C#-скрипты, GDExtension `.so` без сборки под `aarch64`/`x86_64`,
Vulkan-only шейдеры/фичи, требование X11, запись в `res://`, отсутствие `icon.svg`,
проект на Godot 3.x (нужен отдельный путь миграции, кит рассчитан на Godot 4).

После `PLAN.md` переходи к фазам 1–4. Отмечай в плане, что реально сделано.

---

## 3. Фаза 1 — окружение, движок, настройки проекта

### 3.1. Получи движок и шаблоны

Кит ожидает Aurora-сборку Godot (форк `savegame/godot`, тег `4.7.2-auroraos1`) и шаблоны
`auroraos_*.arm64` / `auroraos_release.x86_64`. Скачай их один раз:

```bash
# из локального архива (например, из ранее собранного aurora-export/engine)
./godot-to-aurora/scripts/fetch_engine.sh --from-dir /path/to/engine

# или из GitHub Releases кита
AURORA_KIT_REPO=<owner>/godot-to-aurora ./godot-to-aurora/scripts/fetch_engine.sh

# проверить, что всё на месте
./godot-to-aurora/scripts/fetch_engine.sh --check
```

Скрипт кладёт бинарники в `~/.local/share/godot-to-aurora/engine`, а `arm64`-шаблоны —
в `~/.local/share/godot/export_templates/4.7.2.stable/`, после чего экспортёр Авроры
находит их автоматически.

Для сборки x86_64-RPM нужен Aurora SDK 5.2+ с Docker-образом `aurora-build-tools-*`
(см. `docs/SDK_5_2_ARCHITECTURE.md`). Проверка готовности:

```bash
./godot-to-aurora/scripts/build_x86_64_rpm.sh --check
```

### 3.2. Настрой `project.godot`

Внеси только отсутствующее, не перезаписывай чужие значения вслепую:

```ini
[application]
config/version="<версия игры>"

[display]
window/size/viewport_width=1280        ; базовое разрешение верстки
window/size/viewport_height=800
window/stretch/mode="canvas_items"
window/stretch/aspect="expand"
window/handheld/orientation=0          ; 0=Landscape, 1=Portrait, 2/3=reverse, 6=Dynamic
window/energy_saving/keep_screen_on=true

[physics]
3d/physics_engine="GodotPhysics3D"     ; Jolt на мобильном GLES3 не нужен

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
textures/vram_compression/import_etc2_astc=true

[gui]
theme/custom_font="res://assets/fonts/<ваш-моноширинный>.ttf"
```

Почему ориентация — жёсткая: `window/handheld/orientation=4` (sensor landscape) в
эмуляторе без акселерометра оставляет окно вертикальным. Дополнительно кит-модуль
`aurora_lifecycle.gd` вызывает `DisplayServer.screen_set_orientation()` при старте.

После смены сжатия текстур переимпортируй ресурсы:

```bash
./godot-to-aurora/scripts/build_x86_64_rpm.sh --pck-only --import
# или вручную:
<enginedir>/Godot_v4.7.2-auroraos1_linux.x86_64 --headless --path . --import
```

### 3.3. Встрой шрифты

`fontconfig=no` означает, что `SystemFont` на устройстве не найдёт ни DejaVu, ни Noto.
Скопируй шрифты кита в проект и используй их как `FontFile`:

```bash
mkdir -p assets/fonts
cp godot-to-aurora/modules/fonts/*.ttf assets/fonts/
cp godot-to-aurora/modules/fonts/LICENSE* assets/fonts/
```

Liberation Mono / Sans / Sans Bold покрывают кириллицу, `«»`, тире, `№`, `→`. Замени
`SystemFont.new()` на загрузку из `res://assets/fonts/...` с `SystemFont` только как fallback:

```gdscript
func _load_font(path: String, fallback: PackedStringArray) -> Font:
    if ResourceLoader.exists(path):
        var res := load(path)
        if res is Font:
            return res
    var sys := SystemFont.new()
    sys.font_names = fallback
    return sys
```

Для `Label3D` и `RichTextLabel` назначь тот же `FontFile` вручную: глобальный
`gui/theme/custom_font` на 3D-надписи не действует.

---

## 4. Фаза 2 — код, UI, ввод, жизненный цикл

### 4.1. Safe area и масштаб UI

Скопируй `modules/safe_area_helper.gd` (class `AuroraSafeArea`) в проект, например в
`scripts/aurora/safe_area_helper.gd`.

Ключевая ловушка: на десктопе `DisplayServer.get_display_safe_area()` возвращает либо
`Rect2i(0,0,0,0)`, либо отступы панели монитора даже для маленького окна. Наивная формула
`window.x - safe.end.x` превращает правый/нижний отступ в размер всего экрана и схлопывает
HUD. Модуль уже:

* возвращает нули при пустой/невалидной safe area;
* игнорирует safe area, когда окно меньше экрана (оконный режим);
* переводит отступы в координаты вьюпорта и ограничивает их `clampf`;
* считает `ui_scale` c ограничением `0.85…1.5` и минимальную touch-цель 48 dp.

Пример интеграции в существующий HUD (адаптируй имена под проект):

```gdscript
const BASE_VIEWPORT := Vector2(1280, 800)

func _refresh_metrics() -> void:
    var vp := get_viewport().get_visible_rect().size
    ui_scale = AuroraSafeArea.ui_scale(vp, BASE_VIEWPORT)
    safe = AuroraSafeArea.insets(vp)

func _px(value: float) -> float:
    return value * ui_scale

func _fs(base: int) -> int:
    return maxi(12, int(round(float(base) * ui_scale)))

var insets := AuroraSafeArea.insets(vp)       # {"l","t","r","b","valid"}
var usable := AuroraSafeArea.usable_rect(vp)  # Rect2 с учётом вырезов
left_panel.offset_left = float(insets["l"]) + _px(24.0)
```

Требования к мобильному UI:

* интерактивные элементы — не меньше 48×48 dp; увеличивай `custom_minimum_size`;
* модальные окна не должны упираться в края: добавляй safe insets к отступам;
* проверь шрифты на 1.5× масштабе — заголовки не должны обрезаться;
* не полагайся на наведение мыши и `Esc`: добавь видимую кнопку «Назад/Пауза».

### 4.2. Жизненный цикл: пауза, мьют, автосохранение

Скопируй `modules/aurora_lifecycle.gd` и зарегистрируй как автозагрузку:

```ini
[autoload]
AuroraLifecycle="*res://scripts/aurora/aurora_lifecycle.gd"
```

Подключи сигналы в главной сцене:

```gdscript
func _ready() -> void:
    AuroraLifecycle.suspended.connect(_on_suspended)
    AuroraLifecycle.resumed.connect(_on_resumed)
    AuroraLifecycle.autosave_requested.connect(_save_snapshot)

func _on_suspended(_reason: String) -> void:
    show_pause_overlay()

func _on_resumed(_reason: String) -> void:
    # Дерево намеренно НЕ размораживается: игрок жмёт «Продолжить».
    refresh_pause_button()

func _save_snapshot(reason: String) -> void:
    SaveService.save("default", _snapshot())
```

Встроенные защиты модуля, которые нельзя терять при интеграции:

1. **Первый фокус.** `NOTIFICATION_APPLICATION_FOCUS_OUT` до первого
   `FOCUS_IN` игнорируется. Иначе окно, созданное фоновым, или headless-тест сразу
   встают на паузу (реальный баг, ловившийся графическими тестами).
2. **Идемпотентность.** Повторные `FOCUS_OUT`/`PAUSED` не сохраняют игру и не паузят её дважды.
3. **Мьют Master** запоминает исходное состояние шины и не включает звук, если игра
   сама его выключила.
4. **Автосохранение до заморозки дерева** — сигнал `autosave_requested` приходит
   синхронно до `tree.paused = true`.
5. **Ручной выход из паузы** — `AuroraLifecycle.resume_game()`; не размораживай дерево
   автоматически по `FOCUS_IN`.

Если в проекте уже есть свой `_notification()`, не дублируй его — либо переведи логику
на модуль, либо вызови аналогичные действия вручную, обязательно с защитой первого фокуса.

### 4.3. Сохранения в `user://`

Скопируй `modules/save_service.gd` и зарегистрируй автозагрузкой `SaveService`. Сервис:

* пишет только в `user://` (на устройстве — `~/.local/share/<org>/<app>/`), поэтому
  дополнительных `Permissions` для сохранений не нужно;
* пишет атомарно: `<slot>.json.tmp` → `flush` → `rename`, с fallback на прямую запись;
* хранит JSON-конверт с `version`, `saved_at`, `slot`, `data` и умеет отклонять чужие версии;
* нормализует имя слота (нижний регистр, `[a-z0-9_-]`) и не выпускает из каталога сохранений.

```gdscript
SaveService.save("default", {"level": 3, "score": 1200})
var data := SaveService.load_slot("default")
SaveService.erase_slot("default")
for slot in SaveService.list_slots():
    print(slot, " -> ", SaveService.slot_path(slot))
```

**Важно для тестов:** в режиме `--script` глобальные идентификаторы автозагрузок на этапе
парсинга недоступны. Обращайся к сервису в рантайме:

```gdscript
var saves := get_node_or_null("/root/SaveService")
if saves != null:
    saves.save("default", snapshot)
```

Не пиши в `res://`, `/usr/share/...`, `/tmp` и рядом с бинарником: в RPM всё, кроме
`user://`, может быть read-only, а `/tmp` не сохраняется между запусками.

### 4.4. Ввод: тап vs драг, InputMap, касания

В Godot `_input()` вызывается раньше `_unhandled_input()`. Поэтому попытка «перехватить»
жест в камере через `set_input_as_handled()` не спасает: контроллер взаимодействия уже
увидит событие. Арбитраж делай **внутри контроллера взаимодействия**:

```gdscript
const DRAG_THRESHOLD_DP := 12.0
var touch_index := -1
var touch_start := Vector2.ZERO
var touch_moved := false

func _input(event: InputEvent) -> void:
    if event is InputEventScreenTouch:
        if event.pressed:
            touch_index = event.index
            touch_start = event.position
            touch_moved = false
    elif event is InputEventScreenDrag and event.index == touch_index:
        if event.position.distance_to(touch_start) > _drag_threshold():
            touch_moved = true

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventScreenTouch and not event.pressed and event.index == touch_index:
        var moved := touch_moved
        touch_index = -1
        touch_moved = false
        if not moved:
            _pick(event.position)   # тап: выбор объекта

func _drag_threshold() -> float:
    var screen_scale := maxf(1.0, DisplayServer.screen_get_scale())
    var viewport_scale := maxf(1.0, get_viewport().get_visible_rect().size.y / 800.0)
    return DRAG_THRESHOLD_DP * maxf(screen_scale, viewport_scale)
```

Дополнительно:

* события `InputMap` должны иметь `device:-1`; проверь и пересоздай, если видишь `device:16`;
* дублируй клавиатурные действия сенсорными кнопками; подписи «Esc» заменяй на «Назад»;
* используй `DisplayServer.is_touchscreen_available()` для подсказок, а не как условие
  работоспособности;
* виртуальная клавиатура: `LineEdit`/`TextEdit` на Авроре работают, но проверь, что
  окно не перекрывает поле ввода.

### 4.5. Производительность под GLES3

* Ограничь количество и разрешение `SubViewport` (каждый — отдельный рендер-таргет).
* Тени и `Environment` проверяй на устройстве: на слабом GPU отключай SSAO/SSIL/объёмный туман.
* Текстуры: `import_etc2_astc=true`, размеры 256–1024 для мобильных; большие PNG сжимай.
* Аудио: `.wav` 10 МБ → `.ogg` Vorbis q4–5; обнови ссылки в `.tscn`/`.tres`/`.gd` и
  удали старые `.wav`/`.import`.
* MSAA/FSR: оставь `disabled` или 2×, проверь FPS в эмуляторе.

---

## 5. Фаза 3 — сборка и установка

### 5.1. Пресет экспорта

Кит создаёт пресет сам, если его нет:

```bash
./godot-to-aurora/scripts/build_x86_64_rpm.sh --write-preset
```

Параметры берутся из `export_presets.cfg` (`package/organization`, `package/name`,
`package/launcher_name`, `package/version`, `permissions/*`) или из переменных окружения:

| Переменная | Значение | Пример |
|---|---|---|
| `ORG_NAME` | организация (dotted, lowercase) | `ru.example` |
| `APP_NAME` | имя приложения `[a-z0-9_]` | `mygame` |
| `APP_TITLE` | заголовок в меню | `Моя игра` |
| `APP_VERSION` | версия RPM | `0.1.0` |
| `APP_RELEASE` | релиз RPM | `1` |
| `PERMISSIONS` | права Sailjail через запятую | `Audio,Internet` |
| `ORIENTATION` | `Landscape` / `Portrait` / `Dynamic` | `Landscape` |
| `APP_COMMENT` | комментарий `.desktop` | `Ночная смена оператора` |
| `RPM_LICENSE` | лицензия RPM | `Proprietary` / `MIT` |

Полный пакет = `ORG_NAME.APP_NAME` (например, `ru.example.mygame`). Не используй заглавные
буквы, пробелы и дефисы в имени пакета.

Если кита ещё нет в проекте, а пресет есть — проверь вручную, что в нём:

```ini
platform="AuroraOS"
texture_format/s3tc_bptc=false
texture_format/etc2_astc=true
binary_format/arm64=true
binary_format/arm32=false
exclude_filter="docs/*, tests/*, utilities/*, tools/*, build/*, addons/*"
```

`export_filter="all_resources"` при пустом `exclude_filter` затянет в PCK тесты, доки,
`utilities/`, `build/` и редакторные аддоны. Скрипт сборки дописывает исключения сам и
делает бэкап `export_presets.cfg`.

### 5.2. Иконки

Нужны PNG `86×86`, `108×108`, `128×128`, `172×172`. Скрипт сборки рендерит их из
`icon.svg` в `icons/` (ImageMagick или rsvg-convert) и переиспользует существующие.
Экспортёр `aarch64` берёт те же файлы из пресета.

### 5.3. RPM для эмулятора (x86_64)

```bash
./godot-to-aurora/scripts/build_x86_64_rpm.sh
```

Что произойдёт:

1. разбор параметров и создание пресета (при необходимости);
2. проверка/сборка шаблона `auroraos_release.x86_64` (Wayland-only, GLES3);
3. `--headless --import` при первом запуске;
4. экспорт `build/<pkg>.pck` через Aurora-редактор;
5. генерация иконок, `.desktop`, `.spec`;
6. копирование `libxkbcommon.so.0*` и `patchelf --force-rpath --set-rpath`;
7. `rpmbuild` внутри Docker-образа SDK (`tools/run`) с обёрткой, потому что `tools/run`
   ломает кавычки в `--define "_topdir ..."`.

Результат: `build/rpmbuild/RPMS/x86_64/<pkg>-<version>-<release>.x86_64.rpm`.

Полезные режимы:

```bash
./godot-to-aurora/scripts/build_x86_64_rpm.sh --check          # только диагностика
./godot-to-aurora/scripts/build_x86_64_rpm.sh --pck-only       # PCK + иконки, без RPM
./godot-to-aurora/scripts/build_x86_64_rpm.sh --skip-template  # не собирать шаблон
./godot-to-aurora/scripts/build_x86_64_rpm.sh --force-preset   # пересоздать пресет
```

Шаблон x86_64 в релизах кита уже собран. Если его нет, скрипт соберёт его в образе
`aurora-build-tools-*` (~30 минут): сам подложит заголовки xkbcommon, `xkbcommon.pc` и
SCons, потому что в образе их нет, а сети/zypper/dnf внутри контейнера тоже нет.

### 5.4. Подпись и установка в эмулятор

Эмулятор SDK 5.2 — это QEMU/KVM (не VirtualBox). Нужны модули KVM и доступ к `/dev/kvm`:

```bash
sudo modprobe kvm && sudo modprobe kvm_amd    # или kvm_intel
sudo setfacl -m u:$USER:rw /dev/kvm           # либо usermod -aG kvm,render + перелогин
```

Затем одной командой:

```bash
./godot-to-aurora/scripts/deploy_emulator.sh
```

Скрипт:

* находит уже зарегистрированное устройство/эмулятор в `sfdk`;
* ждёт готовности SSH (`defaultuser@127.0.0.1:2223`, ключ SDK);
* копирует ключи SDK в `build/.signing/` и подписывает RPM через `rpmsign-external`
  (самоподписанные `openssl`-сертификаты отклоняются с `Failed to get certificate extensions`);
* проверяет подпись через `dump`, копирует пакет в `/home/defaultuser/Downloads/`;
* ставит через D-Bus `ru.omp.APM.Install`;
* ждёт появления пакета в `rpm -q` и подсказывает, как смотреть логи.

Запускай игру **только с иконки в меню ОС**: запуск из консоли не активирует Sailjail
(`OrganizationName`, `ApplicationName`, `Permissions`) и `Orientation` из `.desktop`.

### 5.5. RPM для реального устройства (aarch64)

**Важно:** штатный экспортёр Авроры в форке `savegame/godot` реализует RPM-экспорт через
`sfdk engine exec sb2` — API, удалённый в SDK 5.2. Поэтому «Project → Export → AuroraOS»
на SDK 5.2.1.200 падает с ошибкой про `export/auroraos/build_target`/sfdk и не собирает
пакет. Кит обходит это нативной упаковкой: берёт архитектурно-независимый `.pck`,
готовый `auroraos_release.arm64` и вызывает `rpmbuild --target aarch64-meego-linux-gnu`
в том же Docker-образе SDK.

1. `fetch_engine.sh` уже положил `auroraos_release.arm64` и `auroraos_debug.arm64` в
   `~/.local/share/godot/export_templates/4.7.2.stable/` и в каталог движка.
2. Собери aarch64-RPM:

```bash
./godot-to-aurora/scripts/build_aarch64_rpm.sh
# это обёртка над build_x86_64_rpm.sh --arch aarch64; параметры пакета те же
```

Результат: `build/rpmbuild/RPMS/aarch64/<org>.<app>-<version>-<release>.aarch64.rpm`.

3. Проверь архитектуру и содержимое:

```bash
docker run --rm -v "$PWD/build:/build:ro" --entrypoint /bin/bash \
  aurora-build-tools-deus:5.2.1.200 -lc \
  "rpm -qp --qf '%{ARCH}\n' /build/rpmbuild/RPMS/aarch64/<pkg>.aarch64.rpm"
```

4. Подпиши и установи на устройство в режиме разработчика:

```bash
./godot-to-aurora/scripts/deploy_emulator.sh \
  --rpm build/rpmbuild/RPMS/aarch64/<pkg>-*.aarch64.rpm --device "<имя устройства>"
```

Если SSH-ключ устройства недоступен, `deploy_emulator.sh` откатится на
`sfdk deploy --manual`. Для ручной установки:

```bash
sfdk -c device="<имя>" deploy --manual build/rpmbuild/RPMS/aarch64/<pkg>-*.aarch64.rpm
```

`aarch64`-пакет по умолчанию **не** несёт приватную `libxkbcommon`: на устройстве она
есть в системе. Если нужна приватная копия (нестандартный образ), укажи каталог с
aarch64-библиотекой: `AURORA_ARM64_LIB_DIR=/path/to/arm64/lib ./scripts/build_aarch64_rpm.sh`.

Если в системе установлен старый SDK 5.1 с рабочим `sb2`, штатный экспортёр может
собрать aarch64-RPM сам — но китом этот путь не проверялся и не поддерживается.

---

## 6. Фаза 4 — проверка (Definition of Done)

Прогоняй на эмуляторе, запуская игру с иконки:

- [ ] приложение стартует без ошибок `Wayland`, `EGL`, `libxkbcommon`, `GLES3`;
- [ ] ориентация соответствует `.desktop` (`Landscape`/`Portrait`), HUD не обрезан вырезами;
- [ ] 3D-сцена, материалы и шейдеры отрисовываются как на ПК (нет чёрных/розовых объектов);
- [ ] кириллица читается во всех UI/Label3D; шрифты не «прыгают» при масштабе;
- [ ] касания, свайпы и кнопки работают; драг не срабатывает как тап;
- [ ] звук и музыка играют; при сворачивании звук выключается;
- [ ] сворачивание ставит игру на паузу; возврат не размораживает её без действия игрока;
- [ ] автосохранение появляется в `user://`:

```bash
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec \
  ls -la /home/defaultuser/.local/share/<org>/<app>/
```

- [ ] повторный запуск игры подхватывает сохранение (если игра это поддерживает);
- [ ] `journalctl` не содержит повторяющихся ERROR/Crash:
  `sfdk -c device="<device>" device exec journalctl -f -t <pkg>`;
- [ ] headless-тесты проекта (если есть) проходят; новые тесты safe area/lifecycle/saves — тоже;
- [ ] `build/`, `utilities/`, `*.rpm`, ключи не попали в `git status`.

Команды для быстрой проверки пакета без эмулятора:

```bash
rpm -qlp build/rpmbuild/RPMS/x86_64/<pkg>-*.rpm
readelf -d build/rpmbuild/files/usr/bin/<pkg> | grep -Ei 'libX11|wayland|EGL'  # X11 быть не должно
patchelf --print-rpath build/rpmbuild/files/usr/bin/<pkg>
```

---

## 7. Траблшутинг: проверенные грабли

| Симптом | Причина | Решение |
|---|---|---|
| `sfdk: Неизвестная команда 'engine'/'tools'` | SDK 5.2 удалил sb2/mb2/engine | сборка через `<sdk>/tools/run` + Docker-образ `aurora-build-tools-*`; cmd-ы только `emulator/device/deploy/maintain` |
| `Workspace is not defined. Add WORKSPACE_DIR` | `tools/run` требует переменную | `WORKSPACE_DIR="$PWD" <sdk>/tools/run …` |
| `rpmbuild: Name field must be present` | `%install`/`%post` в комментариях spec раскрываются как макросы | не упоминай `%`-директивы в комментариях spec (шаблон кита уже исправлен) |
| `Failed to get certificate extensions` | самоподписанный openssl-сертификат | подписывать `~/AuroraOS/package-signing/regular_{key,cert}.pem` |
| «Пакет не имеет подписи разработчика» | контейнер не увидел относительные пути ключей | ключи и RPM копировать в `build/` проекта, пути внутри `tools/run` — `/workspace/...` |
| APM `FileNotFound` | RPM не там, где его ищет APM | копировать в `/home/defaultuser/Downloads/` и передавать полный путь |
| эмулятор не стартует, `Could not access KVM` | нет `/dev/kvm` или прав | `modprobe kvm[_amd/_intel]`, `setfacl -m u:$USER:rw /dev/kvm`, группы `kvm,render` |
| `sfdk emulator start` падает по таймауту | QEMU грузится дольше лимита | подождать и проверить `sfdk device exec true`; скрипт кита это делает |
| игра вертикальная в эмуляторе | `orientation=4` ждёт акселерометр | `window/handheld/orientation=0` + `Orientation=Landscape` в `.desktop` |
| HUD схлопнулся/съехал на ПК | нулевая или «мониторная» safe area | `AuroraSafeArea` (проверка `size<=0` и `win < screen`) |
| игра сразу на паузе при старте в фоне | `FOCUS_OUT` до первого `FOCUS_IN` | защита первого фокуса в `aurora_lifecycle.gd` |
| `SystemFont` не находит шрифт на устройстве | `fontconfig=no` | встроенные `.ttf` из `modules/fonts` |
| шрифт в `Label3D` не применился | глобальная тема не влияет на 3D | назначить `FontFile` напрямую |
| `--script` тесты падают на автозагрузке | глобальное имя не резолвится при парсинге | `get_node_or_null("/root/SaveService")` в рантайме |
| тап срабатывает после драга | `_input` раньше `_unhandled_input` | арбитраж в контроллере по накопленному смещению |
| PCK на сотни МБ | `exclude_filter` пуст | исключить `docs/tests/tools/utilities/build/addons`, кит делает это сам |
| `Cannot get class 'GitPlugin'` при импорте | редакторный аддон исключён из проекта | безвредно; не включай `addons/*` в PCK |
| `Invalid package organization/name` | заглавные буквы/пробелы/дефисы | `[a-z0-9_]`, dotted org |
| приложение не поворачивается после установки | запуск из консоли | запускать только с иконки меню |
| `rpmbuild` не видит patchelf/scons/заголовки | их нет в образе | patchelf — на хосте; scons/xkbcommon — `prepare_extra` в ките |
| xkbcommon conflict при установке | системная зависимость | `__requires_exclude`, приватная копия в `/usr/share/<pkg>/lib`, RPATH |

---

## 8. Отчёт в конце

Выведи пользователю:

1. **Что изменено** — таблица: файл → что сделано → зачем.
2. **Что создано** — `PLAN.md`, `build/<pkg>.pck`, RPM, иконки, тесты.
3. **Команды прогонов** и результаты (тесты, `--check`, сборка, установка, `journalctl`).
4. **Параметры пакета** — org/app/title/version/orientation/permissions.
5. **Осталось/риски** — например, проверка на физическом `aarch64`-устройстве, оптимизация
   ассетов, отсутствие ключей для продакшн-подписи.
6. **Как запускать** — короткая инструкция: установить, открыть меню, свернуть, где логи.

Не пиши «всё готово», если RPM не установлен и игра не проверена в эмуляторе. Разделяй
«собрано», «установлено» и «проверено в бою».

---

## 9. Карта файлов кита

```
godot-to-aurora/
├── AGENTS.md                     этот плейбук
├── README.md                     быстрый старт для человека
├── scripts/
│   ├── fetch_engine.sh           движок + шаблоны + export_templates
│   ├── build_x86_64_rpm.sh       пресет, PCK, иконки, RPM; --arch x86_64|aarch64
│   ├── build_aarch64_rpm.sh      обёртка для aarch64 (устройство)
│   └── deploy_emulator.sh        KVM, подпись, APM, установка, логи
├── templates/
│   ├── export_presets.aurora.cfg шаблон пресета AuroraOS
│   ├── app.desktop.in            .desktop с Sailjail и Orientation
│   └── app.spec.in               .spec без BuildRequires: patchelf/xkbcommon
├── modules/
│   ├── aurora_lifecycle.gd       ориентация, пауза, мьют, автосохранение
│   ├── safe_area_helper.gd       safe area + ui_scale + touch-цели
│   ├── save_service.gd           атомарные JSON-сохранения в user://
│   └── fonts/                    Liberation + лицензии
└── docs/
    ├── SDK_5_2_ARCHITECTURE.md   устройство SDK 5.2, tools/run, QEMU, APM, Sailjail
    └── RELEASES_GUIDE.md         как публиковать бинарники движка в GitHub Releases
```

Если чего-то не хватает — сначала посмотри `--help` соответствующего скрипта и
`docs/SDK_5_2_ARCHITECTURE.md`, потом меняй код кита. Правки кита должны оставаться
универсальными: никаких имён конкретной игры в скриптах и шаблонах.

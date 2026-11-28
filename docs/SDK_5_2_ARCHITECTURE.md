# Аврора SDK 5.2 — архитектура и подводные камни

Документ описывает SDK **5.2.1.200** (ветка 5.2+), на которой проверялся кит. Более
ранние SDK (5.0/5.1) использовали `sb2`/`mb2` и VirtualBox; их поведение отличается и
в конце отмечено отдельно.

Версии, которые встречаются ниже (тег движка, версия SDK, SCons, xkbcommon, версия
кита), вынесены в [`versions.env`](../versions.env) в корне репозитория: скрипты читают
их оттуда, а документация ссылается на тот же источник. Официальная документация
платформы — <https://developer.auroraos.ru/doc/software_development>.

---

## 1. Что установлено и где лежит

Типичная раскладка после установки `AuroraSDK-5.2.1.200`:

```
~/AuroraOS/
├── bin/sfdk                      # CLI SDK
├── sdk/5.2.1.200/
│   ├── tools/run                 # вход в сборочный Docker-контейнер
│   ├── tools/gcc-x86_64, g++-x86_64, qmake-x86_64, pkg-config, …
│   ├── targets/x86_64-meego-linux-gnu/   # sysroot для приложений
│   └── toolchains/               # обычно пусто в 5.2.1
├── emulator/
│   ├── AuroraOS-5.2.1.200/       # конфиг эмулятора (image.qcow2, ssh/, vmshare/)
│   └── Aurora_OS-5.2.1.200-Emulator_x86_64.qcow2
├── package-signing/
│   ├── regular_key.pem           # тестовый ключ подписи RPM
│   └── regular_cert.pem
└── vmshare/ssh/private_keys/sdk  # SSH-ключ к эмулятору
```

`tools/run` — обычный bash-скрипт. Он:

1. требует переменную `WORKSPACE_DIR` (иначе `Workspace is not defined`);
2. заменяет `$WORKSPACE_DIR` на `/workspace` в `PWD` и во **всех аргументах**;
3. запускает `docker run --rm -v "$WORKSPACE_DIR:/workspace" -w <путь> <образ> <аргументы>`.

Имя образа зашито в `tools/run` (`aurora-build-tools-<user>:5.2.1.200` в проверенной
установке, `<user>` — логин владельца SDK). Кит читает его оттуда, но его можно
переопределить `AURORA_BUILD_IMAGE`.

---

## 2. CLI: что осталось от sfdk

Кит рассчитан на Aurora SDK **5.2.x**. Версия установленного SDK берётся из имени
каталога `~/AuroraOS/sdk/<версия>`. Для другой серии (`5.1.x`, `5.3.x`, …)
`build_x86_64_rpm.sh` и `deploy_emulator.sh` печатают предупреждение и продолжают;
флаг `--strict-sdk` превращает это в ошибку. Поддерживаемая серия задаётся
`SDK_SUPPORTED_PREFIX` в `versions.env` (по умолчанию `5.2.`).

В 5.2 команды сборки удалены. Доступно:

```bash
sfdk --version
sfdk device list
sfdk device exec <команда>
sfdk emulator list
sfdk emulator start [имя]
sfdk emulator status
sfdk deploy --manual <путь.rpm>
sfdk config [-c device=...] ...
```

Нет `sfdk engine`, `sfdk tools`, `sb2`, `mb2`, `sb2-config`. Если видишь ошибку
`Неизвестная команда 'engine'` — это не поломка, а новая архитектура.

`sfdk` печатает в stderr безобидные `SOFT ASSERT`/`Failed to load system-wide build
engine configuration` — это остатки старой сборочной ВМ, работе не мешают.

### Имена устройств

Имя устройства — человекочитаемое, с пробелами и кириллицей:

```
#0 "Aurora OS эмулятор 5.2.1.200"
    эмулятор    автоопределённое    defaultuser@127.0.0.1:2223
    закрытый ключ: ~/AuroraOS/vmshare/ssh/private_keys/sdk
```

Выбор устройства:

```bash
sfdk config --global device="Aurora OS эмулятор 5.2.1.200"
# или на одну команду:
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec uname -m
```

Всегда квотируй имя: без кавычек `No such device`.

---

## 3. Эмулятор: QEMU + KVM

В 5.2 эмулятор — не VirtualBox, а QEMU/KVM с дисками `.qcow2`. VirtualBox не нужен и
может конфликтовать за аппаратную виртуализацию.

Требования:

```bash
ls -l /dev/kvm
sudo modprobe kvm && sudo modprobe kvm_amd      # Intel: kvm_intel
sudo setfacl -m u:$USER:rw /dev/kvm            # на текущую сессию
# постоянно:
sudo usermod -aG kvm,render "$USER"            # затем перелогиниться
```

Ошибки и их смысл:

| Сообщение | Причина |
|---|---|
| `Could not access KVM kernel module: No such file or directory` | модуль `kvm` не загружен |
| `failed to initialize kvm` + «User is not in the group: kvm» | нет прав на `/dev/kvm` |
| `waiting for virtual machine started is timed out` | QEMU не стартовал (KVM/права) либо грузится дольше лимита `sfdk` |

`sfdk emulator start` может вернуть таймаут, хотя ВМ уже поднимается. Надёжнее проверять
готовность через SSH:

```bash
until sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec true; do sleep 5; done
```

SSH к эмулятору: `defaultuser@127.0.0.1:2223`, ключ
`~/AuroraOS/vmshare/ssh/private_keys/sdk` (`deploy_emulator.sh` берёт его по умолчанию,
переопределяется `AURORA_SSH_KEY`), пароль `devel-su` по умолчанию — `defaultuser`.

---

## 4. Сборочное окружение SDK 5.2

Способ доступа к сборочному окружению определяет `kit_detect_sdk`: `docker` — SDK 5.2 с
`tools/run` и образом сборки (единственный рабочий режим), либо `none` — собирать нечем.
`sfdk` нужен только для устройств и эмулятора (`device exec`, `journalctl`), команд
сборки в 5.2 нет.

Образ `aurora-build-tools-*` — это **нативный rootfs Авроры**, а не кросс-тулчейн:

* есть `gcc`/`g++`, `wayland-scanner`, `pkg-config`, `rpmbuild`, `python3`;
* **нет** сети, `zypper`/`dnf`, `patchelf`, `scons`;
* **нет** заголовков/`.pc` для `xkbcommon` и symlink `libxkbcommon.so`;
* `targets/x86_64-meego-linux-gnu` — sysroot без пакетного менеджера.

Поэтому:

1. **`patchelf` — на хосте**, до упаковки RPM. В контейнере его нет.
2. **`scons`, заголовки `xkbcommon` и `.pc`** подкладываются в контейнер скриптом
   `prepare_extra()` из `build_x86_64_rpm.sh`. Версии зафиксированы в `versions.env`:
   `SCONS_VERSION` (wheel ставится как `pip download "scons==$SCONS_VERSION"`) и
   `XKBCOMMON_VERSION`; SHA-256 скачанного архива xkbcommon и wheel-пакета SCons
   сверяются с `XKBCOMMON_SHA256` / `SCONS_SHA256` перед распаковкой.
   Это нужно только при компиляции x86_64-шаблона, не для сборки игры.
   `extra/` монтируется в `/opt/extra` **только для чтения**, а контейнер
   запускается под `--user "$(id -u):$(id -g)"`. Заголовки, `.pc` и симлинк
   `libxkbcommon.so` лежат внутри `/opt/extra`; в `/usr/include` или `/usr/lib64`
   ничего не копируется. `pkg-config` получает путь через
   `PKG_CONFIG_PATH=/opt/extra/pkgconfig`, а сборка — `-I/opt/extra/include` и
   `-L/opt/extra/lib` (в том числе через `CFLAGS`/`LDFLAGS`).

   Версия библиотеки определяется из образа (`rpm -q libxkbcommon` или
   `strings`). RPM может отдавать packaging-суффикс (`1.3.1+git1`), поэтому
   `versions.env` содержит `XKBCOMMON_KNOWN_VERSIONS` — список версий, для которых
   подходит `XKBCOMMON_SHA256`. Если версия не входит в список, сборка
   останавливается с указанием добавить её в `versions.env` или передать
   `--skip-checksum` (явный, не рекомендуется).
3. **`rpmbuild` запускается обёрткой.** `tools/run` склеивает аргументы в строку и ломает
   кавычки в `--define "_topdir ..."`. Кит пишет `build/rpmbuild/rpmbuild.sh` внутри
   `/workspace` и вызывает его.
4. **Пути.** Внутри контейнера проект виден как `/workspace`. Любой путь вне проекта
   (ключи, RPM, шаблон) недоступен. Кит переводит пути через `kit_to_workspace_path`
   (учитывает произвольный `BUILD_DIR`) и на время подписи кладёт ключи во временный
   каталог `$BUILD_DIR/.signing.XXXXXX`, который удаляется по `trap ... EXIT INT TERM`.
   Постоянного каталога `$BUILD_DIR/.signing/` и копий ключей в проекте не остаётся.

Пример ручного запуска:

```bash
WORKSPACE_DIR="$PWD" ~/AuroraOS/sdk/5.2.1.200/tools/run rpmbuild \
  --target x86_64-meego-linux-gnu \
  --define "_topdir /workspace/build/rpmbuild" \
  -bb /workspace/build/rpmbuild/SPECS/<pkg>.spec
```

Целевая платформа `x86_64-meego-linux-gnu` даёт пакет `Architecture: x86_64`.

---

## 5. Движок Godot для Авроры

Ванильный Godot не содержит платформу `AuroraOS`. Нужен форк
[`savegame/godot`](https://github.com/savegame/godot), тег **`4.7.2-auroraos1`**
(версия совпадает с 4.7.2). Он собирается как `platform=linuxbsd auroraos=yes`:

* `wayland=True`, `x11=False`, `alsa=False`;
* `fontconfig=no` (поэтому `SystemFont` на устройстве не работает); в шрифтах
  `Liberation` нет эмодзи и спецсимволов (`⏸`, `⌖` и т. п.) — при `fontconfig=no` они
  дают пустые глифы, рисуй такие значки примитивами или подключай шрифт с нужными
  глифами;
* экспортёр платформы `AuroraOS` (RPM-экспорт, Sailjail-манифест, иконки).

### Почему нужен шаблон x86_64 «руками»

Экспортный плагин форка объявляет только `arm64` и `arm32`
(`architectures[]` в `export_plugin.cpp`). Готового `auroraos_release.x86_64` в релизе
нет, поэтому для эмулятора шаблон собирается один раз в контейнере SDK:

```bash
python3 /opt/extra/scons-run.py \
  platform=linuxbsd arch=x86_64 target=template_release \
  auroraos=yes use_sowrap=no udev=no speechd=no fontconfig=no \
  accesskit=no openxr=no disable_path_overrides=no \
  optimize=size debug_symbols=no -j"$(nproc)"
```

Сборка занимает ~30 минут на 6–8 потоках (число задаётся `--jobs`, по умолчанию
`nproc`). Результат:
`bin/godot.linuxbsd.template_release.x86_64` (~58 МБ).

Проверка, что шаблон годится для Авроры:

```bash
readelf -d auroraos_release.x86_64 | grep -Ei 'libX11|libxcb|libdecor|libXext'   # пусто
readelf -d auroraos_release.x86_64 | grep -Ei 'wayland|libEGL'                    # есть
```

Шаблон должен быть собран внутри контейнера SDK, а не на хосте: иначе он слинкован с
хостовой glibc, и на устройстве/эмуляторе возможны несовместимости ABI.

### ARM-шаблоны и почему штатный экспорт aarch64 не работает в 5.2

`auroraos_release.arm64` и `auroraos_debug.arm64` из релиза форка кладутся в
`~/.local/share/godot/export_templates/4.7.2.stable/`; Aurora-редактор использует их
для сборки и отладки сборок под устройство.

Однако **штатный RPM-экспорт платформы AuroraOS реализован через `sfdk engine exec sb2`**
(`platform/auroraos/export/export_plugin.cpp`) и в SDK 5.2 не работает: команды `engine`
и sb2 удалены, а редактор требует настройки `export/auroraos/build_target` формата
`AuroraOS-5.1.x-MB2`. Поэтому кит не полагается на GUI-экспорт и упаковывает aarch64-RPM
нативно:

1. `.pck` экспортируется тем же `--export-pack`;
2. в `usr/bin/<pkg>` кладётся `auroraos_release.arm64`;
3. `rpmbuild --target aarch64-meego-linux-gnu` запускается в образе SDK 5.2.

```bash
./godot-to-aurora/scripts/build_aarch64_rpm.sh
```

Такой пакет не содержит приватную `libxkbcommon`: arm64-библиотеки в x86_64-образе нет, а
на устройстве библиотека системная. При необходимости укажи `AURORA_ARM64_LIB_DIR`.

---

## 6. RPM: состав и особенности

Типовая структура пакета:

```
/usr/bin/<org>.<app>
/usr/share/<org>.<app>/<org>.<app>.pck
/usr/share/<org>.<app>/lib/libxkbcommon.so.0*
/usr/share/applications/<org>.<app>.desktop
/usr/share/icons/hicolor/{86x86,108x108,128x128,172x172}/apps/<org>.<app>.png
```

### `libxkbcommon` и RPATH

В образе есть только рантайм-библиотека `libxkbcommon.so.0*` — без `.so`-symlink и
заголовков. Кит:

1. определяет версию библиотеки **из самого образа** (`/usr/lib64/libxkbcommon.so.0.*`)
   и подставляет её в `.pc`(`Version:`). Известные версии перечислены в
   `XKBCOMMON_KNOWN_VERSIONS`; для неизвестной версии сборка просит добавить её в
   `versions.env` или передать `--skip-checksum`. Заголовки берутся из архива
   `XKBCOMMON_VERSION` (ABI совместим);
2. подкладывает заголовки и симлинк `libxkbcommon.so` в `/opt/extra`, не записывая
   ничего в `/usr`; контейнер видит `/opt/extra` только для чтения;
3. копирует `libxkbcommon.so.0*` из sysroot или образа в `/usr/share/<pkg>/lib/`;
4. на хосте выполняет
   `patchelf --force-rpath --set-rpath /usr/share/<pkg>/lib usr/bin/<pkg>`;
5. исключает `libxkbcommon` из автоматических `Requires` (`__requires_exclude`).

Это делает пакет самодостаточным, не ломая системные зависимости Авроры.

### `.desktop` и Sailjail

```ini
[Desktop Entry]
Type=Application
Name=<Заголовок>
Icon=<org>.<app>
Exec=<org>.<app> --main-pack /usr/share/<org>.<app>/<org>.<app>.pck \
     --display-driver wayland --rendering-driver opengl3
X-Nemo-Application-Type=no-invoker
Categories=Game
Terminal=false

[X-Application]
Permissions=Audio,Internet
OrganizationName=<org>
ApplicationName=<app>

[X-Aurora-Application]
Orientation=Landscape
IconMode=Scale
```

Важно:

* `OrganizationName` + `ApplicationName` должны совпадать с `user://`-песочницей;
* `Permissions` — только реально нужные права (нет права «читать весь FS»);
* `Exec` должен содержать `--display-driver wayland --rendering-driver opengl3`;
* `Comment=` обязано быть непустым: APM 5.2 отклоняет `.desktop` без описания
  (при пустом `APP_COMMENT` кит подставляет `APP_TITLE`);
* запуск **только с иконки меню**: консольный запуск не применяет Sailjail и
  `Orientation`.

### Лицензии: `/usr/share/<pkg>/`, без `%license`

Валидатор контента APM 5.2 отвергает любые файлы в `/usr/share/licenses/<pkg>/`
с ошибкой `ru.omp.APM.Error.BadPackageContent`
(`Installation not allowed in this location`), поэтому `LICENSE.Godot` и
`LICENSE.libxkbcommon` кладутся строго внутрь `/usr/share/<pkg>/` (покрыто
`%{_datadir}/%{name}` в `%files`). Макрос `%license` не возвращать, даже если
этого потребует rpmlint или статический ревьюер: для APM классические требования
RPM неприменимы.

### `.spec`

Кит использует минимальный spec без тега `Group:` (устарел) и без
`BuildRequires: patchelf` (его нет в образе):

```spec
%define __requires_exclude ^libxkbcommon.*$
%define __provides_exclude_from ^%{_datadir}/%{name}/lib/.*\.so.*$
%define debug_package %{nil}

%install
cp -a %{_topdir}/files/. %{buildroot}/
```

Комментарии в spec не должны содержать `%install`/`%post` и другие `%`-директивы:
rpm раскрывает макросы даже в комментариях, и пакет становится невалидным
(`Name field must be present`). Поэтому значения полей (Summary, Description, License)
экранируются: `%` → `%%`, управляющие символы и переводы строк вырезаются.

### Что попадает в `.pck`

В пресете `exclude_filter` кит дополняет только `build/*` и каталог самого кита
относительно проекта (например, `godot-to-aurora/*`). Каталоги `tools/`, `addons/`,
`docs/` **не** исключаются автоматически — они могут быть нужны игре. Токены
сравниваются точно (после разбиения по `,` и trim): `mybuild/*` не равно `build/*`.

---

## 7. Подпись и установка

### Подпись

`ru.omp.APM` устанавливает только подписанные RPM. Используй тестовые ключи SDK:

```bash
# ключи живут только в ~/AuroraOS/package-signing/ и во временном staging внутри build/
WORKSPACE_DIR="$PWD" ~/AuroraOS/sdk/5.2.1.200/tools/run rpmsign-external sign \
  -k /workspace/build/.signing.XXXXXX/regular_key.pem \
  -c /workspace/build/.signing.XXXXXX/regular_cert.pem \
  /workspace/build/rpmbuild/RPMS/x86_64/<pkg>-<ver>-<rel>.x86_64.rpm

WORKSPACE_DIR="$PWD" ~/AuroraOS/sdk/5.2.1.200/tools/run rpmsign-external dump \
  /workspace/build/rpmbuild/RPMS/x86_64/<pkg>-<ver>-<rel>.x86_64.rpm
```

* Исходные ключи лежат в `~/AuroraOS/package-signing/`. Контейнер видит только проект,
  поэтому кит копирует их в `mktemp -d "$BUILD_DIR/.signing.XXXXXX"`, а после подписи
  **удаляет** каталог (`trap ... EXIT INT TERM`). Постоянного `$BUILD_DIR/.signing/` нет,
  ключи не попадают ни в Git, ни в резервные копии.
* Код возврата `rpmsign-external dump` проверяется, а отсутствие подписи в выводе
  (`No signatures found in package`) считается ошибкой деплоя.
* Самоподписанный `openssl`-сертификат даёт `Failed to get certificate extensions` —
  `rpmsign-external` требует расширения X.509 v3, которых у простого self-signed нет.

### Установка

```bash
scp -P 2223 -i ~/AuroraOS/vmshare/ssh/private_keys/sdk \
  build/rpmbuild/RPMS/x86_64/<pkg>.rpm defaultuser@127.0.0.1:/home/defaultuser/Downloads/

# аргументы — раздельными элементами argv, без склейки через printf %q
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec \
  gdbus call -y -d ru.omp.APM -o /ru/omp/APM \
  -m ru.omp.APM.Install "/home/defaultuser/Downloads/<pkg>.rpm" "{'ShowPrompt': <true>}"
```

`ShowPrompt: <true>` показывает диалог подтверждения на экране эмулятора;
`<false>` — без диалога.

`sfdk device exec` (в отличие от `tools/run`) передаёт аргументы напрямую в `exec`, без
обёртки в удалённый shell: склейка в одну строку через `printf %q`/
`device_exec_quoted` ломает запуск (`bash: exec: ...: not found`), а `<true>`
в склеенной строке ещё и выглядит как редирект.

После установки проверяй факт установки и `VERSION-RELEASE` по реестру APM, а не
`rpm -q`: APM 5.2 держит пакеты в собственном реестре `/var/lib/apm/registry` и не
пишет их в системный `rpmdb`, поэтому `rpm -q` на устройстве всегда отвечает
«не установлен».

```bash
# реестр APM (deploy_emulator.sh читает его через cat и парсит
# записи вида {"name":"<pkg>","version":"X.Y.Z","release":N};
# если чтение закрыто — fallback по .desktop и /opt/app)
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec \
  cat /var/lib/apm/registry
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec \
  ls /usr/share/applications/<org>.<app>.desktop
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec \
  ls -l /opt/app/<org>.<app>/current
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec journalctl -f
```

Если APM ответил `SamePackageIsInstalled`, значит та же сборка уже стоит — подними
`APP_RELEASE` в `versions.env` (или флагом сборки) и собери пакет заново.

Типичные ошибки APM:

| Ошибка | Причина |
|---|---|
| «Пакет не имеет подписи разработчика» | RPM не подписан либо подпись не попала в файл |
| `ru.omp.APM.Error.FileNotFound` | неверный путь; APM видит `/home/defaultuser/Downloads/...` |
| `ru.omp.APM.Error.BadPackageContent` | файл в запретном месте (`/usr/share/licenses/<pkg>/`), пустой `Comment=` в `.desktop` |
| `SamePackageIsInstalled` | та же сборка уже установлена — поднять `APP_RELEASE` |
| отказ после установки | архитектура пакета не совпадает (x86_64 в устройство/aarch64 в эмулятор) |

---

## 8. Песочница Sailjail

Официальная документация по профилям безопасности и песочнице:
<https://developer.auroraos.ru/doc/software_development/guidelines/security_profiles>
(раздел «Профили безопасности» на developer.auroraos.ru; прежний путь
`/doc/software_development/sailjail` больше не существует и редиректит на оглавление).

* `/usr/share/<pkg>/` — read-only; писать туда нельзя.
* `user://` → `~/.local/share/<org>/<app>/`; `res://` → `/usr/share/<org>/<app>/`.
* Запись в `user://` не требует отдельного `Permissions`.
* Если игра использует сеть — добавь `Internet` в `Permissions`; камеру/микрофон —
  соответствующие права.
* Настройки, кэш и сохранения — только `user://` (см. `modules/save_service.gd`).
* `OrganizationName` + `ApplicationName` из `.desktop` задают песочницу и путь `user://`;
  их надо согласовать с `ORG_NAME`/`APP_NAME` пакета.

---

## 9. Ориентация

Три уровня, все должны согласовываться:

1. `project.godot`: `display/window/handheld/orientation`;
2. `DisplayServer.screen_set_orientation(...)` при старте (кит делает это в
   `aurora_lifecycle.gd`);
3. `.desktop`: `[X-Aurora-Application] Orientation=Landscape` (или `Portrait`).

Нормализация одна и та же в коде (`kit_normalize_orientation`) и в документации:

| Значение `ORIENTATION` / enum Godot | Итог |
|---|---|
| `0`, `2`, `4`, `landscape`, `reverse_landscape`, `sensor_landscape` | `Landscape` |
| `1`, `3`, `5`, `portrait`, `reverse_portrait`, `sensor_portrait` | `Portrait` |
| `6`, `dynamic`, `sensor` | `Dynamic` |

Неизвестное значение — ошибка, а не «тихий» дефолт. `Dynamic`/`sensor` на эмуляторе
без акселерометра остаётся в текущей ориентации окна.

Если всё же окно вертикальное — проверь, что приложение запущено с иконки меню, а не из
консоли.

---

## 10. Эмулятор vs реальное устройство

| | Эмулятор | Устройство |
|---|---|---|
| Арх. | `x86_64` | `aarch64` (есть старые `armv7hl`) |
| Шаблон | собранный `auroraos_release.x86_64` | готовый `auroraos_release.arm64` |
| Сборка RPM | вручную (`build_x86_64_rpm.sh`) | `build_aarch64_rpm.sh` (нативная упаковка; GUI-экспортёр в 5.2 сломан) |
| Эмуляция | QEMU/KVM | — |
| SSH | `127.0.0.1:2223`, ключ SDK | устройство в режиме разработчика |
| Подпись | тестовые ключи SDK | продакшн-сертификат вендора |
| KVM | обязателен | — |

`deploy_emulator.sh` определяет эмулятор по типу устройства из `sfdk device list`
(`эмулятор`/`emulator`) и не подставляет `127.0.0.1:2223` при ошибке разбора. Параметры
SSH `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` применяются только к
локальному эмулятору: для реального устройства проверка ключа хоста остаётся обычной.
Имя установленного пакета берётся из `rpm -qp --queryformat '%{NAME}'`, а не из имени
файла; удалённый каталог загрузок — `/home/$SSH_USER/Downloads`.

---

## 11. Быстрые проверки

```bash
# окружение
./scripts/build_x86_64_rpm.sh --check

# шаблон без X11
readelf -d ~/.local/share/godot-to-aurora/engine/auroraos_release.x86_64 \
  | grep -Ei 'libX11|libxcb|libdecor'   # пусто

# содержимое RPM
rpm -qlp build/rpmbuild/RPMS/x86_64/<pkg>.rpm

# подпись
WORKSPACE_DIR="$PWD" ~/AuroraOS/sdk/5.2.1.200/tools/run \
  rpmsign-external dump /workspace/build/rpmbuild/RPMS/x86_64/<pkg>.rpm

# устройство/эмулятор
sfdk device list
sfdk -c device="<имя>" device exec uname -m
sfdk -c device="<имя>" device exec cat /var/lib/apm/registry
sfdk -c device="<имя>" device exec journalctl -f -t <pkg>

# скриншот снимай из самой игры: штатного CLI-скриншотера в эмуляторе нет
./<org>.<app> --main-pack /usr/share/<pkg>/<pkg>.pck -- --shot=path.png
```

---

## 12. Отличия от SDK 5.0/5.1 (историческая справка)

* Было: `sfdk engine exec sb2 -t <target> ...`, `sb2-config -l`, сборочная ВМ и VirtualBox.
* Стало: прямые sysroot-таргеты, Docker-образ `aurora-build-tools-*` и `tools/run`.
* Было: эмулятор VirtualBox (`VBoxManage`, порт 2223).
* Стало: QEMU/KVM (`qcow2`, тот же SSH-порт).
* В 5.2.1 `toolchains/` обычно пуст; компиляция приложений идёт в контейнере.
* `sfdk deploy --manual` копирует пакет, но не всегда устанавливает; надёжнее APM через
  D-Bus (кит делает это сам).

Кит рассчитан на SDK 5.2.x (Docker `tools/run`); `SDK_SUPPORTED_PREFIX` задаёт
поддерживаемую серию, а `--strict-sdk` блокирует 5.1.x/5.3.x и другие версии. Режим
сборочного окружения (`kit_detect_sdk`) — `docker` или `none`: legacy-путей через
`sfdk engine`/`sb2` в ките больше нет, а сборка aarch64 идёт тем же способом, что и
x86_64 (см. § 5).

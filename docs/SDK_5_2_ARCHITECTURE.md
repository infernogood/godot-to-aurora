# Аврора SDK 5.2 — архитектура и подводные камни

Документ описывает SDK **5.2.1.200** (ветка 5.2+), на которой проверялся кит. Более
ранние SDK (5.0/5.1) использовали `sb2`/`mb2` и VirtualBox; их поведение отличается и
в конце отмечено отдельно.

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

Имя образа зашито в `tools/run` (`aurora-build-tools-deus:5.2.1.200` в проверенной
установке). Кит читает его оттуда, но его можно переопределить `AURORA_BUILD_IMAGE`.

---

## 2. CLI: что осталось от sfdk

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
`~/AuroraOS/vmshare/ssh/private_keys/sdk`, пароль `devel-su` по умолчанию — `defaultuser`.

---

## 4. Сборочное окружение SDK 5.2

Образ `aurora-build-tools-*` — это **нативный rootfs Авроры**, а не кросс-тулчейн:

* есть `gcc`/`g++`, `wayland-scanner`, `pkg-config`, `rpmbuild`, `python3`;
* **нет** сети, `zypper`/`dnf`, `patchelf`, `scons`;
* **нет** заголовков/`.pc` для `xkbcommon` и symlink `libxkbcommon.so`;
* `targets/x86_64-meego-linux-gnu` — sysroot без пакетного менеджера.

Поэтому:

1. **`patchelf` — на хосте**, до упаковки RPM. В контейнере его нет.
2. **`scons`, заголовки `xkbcommon` и `.pc`** подкладываются в контейнер скриптом
   `prepare_extra()` из `build_x86_64_rpm.sh` (wheel SCons + tarball xkbcommon 1.3.1).
   Это нужно только при компиляции x86_64-шаблона, не для сборки игры.
3. **`rpmbuild` запускается обёрткой.** `tools/run` склеивает аргументы в строку и ломает
   кавычки в `--define "_topdir ..."`. Кит пишет `build/rpmbuild/rpmbuild.sh` внутри
   `/workspace` и вызывает его.
4. **Пути.** Внутри контейнера проект виден как `/workspace`. Любой путь вне проекта
   (ключи, RPM, шаблон) недоступен. Кит копирует ключи подписи в `build/.signing/` и
   переводит пути в `/workspace/...`.

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
* `fontconfig=no` (поэтому `SystemFont` на устройстве не работает);
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
  optimize=size debug_symbols=no -j6
```

Сборка занимает ~30 минут (Fedora, 6 потоков). Результат:
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

В проверенной установке `libxkbcommon.so` нет в том виде, который ожидает линковщик
(нет `.so`-symlink и заголовков), а внутри образа есть только рантайм-библиотека. Кит:

1. копирует `libxkbcommon.so.0*` из sysroot или образа в `/usr/share/<pkg>/lib/`;
2. на хосте выполняет
   `patchelf --force-rpath --set-rpath /usr/share/<pkg>/lib usr/bin/<pkg>`;
3. исключает `libxkbcommon` из автоматических `Requires` (`__requires_exclude`).

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
* запуск **только с иконки меню**: консольный запуск не применяет Sailjail и
  `Orientation`.

### `.spec`

Кит использует минимальный spec без `BuildRequires: patchelf` (его нет в образе):

```spec
%define __requires_exclude ^libxkbcommon.*$
%define __provides_exclude_from ^%{_datadir}/%{name}/lib/.*\.so.*$
%define debug_package %{nil}

%install
cp -a %{_topdir}/files/. %{buildroot}/
```

Комментарии в spec не должны содержать `%install`/`%post` и другие `%`-директивы:
rpm раскрывает макросы даже в комментариях, и пакет становится невалидным
(`Name field must be present`).

---

## 7. Подпись и установка

### Подпись

`ru.omp.APM` устанавливает только подписанные RPM. Используй тестовые ключи SDK:

```bash
WORKSPACE_DIR="$PWD" ~/AuroraOS/sdk/5.2.1.200/tools/run rpmsign-external sign \
  -k /workspace/build/.signing/regular_key.pem \
  -c /workspace/build/.signing/regular_cert.pem \
  /workspace/build/rpmbuild/RPMS/x86_64/<pkg>-<ver>-<rel>.x86_64.rpm

WORKSPACE_DIR="$PWD" ~/AuroraOS/sdk/5.2.1.200/tools/run rpmsign-external dump \
  /workspace/build/rpmbuild/RPMS/x86_64/<pkg>-<ver>-<rel>.x86_64.rpm
```

* Ключи лежат в `~/AuroraOS/package-signing/`, их надо скопировать в проект, иначе
  контейнер их не увидит.
* Самоподписанный `openssl`-сертификат даёт `Failed to get certificate extensions` —
  `rpmsign-external` требует расширения X.509 v3, которых у простого self-signed нет.
* `dump` без подписи печатает `No signatures found in package`.

### Установка

```bash
scp -P 2223 -i ~/AuroraOS/vmshare/ssh/private_keys/sdk \
  build/rpmbuild/RPMS/x86_64/<pkg>.rpm defaultuser@127.0.0.1:/home/defaultuser/Downloads/

sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec \
  gdbus call -y -d ru.omp.APM -o /ru/omp/APM \
  -m ru.omp.APM.Install "/home/defaultuser/Downloads/<pkg>.rpm" "{'ShowPrompt': <true>}"
```

`ShowPrompt: <true>` показывает диалог подтверждения на экране эмулятора;
`<false>` — без диалога. После установки:

```bash
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec rpm -q <pkg>
sfdk -c device="Aurora OS эмулятор 5.2.1.200" device exec journalctl -f
```

Типичные ошибки APM:

| Ошибка | Причина |
|---|---|
| «Пакет не имеет подписи разработчика» | RPM не подписан либо подпись не попала в файл |
| `ru.omp.APM.Error.FileNotFound` | неверный путь; APM видит `/home/defaultuser/Downloads/...` |
| отказ после установки | архитектура пакета не совпадает (x86_64 в устройство/aarch64 в эмулятор) |

---

## 8. Песочница Sailjail

* `/usr/share/<pkg>/` — read-only; писать туда нельзя.
* `user://` → `~/.local/share/<org>/<app>/`; `res://` → `/usr/share/<org>/<app>/`.
* Запись в `user://` не требует отдельного `Permissions`.
* Если игра использует сеть — добавь `Internet` в `Permissions`; камеру/микрофон —
  соответствующие права.
* Настройки, кэш и сохранения — только `user://` (см. `modules/save_service.gd`).

---

## 9. Ориентация

Три уровня, все должны согласоваться:

1. `project.godot`: `display/window/handheld/orientation=0` (Landscape), `1` (Portrait),
   `6` (Dynamic). Значения `4`/`5` — сенсорные: в эмуляторе без акселерометра окно
   остаётся вертикальным.
2. `DisplayServer.screen_set_orientation(...)` при старте (кит делает это в
   `aurora_lifecycle.gd`).
3. `.desktop`: `[X-Aurora-Application] Orientation=Landscape` (или `Portrait`).

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
sfdk -c device="<имя>" device exec rpm -q <pkg>
sfdk -c device="<имя>" device exec journalctl -f -t <pkg>
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

Кит поддерживает оба поколения: если в системе есть `sfdk engine`/`sb2`, скрипты
используют их; иначе — Docker-режим SDK 5.2.

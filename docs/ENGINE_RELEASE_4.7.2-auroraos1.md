# Релиз движка `engine-4.7.2-auroraos1`

Это сопроводительные заметки к GitHub Release
[`engine-4.7.2-auroraos1`](https://github.com/infernogood/godot-to-aurora/releases/tag/engine-4.7.2-auroraos1)
для `godot-to-aurora` 1.1.0. Это инструменты сборки, а не пример игры: кит собирает
`.pck` и RPM из вашего Godot-проекта.

## Состав

| Файл | Назначение |
|---|---|
| `Godot_v4.7.2-auroraos1_linux.x86_64` | редактор Godot с экспортёром AuroraOS |
| `auroraos_release.x86_64` | release-шаблон для эмулятора x86_64 |
| `auroraos_release.arm64` | release-шаблон для устройства aarch64 |
| `auroraos_debug.arm64` | debug-шаблон для отладки на устройстве aarch64 |
| `SHA256SUMS` | контрольные суммы всех файлов |
| `LICENSE` | MIT кита |
| `THIRD_PARTY_NOTICES.md` | MIT Godot Engine и уведомления об авторских правах |

## Контрольные суммы

```text
28299973ea042a82b42dcdecac6a8c3d1c50c465924bf638306f1d42ac947633  Godot_v4.7.2-auroraos1_linux.x86_64
95b1fd82768d055005163b27d4756fcea4a30323e3dab48ad6301e07654c7490  auroraos_release.x86_64
4804de5937fdb33a512e805edb1f5aeb3aa128c6e1dff185e19a8f3b2c45e89e  auroraos_release.arm64
f9e1606aa48ae5818a69184439a1a099ab736757665d38d6e5d81a98a7f58391  auroraos_debug.arm64
```

## Требования

* Linux x86_64 (проверялось на Fedora; подойдёт Ubuntu).
* Aurora SDK **5.2.1.200**: `sfdk`, sysroot, эмулятор, `package-signing/regular_*.pem`.
* Docker и образ `aurora-build-tools-*`, который загружает установщик SDK.
* `patchelf`, `readelf` (binutils), `curl`, `git`; для иконок — ImageMagick или `rsvg-convert`.
* Для эмулятора — доступный `/dev/kvm`.

## Установка

Скрипт кита скачает нужные файлы и проверит `SHA256SUMS`:

```bash
./godot-to-aurora/scripts/fetch_engine.sh
./godot-to-aurora/scripts/fetch_engine.sh --check
```

Либо скачайте файлы вручную и передайте каталог:

```bash
sha256sum -c SHA256SUMS
./godot-to-aurora/scripts/fetch_engine.sh --from-dir /path/to/assets
```

`--skip-checksum` предназначен только для отладки: он отключает защиту от подмены
бинарников. Для release-сборок используйте проверку sums.

## Поддержка

* Godot: **4.7.2-auroraos1**, рендерер — GL Compatibility / GLES3, Wayland-only.
* Aurora SDK: серия **5.2.x**; на 5.1/5.3 кит выдаёт предупреждение, `--strict-sdk`
  блокирует сборку.
* x86_64 — эмулятор QEMU/KVM; aarch64 — реальное устройство.
* C#/.NET и GDExtension без нативной сборки под Аврору не поддерживаются.

## Происхождение и лицензии

Движок собран из открытого форка [`savegame/godot`](https://github.com/savegame/godot),
тег `4.7.2-auroraos1`; исходники — в [`savegame/godot`](https://github.com/savegame/godot), лицензия — в этом репозитории. Godot Engine
распространяется по лицензии MIT:

```text
Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.
```

Полный текст MIT для кита — в [`LICENSE`](../LICENSE), для Godot Engine и уведомления
об авторских правах — в [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md). Оба
файла приложены к релизу движка. Шрифты Liberation, которые кит копирует в игру, —
SIL OFL 1.1 (`modules/fonts/LICENSE`).

Контрольные суммы фиксируют именно эти артефакты. Если файл не совпал с `SHA256SUMS`,
не запускайте его: скачайте заново из этого релиза.

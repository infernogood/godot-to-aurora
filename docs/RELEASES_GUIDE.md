# Публикация бинарников движка в GitHub Releases

GitHub ограничивает размер одного файла в репозитории **100 МБ** (предупреждение уже на
50 МБ), а один только Aurora-редактор Godot весит ~156 МБ. Поэтому движок и шаблоны **не
коммитятся**, а прикрепляются к Release. Скрипт `scripts/fetch_engine.sh` скачивает их оттуда.

---

## 1. Что должно попасть в Release

| Asset | Размер | Назначение | Обязателен |
|---|---|---|---|
| `Godot_v4.7.2-auroraos1_linux.x86_64` | ~156 МБ | редактор с экспортёром AuroraOS | да |
| `auroraos_release.x86_64` | ~58 МБ | Wayland/GLES3-шаблон для эмулятора | да (для x86_64 RPM) |
| `auroraos_release.arm64` | ~58 МБ | релизный шаблон для устройств | да (для aarch64 RPM) |
| `auroraos_debug.arm64` | ~62 МБ | debug-шаблон для устройств | рекомендуется |
| `SHA256SUMS` | < 1 КБ | контрольные суммы | рекомендуется |

Больше ничего не нужно: исходники форка, `.zip`-архивы, Windows-шаблоны и RPM самого
движка к киту отношения не имеют.

---

## 2. Откуда взять файлы

Вариант A — из уже собранного окружения (как в исходном проекте):

```
aurora-export/engine/
├── Godot_v4.7.2-auroraos1_linux.x86_64
├── auroraos_release.arm64
├── auroraos_debug.arm64
└── auroraos_release.x86_64      # собран один раз в контейнере SDK 5.2
```

Вариант B — скачать редактор и ARM-шаблоны из релизов форка
[`savegame/godot`](https://github.com/savegame/godot) (тег `4.7.2-auroraos1`), а
`auroraos_release.x86_64` собрать по инструкции из
[SDK_5_2_ARCHITECTURE.md](SDK_5_2_ARCHITECTURE.md#почему-нужен-шаблон-x86_64-руками).

Проверь, что x86_64-шаблон собран под Аврору и не тянет X11:

```bash
readelf -d auroraos_release.x86_64 | grep -Ei 'libX11|libxcb|libdecor|libXext'  # пусто
readelf -d auroraos_release.x86_64 | grep -Ei 'wayland|libEGL'                   # есть
```

---

## 3. Собери контрольные суммы

```bash
mkdir -p ~/release-assets
cp ~/AuroraProjects/engine/{Godot_v4.7.2-auroraos1_linux.x86_64,auroraos_release.x86_64,auroraos_release.arm64,auroraos_debug.arm64} ~/release-assets/
cd ~/release-assets
sha256sum Godot_v4.7.2-auroraos1_linux.x86_64 auroraos_release.x86_64 \
          auroraos_release.arm64 auroraos_debug.arm64 > SHA256SUMS
```

Или установи движок через кит и попроси его:

```bash
./godot-to-aurora/scripts/fetch_engine.sh --from-dir ~/release-assets \
  --dest ~/release-assets/installed --no-templates --write-sums
```

---

## 4. Создай релиз

Тег лучше делать по версии движка, а не по версии кита, чтобы было понятно, что внутри:

```bash
TAG=engine-4.7.2-auroraos1

gh release create "$TAG" \
  ~/release-assets/Godot_v4.7.2-auroraos1_linux.x86_64 \
  ~/release-assets/auroraos_release.x86_64 \
  ~/release-assets/auroraos_release.arm64 \
  ~/release-assets/auroraos_debug.arm64 \
  ~/release-assets/SHA256SUMS \
  --title "Godot 4.7.2 AuroraOS toolchain" \
  --notes "Aurora-enabled Godot editor and export templates used by godot-to-aurora."
```

Без `gh` можно создать релиз в веб-интерфейсе GitHub и прикрепить те же пять файлов.

Проверь, что assets доступны:

```bash
curl -I https://github.com/infernogood/godot-to-aurora/releases/download/engine-4.7.2-auroraos1/SHA256SUMS
```

---

## 5. Настрой скрипт у других пользователей

`fetch_engine.sh` по умолчанию использует текущий репозиторий:

```bash
# 1) стандартный релиз текущего репозитория (рекомендуется)
./scripts/fetch_engine.sh

# 2) другой репозиторий через переменную
AURORA_KIT_REPO=other-owner/godot-to-aurora ./scripts/fetch_engine.sh

# 3) прямой URL релиза
./scripts/fetch_engine.sh \
  --release-base https://github.com/infernogood/godot-to-aurora/releases/download/engine-4.7.2-auroraos1
```

Тег по умолчанию — `engine-4.7.2-auroraos1`; переопределяется `AURORA_KIT_RELEASE_TAG`
или `--release-tag`.

`fetch_engine.sh` сам скачает `SHA256SUMS`, проверит файлы и установит:

* редактор и шаблоны — в `~/.local/share/godot-to-aurora/engine/`;
* `auroraos_release.arm64` и `auroraos_debug.arm64` — в
  `~/.local/share/godot/export_templates/4.7.2.stable/`.

### Проверка «как у пользователя»

```bash
TMPH=$(mktemp -d)
AURORA_KIT_REPO=<owner>/godot-to-aurora \
XDG_DATA_HOME="$TMPH" \
  ./scripts/fetch_engine.sh

XDG_DATA_HOME="$TMPH" ./scripts/fetch_engine.sh --check
ls -lh "$TMPH/godot-to-aurora/engine" "$TMPH/godot/export_templates/4.7.2.stable"
rm -rf "$TMPH"
```

---

## 6. Обновление движка

Когда выйдет новый тег форка (например, `4.7.3-auroraos1`):

1. собери/скачай новые бинарники и x86_64-шаблон;
2. обнови версии/имена в скриптах:
   * `EDITOR_ASSET` в `scripts/fetch_engine.sh`,
   * `AURORA_GODOT_TAG` и `TEMPLATE_ASSET`/`TEMPLATE_ARCH` в `scripts/build_x86_64_rpm.sh`,
   * `GODOT_TEMPLATE_VERSION` (переменная окружения, используется `fetch_engine.sh`; при
     новой версии движка поменяй дефолт на `4.7.3.stable`);
3. обнови `docs/SDK_5_2_ARCHITECTURE.md`, `README.md` и `AGENTS.md` (версии, имена файлов);
4. создай новый Release, например `engine-4.7.3-auroraos1`;
5. проверь `fetch_engine.sh --check` и полный цикл `build_x86_64_rpm.sh` на тестовой игре.

Не перезаписывай ассеты существующего тега: старые установки могут кэшировать суммы.
Лучше новый тег.

---

## 7. Что не надо делать

* **Не коммить бинарники** и не использовать Git LFS для 60-МБ шаблонов без
  необходимости: LFS-квоты быстро кончаются, а Releases бесплатны.
* **Не публикуй RPM игры** в релизах кита: киту нужны только инструменты.
* **Не публикуй ключи подписи** (`regular_key.pem`, `regular_cert.pem`): они поставляются
  с Aurora SDK; в репозитории им не место.
* **Не переименовывай assets** без обновления скриптов: имена — часть контракта
  `fetch_engine.sh`.

---

## 8. Лицензии и распространение

* Godot и форк `savegame/godot` — MIT. Распространение собранных бинарников допустимо;
  сохраняй уведомление об авторских правах и текст лицензии движка (например, в
  `docs/THIRD_PARTY.md` при желании).
* Шрифты Liberation в ките — SIL OFL 1.1; лицензии лежат рядом со шрифтами.
* Игра пользователя и её ассеты в кит не входят и не публикуются.

---

## 9. Чек-лист релиза

- [ ] 5 файлов (редактор, 3 шаблона, `SHA256SUMS`) прикреплены к тегу;
- [ ] `readelf -d` x86_64-шаблона не показывает X11;
- [ ] `fetch_engine.sh` с `AURORA_KIT_REPO` скачивает и проверяет суммы;
- [ ] `fetch_engine.sh --check` показывает все `[ok]`;
- [ ] `build_x86_64_rpm.sh --check` считает окружение готовым;
- [ ] на чистой копии игры собирается RPM (~30 с после первого импорта);
- [ ] RPM подписывается SDK-ключами и устанавливается в эмулятор;
- [ ] README/AGENTS/docs не содержат имён конкретной игры.

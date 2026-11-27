#!/usr/bin/env bash
# shellcheck shell=bash
#
# Сборка RPM x86_64 (эмулятор) или aarch64 (устройство) из проекта Godot 4.
#
# Имя файла сохранено ради совместимости; `--arch aarch64` (или тонкая
# обёртка scripts/build_aarch64_rpm.sh) переключает целевую архитектуру.
#
# В Aurora SDK 5.2+ нет sb2/mb2/sfdk-engine: сборочное окружение — это
# Docker-образ (aurora-build-tools-*), которым управляет <sdk>/tools/run и
# который монтирует проект в /workspace. Скрипт закрывает весь цикл:
#
#   1. параметры пакета из project.godot / export_presets.cfg;
#   2. создание пресета AuroraOS, только если его ещё нет;
#   3. поиск (или сборка) Wayland/GLES3 шаблона экспорта нужной архитектуры;
#   4. экспорт PCK редактором Godot с экспортёром AuroraOS;
#   5. иконки, .desktop и RPM .spec;
#   6. patchelf RPATH на хосте и rpmbuild внутри образа SDK.
#
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
	cat <<EOF
godot-to-aurora — сборка RPM x86_64 или aarch64 для Aurora OS

ИСПОЛЬЗОВАНИЕ
  build_x86_64_rpm.sh [--arch x86_64|aarch64] [опции]

ОПЦИИ
  -h, --help               Показать эту справку и выйти.
  -V, --version            Напечатать версию кита и выйти.
      --arch ARCH          x86_64 (эмулятор, по умолчанию) или aarch64.
      --check              Показать параметры и готовность окружения; ничего
                           не менять. С --strict вернуть код 1, если не готово.
      --strict             С --check: ненулевой код, если сборка невозможна.
      --write-preset       Создать пресет AuroraOS (если его нет) и выйти.
      --force-preset       Пересоздать/заменить пресет AuroraOS.
      --skip-template      Не собирать шаблон; падать, если его нет.
      --force-template     Пересобрать шаблон, даже если он уже есть.
      --jobs N             Параллельные задачи при сборке шаблона
                           (по умолчанию: nproc).
      --preset NAME        Имя пресета экспорта. По умолчанию берётся первый
                           пресет с platform="AuroraOS" (любое имя).
      --pck-only           Экспортировать только PCK и иконки, без RPM.
      --import             Принудительный импорт ресурсов перед экспортом.
      --no-xkbcommon        Не включать libxkbcommon в пакет.
      --skip-checksum      Не проверять SHA-256 xkbcommon/SCons (не рекомендуется).
      --strict-sdk         Блокировать сборку, если SDK не ${SDK_SUPPORTED_PREFIX}x.
      --clean              Удалить предыдущее дерево build/rpmbuild.
  -q, --quiet              Меньше вывода экспортёра Godot.

ОКРУЖЕНИЕ (всё опционально)
  GAME_DIR=/path/to/game          Корень проекта (по умолчанию — родитель кита).
  ORG_NAME=ru.example             package/organization.
  APP_NAME=game                   package/name.
  APP_TITLE="My Game"             package/launcher_name.
  APP_VERSION=1.0.0               package/version.
  APP_RELEASE=1                   Номер релиза RPM.
  PERMISSIONS="Audio,Internet"    Разрешения Sailjail через запятую.
  ORIENTATION=Landscape           Landscape | Portrait | Dynamic.
  APP_COMMENT="..."               Comment в .desktop.
  APP_CATEGORIES=Game             Categories в .desktop.
  RPM_LICENSE=MIT                 Тег License (по умолчанию Proprietary).
  ICON_SVG=/path/icon.svg         Мастер-иконка (по умолчанию <проект>/icon.svg).
  GODOT_BIN=/path/godot           Редактор Godot с экспортёром AuroraOS.
  AURORA_TEMPLATE_X86_64=FILE     Шаблон auroraos_release.x86_64.
  AURORA_TEMPLATE_AARCH64=FILE    Шаблон auroraos_release.arm64.
  AURORA_TEMPLATE=FILE            Устаревшая общая переменная для обеих архитектур.
  AURORA_KIT_ENGINE_DIR=DIR      Куда fetch_engine.sh установил бинарники.
  AURORA_SDK_HOME=DIR             Корень Aurora SDK (по умолчанию ~/AuroraOS).
  AURORA_BUILD_IMAGE=IMAGE        Переопределить образ aurora-build-tools.
  AURORA_EXTRA_DIR=DIR            Готовый extra/ для сборки шаблона.
  AURORA_ARM64_LIB_DIR=DIR        aarch64 libxkbcommon для включения в пакет.
  JOBS=N                          Параллельные задачи.
  BUILD_DIR=DIR                   Каталог сборки (по умолчанию <проект>/build).

РЕЗУЛЬТАТ
  <project>/build/<org>.<app>.pck
  <project>/build/rpmbuild/RPMS/<arch>/<org>.<app>-<version>-<release>.<arch>.rpm

AARCH64
  Плагин экспорта AuroraOS в форке savegame/godot использует sb2 API, который
  удалён в SDK 5.2. Поэтому aarch64 RPM собирается нативно: шаблон arm64 плюс
  независимый от архитектуры PCK, упакованные rpmbuild --target
  aarch64-meego-linux-gnu внутри образа SDK.
EOF
}

# ---------------------------------------------------------------------------
# Аргументы
# ---------------------------------------------------------------------------
SKIP_TEMPLATE="${SKIP_TEMPLATE:-0}"
FORCE_TEMPLATE="${FORCE_TEMPLATE:-0}"
CHECK_ONLY=0
STRICT_CHECK=0
WRITE_PRESET_ONLY=0
FORCE_PRESET=0
PCK_ONLY=0
FORCE_IMPORT=0
BUNDLE_XKBCOMMON=1
SKIP_CHECKSUM=0
STRICT_SDK=0
CLEAN_BUILD=0
QUIET=0
JOBS="${JOBS:-}"
AURORA_PRESET_ARG="${AURORA_PRESET:-}"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"

while (( $# > 0 )); do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		-V|--version) kit_version_banner; exit 0 ;;
		--check) CHECK_ONLY=1 ;;
		--strict) STRICT_CHECK=1 ;;
		--write-preset) WRITE_PRESET_ONLY=1 ;;
		--force-preset) FORCE_PRESET=1 ;;
		--skip-template) SKIP_TEMPLATE=1 ;;
		--force-template) FORCE_TEMPLATE=1 ;;
		--arch) [[ $# -ge 2 ]] || kit_die "--arch требует x86_64 или aarch64"; TARGET_ARCH="$2"; shift ;;
		--jobs) [[ $# -ge 2 ]] || kit_die "--jobs требует значение"; JOBS="$2"; shift ;;
		--preset) [[ $# -ge 2 ]] || kit_die "--preset требует имя"; AURORA_PRESET_ARG="$2"; shift ;;
		--pck-only) PCK_ONLY=1 ;;
		--import) FORCE_IMPORT=1 ;;
		--no-xkbcommon) BUNDLE_XKBCOMMON=0 ;;
		--skip-checksum) SKIP_CHECKSUM=1 ;;
		--strict-sdk) STRICT_SDK=1 ;;
		--clean) CLEAN_BUILD=1 ;;
		-q|--quiet) QUIET=1 ;;
		*) kit_die "неизвестная опция: $1 (см. --help)" ;;
	esac
	shift
done

# Валидация JOBS — только после разбора аргументов.
if [[ -z "$JOBS" ]]; then
	JOBS="$(nproc 2>/dev/null || printf '4')"
fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || kit_die "JOBS/--jobs должен быть положительным целым (получено '$JOBS')."

AURORA_PRESET="$AURORA_PRESET_ARG"

case "$TARGET_ARCH" in
	x86_64)
		TEMPLATE_ARCH="x86_64"
		TEMPLATE_ASSET="auroraos_release.x86_64"
		RPM_TARGET="x86_64-meego-linux-gnu"
		RPM_ARCH="x86_64"
		;;
	aarch64)
		TEMPLATE_ARCH="aarch64"
		TEMPLATE_ASSET="auroraos_release.arm64"
		RPM_TARGET="aarch64-meego-linux-gnu"
		RPM_ARCH="aarch64"
		;;
	*)
		kit_die "неподдерживаемый --arch '$TARGET_ARCH' (используйте x86_64 или aarch64)"
		;;
esac

# ---------------------------------------------------------------------------
# Параметры пакета
# ---------------------------------------------------------------------------
kit_load_package_params
BUILD_DIR="${BUILD_DIR:-$PROJECT_ROOT/build}"
BUILD_DIR="$(kit_abspath "$BUILD_DIR")"
RPMBUILD="$BUILD_DIR/rpmbuild"
PCK_PATH="$BUILD_DIR/$PKG_FULL.pck"
SPEC_PATH="$RPMBUILD/SPECS/$PKG_FULL.spec"
LIBDIR_IN_PACKAGE="/usr/share/$PKG_FULL/lib"
TEMPLATE_DEST="$(kit_engine_dir)/$TEMPLATE_ASSET"

kit_log "godot-to-aurora $KIT_VERSION — RPM $RPM_ARCH для Aurora OS"
kit_print_params

editor=""
editor="$(kit_find_godot)" || editor=""
template=""
template="$(kit_find_template "$TEMPLATE_ARCH" release)" || template=""

if [[ -n "$editor" ]]; then
	editor_version="$("$editor" --headless --version 2>/dev/null | head -1 || true)"
else
	editor_version=""
fi

# Стоковый Godot не содержит платформы экспорта AuroraOS, а строка --version
# у форка и стока совпадает, поэтому ищем имя платформы в самом бинарнике.
editor_has_aurora_platform() {
	local bin="$1"
	[[ -f "$bin" ]] || return 1
	kit_has grep || return 0
	LC_ALL=C grep -aq 'AuroraOS' "$bin"
}

kit_detect_sdk
kit_log "окружение сборки: $(kit_sdk_description)"

# --strict-sdk блокирует реальную сборку, но не мешает --check/--write-preset
# и экспорту одного PCK, которым сборочное окружение SDK не нужно.
if (( STRICT_SDK && ! KIT_SDK_SUPPORTED && ! PCK_ONLY && ! CHECK_ONLY && ! WRITE_PRESET_ONLY )); then
	kit_die "Aurora SDK ${KIT_SDK_VERSION:-?} не входит в поддерживаемую серию ${SDK_SUPPORTED_PREFIX}x.
Установите SDK $SDK_DEFAULT_VERSION или уберите --strict-sdk."
fi

# Падаем сразу, а не через полчаса компиляции шаблона.
if (( ! PCK_ONLY && ! CHECK_ONLY && ! WRITE_PRESET_ONLY )); then
	[[ -n "$editor" ]] || kit_die "не найден Godot с экспортёром AuroraOS.
Установите его: scripts/fetch_engine.sh, либо задайте GODOT_BIN=/path/to/Godot_v${GODOT_AURORA_TAG}_linux.x86_64"
	if [[ "$KIT_SDK_MODE" == "none" ]]; then
		kit_die "нет сборочного окружения Aurora SDK (Docker-образ SDK 5.2+).
См. docs/SDK_5_2_ARCHITECTURE.md. Для экспорта только PCK используйте --pck-only."
	fi
fi

if [[ -z "$template" && "$TARGET_ARCH" == "x86_64" && -n "$KIT_SDK_IMAGE" ]] && kit_has docker \
	&& docker image inspect "$KIT_SDK_IMAGE" >/dev/null 2>&1; then
	template_note="нет (можно собрать в $KIT_SDK_IMAGE)"
elif [[ -n "$template" ]]; then
	template_note="$(du -h "$template" | cut -f1)"
else
	template_note="нет"
fi

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if (( CHECK_ONLY )); then
	ready=1
	echo
	echo "Окружение"
	printf '  редактор          %s\n' "${editor:-НЕТ}${editor_version:+  ($editor_version)}"
	printf '  шаблон %-10s %s\n' "$TARGET_ARCH" "${template:-НЕТ}  [$template_note]"
	printf '  export templates  %s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/${GODOT_TEMPLATE_VERSION}"
	printf '  Aurora SDK        %s\n' "$(kit_sdk_description)"
	printf '  версия SDK        %s (поддерживается %s*)\n' "${KIT_SDK_VERSION:-НЕТ}" "$SDK_SUPPORTED_PREFIX"
	printf '  docker            %s\n' "$(kit_yes_no kit_has docker)"
	printf '  patchelf          %s\n' "$(kit_yes_no kit_has patchelf)"
	printf '  magick/rsvg       %s\n' "$(kit_yes_no kit_has_any magick rsvg-convert)"
	echo
	[[ -n "$editor" ]] || { kit_warn "не найден Godot с экспортёром AuroraOS (fetch_engine.sh)."; ready=0; }
	if [[ -n "$editor" ]] && ! editor_has_aurora_platform "$editor"; then
		kit_warn "найден стоковый Godot без платформы AuroraOS: $editor — экспорт не заработает."
		ready=0
	fi
	if (( ! KIT_SDK_SUPPORTED )); then
		if (( STRICT_SDK )); then ready=0; fi
	fi
	[[ -z "$PKG_PRESET_INDEX" ]] && kit_info "пресет AuroraOS будет создан во время сборки."
	[[ -f "${ICON_SVG:-$PROJECT_ROOT/icon.svg}" || -f "$BUILD_DIR/icons/86.png" ]] \
		|| { kit_warn "в проекте нет icon.svg и в build/icons нет готовых PNG."; ready=0; }
	if (( PCK_ONLY )); then
		:
	else
		[[ -z "$template" ]] && { kit_warn "шаблон $TARGET_ARCH не найден."; ready=0; }
		[[ "$KIT_SDK_MODE" == "none" ]] && { kit_warn "нет сборочного окружения Aurora SDK."; ready=0; }
		if (( BUNDLE_XKBCOMMON )); then
			if [[ "$TARGET_ARCH" == "x86_64" || -n "${AURORA_ARM64_LIB_DIR:-}" ]]; then
				kit_has patchelf || { kit_warn "для включения libxkbcommon нужен patchelf."; ready=0; }
			fi
		fi
	fi
	echo
	if (( ready )); then
		kit_ok "ГОТОВО"
	else
		kit_warn "НЕ ГОТОВО — установите недостающие компоненты (см. выше)."
		if (( STRICT_CHECK )) || (( STRICT_SDK && ! KIT_SDK_SUPPORTED )); then exit 1; fi
	fi
	exit 0
fi

if (( WRITE_PRESET_ONLY )); then
	if [[ -n "$PKG_PRESET_INDEX" && "$FORCE_PRESET" != "1" ]]; then
		kit_ok "пресет AuroraOS уже существует (индекс $PKG_PRESET_INDEX, имя $PKG_PRESET_NAME); файл не изменяется."
	elif (( FORCE_PRESET )); then
		kit_write_aurora_preset --force
	else
		kit_write_aurora_preset
	fi
	kit_ensure_project_gitignore
	exit 0
fi


# ---------------------------------------------------------------------------
# Пресет
# ---------------------------------------------------------------------------
if [[ -n "$PKG_PRESET_INDEX" ]]; then
	if (( FORCE_PRESET )); then
		kit_write_aurora_preset --force
	fi
else
	kit_write_aurora_preset
fi
kit_patch_exclude_filter
kit_ensure_project_gitignore
preset_name="$PKG_PRESET_NAME"
[[ -n "$preset_name" ]] || preset_name="${AURORA_PRESET:-AuroraOS}"

# ---------------------------------------------------------------------------
# Сборка шаблона экспорта
# ---------------------------------------------------------------------------
KIT_GODOT_REPO="${AURORA_GODOT_REPO:-https://github.com/savegame/godot.git}"
AURORA_WORKSPACE="${AURORA_WORKSPACE:-$HOME/AuroraProjects}"
AURORA_BUILD_CONTAINER=""

KIT_SCONS_ARGS=(
	platform=linuxbsd arch=x86_64 target=template_release
	auroraos=yes use_sowrap=no udev=no speechd=no fontconfig=no
	accesskit=no openxr=no disable_path_overrides=no
	optimize=size debug_symbols=no
)

cleanup_container() {
	[[ -n "${AURORA_BUILD_CONTAINER:-}" ]] || return 0
	kit_has docker || return 0
	docker rm -f "$AURORA_BUILD_CONTAINER" >/dev/null 2>&1 || true
}

verify_sha256() {
	local file="$1" expected="$2" label="$3" actual
	if [[ -z "$expected" ]]; then
		kit_warn "SHA256 для «$label» не задан; проверка пропущена."
		return 0
	fi
	if ! kit_has sha256sum; then
		kit_warn "sha256sum не найден; проверка «$label» пропущена."
		return 0
	fi
	actual="$(sha256sum "$file" | awk '{print $1}')"
	if [[ "$actual" != "$expected" ]]; then
		kit_err "SHA256 «$label» не совпал"
		kit_err "  ожидалось $expected"
		kit_err "  получено  $actual"
		return 1
	fi
	kit_info "SHA256 ok: $label"
}

# download_xkbcommon_archive DEST URL... — официальный релизный архив xkbcommon
# с зеркалом; SHA-256 проверяется по .part, целевой файл появляется только
# после успешной проверки.
download_xkbcommon_archive() {
	local dest="$1"
	shift
	local url label
	label="xkbcommon-$(basename -- "$dest")"
	for url in "$@"; do
		if ! kit_download "$url" "$dest"; then
			kit_warn "источник недоступен: $url"
			continue
		fi
		if (( SKIP_CHECKSUM )); then
			kit_warn "SHA-256 xkbcommon пропущена (--skip-checksum)."
		elif ! verify_sha256 "$dest.part" "$XKBCOMMON_SHA256" "$label"; then
			rm -f -- "$dest.part"
			kit_err "архив xkbcommon не прошёл проверку SHA256."
			return 1
		fi
		kit_commit_download "$dest"
		return 0
	done
	return 1
}

# Версия libxkbcommon в образе (заголовки фиксированы, .pc подгоняется под ABI).
detect_xkbcommon_version() {
	local image="$1" version=""
	version="$(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
		--entrypoint /bin/bash "$image" -lc '
			lib="$(ls -1 /usr/lib64/libxkbcommon.so.0.* 2>/dev/null | sort -V | tail -1)"
			[ -n "$lib" ] || exit 3
			ver="$(rpm -q --queryformat "%{VERSION}" libxkbcommon 2>/dev/null || true)"
			if [ -z "$ver" ] && command -v strings >/dev/null 2>&1; then
				ver="$(strings -a "$lib" | grep -oE "^1\\.[0-9]+\\.[0-9]+$" | head -1 || true)"
			fi
			printf "%s" "$ver"
		' 2>/dev/null || true)"
	printf '%s\n' "$version"
}

detect_xkbcommon_lib() {
	local image="$1" lib=""
	lib="$(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
		--entrypoint /bin/bash "$image" -lc '
			lib="$(ls -1 /usr/lib64/libxkbcommon.so.0.* 2>/dev/null | sort -V | tail -1)"
			[ -n "$lib" ] || exit 3
			basename "$lib"
		' 2>/dev/null || true)"
	printf '%s\n' "$lib"
}

prepare_extra() {
	local extra="$1" tmp src_archive wheel pc_version archive_version
	local -a archive_urls
	local archive_top
	mkdir -p "$extra/include" "$extra/pkgconfig" "$extra/lib" "$extra/scons"

	if [[ ! -f "$extra/include/xkbcommon/xkbcommon.h" ]]; then
		archive_version="$(kit_xkbcommon_base_version "$XKBCOMMON_VERSION")"
		kit_log "подготавливаю заголовки xkbcommon $archive_version (в образе нет -devel)…"
		tmp="$(mktemp -d)"
		src_archive="$tmp/xkbcommon-$archive_version.tar.xz"
		archive_urls=(
			"https://xkbcommon.org/download/libxkbcommon-${archive_version}.tar.xz"
			"https://distfiles.gentoo.org/distfiles/libxkbcommon-${archive_version}.tar.xz"
		)
		archive_top="libxkbcommon-${archive_version}"
		download_xkbcommon_archive "$src_archive" "${archive_urls[@]}" \
			|| kit_die "не удалось скачать архив xkbcommon $archive_version."
		tar -xJf "$src_archive" -C "$tmp" \
			|| kit_die "не удалось распаковать $src_archive (нужен xz)."
		cp -r "$tmp/$archive_top/include/xkbcommon" "$extra/include/" \
			|| kit_die "в архиве xkbcommon нет $archive_top/include/xkbcommon."
		# Текст лицензии кэшируется рядом с extra/: он нужен для %license в RPM.
		if [[ -f "$tmp/$archive_top/LICENSE" ]]; then
			install -m 0644 "$tmp/$archive_top/LICENSE" "$extra/LICENSE.libxkbcommon"
		fi
		rm -rf -- "$tmp"
	fi

	# .pc перезаписывается каждый раз: старый extra/ мог ссылаться на /usr.
	pc_version="${XKBCOMMON_DETECTED_VERSION:-$XKBCOMMON_VERSION}"
	cat > "$extra/pkgconfig/xkbcommon.pc" <<PC
prefix=/opt/extra
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: xkbcommon
Description: XKB API common to servers and clients
Version: $pc_version
Libs: -L\${libdir} -lxkbcommon
Cflags: -I\${includedir}
PC

	# Симлинк живёт в /opt/extra, а не в /usr/lib64: контейнер запущен под
	# непривилегированным пользователем и не должен писать в системные каталоги.
	ln -sfn "/usr/lib64/${XKBCOMMON_LIB_NAME:-libxkbcommon.so.0}" "$extra/lib/libxkbcommon.so"

	if [[ ! -d "$extra/scons/SCons" ]]; then
		kit_has python3 || kit_die "для подготовки SCons нужен python3."
		kit_log "подготавливаю SCons $SCONS_VERSION для образа…"
		rm -f "$extra"/scons-*.whl "$extra"/scons-*.tar.gz
		python3 -m pip download "scons==$SCONS_VERSION" --no-deps --only-binary=:all: -d "$extra" >/dev/null \
			|| kit_die "python3 -m pip download scons==$SCONS_VERSION не удался (нет сети или pip)."
		wheel=""
		if [[ -f "$extra/scons-${SCONS_VERSION}-py3-none-any.whl" ]]; then
			wheel="$extra/scons-${SCONS_VERSION}-py3-none-any.whl"
		else
			wheel="$(find "$extra" -maxdepth 1 -name 'scons-*.whl' -print -quit)"
		fi
		if [[ -n "$wheel" ]]; then
			if (( SKIP_CHECKSUM )); then
				kit_warn "SHA-256 SCons пропущена (--skip-checksum)."
			else
				verify_sha256 "$wheel" "$SCONS_SHA256" "SCons $SCONS_VERSION wheel" \
					|| kit_die "wheel SCons не прошёл проверку SHA256."
			fi
			python3 -m zipfile -e "$wheel" "$extra/scons"
			rm -f -- "$wheel"
		else
			kit_die "pip не вернул wheel SCons $SCONS_VERSION; нужен universal wheel."
		fi
	fi

	cat > "$extra/scons-run.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.path.insert(0, "/opt/extra/scons")
import SCons.Script
sys.exit(SCons.Script.main())
PY
}

build_template_docker() {
	local src="$AURORA_WORKSPACE/godot-$GODOT_AURORA_TAG"
	local extra="${AURORA_EXTRA_DIR:-$AURORA_WORKSPACE/extra}"
	local out head_rev
	mkdir -p "$AURORA_WORKSPACE"
	if [[ ! -d "$src/.git" ]]; then
		kit_has git || kit_die "для загрузки исходников Godot нужен git."
		kit_log "клонирую $KIT_GODOT_REPO ($GODOT_AURORA_TAG) в $src"
		git clone --depth 1 --branch "$GODOT_AURORA_TAG" "$KIT_GODOT_REPO" "$src"
	fi

	# Тег мог быть перевешен: исходники должны указывать ровно на GODOT_AURORA_SHA.
	if [[ -n "${GODOT_AURORA_SHA:-}" ]]; then
		kit_has git || kit_die "для проверки коммита Godot нужен git."
		head_rev="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
		if [[ "$head_rev" != "$GODOT_AURORA_SHA" ]]; then
			kit_die "исходники в $src указывают на ${head_rev:-неизвестный коммит},
а тег $GODOT_AURORA_TAG по versions.env — это $GODOT_AURORA_SHA.
Удалите каталог и повторите сборку: rm -rf '$src'"
		fi
	fi

	XKBCOMMON_DETECTED_VERSION="$(detect_xkbcommon_version "$KIT_SDK_IMAGE")"
	XKBCOMMON_LIB_NAME="$(detect_xkbcommon_lib "$KIT_SDK_IMAGE")"
	if [[ -z "$XKBCOMMON_LIB_NAME" ]]; then
		XKBCOMMON_LIB_NAME="libxkbcommon.so.0"
	fi
	if [[ -z "$XKBCOMMON_DETECTED_VERSION" ]]; then
		kit_warn "не удалось определить версию libxkbcommon в $KIT_SDK_IMAGE; использую $XKBCOMMON_VERSION."
		XKBCOMMON_DETECTED_VERSION="$XKBCOMMON_VERSION"
	else
		kit_info "libxkbcommon в образе: $XKBCOMMON_DETECTED_VERSION ($XKBCOMMON_LIB_NAME)"
	fi
	if kit_xkbcommon_sha256 "$XKBCOMMON_DETECTED_VERSION" >/dev/null; then
		if [[ "$XKBCOMMON_DETECTED_VERSION" != "$XKBCOMMON_VERSION" ]]; then
			kit_info "заголовки xkbcommon берутся из архива $XKBCOMMON_VERSION; ABI совместим."
		fi
	else
		if (( SKIP_CHECKSUM )); then
			kit_warn "для libxkbcommon $XKBCOMMON_DETECTED_VERSION нет SHA-256 в versions.env; проверка пропущена (--skip-checksum)."
		else
			kit_die "для libxkbcommon $XKBCOMMON_DETECTED_VERSION нет SHA-256 в versions.env.
Добавьте версию в XKBCOMMON_KNOWN_VERSIONS (и обновите XKBCOMMON_VERSION/XKBCOMMON_SHA256 для архива заголовков)
либо передайте --skip-checksum (не рекомендуется)."
		fi
	fi

	prepare_extra "$extra"

	AURORA_BUILD_CONTAINER="godot-to-aurora-build-$$-$(date +%s)"
	kit_log "запускаю контейнер $AURORA_BUILD_CONTAINER из $KIT_SDK_IMAGE…"
	docker run -d --name "$AURORA_BUILD_CONTAINER" \
		--user "$(id -u):$(id -g)" -e HOME=/tmp \
		-v "$src:/src" -v "$extra:/opt/extra:ro" -w /src \
		"$KIT_SDK_IMAGE" sleep infinity >/dev/null
	# trap ставим только после успешного запуска контейнера.
	trap cleanup_container EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	kit_log "проверяю xkbcommon в контейнере без записи в /usr…"
	docker exec -w /src \
		-e PKG_CONFIG_PATH="/opt/extra/pkgconfig" \
		-e CFLAGS="-I/opt/extra/include" \
		-e CXXFLAGS="-I/opt/extra/include" \
		-e CCFLAGS="-I/opt/extra/include" \
		-e LDFLAGS="-L/opt/extra/lib" \
		-e LINKFLAGS="-L/opt/extra/lib" \
		-e LIBRARY_PATH="/opt/extra/lib" \
		-e PYTHONDONTWRITEBYTECODE=1 \
		"$AURORA_BUILD_CONTAINER" bash -lc '
			set -e
			pkg-config --cflags --libs xkbcommon
			printf "%s\n" "#include <xkbcommon/xkbcommon.h>" "int main(void) { return xkb_context_new(XKB_CONTEXT_NO_FLAGS) ? 0 : 1; }" > /tmp/xkb-smoke.c
			cc $(pkg-config --cflags xkbcommon) /tmp/xkb-smoke.c $(pkg-config --libs xkbcommon) -o /tmp/xkb-smoke
			/tmp/xkb-smoke
		'

	kit_log "компилирую шаблон x86_64 (-j$JOBS); это занимает около 30 минут…"
	docker exec -w /src \
		-e PKG_CONFIG_PATH="/opt/extra/pkgconfig" \
		-e CFLAGS="-I/opt/extra/include" \
		-e CXXFLAGS="-I/opt/extra/include" \
		-e CCFLAGS="-I/opt/extra/include" \
		-e LDFLAGS="-L/opt/extra/lib" \
		-e LINKFLAGS="-L/opt/extra/lib" \
		-e LIBRARY_PATH="/opt/extra/lib" \
		-e PYTHONDONTWRITEBYTECODE=1 \
		"$AURORA_BUILD_CONTAINER" \
		python3 /opt/extra/scons-run.py "${KIT_SCONS_ARGS[@]}" -j"$JOBS"

	out="$src/bin/godot.linuxbsd.template_release.x86_64"
	[[ -f "$out" ]] || kit_die "scons завершился, но $out отсутствует"
	mkdir -p "$(dirname -- "$TEMPLATE_DEST")"
	install -m 0755 "$out" "$TEMPLATE_DEST"

	docker rm -f "$AURORA_BUILD_CONTAINER" >/dev/null 2>&1 || true
	AURORA_BUILD_CONTAINER=""
}

build_template() {
	if [[ "$TARGET_ARCH" != "x86_64" ]]; then
		kit_die "шаблон $TARGET_ARCH нельзя собрать на x86_64-хосте внутри образа SDK.
Скачайте готовый auroraos_release.arm64 через scripts/fetch_engine.sh."
	fi
	case "$KIT_SDK_MODE" in
		docker) build_template_docker ;;
		*)
			kit_die "нет сборочного окружения Aurora SDK; собрать шаблон x86_64 нельзя.

Варианты:
  * установить Aurora SDK 5.2+ с образом aurora-build-tools, либо
  * скачать готовый auroraos_release.x86_64 через scripts/fetch_engine.sh."
			;;
	esac
	template="$(kit_find_template "$TEMPLATE_ARCH" release)" || template=""
	[[ -n "$template" ]] || kit_die "сборка шаблона завершилась, но $TEMPLATE_ASSET не найден"
	kit_ok "шаблон готов: $template ($(du -h "$template" | cut -f1))"
}

if (( ! PCK_ONLY )); then
	if [[ -n "$template" ]]; then
		kit_log "использую шаблон: $template ($(du -h "$template" | cut -f1))"
		if (( FORCE_TEMPLATE )); then
			kit_log "пересборка шаблона из-за --force-template"
			TEMPLATE_DEST="$template"
			build_template
		fi
	elif (( SKIP_TEMPLATE )); then
		kit_die "шаблон $TARGET_ARCH не найден и задан --skip-template.
Сначала запустите scripts/fetch_engine.sh или положите $TEMPLATE_ASSET в:
  $(kit_engine_dir)
  $PROJECT_ROOT/utilities"
	else
		build_template
	fi
	kit_verify_template_arch "$template" "$TEMPLATE_ARCH" \
		|| kit_die "шаблон собран для другой архитектуры; упаковка отменена."
	kit_verify_no_x11 "$template" \
		|| kit_die "шаблон линкуется с X11; его нужно собрать с auroraos=yes (Wayland-only)."
fi

# ---------------------------------------------------------------------------
# Иконки
# ---------------------------------------------------------------------------
# Иконки всегда генерируются в BUILD_DIR: дерево игры не должно засоряться.
ICON_SRC="${ICON_SVG:-$PROJECT_ROOT/icon.svg}"
ICON_STAGE="$BUILD_DIR/icons"

render_icon() { # render_icon <размер> <файл>
	local size="$1" out="$2" rc=0
	[[ -f "$ICON_SRC" ]] || kit_die "источник иконки не найден: $ICON_SRC (создайте icon.svg в корне проекта)"
	if kit_has magick; then
		magick -background none "$ICON_SRC" \
			-resize "${size}x${size}" -gravity center -extent "${size}x${size}" "$out" || rc=$?
	elif kit_has rsvg-convert; then
		rsvg-convert -w "$size" -h "$size" -o "$out" "$ICON_SRC" || rc=$?
	else
		kit_die "для рендера $ICON_SRC нужен ImageMagick (magick) или rsvg-convert"
	fi
	if (( rc != 0 )); then
		kit_die "рендер иконки ${size}x${size} завершился с кодом $rc"
	fi
	[[ -s "$out" ]] || kit_die "не удалось создать иконку $out"
}

render_icons() {
	local size out dest
	mkdir -p "$ICON_STAGE"
	for size in 86 108 128 172; do
		dest="$RPMBUILD/files/usr/share/icons/hicolor/${size}x${size}/apps"
		mkdir -p "$dest"
		out="$ICON_STAGE/$size.png"
		# icon.svg новее PNG — перерисовываем; иначе используем готовый файл.
		if [[ -f "$out" ]] && { [[ ! -f "$ICON_SRC" ]] || [[ ! "$ICON_SRC" -nt "$out" ]]; }; then
			kit_info "использую готовую иконку: $out"
		else
			render_icon "$size" "$out"
			kit_log "сгенерирована иконка: $out"
		fi
		install -m 0644 "$out" "$dest/$PKG_FULL.png"
	done
}

# ---------------------------------------------------------------------------
# Дерево сборки
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
: > "$BUILD_DIR/.gdignore"
find "$BUILD_DIR" -name '*.import' -delete 2>/dev/null || true
if (( CLEAN_BUILD )); then
	kit_log "удаляю предыдущее дерево RPM"
	rm -rf -- "$RPMBUILD"
else
	# Пересобираем payload всегда: остатки другой архитектуры (например,
	# вложенный x86_64 libxkbcommon) не должны попасть в пакет.
	rm -rf -- "$RPMBUILD/files"
fi
mkdir -p "$RPMBUILD/SPECS" "$RPMBUILD/RPMS" "$RPMBUILD/files/usr/bin" \
	"$RPMBUILD/files/usr/share/applications" \
	"$RPMBUILD/files/usr/share/$PKG_FULL/lib"

render_icons

# ---------------------------------------------------------------------------
# PCK
# ---------------------------------------------------------------------------
[[ -n "$editor" ]] || kit_die "не найден Godot с экспортёром AuroraOS.
Установите его: scripts/fetch_engine.sh, либо задайте GODOT_BIN=/path/to/Godot_v${GODOT_AURORA_TAG}_linux.x86_64"

if (( FORCE_IMPORT )) || [[ ! -d "$PROJECT_ROOT/.godot" ]]; then
	kit_log "импортирую ресурсы проекта (первый запуск)…"
	if ! "$editor" --headless --path "$PROJECT_ROOT" --import; then
		# Редактор иногда падает на самом первом импорте большого проекта,
		# когда кэш импорта записан наполовину; второй проход обычно проходит.
		kit_warn "импорт ресурсов не удался; повторяю один раз…"
		"$editor" --headless --path "$PROJECT_ROOT" --import \
			|| kit_die "импорт не удался дважды; откройте проект в редакторе AuroraOS и посмотрите ошибки."
	fi
fi

kit_log "экспортирую PCK с пресетом '$preset_name': $PCK_PATH"
export_log="$BUILD_DIR/export.log"
set +e
if (( QUIET )); then
	"$editor" --headless --path "$PROJECT_ROOT" --export-pack "$preset_name" "$PCK_PATH" >"$export_log" 2>&1
	export_rc=$?
else
	"$editor" --headless --path "$PROJECT_ROOT" --export-pack "$preset_name" "$PCK_PATH" 2>&1 | tee "$export_log"
	export_rc=${PIPESTATUS[0]}
fi
set -e
if (( export_rc != 0 )); then
	tail -n 25 "$export_log" >&2 || true
	kit_die "экспорт PCK не удался (код $export_rc). Если ошибка про пресет — запустите с --force-preset."
fi
[[ -s "$PCK_PATH" ]] || kit_die "PCK не создан: $PCK_PATH"
pck_magic="$(head -c 4 -- "$PCK_PATH" 2>/dev/null || true)"
[[ "$pck_magic" == "GDPC" ]] || kit_warn "PCK не начинается с магии GDPC; проверьте $PCK_PATH."
pck_size="$(du -h "$PCK_PATH" | cut -f1)"
kit_ok "PCK готов: $PCK_PATH ($pck_size)"
if [[ "$(stat -c %s "$PCK_PATH")" -gt $((400 * 1024 * 1024)) ]]; then
	kit_warn "PCK больше 400 МБ; проверьте exclude_filter и сжатие ассетов."
fi

if (( PCK_ONLY )); then
	kit_ok "режим --pck-only: готово."
	exit 0
fi

# ---------------------------------------------------------------------------
# Payload RPM
# ---------------------------------------------------------------------------
kit_log "готовлю payload RPM в $RPMBUILD/files"
install -m 0755 "$template" "$RPMBUILD/files/usr/bin/$PKG_FULL"
install -m 0644 "$PCK_PATH" "$RPMBUILD/files/usr/share/$PKG_FULL/$PKG_FULL.pck"

# libxkbcommon: в rootfs Aurora он есть, но приватная копия позволяет запускать
# пакет на образах без библиотеки. Жёсткого Requires нет.
copy_xkbcommon() {
	local dst="$RPMBUILD/files/usr/share/$PKG_FULL/lib"
	local sdk_dir
	sdk_dir="$(kit_sdk_version_dir)"

	if [[ -n "${AURORA_ARM64_LIB_DIR:-}" && "$TARGET_ARCH" == "aarch64" ]] \
		&& compgen -G "$AURORA_ARM64_LIB_DIR/libxkbcommon.so.0*" >/dev/null; then
		cp -a "$AURORA_ARM64_LIB_DIR"/libxkbcommon.so.0* "$dst/"
		kit_log "libxkbcommon взят из AURORA_ARM64_LIB_DIR"
		return 0
	fi
	if [[ -n "$sdk_dir" && -d "$sdk_dir/targets/$RPM_TARGET" ]] \
		&& compgen -G "$sdk_dir/targets/$RPM_TARGET/usr/lib64/libxkbcommon.so.0*" >/dev/null; then
		cp -a "$sdk_dir/targets/$RPM_TARGET"/usr/lib64/libxkbcommon.so.0* "$dst/"
		kit_log "libxkbcommon взят из sysroot SDK"
		return 0
	fi
	if [[ "$TARGET_ARCH" == "x86_64" && -n "$KIT_SDK_IMAGE" ]] && kit_has docker \
		&& docker image inspect "$KIT_SDK_IMAGE" >/dev/null 2>&1; then
		kit_log "libxkbcommon берётся из $KIT_SDK_IMAGE"
		docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
			-v "$dst:/out" --entrypoint /bin/bash "$KIT_SDK_IMAGE" -lc \
			'cp -a /usr/lib64/libxkbcommon.so.0* /out/' || {
			kit_warn "не удалось скопировать libxkbcommon из образа; продолжаю без неё."
			return 0
		}
		return 0
	fi
	if [[ "$TARGET_ARCH" == "aarch64" ]]; then
		kit_info "aarch64 libxkbcommon локально недоступен; устройство даёт системную копию."
	else
		kit_warn "libxkbcommon не найдена; пакет будет использовать системную копию."
	fi
	return 0
}

finalize_binary() {
	local xkb_real
	xkb_real="$(find "$RPMBUILD/files/usr/share/$PKG_FULL/lib" -name 'libxkbcommon.so.0*' ! -type l -print -quit)"
	if [[ -n "$xkb_real" && ! -e "$RPMBUILD/files/usr/share/$PKG_FULL/lib/libxkbcommon.so.0" ]]; then
		ln -sf "$(basename -- "$xkb_real")" \
			"$RPMBUILD/files/usr/share/$PKG_FULL/lib/libxkbcommon.so.0"
	fi
	if kit_has patchelf; then
		patchelf --force-rpath --set-rpath "$LIBDIR_IN_PACKAGE" "$RPMBUILD/files/usr/bin/$PKG_FULL"
		kit_log "RPATH: $(patchelf --print-rpath "$RPMBUILD/files/usr/bin/$PKG_FULL")"
	else
		kit_die "для указания на вложенный libxkbcommon нужен patchelf.
Установите его (dnf install patchelf / apt install patchelf) или передайте --no-xkbcommon."
	fi
}

if (( BUNDLE_XKBCOMMON )); then
	copy_xkbcommon
	if compgen -G "$RPMBUILD/files/usr/share/$PKG_FULL/lib/libxkbcommon.so.0*" >/dev/null; then
		finalize_binary
	fi
fi

# ---------------------------------------------------------------------------
# Лицензии в пакете (%license)
# ---------------------------------------------------------------------------
# xkbcommon_license_file — текст лицензии библиотеки. Берётся из extra/ после
# сборки шаблона либо из проверенного архива xkbcommon (кэш в BUILD_DIR).
xkbcommon_license_file() {
	local extra="${AURORA_EXTRA_DIR:-$AURORA_WORKSPACE/extra}"
	local base cached tmp archive
	base="$(kit_xkbcommon_base_version "$XKBCOMMON_VERSION")"
	cached="$BUILD_DIR/.licenses/libxkbcommon-${base}.LICENSE"
	if [[ -f "$extra/LICENSE.libxkbcommon" ]]; then
		printf '%s\n' "$extra/LICENSE.libxkbcommon"
		return 0
	fi
	if [[ -f "$cached" ]]; then
		printf '%s\n' "$cached"
		return 0
	fi
	kit_has tar || return 1
	tmp="$(mktemp -d)" || return 1
	archive="$tmp/xkbcommon-$base.tar.xz"
	if ! download_xkbcommon_archive "$archive" \
		"https://xkbcommon.org/download/libxkbcommon-${base}.tar.xz" \
		"https://distfiles.gentoo.org/distfiles/libxkbcommon-${base}.tar.xz"; then
		rm -rf -- "$tmp"
		return 1
	fi
	if ! tar -xJf "$archive" -C "$tmp" "libxkbcommon-${base}/LICENSE"; then
		rm -rf -- "$tmp"
		return 1
	fi
	mkdir -p "$BUILD_DIR/.licenses"
	install -m 0644 "$tmp/libxkbcommon-${base}/LICENSE" "$cached"
	rm -rf -- "$tmp"
	printf '%s\n' "$cached"
}

LICENSE_DIR="$RPMBUILD/files/usr/share/licenses/$PKG_FULL"
mkdir -p "$LICENSE_DIR"
# MIT-уведомления Godot и AuroraOS-форка обязательны для любого пакета кита.
kit_render_template "$KIT_ROOT/THIRD_PARTY_NOTICES.md" "$LICENSE_DIR/LICENSE.Godot" \
	|| kit_die "не удалось подготовить LICENSE.Godot из THIRD_PARTY_NOTICES.md"
spec_license_files='%license %{_licensedir}/%{name}/LICENSE.Godot'
if compgen -G "$RPMBUILD/files/usr/share/$PKG_FULL/lib/libxkbcommon.so.0*" >/dev/null; then
	xkb_license="$(xkbcommon_license_file)" || xkb_license=""
	if [[ -n "$xkb_license" ]]; then
		install -m 0644 "$xkb_license" "$LICENSE_DIR/LICENSE.libxkbcommon"
		spec_license_files+=$'\n%license %{_licensedir}/%{name}/LICENSE.libxkbcommon'
	else
		kit_warn "текст лицензии libxkbcommon не найден; %license этого файла пропущен."
	fi
fi

# ---------------------------------------------------------------------------
# .desktop и .spec
# ---------------------------------------------------------------------------
desktop_path="$RPMBUILD/files/usr/share/applications/$PKG_FULL.desktop"
kit_render_template "$KIT_TEMPLATES/app.desktop.in" "$desktop_path" \
	"APP_TITLE=$(kit_escape_desktop "$PKG_TITLE")" \
	"APP_COMMENT=$(kit_escape_desktop "$PKG_COMMENT")" \
	"PKG_NAME=$(kit_escape_desktop "$PKG_FULL")" \
	"ORG=$(kit_escape_desktop "$PKG_ORG")" \
	"APP=$(kit_escape_desktop "$PKG_APP")" \
	"PERMISSIONS=$(kit_escape_desktop "$PKG_PERMISSIONS")" \
	"ORIENTATION=$(kit_escape_desktop "$PKG_ORIENTATION")" \
	"APP_CATEGORIES=$(kit_escape_desktop "$PKG_CATEGORIES")"
sed -i -e '/^Comment=$/d' -e '/^Permissions=$/d' "$desktop_path"
chmod 0644 "$desktop_path"
kit_log "desktop entry: $desktop_path"

spec_summary="$(kit_escape_spec "$PKG_TITLE")"
spec_description="${APP_DESCRIPTION:-$PKG_COMMENT}"
[[ -n "$spec_description" ]] || spec_description="$PKG_TITLE — игра Godot для Aurora OS."
spec_description="$(kit_escape_spec "$spec_description")"
changelog_date="$(LC_ALL=C date '+%a %b %d %Y')"
# libxkbcommon упаковывается только в x86_64-пакет: там её надо исключить
# из автозависимостей. Для aarch64 строки нет вовсе.
spec_requires_exclude=""
if [[ "$TARGET_ARCH" == "x86_64" ]]; then
	spec_requires_exclude='%define __requires_exclude ^libxkbcommon.*$'
fi
kit_render_template "$KIT_TEMPLATES/app.spec.in" "$SPEC_PATH" \
	"PKG_NAME=$(kit_escape_spec "$PKG_FULL")" \
	"SUMMARY=$spec_summary" \
	"VERSION=$(kit_escape_spec "$PKG_VERSION")" \
	"RELEASE=$(kit_escape_spec "$PKG_RELEASE")" \
	"LICENSE=$(kit_escape_spec "$PKG_LICENSE")" \
	"DESCRIPTION=$spec_description" \
	"CHANGELOG_DATE=$changelog_date" \
	"REQUIRES_EXCLUDE=$spec_requires_exclude" \
	"LICENSE_FILES=$spec_license_files"
kit_log "spec: $SPEC_PATH"

kit_info "payload: $(find "$RPMBUILD/files" -type f | wc -l) файлов, $(du -sh "$RPMBUILD/files" | cut -f1)"

# ---------------------------------------------------------------------------
# rpmbuild
# ---------------------------------------------------------------------------
# Удаляем только выход этой архитектуры, чтобы сборка x86_64 не стирала
# готовый aarch64-пакет (и наоборот).
rm -rf -- "$RPMBUILD/RPMS/$RPM_ARCH"
mkdir -p "$RPMBUILD/RPMS"

rpm_path=""
case "$KIT_SDK_MODE" in
	docker)
		[[ -n "$KIT_SDK_RUN" ]] || kit_die "SDK tools/run не найден; задайте AURORA_SDK_HOME."
		if ! kit_path_inside "$BUILD_DIR" "$PROJECT_ROOT"; then
			kit_die "BUILD_DIR должен находиться внутри проекта: контейнер SDK видит только $PROJECT_ROOT (/workspace)."
		fi
		# tools/run склеивает аргументы в строку и уничтожает кавычки, поэтому
		# --define "_topdir ..." напрямую передать нельзя: используем обёртку.
		topdir_ws="$(kit_to_workspace_path "$RPMBUILD")"
		spec_ws="$(kit_to_workspace_path "$SPEC_PATH")"
		builder="$RPMBUILD/rpmbuild.sh"
		{
			printf '#!/bin/bash\n'
			printf 'set -euo pipefail\n'
			printf 'exec rpmbuild --target %s --define "_topdir %s" -bb "%s"\n' \
				"$RPM_TARGET" "$topdir_ws" "$spec_ws"
		} > "$builder"
		chmod +x "$builder"
		kit_log "запускаю rpmbuild в $KIT_SDK_IMAGE через tools/run"
		WORKSPACE_DIR="$PROJECT_ROOT" "$KIT_SDK_RUN" \
			bash "$(kit_to_workspace_path "$builder")"
		;;
	none)
		kit_die "нет сборочного окружения Aurora SDK; rpmbuild запустить нельзя.
Настройте Aurora SDK 5.2+ (см. docs/SDK_5_2_ARCHITECTURE.md) или используйте --pck-only."
		;;
esac

rpm_path="$(find "$RPMBUILD/RPMS/$RPM_ARCH" -type f -name '*.rpm' 2>/dev/null | sort | tail -1 || true)"
[[ -n "$rpm_path" ]] || rpm_path="$(find "$RPMBUILD/RPMS" -type f -name '*.rpm' 2>/dev/null | sort | tail -1 || true)"
[[ -n "$rpm_path" ]] || kit_die "rpmbuild завершился, но .rpm не найден в $RPMBUILD/RPMS"
kit_ok "RPM готов: $rpm_path ($(du -h "$rpm_path" | cut -f1))"
if kit_has rpm; then
	kit_log "содержимое пакета:"
	rpm -qlp "$rpm_path" | sed 's/^/  /'
else
	kit_info "установите 'rpm', чтобы посмотреть пакет командой rpm -qlp"
fi

cat <<EOF

Дальнейшие шаги:
  * подписать и установить:
      ./godot-to-aurora/scripts/deploy_emulator.sh --rpm "$rpm_path"
  * для aarch64 укажите --device "<имя>" (реальное устройство); для x86_64
    скрипт деплоя сам поднимает эмулятор QEMU.
EOF

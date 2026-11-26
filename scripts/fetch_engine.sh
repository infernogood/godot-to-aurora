#!/usr/bin/env bash
# shellcheck shell=bash
#
# Загрузка Aurora-сборки Godot для кита:
#
#   * Godot_v<GODOT_AURORA_TAG>_linux.x86_64 — редактор с экспортёром AuroraOS
#   * auroraos_release.x86_64                 — Wayland/GLES3 шаблон для эмулятора
#   * auroraos_release.arm64                  — шаблон для устройств
#   * auroraos_debug.arm64                    — debug-шаблон для устройств
#
# Бинарники весят ~60 МБ каждый (редактор ~160 МБ), поэтому лежат в GitHub
# Releases, а не в git. Скрипт скачивает их из релиза либо копирует из
# локального каталога. aarch64-шаблоны дополнительно ставятся в пользовательский
# каталог export_templates Godot, чтобы редактор умел экспортировать aarch64.
#
# Контрольные суммы обязательны: без SHA256SUMS установка не выполняется
# (явный отказ — флаг --skip-checksum).
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

EDITOR_ASSET="${AURORA_GODOT_ASSET:-Godot_v${GODOT_AURORA_TAG}_linux.x86_64}"
X64_ASSET="auroraos_release.x86_64"
ARM64_RELEASE_ASSET="auroraos_release.arm64"
ARM64_DEBUG_ASSET="auroraos_debug.arm64"
ALL_ASSETS=("$EDITOR_ASSET" "$X64_ASSET" "$ARM64_RELEASE_ASSET" "$ARM64_DEBUG_ASSET")

# Минимальные правдоподобные размеры (защита от обрезанных загрузок и
# LFS-указателей). --no-verify отключает проверку.
MIN_EDITOR_BYTES=$((80 * 1024 * 1024))
MIN_TEMPLATE_BYTES=$((30 * 1024 * 1024))

DEST="$(kit_engine_dir)"
TEMPLATES_DIR="${GODOT_EXPORT_TEMPLATES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/${GODOT_TEMPLATE_VERSION}}"
SOURCE_DIR=""
RELEASE_BASE=""
RELEASE_TAG="${AURORA_KIT_RELEASE_TAG:-engine-${GODOT_AURORA_TAG}}"
AURORA_KIT_REPO="${AURORA_KIT_REPO:-infernogood/godot-to-aurora}"
MODE="auto"
FORCE=0
DRY_RUN=0
CHECK_ONLY=0
PRINT_PATHS=0
WRITE_SUMS=0
INSTALL_TEMPLATES=1
VERIFY=1
CHECKSUM=1
SUMS_FILE=""

usage() {
	cat <<EOF
godot-to-aurora — загрузка бинарников Aurora-сборки Godot

ИСПОЛЬЗОВАНИЕ
  fetch_engine.sh [опции]

ИСТОЧНИК (выберите один)
      --from-dir DIR       Копировать бинарники из локального каталога.
      --release-tag TAG    Скачать ассеты из GitHub Release (по умолчанию:
                           $RELEASE_TAG).
      --release-base URL   Скачать ассеты по явному базовому URL.
      --check              Проверить, что уже установлено. Ничего не меняет;
                           код возврата != 0, если чего-то не хватает.
      --print-paths        Напечатать пути в формате KEY=VALUE и выйти.

КАТАЛОГИ
      --dest DIR           Каталог движка (по умолчанию: $DEST).
      --templates-dir DIR  Каталог export_templates Godot
                           (по умолчанию: $TEMPLATES_DIR).
      --no-templates       Не устанавливать aarch64-шаблоны в Godot.
      --force              Перезаписать существующие файлы.
      --dry-run            Показать план; ничего не качать и не создавать.
      --write-sums         Записать SHA256SUMS для установленных бинарников.
      --skip-checksum      Не проверять SHA256SUMS (явный отказ от проверки).
      --no-verify          Не проверять минимальные размеры файлов.
  -V, --version            Напечатать версию кита и выйти.
  -h, --help               Показать эту справку.

РЕПОЗИТОРИЙ
  По умолчанию релизы берутся из infernogood/godot-to-aurora.
  Переопределение: AURORA_KIT_REPO=owner/repo (и при необходимости
  AURORA_KIT_RELEASE_TAG) либо AURORA_KIT_RELEASES_URL.

ПРИМЕРЫ
  ./scripts/fetch_engine.sh --from-dir ~/AuroraProjects/aurora-export/engine
  ./scripts/fetch_engine.sh
  ./scripts/fetch_engine.sh --check --print-paths
EOF
}

while (( $# > 0 )); do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		-V|--version) kit_version_banner; exit 0 ;;
		--from-dir) [[ $# -ge 2 ]] || kit_die "--from-dir требует путь"; SOURCE_DIR="$(kit_abspath "$2")"; shift ;;
		--release-tag) [[ $# -ge 2 ]] || kit_die "--release-tag требует тег"; RELEASE_TAG="$2"; shift ;;
		--release-base) [[ $# -ge 2 ]] || kit_die "--release-base требует URL"; RELEASE_BASE="${2%/}"; shift ;;
		--dest) [[ $# -ge 2 ]] || kit_die "--dest требует путь"; DEST="$2"; shift ;;
		--templates-dir) [[ $# -ge 2 ]] || kit_die "--templates-dir требует путь"; TEMPLATES_DIR="$2"; shift ;;
		--no-templates) INSTALL_TEMPLATES=0 ;;
		--force) FORCE=1 ;;
		--dry-run) DRY_RUN=1 ;;
		--check) CHECK_ONLY=1 ;;
		--print-paths) PRINT_PATHS=1 ;;
		--write-sums) WRITE_SUMS=1 ;;
		--skip-checksum|--no-checksum) CHECKSUM=0 ;;
		--no-verify) VERIFY=0 ;;
		*) kit_die "неизвестная опция: $1 (см. --help)" ;;
	esac
	shift
done

DEST="$(kit_abspath "$DEST")"

print_paths() {
	printf 'ENGINE_DIR=%s\n' "$DEST"
	printf 'GODOT_BIN=%s\n' "$DEST/$EDITOR_ASSET"
	printf 'AURORA_TEMPLATE_X86_64=%s\n' "$DEST/$X64_ASSET"
	printf 'AURORA_TEMPLATE_AARCH64=%s\n' "$DEST/$ARM64_RELEASE_ASSET"
	printf 'ARM64_RELEASE_TEMPLATE=%s\n' "$DEST/$ARM64_RELEASE_ASSET"
	printf 'ARM64_DEBUG_TEMPLATE=%s\n' "$DEST/$ARM64_DEBUG_ASSET"
	printf 'EXPORT_TEMPLATES_DIR=%s\n' "$TEMPLATES_DIR"
}

# ---------------------------------------------------------------------------
# --print-paths / --check (только чтение)
# ---------------------------------------------------------------------------
if (( PRINT_PATHS )); then
	print_paths
	(( CHECK_ONLY )) || exit 0
fi

if (( CHECK_ONLY )); then
	missing_count=0
	printf 'Каталог движка: %s\n' "$DEST"
	for asset in "${ALL_ASSETS[@]}"; do
		path="$DEST/$asset"
		if [[ -f "$path" ]]; then
			printf '  [ok]   %-40s %s\n' "$asset" "$(du -h "$path" | cut -f1)"
		else
			printf '  [НЕТ]  %s\n' "$asset"
			missing_count=1
		fi
	done
	printf 'Шаблоны экспорта Godot: %s\n' "$TEMPLATES_DIR"
	for asset in "$ARM64_RELEASE_ASSET" "$ARM64_DEBUG_ASSET"; do
		path="$TEMPLATES_DIR/$asset"
		if [[ -f "$path" ]]; then
			printf '  [ok]   %-40s %s\n' "$asset" "$(du -h "$path" | cut -f1)"
		else
			printf '  [НЕТ]  %s\n' "$asset"
			missing_count=1
		fi
	done
	if [[ -f "$DEST/$EDITOR_ASSET" && -x "$DEST/$EDITOR_ASSET" ]]; then
		version="$(timeout 30 "$DEST/$EDITOR_ASSET" --headless --version 2>/dev/null | head -1 || true)"
		[[ -n "$version" ]] && printf 'Версия редактора:    %s\n' "$version"
	fi
	if (( missing_count )); then
		kit_warn "часть компонентов отсутствует; запустите fetch_engine.sh без --check."
		exit 1
	fi
	kit_ok "все компоненты движка на месте."
	exit 0
fi

# ---------------------------------------------------------------------------
# Выбор источника
# ---------------------------------------------------------------------------
if [[ -n "$SOURCE_DIR" ]]; then
	MODE="local"
	[[ -d "$SOURCE_DIR" ]] || kit_die "каталог-источник не найден: $SOURCE_DIR"
else
	if [[ -z "$RELEASE_BASE" && -n "${AURORA_KIT_RELEASES_URL:-}" ]]; then
		RELEASE_BASE="${AURORA_KIT_RELEASES_URL%/}"
	fi
	if [[ -z "$RELEASE_BASE" && -n "${AURORA_KIT_REPO:-}" ]]; then
		RELEASE_BASE="https://github.com/${AURORA_KIT_REPO:-infernogood/godot-to-aurora}/releases/download/${RELEASE_TAG}"
	fi
	if [[ -n "$RELEASE_BASE" ]]; then
		MODE="release"
	elif [[ -n "${AURORA_ENGINE_SOURCE:-}" ]]; then
		SOURCE_DIR="$(kit_abspath "$AURORA_ENGINE_SOURCE")"
		MODE="local"
		[[ -d "$SOURCE_DIR" ]] || kit_die "AURORA_ENGINE_SOURCE не каталог: $SOURCE_DIR"
	fi
fi

if [[ "$MODE" == "auto" ]]; then
	kit_die "источник не выбран.

Выберите один:
  --from-dir /path/to/engine          копировать из локального каталога
  AURORA_KIT_REPO=owner/repo          скачать из GitHub Releases
  --release-base https://…            скачать по явному URL

Подробности: --help"
fi

kit_log "каталог движка: $DEST"
if [[ "$MODE" == "local" ]]; then
	kit_log "источник: $SOURCE_DIR"
else
	kit_log "источник: $RELEASE_BASE"
fi

if (( DRY_RUN )); then
	kit_log "dry-run: файлы не создаются и не скачиваются"
	if [[ "$MODE" == "local" ]]; then
		for asset in "${ALL_ASSETS[@]}"; do
			if [[ -f "$SOURCE_DIR/$asset" ]]; then
				kit_log "скопировал бы $SOURCE_DIR/$asset -> $DEST/$asset"
			else
				kit_warn "в источнике нет $asset"
			fi
		done
	else
		for asset in "${ALL_ASSETS[@]}"; do
			kit_log "скачал бы $RELEASE_BASE/$asset -> $DEST/$asset"
		done
	fi
	exit 0
fi

mkdir -p "$DEST"

# ---------------------------------------------------------------------------
# Проверки
# ---------------------------------------------------------------------------
asset_size() { stat -c %s -- "$1" 2>/dev/null || printf 0; }

verify_size() {
	local path="$1" min="$2" size
	(( VERIFY )) || return 0
	size="$(asset_size "$path")"
	if (( size < min )); then
		kit_warn "$(basename -- "$path") весит $size байт (ожидалось не меньше $min)."
		return 1
	fi
	return 0
}

checksum_for() {
	# Печатает ожидаемый sha256 файла из SHA256SUMS (второй столбец) или пусто.
	local name="$1" sums="$2"
	[[ -n "$sums" && -f "$sums" ]] || return 0
	awk -v name="$name" '$2 == name || $2 == "*" name { print $1; exit }' "$sums"
}

# verify_checksum PATH SUMS — строгая проверка по SHA256SUMS.
verify_checksum() {
	local path="$1" sums="$2" expected actual name
	(( CHECKSUM )) || return 0
	name="$(basename -- "$path")"
	if [[ -z "$sums" || ! -f "$sums" ]]; then
		kit_err "SHA256SUMS не найден: ${sums:-<не указан>}"
		kit_err "Установка без контрольных сумм отключается только флагом --skip-checksum."
		return 1
	fi
	expected="$(checksum_for "$name" "$sums")"
	if [[ -z "$expected" ]]; then
		kit_err "в $sums нет строки для $name"
		return 1
	fi
	kit_has sha256sum || { kit_err "sha256sum не найден; установите coreutils."; return 1; }
	actual="$(sha256sum "$path" | awk '{print $1}')"
	if [[ "$actual" != "$expected" ]]; then
		kit_err "контрольная сумма $name не совпала"
		kit_err "  ожидалось $expected"
		kit_err "  получено  $actual"
		return 1
	fi
	kit_info "контрольная сумма ok: $name"
	return 0
}

# ---------------------------------------------------------------------------
# Копирование из локального каталога
# ---------------------------------------------------------------------------
copy_local_assets() {
	local asset src sums=""
	if [[ -f "$SOURCE_DIR/SHA256SUMS" ]]; then
		sums="$SOURCE_DIR/SHA256SUMS"
	elif (( CHECKSUM )); then
		kit_err "в $SOURCE_DIR нет SHA256SUMS, а проверка обязательна."
		kit_err "Положите SHA256SUMS рядом с бинарниками или передайте --skip-checksum."
		return 1
	fi

	for asset in "${ALL_ASSETS[@]}"; do
		src="$SOURCE_DIR/$asset"
		if [[ ! -f "$src" ]]; then
			kit_warn "в источнике отсутствует $asset"
			continue
		fi
		if [[ -f "$DEST/$asset" && "$FORCE" != "1" ]]; then
			kit_info "уже установлен: $asset"
			continue
		fi
		cp -f -- "$src" "$DEST/$asset.part"
		mv -f -- "$DEST/$asset.part" "$DEST/$asset"
		if ! verify_checksum "$DEST/$asset" "$sums"; then
			rm -f -- "$DEST/$asset"
			kit_err "контрольная сумма $asset не совпала; файл не установлен."
			return 1
		fi
		kit_ok "установлен $asset ($(du -h "$DEST/$asset" | cut -f1))"
	done
	return 0
}

# ---------------------------------------------------------------------------
# Загрузка из релиза
# ---------------------------------------------------------------------------
download_release_assets() {
	local asset url sums="" failed=0
	if (( CHECKSUM )); then
		sums="$(mktemp)"
		if curl -fsSL --connect-timeout 20 --max-time 60 \
			--output "$sums" "$RELEASE_BASE/SHA256SUMS" 2>/dev/null; then
			SUMS_FILE="$sums"
			kit_info "используется SHA256SUMS из релиза"
		else
			rm -f -- "$sums"
			kit_err "в релизе нет SHA256SUMS, а проверка обязательна."
			kit_err "Передайте --skip-checksum, чтобы установить без проверки."
			return 1
		fi
	fi
	for asset in "${ALL_ASSETS[@]}"; do
		url="$RELEASE_BASE/$asset"
		if [[ -f "$DEST/$asset" && "$FORCE" != "1" ]]; then
			kit_info "уже установлен: $asset"
			continue
		fi
		if ! ( kit_download "$url" "$DEST/$asset" ); then
			kit_warn "не удалось скачать $asset (нет такого ассета в релизе?)"
			failed=1
			continue
		fi
		if ! verify_checksum "$DEST/$asset" "$sums"; then
			rm -f -- "$DEST/$asset"
			kit_err "контрольная сумма $asset не совпала; файл не установлен."
			return 1
		fi
		kit_ok "скачан $asset ($(du -h "$DEST/$asset" | cut -f1))"
	done
	(( failed == 0 )) || kit_warn "часть ассетов не скачана; проверьте тег и имена файлов."
	return 0
}

if [[ "$MODE" == "local" ]]; then
	copy_local_assets || exit 1
else
	download_release_assets || exit 1
	[[ -z "$SUMS_FILE" ]] || rm -f -- "$SUMS_FILE"
fi

# ---------------------------------------------------------------------------
# Права и проверки целостности
# ---------------------------------------------------------------------------
if [[ -f "$DEST/$EDITOR_ASSET" ]]; then
	chmod 0755 "$DEST/$EDITOR_ASSET"
else
	kit_die "редактор не установлен: $DEST/$EDITOR_ASSET"
fi
if [[ -f "$DEST/$X64_ASSET" ]]; then
	chmod 0755 "$DEST/$X64_ASSET"
fi

verify_size "$DEST/$EDITOR_ASSET" "$MIN_EDITOR_BYTES" || true

if [[ -f "$DEST/$X64_ASSET" ]]; then
	verify_size "$DEST/$X64_ASSET" "$MIN_TEMPLATE_BYTES" || true
	if kit_has readelf; then
		kit_verify_no_x11 "$DEST/$X64_ASSET" || kit_warn "x86_64 шаблон линкуется с X11; пересоберите его с auroraos=yes."
	fi
else
	kit_warn "x86_64 шаблон отсутствует: сборка RPM для эмулятора не заработает."
fi

# ---------------------------------------------------------------------------
# aarch64 export templates
# ---------------------------------------------------------------------------
install_export_templates() {
	local asset src dst version_file
	kit_log "шаблоны экспорта Godot: $TEMPLATES_DIR"
	mkdir -p "$TEMPLATES_DIR"
	for asset in "$ARM64_RELEASE_ASSET" "$ARM64_DEBUG_ASSET"; do
		src="$DEST/$asset"
		dst="$TEMPLATES_DIR/$asset"
		if [[ ! -f "$src" ]]; then
			kit_warn "шаблон недоступен, пропускаю: $asset"
			continue
		fi
		if [[ -f "$dst" && "$FORCE" != "1" ]]; then
			kit_info "шаблон уже установлен: $dst"
			continue
		fi
		kit_log "устанавливаю $asset в $TEMPLATES_DIR"
		install -m 0644 "$src" "$dst"
	done
	version_file="$TEMPLATES_DIR/version.txt"
	if [[ ! -f "$version_file" ]] || [[ "$(cat -- "$version_file")" != "$GODOT_TEMPLATE_VERSION" ]]; then
		printf '%s\n' "$GODOT_TEMPLATE_VERSION" > "$version_file"
		kit_info "version.txt обновлён: $GODOT_TEMPLATE_VERSION"
	fi
	kit_info "редактор AuroraOS теперь находит эти шаблоны автоматически."
}

if (( INSTALL_TEMPLATES )); then
	install_export_templates
fi

# ---------------------------------------------------------------------------
# Необязательные контрольные суммы для владельца релиза
# ---------------------------------------------------------------------------
if (( WRITE_SUMS )); then
	sums_path="$DEST/SHA256SUMS"
	: > "$sums_path"
	for asset in "${ALL_ASSETS[@]}"; do
		[[ -f "$DEST/$asset" ]] || continue
		if kit_has sha256sum; then
			printf '%s  %s\n' "$(sha256sum "$DEST/$asset" | awk '{print $1}')" "$asset" >> "$sums_path"
		fi
	done
	kit_ok "записан $sums_path"
fi

kit_ok "тулчейн движка готов в $DEST ($(du -sh "$DEST" | cut -f1))"
cat <<EOF

Пути для остальных скриптов (определяются автоматически):
  GODOT_BIN="$DEST/$EDITOR_ASSET"
  AURORA_TEMPLATE_X86_64="$DEST/$X64_ASSET"

Далее:
  ./godot-to-aurora/scripts/build_x86_64_rpm.sh --check
EOF

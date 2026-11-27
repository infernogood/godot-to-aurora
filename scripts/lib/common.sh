#!/usr/bin/env bash
# shellcheck shell=bash
#
# godot-to-aurora — общие функции для shell-скриптов кита.
#
# Файл подключается через `source` из fetch_engine.sh, build_x86_64_rpm.sh
# и deploy_emulator.sh. Сам по себе не запускается и требует bash 5+.
#
# Имена: все глобальные переменные имеют префикс KIT_ / PKG_ / AURORA_, чтобы
# в вызывающем скрипте было видно происхождение значения.

# ---------------------------------------------------------------------------
# Защита от повторного подключения + версии
# ---------------------------------------------------------------------------
if [[ -n "${AURORA_KIT_COMMON_SOURCED:-}" ]]; then
	return 0
fi
AURORA_KIT_COMMON_SOURCED=1

# Bash 5.2+ раскрывает '&' в ${var//pat/repl}; шаблоны кита не содержат '&',
# но заголовок игры может, поэтому подстановку оставляем буквальной.
shopt -u patsub_replacement 2>/dev/null || true

KIT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd -- "$KIT_LIB_DIR/../.." && pwd)"
KIT_TEMPLATES="$KIT_ROOT/templates"
KIT_VERSIONS_FILE="$KIT_ROOT/versions.env"

# Единый источник версий; при отсутствии файла работают значения по умолчанию.
if [[ -f "$KIT_VERSIONS_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$KIT_VERSIONS_FILE"
fi

KIT_VERSION="${KIT_VERSION:-1.1.1}"
GODOT_AURORA_TAG="${GODOT_AURORA_TAG:-4.7.2-auroraos1}"
GODOT_AURORA_SHA="${GODOT_AURORA_SHA:-17d8f3f283a00a1182da7b797edb85eacd831091}"
GODOT_TEMPLATE_VERSION="${GODOT_TEMPLATE_VERSION:-4.7.2.stable}"
SDK_DEFAULT_VERSION="${SDK_DEFAULT_VERSION:-5.2.1.200}"
SDK_SUPPORTED_PREFIX="${SDK_SUPPORTED_PREFIX:-5.2.}"
SCONS_VERSION="${SCONS_VERSION:-4.11.1}"
SCONS_SHA256="${SCONS_SHA256:-454cef364348053422696e3d2ecb4fa593c96a624f955842eaaea64f95c8d11d}"
XKBCOMMON_VERSION="${XKBCOMMON_VERSION:-1.3.1}"
XKBCOMMON_SHA256="${XKBCOMMON_SHA256:-b3c710d27a2630054e1e1399c85b7f330ef03359b460f0c1b3b587fd01fe9234}"
XKBCOMMON_KNOWN_VERSIONS="${XKBCOMMON_KNOWN_VERSIONS:-1.3.1 1.3.1+git1}"
# Известные SHA-256 релизных бинарников (второй якорь поверх SHA256SUMS).
# Пустое значение = проверка по этому якорю не выполняется.
EDITOR_SHA256="${EDITOR_SHA256:-28299973ea042a82b42dcdecac6a8c3d1c50c465924bf638306f1d42ac947633}"
X64_TEMPLATE_SHA256="${X64_TEMPLATE_SHA256:-95b1fd82768d055005163b27d4756fcea4a30323e3dab48ad6301e07654c7490}"
ARM64_RELEASE_SHA256="${ARM64_RELEASE_SHA256:-4804de5937fdb33a512e805edb1f5aeb3aa128c6e1dff185e19a8f3b2c45e89e}"
ARM64_DEBUG_SHA256="${ARM64_DEBUG_SHA256:-f9e1606aa48ae5818a69184439a1a099ab736757665d38d6e5d81a98a7f58391}"

# ---------------------------------------------------------------------------
# Логирование
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
	KIT_C_RESET=$'\033[0m'
	KIT_C_DIM=$'\033[2m'
	KIT_C_CYAN=$'\033[36m'
	KIT_C_YELLOW=$'\033[33m'
	KIT_C_RED=$'\033[31m'
	KIT_C_GREEN=$'\033[32m'
else
	KIT_C_RESET=""
	KIT_C_DIM=""
	KIT_C_CYAN=""
	KIT_C_YELLOW=""
	KIT_C_RED=""
	KIT_C_GREEN=""
fi

kit_log()  { printf '%s[aurora-kit]%s %s\n' "$KIT_C_CYAN" "$KIT_C_RESET" "$*"; }
kit_ok()   { printf '%s[aurora-kit]%s %s\n' "$KIT_C_GREEN" "$KIT_C_RESET" "$*"; }
kit_info() { printf '%s[aurora-kit] %s%s\n' "$KIT_C_DIM" "$*" "$KIT_C_RESET"; }
kit_warn() { printf '%s[aurora-kit] WARNING:%s %s\n' "$KIT_C_YELLOW" "$KIT_C_RESET" "$*" >&2; }
kit_err()  { printf '%s[aurora-kit] ERROR:%s %s\n' "$KIT_C_RED" "$KIT_C_RESET" "$*" >&2; }
kit_die()  { kit_err "$*"; exit 1; }

kit_has() { command -v -- "$1" >/dev/null 2>&1; }

# kit_has_any cmd... — успех, если найдена хотя бы одна команда.
kit_has_any() {
	local cmd
	for cmd in "$@"; do
		kit_has "$cmd" && return 0
	done
	return 1
}

kit_require() {
	local missing=() cmd
	for cmd in "$@"; do
		kit_has "$cmd" || missing+=("$cmd")
	done
	if (( ${#missing[@]} > 0 )); then
		kit_die "не найдены обязательные команды: ${missing[*]}. Установите их и повторите."
	fi
}

# kit_yes_no <command> [args...] — печатает yes/no, не глуша код возврата.
kit_yes_no() {
	local rc=0
	"$@" >/dev/null 2>&1 || rc=$?
	if (( rc == 0 )); then
		printf 'yes'
	else
		printf 'no'
	fi
}

# ---------------------------------------------------------------------------
# Файловая система
# ---------------------------------------------------------------------------
kit_abspath() {
	# Нормализует путь, не создавая его.
	local path="$1" dir
	if [[ -d "$path" ]]; then
		(cd -- "$path" && pwd)
		return 0
	fi
	dir="$(dirname -- "$path")"
	if [[ -d "$dir" ]]; then
		printf '%s/%s\n' "$(cd -- "$dir" && pwd)" "$(basename -- "$path")"
	else
		printf '%s\n' "$path"
	fi
}

kit_trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

# kit_path_inside PATH ROOT — точная проверка вложенности после realpath -m:
# /home/u/game-old не является подкаталогом /home/u/game.
kit_path_inside() {
	local target root
	target="$(realpath -m -- "$1")"
	root="$(realpath -m -- "$2")"
	[[ "$target" == "$root" || "$target" == "$root/"* ]]
}

# kit_backup_file FILE — резервная копия под ${BUILD_DIR:-$PROJECT_ROOT/build}/backups/.
kit_backup_file() {
	local file="$1" base dir stamp backup
	[[ -f "$file" ]] || return 0
	if [[ -n "${BUILD_DIR:-}" ]]; then
		base="$BUILD_DIR"
	elif [[ -n "${PROJECT_ROOT:-}" ]]; then
		base="$PROJECT_ROOT/build"
	else
		base="$(dirname -- "$file")/build"
	fi
	dir="$base/backups"
	mkdir -p -- "$dir"
	stamp="$(date +%Y%m%d-%H%M%S)"
	backup="$dir/$(basename -- "$file").bak.$stamp"
	cp -p -- "$file" "$backup"
	kit_info "резервная копия: $backup"
}

# kit_ensure_project_gitignore — идемпотентно дописывает артефакты кита
# в .gitignore целевого проекта (точными строками, без дубликатов).
kit_ensure_project_gitignore() {
	local root="${PROJECT_ROOT:-}"
	[[ -n "$root" ]] || return 0
	local file="$root/.gitignore"
	local entry added=0
	local -a entries=("build/" "*.rpm" "export_presets.cfg.bak.*")
	[[ -f "$file" ]] || : > "$file"
	# Дописываемая строка не должна склеиться с последней строкой файла.
	if [[ -s "$file" ]] && [[ -n "$(tail -c 1 -- "$file")" ]]; then
		printf '\n' >> "$file"
	fi
	for entry in "${entries[@]}"; do
		if ! grep -qxF -- "$entry" "$file"; then
			printf '%s\n' "$entry" >> "$file"
			added=1
		fi
	done
	if (( added )); then
		kit_info "в .gitignore проекта добавлены артефакты сборки: $file"
	fi
	return 0
}

kit_download() {
	# kit_download <url> <dest>
	# Качает в <dest>.part и НЕ переименовывает: проверка контрольной суммы
	# должна пройти до mv, иначе битая загрузка уничтожит рабочий файл.
	local url="$1" dest="$2"
	kit_has curl || kit_die "для загрузки $url требуется curl"
	mkdir -p -- "$(dirname -- "$dest")"
	kit_log "загрузка $(basename -- "$dest")…"
	if ! curl --fail --location --retry 3 --retry-delay 2 \
		--connect-timeout 30 --progress-bar \
		--output "$dest.part" "$url"; then
		rm -f -- "$dest.part"
		kit_err "не удалось загрузить: $url"
		return 1
	fi
}

# kit_commit_download <dest> — переносит проверенный <dest>.part на место.
kit_commit_download() {
	local dest="$1"
	[[ -f "$dest.part" ]] || kit_die "нет загруженного файла: $dest.part"
	mv -f -- "$dest.part" "$dest"
}

# ---------------------------------------------------------------------------
# Поиск проекта игры
# ---------------------------------------------------------------------------
# Кит кладётся в корень Godot-проекта как "godot-to-aurora/". Работает и
# вариант, когда содержимое кита скопировано прямо в корень. GAME_DIR
# переопределяет оба случая.
kit_project_root() {
	local dir
	if [[ -n "${GAME_DIR:-}" ]]; then
		dir="$(kit_abspath "$GAME_DIR")"
		[[ -f "$dir/project.godot" ]] || kit_die "GAME_DIR не содержит project.godot: $dir"
		printf '%s\n' "$dir"
		return 0
	fi
	if [[ -f "$KIT_ROOT/project.godot" ]]; then
		printf '%s\n' "$KIT_ROOT"
		return 0
	fi
	dir="$(cd -- "$KIT_ROOT/.." && pwd)"
	if [[ -f "$dir/project.godot" ]]; then
		printf '%s\n' "$dir"
		return 0
	fi
	kit_die "project.godot не найден. Положите godot-to-aurora/ в корень Godot-проекта или задайте GAME_DIR=/путь/к/игре."
}

# kit_read_project_setting <section/key> [default]
kit_read_project_setting() {
	local full="$1" fallback="${2:-}" file="${PROJECT_ROOT:-}/project.godot"
	local value
	[[ -f "$file" ]] || { printf '%s\n' "$fallback"; return 0; }
	value="$(awk -v full="$full" '
		BEGIN {
			split(full, parts, "/")
			sect = parts[1]
			leaf = substr(full, length(sect) + 2)
			cur = ""
		}
		{ sub(/\r$/, "") }
		/^[[:space:]]*\[/ {
			cur = $0
			sub(/^[[:space:]]*\[/, "", cur)
			sub(/\][[:space:]]*$/, "", cur)
			next
		}
		cur == sect {
			pos = index($0, "=")
			if (pos == 0) next
			key = substr($0, 1, pos - 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
			if (key != leaf) next
			val = substr($0, pos + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
			gsub(/^"|"$/, "", val)
			print val
			exit
		}
	' "$file")"
	printf '%s\n' "${value:-$fallback}"
}

# ---------------------------------------------------------------------------
# export_presets.cfg
# ---------------------------------------------------------------------------
KIT_PRESET_FILE=""

kit_preset_file() {
	if [[ -n "${PRESET_FILE:-}" ]]; then
		printf '%s\n' "$(kit_abspath "$PRESET_FILE")"
	else
		printf '%s\n' "${PROJECT_ROOT:-}/export_presets.cfg"
	fi
}

# Индекс пресета: при пустом AURORA_PRESET — первый с platform="AuroraOS"
# (имя не важно, например "Aurora Phone"); иначе — пресет с этим именем.
# Печатает пустую строку, если подходящего пресета нет.
kit_aurora_preset_index() {
	local file="$1" want="${AURORA_PRESET:-}" idx
	[[ -f "$file" ]] || return 0
	local -a candidates=()
	mapfile -t candidates < <(awk '
		{ sub(/\r$/, "") }
		/^\[preset\.[0-9]+\]$/ {
			idx = $0
			sub(/^\[preset\./, "", idx)
			sub(/\]$/, "", idx)
			next
		}
		/^\[/ { idx = ""; next }
		idx != "" && /^platform="AuroraOS"$/ { print idx; next }
	' "$file")
	(( ${#candidates[@]} > 0 )) || return 0
	if [[ -z "$want" ]]; then
		printf '%s\n' "${candidates[0]}"
		return 0
	fi
	for idx in "${candidates[@]}"; do
		if [[ "$(kit_preset_value "$file" "$idx" "name" "")" == "$want" ]]; then
			printf '%s\n' "$idx"
			return 0
		fi
	done
	return 0
}

# Читает ключ из конкретного пресета (секция preset.N или preset.N.options).
kit_preset_value() {
	local file="$1" idx="$2" key="$3" fallback="${4:-}" value
	[[ -f "$file" && -n "$idx" ]] || { printf '%s\n' "$fallback"; return 0; }
	value="$(awk -v idx="$idx" -v key="$key" '
		BEGIN { inside = 0 }
		{ sub(/\r$/, "") }
		/^\[/ {
			inside = ($0 == "[preset." idx "]" || $0 == "[preset." idx ".options]")
			next
		}
		inside {
			pos = index($0, "=")
			if (pos == 0) next
			k = substr($0, 1, pos - 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
			if (k != key) next
			val = substr($0, pos + 1)
			sub(/^[[:space:]]+/, "", val)
			sub(/[[:space:]]+$/, "", val)
			# Кавычки Godot экранирует: \" и \\. Раскодируем одним проходом,
			# иначе обратные слэши утекут в .desktop и .spec.
			if (val ~ /^".*"$/ && length(val) >= 2) {
				body = substr(val, 2, length(val) - 2)
				out = ""
				i = 1
				while (i <= length(body)) {
					c = substr(body, i, 1)
					if (c == "\\" && i < length(body)) {
						i++
						out = out substr(body, i, 1)
					} else {
						out = out c
					}
					i++
				}
				val = out
			}
			print val
			exit
		}
	' "$file")"
	printf '%s\n' "${value:-$fallback}"
}

kit_aurora_preset_name() {
	local file="$1" idx="$2"
	kit_preset_value "$file" "$idx" "name" "AuroraOS"
}

kit_next_preset_index() {
	local file="$1" max=""
	[[ -f "$file" ]] || { printf '0\n'; return 0; }
	max="$(sed -n 's/^\[preset\.\([0-9]\+\)\].*/\1/p' "$file" | sort -n | tail -1)"
	printf '%s\n' "$(( ${max:--1} + 1 ))"
}

# Удаляет [preset.N] и [preset.N.options] вместе с телом.
kit_remove_preset() {
	local file="$1" idx="$2"
	[[ -f "$file" && -n "$idx" ]] || return 0
	awk -v idx="$idx" '
		{ sub(/\r$/, "") }
		BEGIN { skip = 0 }
		/^\[/ {
			if ($0 == "[preset." idx "]" || $0 == "[preset." idx ".options]") { skip = 1; next }
			skip = 0
			print
			next
		}
		skip { next }
		{ print }
	' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# ---------------------------------------------------------------------------
# Экранирование значений шаблонов
# ---------------------------------------------------------------------------
# kit_strip_control_chars — удаляет управляющие символы (CR/LF/TAB и прочие).
kit_strip_control_chars() {
	local value="$1"
	printf '%s' "$value" | LC_ALL=C tr -d '\001-\037\177'
}

# kit_escape_spec VALUE — для .spec: нет управляющих символов, '%' -> '%%'.
kit_escape_spec() {
	local value
	value="$(kit_strip_control_chars "$1")"
	value="${value//%/%%}"
	printf '%s\n' "$value"
}

# kit_escape_desktop VALUE — для .desktop: управляющие символы удаляются,
# обратный слэш экранируется (Exec/TryExec не должны ломать строку).
kit_escape_desktop() {
	local value
	value="$(kit_strip_control_chars "$1")"
	value="${value//\\/\\\\}"
	printf '%s\n' "$value"
}

# kit_escape_cfg VALUE — для export_presets.cfg: экранируются '\' и '"'.
kit_escape_cfg() {
	local value
	value="$(kit_strip_control_chars "$1")"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '%s\n' "$value"
}

# ---------------------------------------------------------------------------
# Параметры пакета
# ---------------------------------------------------------------------------
AURORA_PERMISSION_KEYS=(
	Audio Bluetooth Camera DeviceInfo Documents Downloads Internet Location
	MediaIndexing Microphone Music NFC Pictures PublicDir RemovableMedia
	Sensors UserDirs Videos WebView
)

kit_translit() {
	# Минимальная транслитерация ru/uk -> latin: имя пакета должно быть ASCII.
	# Под LC_ALL=C bash не переводит кириллицу в нижний регистр, поэтому
	# внутри функции явно выставляется UTF-8-локаль (и восстанавливается).
	local input="$1" out="" ch lower
	local prev_lc="${LC_ALL:-}" had_lc=0
	[[ -n "${LC_ALL+set}" ]] && had_lc=1
	export LC_ALL=C.UTF-8
	local -A map=(
		[а]=a [б]=b [в]=v [г]=g [д]=d [е]=e [ё]=e [ж]=zh [з]=z [и]=i
		[й]=y [к]=k [л]=l [м]=m [н]=n [о]=o [п]=p [р]=r [с]=s [т]=t
		[у]=u [ф]=f [х]=h [ц]=ts [ч]=ch [ш]=sh [щ]=sch [ъ]="" [ы]=y
		[ь]="" [э]=e [ю]=yu [я]=ya [і]=i [ї]=yi [є]=ye [ґ]=g
	)
	local i
	for (( i = 0; i < ${#input}; i++ )); do
		ch="${input:i:1}"
		lower="${ch,,}"
		if [[ -n "${map[$lower]+x}" ]]; then
			out+="${map[$lower]}"
		else
			out+="$ch"
		fi
	done
	if (( had_lc )); then export LC_ALL="$prev_lc"; else unset LC_ALL; fi
	printf '%s\n' "$out"
}

kit_slug() {
	# ASCII slug: только [a-z0-9_], повторы разделителей схлопываются.
	# tr и sed тоже зависят от локали — фиксируем UTF-8 на время вызова.
	local raw prev_lc="${LC_ALL:-}" had_lc=0
	[[ -n "${LC_ALL+set}" ]] && had_lc=1
	export LC_ALL=C.UTF-8
	raw="$(kit_translit "$1" | tr '[:upper:]' '[:lower:]')"
	if (( had_lc )); then export LC_ALL="$prev_lc"; else unset LC_ALL; fi
	raw="$(printf '%s' "$raw" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/_+/_/g')"
	printf '%s\n' "$raw"
}

kit_validate_org() {
	[[ "$1" =~ ^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$ ]]
}

kit_validate_app() {
	[[ "$1" =~ ^[a-z][a-z0-9_]*$ ]]
}

kit_normalize_orientation() {
	# Единая карта для кода и документации:
	#   0 2 4 landscape reverse_landscape sensor_landscape       -> Landscape
	#   1 3 5 portrait  reverse_portrait   sensor_portrait       -> Portrait
	#   6     dynamic   sensor                                    -> Dynamic
	local raw="${1,,}" mapped=""
	case "$raw" in
		landscape|0|2|4|reverse_landscape|sensor_landscape|sensorlandscape) mapped="Landscape" ;;
		portrait|1|3|5|reverse_portrait|sensor_portrait|sensorportrait) mapped="Portrait" ;;
		dynamic|sensor|6) mapped="Dynamic" ;;
		*) return 1 ;;
	esac
	printf '%s\n' "$mapped"
}

kit_parse_permissions() {
	# Принимает "Audio,Internet" / "Audio Internet" и печатает канонический
	# список без дубликатов. Неизвестное имя — ошибка, чтобы опечатка не
	# приводила к молчаливому отсутствию прав.
	local raw="${1//,/ }" item canonical out=()
	local -A seen=()
	for item in $raw; do
		canonical=""
		local key
		for key in "${AURORA_PERMISSION_KEYS[@]}"; do
			if [[ "${item,,}" == "${key,,}" ]]; then canonical="$key"; break; fi
		done
		if [[ -z "$canonical" ]]; then
			kit_die "неизвестное разрешение '$item'. Допустимые значения: ${AURORA_PERMISSION_KEYS[*]}"
		fi
		[[ -n "${seen[$canonical]:-}" ]] && continue
		seen[$canonical]=1
		out+=("$canonical")
	done
	local IFS=,
	printf '%s\n' "${out[*]}"
}

kit_permissions_from_preset() {
	local file="$1" idx="$2" out=() key
	for key in "${AURORA_PERMISSION_KEYS[@]}"; do
		if [[ "$(kit_preset_value "$file" "$idx" "permissions/$key" "false")" == "true" ]]; then
			out+=("$key")
		fi
	done
	local IFS=,
	printf '%s\n' "${out[*]}"
}

# kit_load_package_params — заполняет PKG_* и PROJECT_ROOT из проекта/пресета.
kit_load_package_params() {
	PROJECT_ROOT="$(kit_project_root)"
	KIT_PRESET_FILE="$(kit_preset_file)"
	PKG_PRESET_INDEX="$(kit_aurora_preset_index "$KIT_PRESET_FILE")"
	PKG_PRESET_NAME=""
	if [[ -n "$PKG_PRESET_INDEX" ]]; then
		PKG_PRESET_NAME="$(kit_aurora_preset_name "$KIT_PRESET_FILE" "$PKG_PRESET_INDEX")"
	fi

	local project_name project_version preset_exclude
	project_name="$(kit_read_project_setting application/config/name "")"
	project_version="$(kit_read_project_setting application/config/version "0.1.0")"

	PKG_ORG="${ORG_NAME:-}"
	if [[ -z "$PKG_ORG" && -n "$PKG_PRESET_INDEX" ]]; then
		PKG_ORG="$(kit_preset_value "$KIT_PRESET_FILE" "$PKG_PRESET_INDEX" "package/organization" "")"
	fi

	PKG_APP="${APP_NAME:-}"
	if [[ -z "$PKG_APP" && -n "$PKG_PRESET_INDEX" ]]; then
		PKG_APP="$(kit_preset_value "$KIT_PRESET_FILE" "$PKG_PRESET_INDEX" "package/name" "")"
	fi
	if [[ -z "$PKG_APP" ]]; then
		PKG_APP="$(kit_slug "${project_name:-$(basename -- "$PROJECT_ROOT")}")"
	fi
	if [[ -z "$PKG_ORG" ]]; then
		PKG_ORG="ru.${PKG_APP}"
		kit_warn "package/organization не задан; используется '$PKG_ORG' (переопределяется ORG_NAME)."
	fi

	PKG_TITLE="${APP_TITLE:-}"
	if [[ -z "$PKG_TITLE" && -n "$PKG_PRESET_INDEX" ]]; then
		PKG_TITLE="$(kit_preset_value "$KIT_PRESET_FILE" "$PKG_PRESET_INDEX" "package/launcher_name" "")"
	fi
	PKG_TITLE="${PKG_TITLE:-${project_name:-$PKG_APP}}"

	PKG_VERSION="${APP_VERSION:-}"
	if [[ -z "$PKG_VERSION" ]]; then
		PKG_VERSION="$(kit_preset_value "$KIT_PRESET_FILE" "${PKG_PRESET_INDEX:-}" "package/version" "")"
	fi
	PKG_VERSION="${PKG_VERSION:-${project_version:-0.1.0}}"
	PKG_VERSION="${PKG_VERSION#v}"
	PKG_VERSION="$(printf '%s' "$PKG_VERSION" | sed -E 's/[^A-Za-z0-9._+]+/./g; s/^\.+//; s/\.+$//')"
	[[ -n "$PKG_VERSION" ]] || PKG_VERSION="0.1.0"

	PKG_RELEASE="${APP_RELEASE:-}"
	if [[ -z "$PKG_RELEASE" ]]; then
		PKG_RELEASE="$(kit_preset_value "$KIT_PRESET_FILE" "${PKG_PRESET_INDEX:-}" "package/release" "")"
	fi
	PKG_RELEASE="${PKG_RELEASE:-1}"
	[[ "$PKG_RELEASE" =~ ^[0-9]+$ ]] || kit_die "некорректный release '$PKG_RELEASE' (ожидается целое число)."

	PKG_FULL="$PKG_ORG.$PKG_APP"
	if ! kit_validate_org "$PKG_ORG"; then
		kit_die "некорректная организация '$PKG_ORG' (нужен точечный lowercase, например ru.example). Задайте ORG_NAME."
	fi
	if ! kit_validate_app "$PKG_APP"; then
		kit_die "некорректное имя приложения '$PKG_APP' (нужен lowercase [a-z0-9_]). Задайте APP_NAME."
	fi

	local orientation_raw
	orientation_raw="${ORIENTATION:-$(kit_read_project_setting display/window/handheld/orientation "0")}"
	PKG_ORIENTATION="$(kit_normalize_orientation "$orientation_raw")" \
		|| kit_die "неподдерживаемая ориентация '$orientation_raw' (Landscape, Portrait или Dynamic)."

	PKG_PERMISSIONS=""
	if [[ -n "${PERMISSIONS:-}" ]]; then
		PKG_PERMISSIONS="$(kit_parse_permissions "$PERMISSIONS")"
	elif [[ -n "$PKG_PRESET_INDEX" ]]; then
		PKG_PERMISSIONS="$(kit_permissions_from_preset "$KIT_PRESET_FILE" "$PKG_PRESET_INDEX")"
	fi
	if [[ -z "$PKG_PERMISSIONS" ]]; then
		PKG_PERMISSIONS="Audio"
		kit_info "разрешения Sailjail не заданы; по умолчанию Audio (переопределяется PERMISSIONS)."
	fi

	# shellcheck disable=SC2034 # читается скриптами сборки
	PKG_COMMENT="${APP_COMMENT:-$(kit_read_project_setting application/config/description "")}"
	PKG_LICENSE="${RPM_LICENSE:-Proprietary}"
	# shellcheck disable=SC2034 # читается скриптами сборки
	PKG_CATEGORIES="${APP_CATEGORIES:-Game}"

	preset_exclude=""
	if [[ -n "$PKG_PRESET_INDEX" ]]; then
		preset_exclude="$(kit_preset_value "$KIT_PRESET_FILE" "$PKG_PRESET_INDEX" "exclude_filter" "")"
	fi
	PKG_EXCLUDE_FILTER="$preset_exclude"
}

kit_print_params() {
	cat <<EOF
  project           $PROJECT_ROOT
  preset            ${PKG_PRESET_NAME:-<будет создан>} (индекс ${PKG_PRESET_INDEX:-нет})
  package           $PKG_FULL
  title             $PKG_TITLE
  version           $PKG_VERSION-$PKG_RELEASE
  orientation       $PKG_ORIENTATION
  permissions       $PKG_PERMISSIONS
  license           $PKG_LICENSE
  build dir         ${BUILD_DIR:-$PROJECT_ROOT/build}
EOF
}

# ---------------------------------------------------------------------------
# Шаблоны и генерация пресета
# ---------------------------------------------------------------------------
# kit_render_template <src> <dst> [KEY=VALUE ...]
# Однопроходная замена: строка собирается слева направо, вставленное значение
# не сканируется повторно (значение с @OTHER_KEY@ остаётся буквальным).
# Значения экранируются вызывающей стороной через kit_escape_*.
kit_render_template() {
	local src="$1" dst="$2"
	shift 2
	[[ -f "$src" ]] || kit_die "шаблон не найден: $src"
	local content result="" rest="" prefix="" token="" pair key matched
	local -A values=()
	for pair in "$@"; do
		values["${pair%%=*}"]="${pair#*=}"
	done
	content="$(cat -- "$src")"
	while [[ "$content" == *"@"* ]]; do
		prefix="${content%%@*}"
		result+="$prefix"
		rest="${content:${#prefix}}"
		matched=0
		for key in "${!values[@]}"; do
			token="@${key}@"
			if [[ "$rest" == "$token"* ]]; then
				result+="${values[$key]}"
				rest="${rest:${#token}}"
				matched=1
				break
			fi
		done
		if (( matched )); then
			content="$rest"
		else
			result+="@"
			content="${rest:1}"
		fi
	done
	result+="$content"
	mkdir -p -- "$(dirname -- "$dst")"
	printf '%s\n' "$result" > "$dst"
}

kit_permissions_block() {
	local key
	for key in "${AURORA_PERMISSION_KEYS[@]}"; do
		if [[ ",$PKG_PERMISSIONS," == *",$key,"* ]]; then
			printf 'permissions/%s=true\n' "$key"
		else
			printf 'permissions/%s=false\n' "$key"
		fi
	done
}

# kit_write_aurora_preset [--force]
# Создаёт пресет AuroraOS из templates/export_presets.aurora.cfg. Существующий
# пресет НЕ перезаписывается без --force; новый индекс — только если пресета
# с platform="AuroraOS" в файле нет.
kit_write_aurora_preset() {
	local force=0
	[[ "${1:-}" == "--force" ]] && force=1
	local file="$KIT_PRESET_FILE"
	[[ -n "$file" ]] || file="$(kit_preset_file)"
	local idx name tmp exclude_raw exclude perms_block escape_name escape_org escape_app
	local escape_title escape_version escape_release

	idx="$(kit_aurora_preset_index "$file")"
	if [[ -n "$idx" && "$force" != "1" ]]; then
		kit_info "пресет AuroraOS уже существует (индекс $idx); файл не изменяется."
		PKG_PRESET_INDEX="$idx"
		PKG_PRESET_NAME="$(kit_aurora_preset_name "$file" "$idx")"
		return 0
	fi
	if [[ -z "$idx" ]]; then
		idx="$(kit_next_preset_index "$file")"
	fi

	name="${AURORA_PRESET:-}"
	if [[ -z "$name" ]]; then
		name="${PKG_PRESET_NAME:-AuroraOS}"
	fi

	exclude_raw="$(kit_merge_exclude_filter "${PKG_EXCLUDE_FILTER:-}")"
	perms_block="$(kit_permissions_block)"

	escape_name="$(kit_escape_cfg "$name")"
	escape_org="$(kit_escape_cfg "$PKG_ORG")"
	escape_app="$(kit_escape_cfg "$PKG_APP")"
	escape_title="$(kit_escape_cfg "$PKG_TITLE")"
	escape_version="$(kit_escape_cfg "$PKG_VERSION")"
	escape_release="$(kit_escape_cfg "$PKG_RELEASE")"
	exclude="$(kit_escape_cfg "$exclude_raw")"

	tmp="$(mktemp)"
	kit_render_template \
		"$KIT_TEMPLATES/export_presets.aurora.cfg" "$tmp" \
		"PRESET_NAME=$escape_name" \
		"ORG=$escape_org" \
		"APP=$escape_app" \
		"TITLE=$escape_title" \
		"VERSION=$escape_version" \
		"RELEASE=$escape_release" \
		"EXCLUDE=$exclude" \
		"PERMISSIONS_BLOCK=$perms_block"

	kit_backup_file "$file"
	mkdir -p -- "$(dirname -- "$file")"
	if [[ ! -f "$file" ]]; then
		: > "$file"
	fi

	if (( force )) && [[ -n "$(kit_aurora_preset_index "$file")" ]]; then
		kit_remove_preset "$file" "$idx"
	fi

	# Гарантируем перевод строки перед новой секцией.
	if [[ -s "$file" ]] && [[ -n "$(tail -c 1 -- "$file")" ]]; then
		printf '\n' >> "$file"
	fi

	{
		printf '\n'
		sed -e "s/^\[preset\.0\]$/[preset.${idx}]/" \
			-e "s/^\[preset\.0\.options\]$/[preset.${idx}.options]/" \
			"$tmp"
	} >> "$file"
	rm -f -- "$tmp"

	PKG_PRESET_INDEX="$idx"
	PKG_PRESET_NAME="$name"
	PKG_EXCLUDE_FILTER="$exclude_raw"
	kit_ok "создан пресет AuroraOS '$name' (индекс $idx) в $file"
}

# kit_merge_exclude_filter CURRENT — добавляет только build/* и каталог кита
# (если кит лежит внутри проекта). Членство проверяется точным совпадением
# токена, поэтому mybuild/* не считается build/*.
kit_merge_exclude_filter() {
	local current="${1:-}"
	local -a entries=() required=() parts=()
	local token want found entry kit_rel="" joined=""

	if [[ -n "$current" ]]; then
		IFS=',' read -r -a parts <<< "$current"
		for token in "${parts[@]}"; do
			token="$(kit_trim "$token")"
			[[ -n "$token" ]] && entries+=("$token")
		done
	fi

	required=("build/*")
	if [[ -n "${PROJECT_ROOT:-}" && -n "${KIT_ROOT:-}" ]]; then
		local kit_norm root_norm
		kit_norm="$(realpath -m -- "$KIT_ROOT")"
		root_norm="$(realpath -m -- "$PROJECT_ROOT")"
		if [[ -n "$root_norm" && "$kit_norm" == "$root_norm/"* ]]; then
			kit_rel="${kit_norm#"$root_norm"/}"
			[[ -n "$kit_rel" ]] && required+=("$kit_rel/*")
		fi
	fi

	for want in "${required[@]}"; do
		found=0
		for entry in "${entries[@]}"; do
			if [[ "$entry" == "$want" ]]; then
				found=1
				break
			fi
		done
		(( found )) || entries+=("$want")
	done

	for entry in "${entries[@]}"; do
		joined="${joined:+$joined,}$entry"
	done
	printf '%s\n' "$joined"
}

# kit_patch_exclude_filter — дописывает build/* и каталог кита в exclude_filter
# выбранного пресета. Файл предварительно копируется в backups/.
kit_patch_exclude_filter() {
	local merged current idx="$PKG_PRESET_INDEX" tmp tmp2 has_line
	[[ -n "$idx" ]] || return 0
	current="$(kit_preset_value "$KIT_PRESET_FILE" "$idx" "exclude_filter" "")"
	merged="$(kit_merge_exclude_filter "$current")"
	[[ "$merged" == "$current" ]] && return 0
	kit_backup_file "$KIT_PRESET_FILE"
	tmp="$(mktemp)"
	local escaped
	escaped="$(kit_escape_cfg "$merged")"

	# Пустая строка exclude_filter="" тоже считается существующей: наличие
	# ключа проверяется отдельно, иначе появился бы дубликат.
	has_line="$(awk -v idx="$idx" '
		{ sub(/\r$/, "") }
		$0 == "[preset." idx "]" || $0 == "[preset." idx ".options]" { inside=1; next }
		/^\[/ { inside=0; next }
		inside && /^exclude_filter=/ { print "yes"; exit }
	' "$KIT_PRESET_FILE")"

	# Фаза 1: заменяем существующую строку exclude_filter выбранного пресета.
	awk -v idx="$idx" -v value="$escaped" '
		{ sub(/\r$/, "") }
		$0 == "[preset." idx "]" || $0 == "[preset." idx ".options]" { inside=1; print; next }
		/^\[/ { inside=0; print; next }
		inside && /^exclude_filter=/ { print "exclude_filter=\"" value "\""; next }
		{ print }
	' "$KIT_PRESET_FILE" > "$tmp"

	# Фаза 2: если строки не было, вставляем её после export_filter (строка
	# другого пресета не должна считаться).
	if [[ -z "$has_line" ]]; then
		tmp2="$(mktemp)"
		awk -v idx="$idx" -v value="$escaped" '
			{ sub(/\r$/, "") }
			$0 == "[preset." idx "]" || $0 == "[preset." idx ".options]" { inside=1; print; next }
			/^\[/ { inside=0; print; next }
			inside && /^export_filter=/ && !done { print; print "exclude_filter=\"" value "\""; done=1; next }
			{ print }
		' "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
	fi

	mv "$tmp" "$KIT_PRESET_FILE"
	PKG_EXCLUDE_FILTER="$merged"
	kit_info "exclude_filter расширен служебными каталогами: $merged"
}

# ---------------------------------------------------------------------------
# Движок и шаблоны экспорта
# ---------------------------------------------------------------------------
kit_engine_dir() {
	printf '%s\n' "${AURORA_KIT_ENGINE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/godot-to-aurora/engine}"
}

# kit_find_godot — печатает путь к редактору Godot с экспортёром AuroraOS.
# Диагностика идёт в stderr; вызывающий не должен глушить его.
kit_find_godot() {
	local candidate dir
	if [[ -n "${GODOT_BIN:-}" ]]; then
		if [[ ! -x "$GODOT_BIN" ]]; then
			kit_err "GODOT_BIN не исполняется: $GODOT_BIN"
			return 1
		fi
		kit_abspath "$GODOT_BIN"
		return 0
	fi
	for dir in "$(kit_engine_dir)" "${PROJECT_ROOT:-}/utilities"; do
		[[ -n "$dir" && -d "$dir" ]] || continue
		candidate="$(find "$dir" -maxdepth 1 -type f -name 'Godot_v*auroraos*.x86_64' | sort -V | tail -1)"
		[[ -n "$candidate" ]] || continue
		if [[ -x "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
		kit_err "найден $candidate, но он не исполняется: chmod +x '$candidate'"
	done
	for candidate in godot4 godot; do
		kit_has "$candidate" || continue
		kit_warn "используется $candidate, но в обычном Godot нет платформы экспорта AuroraOS."
		command -v -- "$candidate"
		return 0
	done
	return 1
}

# kit_verify_template_arch PATH ARCH — проверка ELF-архитектуры шаблона.
# ARCH: x86_64 | aarch64. Диагностика в stderr, код возврата != 0 при
# несовпадении. Без readelf — предупреждение и успех.
kit_verify_template_arch() {
	local path="$1" want="$2" machine="" actual=""
	[[ -f "$path" ]] || { kit_err "шаблон не найден: $path"; return 1; }
	case "$want" in
		x86_64|aarch64) ;;
		*) kit_err "неизвестная архитектура шаблона: $want (ожидается x86_64 или aarch64)"; return 1 ;;
	esac
	if ! kit_has readelf; then
		kit_warn "readelf не найден; проверка ELF-архитектуры $path пропущена."
		return 0
	fi
	machine="$(LC_ALL=C readelf -h -- "$path" 2>/dev/null \
		| awk -F: '/Machine:/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }')"
	case "$machine" in
		*X86-64*|*x86-64*) actual="x86_64" ;;
		*AArch64*|*aarch64*) actual="aarch64" ;;
		*)
			kit_err "не удалось определить ELF-архитектуру $path (readelf Machine: '${machine:-?}')"
			return 1
			;;
	esac
	if [[ "$actual" != "$want" ]]; then
		kit_err "шаблон $path собран для $actual, а нужен $want"
		return 1
	fi
	return 0
}

# kit_find_template ARCH [release|debug]
# Приоритет переменных окружения:
#   AURORA_TEMPLATE_X86_64 / AURORA_TEMPLATE_AARCH64, затем AURORA_TEMPLATE.
# Имена файлов в каталоге движка: auroraos_<mode>.x86_64 / auroraos_<mode>.arm64.
kit_find_template() {
	local arch="$1" mode="${2:-release}" dir candidate name="" env_var=""
	case "$arch" in
		x86_64|x86-64|x64)
			arch="x86_64"
			env_var="AURORA_TEMPLATE_X86_64"
			name="auroraos_${mode}.x86_64"
			;;
		aarch64|arm64|arm64-v8a)
			arch="aarch64"
			env_var="AURORA_TEMPLATE_AARCH64"
			name="auroraos_${mode}.arm64"
			;;
		*)
			kit_err "неподдерживаемая архитектура шаблона: $arch"
			return 1
			;;
	esac

	local explicit="${!env_var:-}"
	local legacy="${AURORA_TEMPLATE:-}"
	local from_env=""
	if [[ -n "$explicit" ]]; then
		from_env="$explicit"
	elif [[ -n "$legacy" ]]; then
		from_env="$legacy"
	fi
	if [[ -n "$from_env" ]]; then
		if [[ ! -f "$from_env" ]]; then
			kit_err "переменная $env_var/AURORA_TEMPLATE указывает на отсутствующий файл: $from_env"
			return 1
		fi
		kit_verify_template_arch "$from_env" "$arch" || return 1
		kit_abspath "$from_env"
		return 0
	fi

	for dir in "$(kit_engine_dir)" "${PROJECT_ROOT:-}/utilities"; do
		[[ -n "$dir" && -d "$dir" ]] || continue
		candidate="$dir/$name"
		[[ -f "$candidate" ]] || continue
		if kit_verify_template_arch "$candidate" "$arch"; then
			printf '%s\n' "$candidate"
			return 0
		fi
		kit_err "пропускаю $candidate: неверная ELF-архитектура"
	done
	return 1
}

kit_verify_no_x11() {
	local bin="$1" bad
	[[ -f "$bin" ]] || { kit_warn "нет файла: $bin"; return 1; }
	if ! kit_has readelf; then
		kit_warn "readelf не найден; проверка зависимостей X11 пропущена."
		return 0
	fi
	bad="$(LC_ALL=C readelf -d "$bin" 2>/dev/null | grep -Ei 'libX11|libxcb|libdecor|libXext' || true)"
	if [[ -n "$bad" ]]; then
		kit_err "бинарник линкуется с X11:"
		printf '%s\n' "$bad" >&2
		return 1
	fi
	kit_info "проверка Wayland-only пройдена (нет NEEDED libX11/libxcb/libdecor)."
	LC_ALL=C readelf -d "$bin" 2>/dev/null | grep -Ei 'wayland|libEGL' | sed 's/^/  /' || true
	return 0
}

# ---------------------------------------------------------------------------
# Версии инструментов сборки шаблона
# ---------------------------------------------------------------------------
# kit_xkbcommon_sha256 VERSION — печатает SHA-256 для известной версии
# libxkbcommon. Неизвестная версия возвращает 1: сборка должна подсказать,
# что добавить в versions.env, либо потребовать явный --skip-checksum.
kit_xkbcommon_sha256() {
	local version="$1" known
	local -a known_versions
	read -r -a known_versions <<<"${XKBCOMMON_KNOWN_VERSIONS:-}"
	for known in "${known_versions[@]}"; do
		if [[ "$version" == "$known" ]]; then
			printf '%s\n' "$XKBCOMMON_SHA256"
			return 0
		fi
	done
	return 1
}

# kit_xkbcommon_base_version VERSION — отбрасывает packaging-суффикс RPM
# (1.3.1+git1 -> 1.3.1), чтобы скачать соответствующий архив заголовков.
kit_xkbcommon_base_version() {
	printf '%s\n' "${1%%+*}"
}

# ---------------------------------------------------------------------------
# Aurora SDK 5.x
# ---------------------------------------------------------------------------
kit_sdk_home() { printf '%s\n' "${AURORA_SDK_HOME:-$HOME/AuroraOS}"; }

kit_sdk_version_dir() {
	local home
	home="$(kit_sdk_home)"
	[[ -d "$home/sdk" ]] || return 0
	find "$home/sdk" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*' 2>/dev/null | sort -V | tail -1 || return 0
}

# kit_sdk_version — версия установленного SDK (имя каталога sdk/<версия>).
kit_sdk_version() {
	local dir
	dir="$(kit_sdk_version_dir)"
	[[ -n "$dir" ]] || return 0
	basename -- "$dir"
}

# kit_sdk_tools_run — печатает путь к tools/run, если он есть.
# Всегда возвращает 0: отсутствие SDK не должно ронять скрипты под set -e.
kit_sdk_tools_run() {
	local dir
	dir="$(kit_sdk_version_dir)"
	if [[ -n "$dir" && -x "$dir/tools/run" ]]; then
		printf '%s\n' "$dir/tools/run"
	fi
	return 0
}

kit_sdk_image() {
	if [[ -n "${AURORA_BUILD_IMAGE:-}" ]]; then
		printf '%s\n' "$AURORA_BUILD_IMAGE"
		return 0
	fi
	local run image=""
	run="$(kit_sdk_tools_run)"
	if [[ -n "$run" ]]; then
		image="$(grep -oE 'aurora-build-tools[^[:space:]]*' "$run" 2>/dev/null | head -1 || true)"
	fi
	if [[ -z "$image" ]] && kit_has docker; then
		image="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^aurora-build-tools' | sort -V | tail -1 || true)"
	fi
	printf '%s\n' "$image"
	return 0
}

# kit_detect_sdk — определяет способ доступа к сборочному окружению SDK.
# Заполняет KIT_SDK_MODE (docker|none), KIT_SDK_RUN, KIT_SDK_IMAGE.
# Legacy-режимы sfdk engine/sb2 удалены: в SDK 5.2+ сборка идёт только в
# Docker-образе aurora-build-tools. Никогда не завершает скрипт.
kit_detect_sdk() {
	KIT_SDK_MODE="none"
	KIT_SDK_VERSION="$(kit_sdk_version)"
	KIT_SDK_SUPPORTED=1
	export KIT_SDK_SUPPORTED
	if [[ -n "$KIT_SDK_VERSION" && "$KIT_SDK_VERSION" != "$SDK_SUPPORTED_PREFIX"* ]]; then
		KIT_SDK_SUPPORTED=0
		kit_warn "Aurora SDK $KIT_SDK_VERSION не входит в поддерживаемую серию ${SDK_SUPPORTED_PREFIX}x (кит тестировался на $SDK_DEFAULT_VERSION)."
		kit_warn "Сборка/деплой продолжатся; используйте --strict-sdk, чтобы блокировать несовместимую версию."
	fi
	KIT_SDK_RUN="$(kit_sdk_tools_run)"
	KIT_SDK_IMAGE="$(kit_sdk_image)"

	if [[ -n "$KIT_SDK_RUN" && -n "$KIT_SDK_IMAGE" ]] && kit_has docker \
		&& docker image inspect "$KIT_SDK_IMAGE" >/dev/null 2>&1; then
		KIT_SDK_MODE="docker"
		return 0
	fi

	local candidate
	candidate="$(kit_sdk_version_dir)"
	if [[ -n "$candidate" ]]; then
		kit_info "SDK найден в $candidate, но сборочного окружения нет (ожидается Aurora SDK $SDK_DEFAULT_VERSION+)."
	fi
	return 0
}

kit_sdk_description() {
	case "${KIT_SDK_MODE:-none}" in
		docker) printf 'docker image %s via %s\n' "$KIT_SDK_IMAGE" "$KIT_SDK_RUN" ;;
		*)      printf 'not found\n' ;;
	esac
}

# kit_to_workspace_path PATH — путь внутри проекта в /workspace (SDK 5.2
# монтирует проект туда). Границы проверяются после нормализации: соседний
# каталог /home/u/game-old не считается частью /home/u/game.
kit_to_workspace_path() {
	local path root
	path="$(realpath -m -- "$1")"
	root="$(realpath -m -- "${PROJECT_ROOT:-.}")"
	if [[ -n "$root" && ( "$path" == "$root" || "$path" == "$root/"* ) ]]; then
		printf '/workspace%s\n' "${path#"$root"}"
	else
		printf '%s\n' "$path"
	fi
}

kit_find_sfdk() {
	if [[ -n "${SFDK:-}" && -x "$SFDK" ]]; then printf '%s\n' "$SFDK"; return 0; fi
	if [[ -x "$(kit_sdk_home)/bin/sfdk" ]]; then printf '%s\n' "$(kit_sdk_home)/bin/sfdk"; return 0; fi
	if kit_has sfdk; then command -v -- sfdk; return 0; fi
	return 1
}

# ---------------------------------------------------------------------------
# Прочее
# ---------------------------------------------------------------------------
kit_version_banner() {
	printf 'godot-to-aurora %s\n' "$KIT_VERSION"
}

# end of common.sh

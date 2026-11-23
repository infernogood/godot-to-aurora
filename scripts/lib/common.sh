#!/usr/bin/env bash
# shellcheck shell=bash
#
# godot-to-aurora — shared helpers.
#
# This file is sourced by fetch_engine.sh, build_x86_64_rpm.sh and
# deploy_emulator.sh. It never runs on its own.
#
# Naming: all globals set here are prefixed with KIT_ or PKG_ so a caller can
# see at a glance where a value came from.

# ---------------------------------------------------------------------------
# Guard + paths
# ---------------------------------------------------------------------------
if [[ -n "${AURORA_KIT_COMMON_SOURCED:-}" ]]; then
	return 0
fi
AURORA_KIT_COMMON_SOURCED=1

# Bash 5.2+ expands '&' in ${var//pat/repl}; templates contain no '&' patterns
# but user-provided titles might, so keep substitution literal.
shopt -u patsub_replacement 2>/dev/null || true

KIT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd -- "$KIT_LIB_DIR/../.." && pwd)"
KIT_TEMPLATES="$KIT_ROOT/templates"
KIT_MODULES="$KIT_ROOT/modules"

KIT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Logging
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

kit_require() {
	local missing=() cmd
	for cmd in "$@"; do
		kit_has "$cmd" || missing+=("$cmd")
	done
	if (( ${#missing[@]} > 0 )); then
		kit_die "missing required command(s): ${missing[*]}. Install them first."
	fi
}

# ---------------------------------------------------------------------------
# Small filesystem helpers
# ---------------------------------------------------------------------------
kit_abspath() {
	# Resolve a possibly non-existent path without touching it.
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

kit_backup_file() {
	# Conservative backup used before touching files that belong to the game.
	local file="$1"
	[[ -f "$file" ]] || return 0
	local backup="$file.bak.$(date +%Y%m%d-%H%M%S)"
	cp -p -- "$file" "$backup"
	kit_info "backup: $backup"
}

kit_download() {
	# kit_download <url> <dest>
	local url="$1" dest="$2"
	kit_has curl || kit_die "curl is required to download $url"
	mkdir -p -- "$(dirname -- "$dest")"
	kit_log "downloading $(basename -- "$dest")…"
	curl --fail --location --retry 3 --retry-delay 2 \
		--connect-timeout 30 --progress-bar \
		--output "$dest.part" "$url" || {
		rm -f -- "$dest.part"
		kit_die "download failed: $url"
	}
	mv -- "$dest.part" "$dest"
}

# ---------------------------------------------------------------------------
# Game project discovery
# ---------------------------------------------------------------------------
# The kit is meant to be copied into the root of a Godot project as
# "godot-to-aurora/". It also works when its contents are copied directly
# into the project root. GAME_DIR overrides both cases.
kit_project_root() {
	local dir
	if [[ -n "${GAME_DIR:-}" ]]; then
		dir="$(kit_abspath "$GAME_DIR")"
		[[ -f "$dir/project.godot" ]] || kit_die "GAME_DIR does not contain project.godot: $dir"
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
	kit_die "project.godot not found. Put godot-to-aurora/ into the root of your Godot project, or set GAME_DIR=/path/to/game."
}

# kit_read_project_setting <section/key> [default]
# Example: kit_read_project_setting application/config/name "My Game"
kit_read_project_setting() {
	local full="$1" fallback="${2:-}" file="$PROJECT_ROOT/project.godot"
	local value
	[[ -f "$file" ]] || { printf '%s\n' "$fallback"; return 0; }
	value="$(awk -v full="$full" '
		BEGIN {
			split(full, parts, "/")
			sect = parts[1]
			leaf = substr(full, length(sect) + 2)
			cur = ""
		}
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
# export_presets.cfg access
# ---------------------------------------------------------------------------
KIT_PRESET_FILE=""

kit_preset_file() {
	if [[ -n "${PRESET_FILE:-}" ]]; then
		printf '%s\n' "$(kit_abspath "$PRESET_FILE")"
	else
		printf '%s\n' "$PROJECT_ROOT/export_presets.cfg"
	fi
}

# Index of the first preset with platform="AuroraOS" (or the one named by
# AURORA_PRESET). Prints nothing when the file has no such preset.
kit_aurora_preset_index() {
	local file="$1" want="${AURORA_PRESET:-}"
	[[ -f "$file" ]] || return 0
	awk -v want="$want" '
		BEGIN { idx = ""; name = ""; in_base = 0 }
		/^\[preset\.[0-9]+\]$/ {
			idx = $0
			sub(/^\[preset\./, "", idx)
			sub(/\]$/, "", idx)
			name = ""
			in_base = 1
			next
		}
		/^\[/ { in_base = 0; next }
		in_base && /^name="/ {
			name = $0
			sub(/^name="/, "", name)
			sub(/"$/, "", name)
			next
		}
		in_base && /^platform="AuroraOS"$/ {
			if (want == "" || name == want) { print idx; exit }
		}
	' "$file"
}

# Read a key from a specific preset (base preset.N section or its .options).
kit_preset_value() {
	local file="$1" idx="$2" key="$3" fallback="${4:-}" value
	[[ -f "$file" && -n "$idx" ]] || { printf '%s\n' "$fallback"; return 0; }
	value="$(awk -v idx="$idx" -v key="$key" '
		BEGIN { inside = 0 }
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
			gsub(/^"|"$/, "", val)
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
	local file="$1"
	[[ -f "$file" ]] || { printf '0\n'; return 0; }
	local max
	max="$(sed -n 's/^\[preset\.\([0-9]\+\)\].*/\1/p' "$file" | sort -n | tail -1)"
	printf '%s\n' "$(( ${max:--1} + 1 ))"
}

# Removes [preset.N] and [preset.N.options] (and their body) from a preset file.
kit_remove_preset() {
	local file="$1" idx="$2"
	[[ -f "$file" && -n "$idx" ]] || return 0
	awk -v idx="$idx" '
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
# Parameter resolution
# ---------------------------------------------------------------------------
AURORA_PERMISSION_KEYS=(
	Audio Bluetooth Camera DeviceInfo Documents Downloads Internet Location
	MediaIndexing Microphone Music NFC Pictures PublicDir RemovableMedia
	Sensors UserDirs Videos WebView
)

kit_translit() {
	# Minimal ru/uk -> latin transliteration so a Cyrillic project name can
	# still produce a valid package identifier. Not a general solution.
	local input="$1" out="" ch lower
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
	printf '%s\n' "$out"
}

kit_slug() {
	# ASCII slug: lowercase, [a-z0-9_] only, collapsed separators.
	local raw
	raw="$(kit_translit "$1" | tr '[:upper:]' '[:lower:]')"
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
	# Accepts Aurora values (Landscape/Portrait/Dynamic) and the Godot
	# screen orientation enum used by display/window/handheld/orientation.
	local raw="${1,,}" mapped=""
	case "$raw" in
		landscape|0|2|4|sensor_landscape|sensorlandscape) mapped="Landscape" ;;
		portrait|1|3|5|sensor_portrait|sensorportrait) mapped="Portrait" ;;
		dynamic|sensor|6|reverse_landscape|reverse_portrait) mapped="Dynamic" ;;
		*) return 1 ;;
	esac
	printf '%s\n' "$mapped"
}

kit_parse_permissions() {
	# Accepts "Audio,Internet" / "Audio Internet" and prints a canonical,
	# de-duplicated comma-separated list. Unknown names are rejected so a typo
	# cannot silently grant nothing.
	local raw="${1//,/ }" item canonical out=()
	local -A seen=()
	for item in $raw; do
		canonical=""
		local key
		for key in "${AURORA_PERMISSION_KEYS[@]}"; do
			if [[ "${item,,}" == "${key,,}" ]]; then canonical="$key"; break; fi
		done
		if [[ -z "$canonical" ]]; then
			kit_die "unknown permission '$item'. Valid values: ${AURORA_PERMISSION_KEYS[*]}"
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

# kit_load_package_params — sets PKG_* globals used by every script.
kit_load_package_params() {
	PROJECT_ROOT="$(kit_project_root)"
	KIT_PRESET_FILE="$(kit_preset_file)"
	PKG_PRESET_INDEX="$(kit_aurora_preset_index "$KIT_PRESET_FILE")"
	PKG_PRESET_NAME=""
	if [[ -n "$PKG_PRESET_INDEX" ]]; then
		PKG_PRESET_NAME="$(kit_aurora_preset_name "$KIT_PRESET_FILE" "$PKG_PRESET_INDEX")"
	fi

	local project_name project_version launcher_name preset_exclude
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
		kit_warn "package organization is not configured; defaulting to '$PKG_ORG' (set ORG_NAME to override)."
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
	[[ "$PKG_RELEASE" =~ ^[0-9]+$ ]] || kit_die "invalid release '$PKG_RELEASE' (expected a positive integer)."

	PKG_FULL="$PKG_ORG.$PKG_APP"
	if ! kit_validate_org "$PKG_ORG"; then
		kit_die "invalid organization '$PKG_ORG' (expected dotted lowercase, e.g. ru.example). Set ORG_NAME."
	fi
	if ! kit_validate_app "$PKG_APP"; then
		kit_die "invalid application name '$PKG_APP' (expected lowercase [a-z0-9_]). Set APP_NAME."
	fi

	local orientation_raw
	orientation_raw="${ORIENTATION:-$(kit_read_project_setting display/window/handheld/orientation "0")}"
	PKG_ORIENTATION="$(kit_normalize_orientation "$orientation_raw")" \
		|| kit_die "unsupported orientation '$orientation_raw' (use Landscape, Portrait or Dynamic)."

	PKG_PERMISSIONS=""
	if [[ -n "${PERMISSIONS:-}" ]]; then
		PKG_PERMISSIONS="$(kit_parse_permissions "$PERMISSIONS")"
	elif [[ -n "$PKG_PRESET_INDEX" ]]; then
		PKG_PERMISSIONS="$(kit_permissions_from_preset "$KIT_PRESET_FILE" "$PKG_PRESET_INDEX")"
	fi
	if [[ -z "$PKG_PERMISSIONS" ]]; then
		PKG_PERMISSIONS="Audio"
		kit_info "no Sailjail permissions configured; defaulting to Audio (set PERMISSIONS to override)."
	fi

	PKG_COMMENT="${APP_COMMENT:-$(kit_read_project_setting application/config/description "")}"
	PKG_LICENSE="${RPM_LICENSE:-Proprietary}"
	PKG_GROUP="${RPM_GROUP:-Amusements/Games}"
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
  preset            ${PKG_PRESET_NAME:-<will be created>} (index ${PKG_PRESET_INDEX:-none})
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
# Templates and preset generation
# ---------------------------------------------------------------------------
# kit_render_template <src> <dst> [KEY=VALUE ...]
# Replaces every occurrence of @KEY@ with VALUE. Values are inserted literally.
kit_render_template() {
	local src="$1" dst="$2"; shift 2
	[[ -f "$src" ]] || kit_die "template not found: $src"
	local content pair key value
	content="$(cat -- "$src")"
	for pair in "$@"; do
		key="${pair%%=*}"
		value="${pair#*=}"
		content="${content//@${key}@/$value}"
	done
	mkdir -p -- "$(dirname -- "$dst")"
	printf '%s\n' "$content" > "$dst"
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
# Creates an AuroraOS preset from templates/export_presets.aurora.cfg.
# Existing presets are never overwritten unless --force is given; a new preset
# always gets the next free index and is appended to export_presets.cfg.
kit_write_aurora_preset() {
	local force=0
	[[ "${1:-}" == "--force" ]] && force=1
	local file="$KIT_PRESET_FILE"
	local idx name

	idx="$(kit_aurora_preset_index "$file")"
	name="${AURORA_PRESET:-AuroraOS}"
	if [[ -n "$idx" && "$force" != "1" ]]; then
		kit_info "AuroraOS preset already exists (index $idx); leaving it untouched."
		return 0
	fi
	if [[ -z "$idx" ]]; then
		idx="$(kit_next_preset_index "$file")"
	fi

	local exclude
	exclude="$(kit_merge_exclude_filter "${PKG_EXCLUDE_FILTER:-}")"
	local perms_block
	perms_block="$(kit_permissions_block)"

	local tmp
	tmp="$(mktemp)"
	mkdir -p -- "$(dirname -- "$file")"
	kit_render_template \
		"$KIT_TEMPLATES/export_presets.aurora.cfg" "$tmp" \
		"PRESET_NAME=$name" \
		"ORG=$PKG_ORG" \
		"APP=$PKG_APP" \
		"TITLE=$PKG_TITLE" \
		"VERSION=$PKG_VERSION" \
		"RELEASE=$PKG_RELEASE" \
		"EXCLUDE=$exclude"

	# Replace the @PERMISSIONS_BLOCK@ line with the generated multiline block.
	local body
	body="$(awk -v block="$perms_block" '
		/^@PERMISSIONS_BLOCK@$/ { print block; next }
		{ print }
	' "$tmp")"
	printf '%s\n' "$body" > "$tmp"

	kit_backup_file "$file"
	if [[ ! -f "$file" ]]; then
		{
			echo '[runnable_presets]'
			echo
			echo "${name}=\"${name}\""
			echo
		} > "$file"
	else
		if (( force )); then
			kit_remove_preset "$file" "$idx"
		fi
		if ! grep -q '^\[runnable_presets\]$' "$file"; then
			# Keep the file valid for the editor by giving it the section Godot
			# normally writes itself.
			{
				echo '[runnable_presets]'
				echo
				echo "${name}=\"${name}\""
				echo
				cat "$file"
			} > "$file.tmp" && mv "$file.tmp" "$file"
		elif ! grep -qx "${name}=\"${name}\"" "$file"; then
			awk -v line="${name}=\"${name}\"" '
				/^\[runnable_presets\]$/ { print; print line; inrun=1; next }
				{ if (inrun && $0 == "") inrun=0; print }
			' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
		fi
	fi

	# Append the preset, re-indexed to idx.
	{
		echo
		sed -e "s/^\[preset\.0\]$/[preset.${idx}]/" \
			-e "s/^\[preset\.0\.options\]$/[preset.${idx}.options]/" \
			"$tmp"
	} >> "$file"
	rm -f -- "$tmp"

	PKG_PRESET_INDEX="$idx"
	PKG_PRESET_NAME="$name"
	PKG_EXCLUDE_FILTER="$exclude"
	kit_ok "created AuroraOS preset '$name' (index $idx) in $file"
}

kit_merge_exclude_filter() {
	# Ensures kit/build/tooling folders never end up inside the PCK.
	local current="$1"
	local required=(build tools utilities)
	local entry out="$current" kit_rel=""
	if [[ "$KIT_ROOT" == "$PROJECT_ROOT"/* ]]; then
		kit_rel="${KIT_ROOT#"$PROJECT_ROOT"/}"
	fi
	[[ -n "$kit_rel" ]] && required+=("$kit_rel")
	# Documentation and tests never need to be inside the game PCK.
	[[ -d "$PROJECT_ROOT/docs" ]] && required+=(docs)
	[[ -d "$PROJECT_ROOT/tests" ]] && required+=(tests)
	for entry in "${required[@]}"; do
		if [[ "$out" != *"$entry/*"* ]]; then
			out="${out:+$out, }$entry/*"
		fi
	done
	printf '%s\n' "$out"
}

kit_patch_exclude_filter() {
	# Rewrites exclude_filter in an existing Aurora preset when kit/build folders
	# are missing from it. Safe: backs the file up first.
	local merged current idx="$PKG_PRESET_INDEX" tmp tmp2
	[[ -n "$idx" ]] || return 0
	current="$(kit_preset_value "$KIT_PRESET_FILE" "$idx" "exclude_filter" "")"
	merged="$(kit_merge_exclude_filter "$current")"
	[[ "$merged" == "$current" ]] && return 0
	kit_backup_file "$KIT_PRESET_FILE"
	tmp="$(mktemp)"

	# Phase 1: replace an existing exclude_filter line of the selected preset.
	awk -v idx="$idx" -v value="$merged" '
		$0 == "[preset." idx "]" || $0 == "[preset." idx ".options]" { inside=1; print; next }
		/^\[/ { inside=0; print; next }
		inside && /^exclude_filter=/ { print "exclude_filter=\"" value "\""; next }
		{ print }
	' "$KIT_PRESET_FILE" > "$tmp"

	# Phase 2: insert the line after export_filter when the selected preset
	# had no exclude_filter (another preset's line must not count).
	if [[ -z "$current" ]]; then
		tmp2="$(mktemp)"
		awk -v idx="$idx" -v value="$merged" '
			$0 == "[preset." idx "]" || $0 == "[preset." idx ".options]" { inside=1; print; next }
			/^\[/ { inside=0; print; next }
			inside && /^export_filter=/ && !done { print; print "exclude_filter=\"" value "\""; done=1; next }
			{ print }
		' "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
	fi

	mv "$tmp" "$KIT_PRESET_FILE"
	PKG_EXCLUDE_FILTER="$merged"
	kit_info "export exclude_filter extended with kit/build folders: $merged"
}

# ---------------------------------------------------------------------------
# Engine binaries
# ---------------------------------------------------------------------------
kit_engine_dir() {
	printf '%s\n' "${AURORA_KIT_ENGINE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/godot-to-aurora/engine}"
}

kit_find_godot() {
	# Prints the path to a Godot editor binary with the AuroraOS exporter.
	local candidate dir
	if [[ -n "${GODOT_BIN:-}" ]]; then
		[[ -x "$GODOT_BIN" ]] || kit_die "GODOT_BIN is not executable: $GODOT_BIN"
		printf '%s\n' "$(kit_abspath "$GODOT_BIN")"
		return 0
	fi
	for dir in "$(kit_engine_dir)" "$PROJECT_ROOT/utilities"; do
		[[ -d "$dir" ]] || continue
		candidate="$(find "$dir" -maxdepth 1 -type f -name 'Godot_v*auroraos*.x86_64' -perm -u+x 2>/dev/null | sort -V | tail -1)"
		[[ -n "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
	done
	candidate="$(command -v godot4 2>/dev/null || command -v godot 2>/dev/null || true)"
	if [[ -n "$candidate" ]]; then
		kit_warn "using $candidate, but stock Godot has no AuroraOS export platform."
		printf '%s\n' "$candidate"
		return 0
	fi
	return 1
}

kit_find_template() {
	# kit_find_template <arch> [debug|release]
	local arch="$1" mode="${2:-release}" dir candidate
	if [[ -n "${AURORA_TEMPLATE:-}" ]]; then
		[[ -f "$AURORA_TEMPLATE" ]] || kit_die "AURORA_TEMPLATE not found: $AURORA_TEMPLATE"
		printf '%s\n' "$(kit_abspath "$AURORA_TEMPLATE")"
		return 0
	fi
	for dir in "$(kit_engine_dir)" "$PROJECT_ROOT/utilities"; do
		candidate="$dir/auroraos_${mode}.${arch}"
		[[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
	done
	return 1
}

kit_verify_no_x11() {
	local bin="$1" bad
	[[ -f "$bin" ]] || { kit_warn "missing binary: $bin"; return 1; }
	if ! kit_has readelf; then
		kit_warn "readelf is missing; skipping X11 dependency check."
		return 0
	fi
	bad="$(readelf -d "$bin" 2>/dev/null | grep -Ei 'libX11|libxcb|libdecor|libXext' || true)"
	if [[ -n "$bad" ]]; then
		kit_err "binary links against X11 components:"
		printf '%s\n' "$bad" >&2
		return 1
	fi
	kit_info "Wayland-only check passed (no libX11/libxcb/libdecor NEEDED entries)."
	readelf -d "$bin" 2>/dev/null | grep -Ei 'wayland|libEGL' | sed 's/^/  /' || true
	return 0
}

# ---------------------------------------------------------------------------
# Aurora SDK 5.x discovery
# ---------------------------------------------------------------------------
kit_sdk_home() { printf '%s\n' "${AURORA_SDK_HOME:-$HOME/AuroraOS}"; }

kit_sdk_version_dir() {
	local home
	home="$(kit_sdk_home)"
	[[ -d "$home/sdk" ]] || return 0
	find "$home/sdk" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*' 2>/dev/null | sort -V | tail -1
}

kit_sdk_tools_run() {
	local dir
	dir="$(kit_sdk_version_dir)"
	[[ -n "$dir" && -x "$dir/tools/run" ]] && printf '%s\n' "$dir/tools/run"
}

kit_sdk_sysroot() {
	local dir
	dir="$(kit_sdk_version_dir)"
	[[ -n "$dir" && -d "$dir/targets/x86_64-meego-linux-gnu" ]] \
		&& printf '%s\n' "$dir/targets/x86_64-meego-linux-gnu"
}

kit_sdk_image() {
	if [[ -n "${AURORA_BUILD_IMAGE:-}" ]]; then
		printf '%s\n' "$AURORA_BUILD_IMAGE"
		return 0
	fi
	local run image=""
	run="$(kit_sdk_tools_run)"
	if [[ -n "$run" ]]; then
		image="$(grep -oE 'aurora-build-tools[^[:space:]]*' "$run" | head -1 || true)"
	fi
	if [[ -z "$image" ]] && kit_has docker; then
		image="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^aurora-build-tools' | sort -V | tail -1 || true)"
	fi
	printf '%s\n' "$image"
}

# Detects how the SDK build environment can be reached.
# Sets KIT_SDK_MODE (sfdk|sb2|docker|none), KIT_SDK_TARGET, KIT_SDK_RUN, KIT_SDK_IMAGE.
kit_detect_sdk() {
	KIT_SDK_MODE="none"
	KIT_SDK_TARGET="${X86_64_TARGET:-}"
	KIT_SDK_RUN="$(kit_sdk_tools_run)"
	KIT_SDK_IMAGE="$(kit_sdk_image)"

	local sfdk_bin="" targets="" candidate
	if [[ -n "${SFDK:-}" ]]; then
		sfdk_bin="$SFDK"
	elif [[ -x "$(kit_sdk_home)/bin/sfdk" ]]; then
		sfdk_bin="$(kit_sdk_home)/bin/sfdk"
	elif kit_has sfdk; then
		sfdk_bin="$(command -v sfdk)"
	fi

	if [[ -n "$sfdk_bin" ]]; then
		# SDK 5.2 dropped `engine`; older SDKs expose sb2 targets there.
		targets="$(timeout 15 "$sfdk_bin" engine exec sb2-config -l 2>/dev/null || true)"
		if grep -qE '^AuroraOS-.*x86_64' <<<"$targets"; then
			KIT_SDK_MODE="sfdk"
			if [[ -z "$KIT_SDK_TARGET" ]]; then
				KIT_SDK_TARGET="$(grep -E '^AuroraOS-.*x86_64.*\.default$' <<<"$targets" | head -1 || true)"
				[[ -n "$KIT_SDK_TARGET" ]] || KIT_SDK_TARGET="$(grep -E '^AuroraOS-.*x86_64' <<<"$targets" | head -1)"
			fi
			return 0
		fi
	fi

	if kit_has sb2-config; then
		targets="$(sb2-config -l 2>/dev/null || true)"
		if grep -qE '^AuroraOS-.*x86_64' <<<"$targets"; then
			KIT_SDK_MODE="sb2"
			if [[ -z "$KIT_SDK_TARGET" ]]; then
				KIT_SDK_TARGET="$(grep -E '^AuroraOS-.*x86_64.*\.default$' <<<"$targets" | head -1 || true)"
				[[ -n "$KIT_SDK_TARGET" ]] || KIT_SDK_TARGET="$(grep -E '^AuroraOS-.*x86_64' <<<"$targets" | head -1)"
			fi
			return 0
		fi
	fi

	if [[ -n "$KIT_SDK_RUN" && -n "$KIT_SDK_IMAGE" ]] && kit_has docker \
		&& docker image inspect "$KIT_SDK_IMAGE" >/dev/null 2>&1; then
		KIT_SDK_MODE="docker"
		return 0
	fi

	candidate="$(kit_sdk_version_dir)"
	[[ -n "$candidate" ]] && kit_info "SDK found at $candidate but no usable build environment yet."
	return 0
}

kit_sdk_description() {
	case "$KIT_SDK_MODE" in
		sfdk)   printf 'sfdk/sb2 target %s\n' "$KIT_SDK_TARGET" ;;
		sb2)    printf 'host sb2 target %s\n' "$KIT_SDK_TARGET" ;;
		docker) printf 'docker image %s via %s\n' "$KIT_SDK_IMAGE" "$KIT_SDK_RUN" ;;
		*)      printf 'not found\n' ;;
	esac
}

# Converts a host path under the project into the container path used by
# Aurora SDK 5.x tools/run (which mounts the project at /workspace).
kit_to_workspace_path() {
	local path="$1"
	if [[ "$path" == "$PROJECT_ROOT"* ]]; then
		printf '/workspace%s\n' "${path#"$PROJECT_ROOT"}"
	else
		printf '%s\n' "$path"
	fi
}

kit_find_sfdk() {
	if [[ -n "${SFDK:-}" && -x "$SFDK" ]]; then printf '%s\n' "$SFDK"; return 0; fi
	if [[ -x "$(kit_sdk_home)/bin/sfdk" ]]; then printf '%s\n' "$(kit_sdk_home)/bin/sfdk"; return 0; fi
	kit_has sfdk && { command -v sfdk; return 0; }
	return 1
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
kit_require_python_free_tools() {
	:
}

kit_version_banner() {
	printf 'godot-to-aurora %s\n' "$KIT_VERSION"
}

# end of common.sh

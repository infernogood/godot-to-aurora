#!/usr/bin/env bash
# shellcheck shell=bash
#
# Fetch the Aurora-enabled Godot toolchain used by the kit:
#
#   * Godot_v4.7.2-auroraos1_linux.x86_64   — editor with the AuroraOS exporter
#   * auroraos_release.x86_64               — Wayland/GLES3 template for the emulator
#   * auroraos_release.arm64                — template for devices
#   * auroraos_debug.arm64                  — debug template for devices
#
# Binaries are ~60 MB each (the editor is ~160 MB), which is why they live in
# GitHub Releases instead of the git repository. This script downloads them from
# a release, or copies them from a local directory such as an aurora-export/
# stash. aarch64 templates are additionally installed into Godot's user
# export_templates directory so the editor can export aarch64 RPMs.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

EDITOR_ASSET="${AURORA_GODOT_ASSET:-Godot_v4.7.2-auroraos1_linux.x86_64}"
X64_ASSET="auroraos_release.x86_64"
ARM64_RELEASE_ASSET="auroraos_release.arm64"
ARM64_DEBUG_ASSET="auroraos_debug.arm64"
ALL_ASSETS=("$EDITOR_ASSET" "$X64_ASSET" "$ARM64_RELEASE_ASSET" "$ARM64_DEBUG_ASSET")

# Minimum plausible sizes (sanity check against truncated downloads / LFS
# pointer files). --no-verify skips these checks.
MIN_EDITOR_BYTES=$((80 * 1024 * 1024))
MIN_TEMPLATE_BYTES=$((30 * 1024 * 1024))

DEST="$(kit_engine_dir)"
TEMPLATES_DIR="${GODOT_EXPORT_TEMPLATES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/${GODOT_TEMPLATE_VERSION:-4.7.2.stable}}"
SOURCE_DIR=""
RELEASE_BASE=""
RELEASE_TAG="${AURORA_KIT_RELEASE_TAG:-engine-4.7.2-auroraos1}"
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

usage() {
	cat <<EOF
godot-to-aurora — fetch the Aurora Godot engine binaries

USAGE
  fetch_engine.sh [options]

SOURCE (choose one)
      --from-dir DIR       Copy binaries from a local directory, e.g. the
                           engine/ folder of an existing aurora-export stash.
      --release-tag TAG    Download assets from a GitHub Release tag
                           (default: $RELEASE_TAG).
      --release-base URL   Download assets from an explicit base URL.
      --check              Verify what is already installed. Changes nothing.
      --print-paths        Print resolved paths as KEY=VALUE and exit.

DESTINATION
      --dest DIR           Engine directory
                           (default: $DEST).
      --templates-dir DIR  Godot export_templates directory
                           (default: $TEMPLATES_DIR).
      --no-templates       Do not install aarch64 templates into Godot.
      --force              Overwrite existing files.
      --dry-run            Print what would be copied/downloaded.
      --write-sums         Write SHA256SUMS for the installed binaries (useful
                           before uploading them to a GitHub Release).
      --no-checksum        Do not verify SHA256SUMS when downloading.
      --no-verify          Skip file size sanity checks.
  -h, --help               Show this help.

REPOSITORY
  Set AURORA_KIT_REPO=owner/repo (and optionally AURORA_KIT_RELEASE_TAG) once
  the kit is published on GitHub:
      AURORA_KIT_REPO=you/godot-to-aurora ./fetch_engine.sh
  Or point AURORA_KIT_RELEASES_URL directly at a release download base URL.

EXAMPLES
  # From a local stash (offline, fastest)
  ./scripts/fetch_engine.sh --from-dir ~/AuroraProjects/aurora-export/engine

  # From the kit's GitHub Releases
  AURORA_KIT_REPO=you/godot-to-aurora ./scripts/fetch_engine.sh

  # Verify and print paths
  ./scripts/fetch_engine.sh --check --print-paths
EOF
}

while (( $# > 0 )); do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--from-dir) [[ $# -ge 2 ]] || kit_die "--from-dir requires a path"; SOURCE_DIR="$(kit_abspath "$2")"; shift ;;
		--release-tag) [[ $# -ge 2 ]] || kit_die "--release-tag requires a tag"; RELEASE_TAG="$2"; shift ;;
		--release-base) [[ $# -ge 2 ]] || kit_die "--release-base requires a URL"; RELEASE_BASE="${2%/}"; shift ;;
		--dest) [[ $# -ge 2 ]] || kit_die "--dest requires a path"; DEST="$2"; shift ;;
		--templates-dir) [[ $# -ge 2 ]] || kit_die "--templates-dir requires a path"; TEMPLATES_DIR="$2"; shift ;;
		--no-templates) INSTALL_TEMPLATES=0 ;;
		--force) FORCE=1 ;;
		--dry-run) DRY_RUN=1 ;;
		--check) CHECK_ONLY=1 ;;
		--print-paths) PRINT_PATHS=1 ;;
		--write-sums) WRITE_SUMS=1 ;;
		--no-checksum) CHECKSUM=0 ;;
		--no-verify) VERIFY=0 ;;
		*) kit_die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

DEST="$(kit_abspath "$DEST")"

# ---------------------------------------------------------------------------
# --print-paths / --check (read-only)
# ---------------------------------------------------------------------------
if (( PRINT_PATHS )); then
	printf 'ENGINE_DIR=%s\n' "$DEST"
	printf 'GODOT_BIN=%s\n' "$DEST/$EDITOR_ASSET"
	printf 'X86_64_TEMPLATE=%s\n' "$DEST/$X64_ASSET"
	printf 'ARM64_RELEASE_TEMPLATE=%s\n' "$DEST/$ARM64_RELEASE_ASSET"
	printf 'ARM64_DEBUG_TEMPLATE=%s\n' "$DEST/$ARM64_DEBUG_ASSET"
	printf 'EXPORT_TEMPLATES_DIR=%s\n' "$TEMPLATES_DIR"
	(( CHECK_ONLY )) || exit 0
fi

if (( CHECK_ONLY )); then
	missing=0
	echo "Engine directory: $DEST"
	for asset in "${ALL_ASSETS[@]}"; do
		path="$DEST/$asset"
		if [[ -f "$path" ]]; then
			printf '  [ok]   %-40s %s\n' "$asset" "$(du -h "$path" | cut -f1)"
		else
			printf '  [MISS] %s\n' "$asset"
			missing=1
		fi
	done
	echo "Godot export templates: $TEMPLATES_DIR"
	for asset in "$ARM64_RELEASE_ASSET" "$ARM64_DEBUG_ASSET"; do
		path="$TEMPLATES_DIR/$asset"
		if [[ -f "$path" ]]; then
			printf '  [ok]   %-40s %s\n' "$asset" "$(du -h "$path" | cut -f1)"
		else
			printf '  [MISS] %s\n' "$asset"
			missing=1
		fi
	done
	if [[ -f "$DEST/$EDITOR_ASSET" && -x "$DEST/$EDITOR_ASSET" ]]; then
		version="$(timeout 30 "$DEST/$EDITOR_ASSET" --headless --version 2>/dev/null | head -1 || true)"
		[[ -n "$version" ]] && echo "Editor version:      $version"
	fi
	if (( missing )); then
		kit_warn "some components are missing; run fetch_engine.sh without --check."
	else
		kit_ok "all engine components are installed."
	fi
	exit 0
fi

# ---------------------------------------------------------------------------
# Resolve source
# ---------------------------------------------------------------------------
if [[ -n "$SOURCE_DIR" ]]; then
	MODE="local"
	[[ -d "$SOURCE_DIR" ]] || kit_die "source directory not found: $SOURCE_DIR"
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
		[[ -d "$SOURCE_DIR" ]] || kit_die "AURORA_ENGINE_SOURCE is not a directory: $SOURCE_DIR"
	fi
fi

if [[ "$MODE" == "auto" ]]; then
	kit_die "no engine source selected.

Choose one:
  --from-dir /path/to/engine          copy from a local stash
  AURORA_KIT_REPO=owner/repo          download from GitHub Releases
  --release-base https://…            download from an explicit URL

Run --help for details."
fi

kit_log "engine directory: $DEST"
kit_log "source: $([[ "$MODE" == local ]] && printf '%s' "$SOURCE_DIR" || printf '%s' "$RELEASE_BASE")"
(( DRY_RUN )) && kit_log "dry run: no files will be written"

mkdir -p "$DEST"

# ---------------------------------------------------------------------------
# Verification helpers
# ---------------------------------------------------------------------------
asset_size() { stat -c %s -- "$1" 2>/dev/null || printf 0; }

verify_size() {
	local path="$1" min="$2" size
	(( VERIFY )) || return 0
	size="$(asset_size "$path")"
	if (( size < min )); then
		kit_warn "$(basename -- "$path") is only $size bytes (expected at least $min)."
		return 1
	fi
	return 0
}

checksum_for() {
	# Prints the expected sha256 for a file from <DEST>/SHA256SUMS or from the
	# release's SHA256SUMS, or nothing.
	local name="$1" sums="$2"
	[[ -n "$sums" && -f "$sums" ]] || return 0
	awk -v name="$name" '$2 == name { print $1; exit }' "$sums"
}

verify_checksum() {
	local path="$1" sums="$2" expected actual
	expected="$(checksum_for "$(basename -- "$path")" "$sums")"
	if [[ -z "$expected" ]]; then
		return 0
	fi
	kit_has sha256sum || { kit_warn "sha256sum not found; skipping checksum verification."; return 0; }
	actual="$(sha256sum "$path" | awk '{print $1}')"
	if [[ "$actual" != "$expected" ]]; then
		kit_err "checksum mismatch for $(basename -- "$path")"
		kit_err "  expected $expected"
		kit_err "  actual   $actual"
		return 1
	fi
	kit_info "checksum ok: $(basename -- "$path")"
	return 0
}

# ---------------------------------------------------------------------------
# Local copy
# ---------------------------------------------------------------------------
copy_local_assets() {
	local asset src missing=0
	local sums=""
	[[ -f "$SOURCE_DIR/SHA256SUMS" ]] && sums="$SOURCE_DIR/SHA256SUMS"
	for asset in "${ALL_ASSETS[@]}"; do
		src="$SOURCE_DIR/$asset"
		if [[ ! -f "$src" ]]; then
			kit_warn "missing in source: $asset"
			missing=1
			continue
		fi
		if [[ -f "$DEST/$asset" && "$FORCE" != "1" ]]; then
			kit_info "already present: $asset"
			continue
		fi
		if (( DRY_RUN )); then
			kit_log "would copy $src -> $DEST/$asset"
			continue
		fi
		cp -f -- "$src" "$DEST/$asset.part"
		mv -f -- "$DEST/$asset.part" "$DEST/$asset"
		if ! verify_checksum "$DEST/$asset" "$sums"; then
			rm -f -- "$DEST/$asset"
			kit_die "checksum mismatch for $asset; refusing to install it."
		fi
		kit_ok "installed $asset ($(du -h "$DEST/$asset" | cut -f1))"
	done
	(( missing )) || return 0
	kit_warn "the source directory is incomplete; see docs/RELEASES_GUIDE.md for the asset list."
	return 0
}

# ---------------------------------------------------------------------------
# Release download
# ---------------------------------------------------------------------------
download_release_assets() {
	local asset url sums="" tmp_sums
	tmp_sums="$(mktemp)"
	if (( CHECKSUM )); then
		if curl -fsSL --connect-timeout 20 --max-time 60 \
			--output "$tmp_sums" "$RELEASE_BASE/SHA256SUMS" 2>/dev/null; then
			sums="$tmp_sums"
			kit_info "using release SHA256SUMS"
		else
			kit_info "release has no SHA256SUMS (optional)"
		fi
	fi
	local failed=0
	for asset in "${ALL_ASSETS[@]}"; do
		url="$RELEASE_BASE/$asset"
		if [[ -f "$DEST/$asset" && "$FORCE" != "1" ]]; then
			kit_info "already present: $asset"
			continue
		fi
		if (( DRY_RUN )); then
			kit_log "would download $url -> $DEST/$asset"
			continue
		fi
		if ! ( kit_download "$url" "$DEST/$asset" ); then
			kit_warn "could not download $asset (release asset missing?)"
			failed=1
			continue
		fi
		if ! verify_checksum "$DEST/$asset" "$sums"; then
			rm -f -- "$DEST/$asset"
			kit_die "checksum mismatch for $asset; refusing to install it."
		fi
		kit_ok "downloaded $asset ($(du -h "$DEST/$asset" | cut -f1))"
	done
	rm -f -- "$tmp_sums"
	(( failed == 0 )) || kit_warn "some assets were not downloaded; check the release tag/asset names."
	return 0
}

if [[ "$MODE" == "local" ]]; then
	copy_local_assets
else
	download_release_assets
fi

if (( DRY_RUN )); then
	exit 0
fi

# ---------------------------------------------------------------------------
# Permissions and sanity checks
# ---------------------------------------------------------------------------
[[ -f "$DEST/$EDITOR_ASSET" ]] && chmod 0755 "$DEST/$EDITOR_ASSET" 2>/dev/null || true
[[ -f "$DEST/$EDITOR_ASSET" ]] || kit_die "editor binary was not installed: $DEST/$EDITOR_ASSET"
[[ -f "$DEST/$X64_ASSET" ]] && chmod 0755 "$DEST/$X64_ASSET" 2>/dev/null || true

if [[ -f "$DEST/$EDITOR_ASSET" ]]; then
	verify_size "$DEST/$EDITOR_ASSET" "$MIN_EDITOR_BYTES" || true
else
	kit_warn "editor binary is missing: $DEST/$EDITOR_ASSET"
fi
if [[ -f "$DEST/$X64_ASSET" ]]; then
	verify_size "$DEST/$X64_ASSET" "$MIN_TEMPLATE_BYTES" || true
	if kit_has readelf; then
		kit_verify_no_x11 "$DEST/$X64_ASSET" || kit_warn "x86_64 template links against X11; rebuild it with auroraos=yes."
	fi
else
	kit_warn "x86_64 template is missing: emulator RPM builds will not work."
fi

# ---------------------------------------------------------------------------
# aarch64 export templates
# ---------------------------------------------------------------------------
if (( INSTALL_TEMPLATES )); then
	kit_log "Godot export templates: $TEMPLATES_DIR"
	if (( ! DRY_RUN )); then
		mkdir -p "$TEMPLATES_DIR"
	fi
	for asset in "$ARM64_RELEASE_ASSET" "$ARM64_DEBUG_ASSET"; do
		src="$DEST/$asset"
		dst="$TEMPLATES_DIR/$asset"
		if [[ ! -f "$src" ]]; then
			kit_warn "template not available, skipping: $asset"
			continue
		fi
		if [[ -f "$dst" && "$FORCE" != "1" ]]; then
			kit_info "export template already installed: $dst"
			continue
		fi
		kit_log "installing $asset into $TEMPLATES_DIR"
		install -m 0644 "$src" "$dst"
	done
	if (( ! DRY_RUN )) && [[ ! -f "$TEMPLATES_DIR/version.txt" ]]; then
		printf '%s\n' "${GODOT_TEMPLATE_VERSION:-4.7.2.stable}" > "$TEMPLATES_DIR/version.txt"
	fi
	kit_info "the AuroraOS editor now finds these templates automatically."
fi

# ---------------------------------------------------------------------------
# Optional checksums for the release owner
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
	kit_ok "wrote $sums_path"
fi

kit_ok "engine toolchain ready in $DEST ($(du -sh "$DEST" | cut -f1))"
cat <<EOF

Paths for the other scripts (they auto-detect these):
  GODOT_BIN="$DEST/$EDITOR_ASSET"
  AURORA_TEMPLATE="$DEST/$X64_ASSET"

Next:
  ./godot-to-aurora/scripts/build_x86_64_rpm.sh --check
EOF

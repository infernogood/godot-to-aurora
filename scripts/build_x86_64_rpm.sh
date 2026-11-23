#!/usr/bin/env bash
# shellcheck shell=bash
#
# Build an x86_64 (emulator) or aarch64 (device) RPM of a Godot 4 game.
#
# The file name follows the original kit layout; `--arch aarch64` (or the thin
# scripts/build_aarch64_rpm.sh wrapper) switches the target architecture.
#
# Aurora SDK 5.2+ has no sb2/mb2/sfdk-engine build shell: the build environment
# is a Docker image (aurora-build-tools-*) driven by <sdk>/tools/run, which
# mounts the project at /workspace. This script wraps that flow end to end:
#
#   1. resolve package parameters from project.godot / export_presets.cfg;
#   2. create an AuroraOS export preset if the project has none;
#   3. locate (or build) the Wayland/GLES3 export template for the target arch;
#   4. export the game PCK with the Aurora-enabled Godot fork;
#   5. render launcher icons, .desktop and RPM .spec;
#   6. patch the binary RPATH on the host and run rpmbuild inside the SDK image.
#
# Legacy environments (older SDK with sfdk engine / sb2) are still supported.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
	cat <<'EOF'
aurora-godot-port-kit — build an x86_64 or aarch64 RPM for Aurora OS

USAGE
  build_x86_64_rpm.sh [--arch x86_64|aarch64] [options]

OPTIONS
  -h, --help               Show this help and exit.
      --arch ARCH          x86_64 (emulator, default) or aarch64 (device).
      --check              Print resolved parameters and environment readiness;
                           change nothing. Add --strict to exit 1 if not ready.
      --strict             With --check: non-zero exit when the build cannot run.
      --write-preset       Create the AuroraOS preset (if missing) and exit.
      --force-preset       Recreate/replace the AuroraOS preset.
      --skip-template      Never build the engine template; fail if it is absent.
      --force-template     Rebuild the engine template even if it already exists.
      --jobs N             Parallel jobs for template compilation (default: 6).
      --preset NAME        Export preset name (default: AURORA_PRESET or AuroraOS).
      --pck-only           Export PCK + icons only; do not build an RPM.
      --import             Force a Godot resource import before exporting.
      --no-project-icons   Generate icons under build/ instead of the project.
      --no-xkbcommon       Do not bundle libxkbcommon into the package.
      --clean              Remove the previous build/rpmbuild tree first.
  -q, --quiet              Less output from the Godot exporter.

ENVIRONMENT (all optional)
  GAME_DIR=/path/to/game          Project root (default: kit parent directory).
  ORG_NAME=ru.example             Package organization (preset package/organization).
  APP_NAME=game                   Package name (preset package/name).
  APP_TITLE="My Game"             Launcher title (preset package/launcher_name).
  APP_VERSION=1.0.0               Version (preset package/version).
  APP_RELEASE=1                   RPM release number.
  PERMISSIONS="Audio,Internet"    Sailjail permissions (comma separated).
  ORIENTATION=Landscape           Landscape | Portrait | Dynamic.
  APP_COMMENT="..."               Desktop entry Comment.
  APP_CATEGORIES=Game             Desktop entry Categories.
  RPM_LICENSE=MIT                 RPM License tag (default: Proprietary).
  RPM_GROUP="Amusements/Games"    RPM Group tag.
  ICON_SVG=/path/icon.svg         Master icon (default: <project>/icon.svg).
  GODOT_BIN=/path/godot           Aurora-enabled Godot editor binary.
  AURORA_TEMPLATE=/path/template  Explicit auroraos_release.<arch> template.
  AURORA_KIT_ENGINE_DIR=DIR      Where fetch_engine.sh installed binaries.
  AURORA_SDK_HOME=DIR             Aurora SDK root (default: ~/AuroraOS).
  AURORA_BUILD_IMAGE=IMAGE        Override the aurora-build-tools Docker image.
  AURORA_EXTRA_DIR=DIR            Reuse a prepared extra/ dir for template builds.
  AURORA_ARM64_LIB_DIR=DIR        aarch64 libxkbcommon dir to bundle (optional).
  JOBS=N                          Parallel jobs.
  BUILD_DIR=DIR                   Build output (default: <project>/build).
  SFDK=/path/sfdk                 Legacy SDK CLI override.
  X86_64_TARGET=NAME              Legacy sb2 target override.

OUTPUT
  <project>/build/<org>.<app>.pck
  <project>/build/rpmbuild/RPMS/<arch>/<org>.<app>-<version>-<release>.<arch>.rpm

AARCH64 NOTES
  The stock AuroraOS export plugin in the savegame/godot fork drives sfdk via the
  sb2 API, which Aurora SDK 5.2 removed. This script therefore packages the
  aarch64 RPM natively: the arm64 export template plus the architecture-neutral
  PCK, wrapped by rpmbuild --target aarch64-meego-linux-gnu in the SDK image.
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
SKIP_TEMPLATE="${SKIP_TEMPLATE:-0}"
FORCE_TEMPLATE="${FORCE_TEMPLATE:-0}"
CHECK_ONLY=0
STRICT_CHECK=0
WRITE_PRESET_ONLY=0
FORCE_PRESET=0
PCK_ONLY=0
FORCE_IMPORT=0
PROJECT_ICONS=1
BUNDLE_XKBCOMMON=1
CLEAN_BUILD=0
QUIET=0
JOBS="${JOBS:-6}"
[[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -gt 0 ]] || kit_die "JOBS/--jobs must be a positive integer."
AURORA_PRESET_ARG="${AURORA_PRESET:-AuroraOS}"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"

while (( $# > 0 )); do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--check) CHECK_ONLY=1 ;;
		--strict) STRICT_CHECK=1 ;;
		--write-preset) WRITE_PRESET_ONLY=1 ;;
		--force-preset) FORCE_PRESET=1 ;;
		--skip-template) SKIP_TEMPLATE=1 ;;
		--force-template) FORCE_TEMPLATE=1 ;;
		--arch) [[ $# -ge 2 ]] || kit_die "--arch requires x86_64 or aarch64"; TARGET_ARCH="$2"; shift ;;
		--jobs) [[ $# -ge 2 ]] || kit_die "--jobs requires a value"; JOBS="$2"; shift ;;
		--preset) [[ $# -ge 2 ]] || kit_die "--preset requires a value"; AURORA_PRESET_ARG="$2"; shift ;;
		--pck-only) PCK_ONLY=1 ;;
		--import) FORCE_IMPORT=1 ;;
		--no-project-icons) PROJECT_ICONS=0 ;;
		--no-xkbcommon) BUNDLE_XKBCOMMON=0 ;;
		--clean) CLEAN_BUILD=1 ;;
		-q|--quiet) QUIET=1 ;;
		*) kit_die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

AURORA_PRESET="$AURORA_PRESET_ARG"

case "$TARGET_ARCH" in
	x86_64)
		TEMPLATE_ARCH="x86_64"
		TEMPLATE_ASSET="auroraos_release.x86_64"
		RPM_TARGET="x86_64-meego-linux-gnu"
		RPM_ARCH="x86_64"
		;;
	aarch64)
		TEMPLATE_ARCH="arm64"
		TEMPLATE_ASSET="auroraos_release.arm64"
		RPM_TARGET="aarch64-meego-linux-gnu"
		RPM_ARCH="aarch64"
		;;
	*)
		kit_die "unsupported --arch '$TARGET_ARCH' (use x86_64 or aarch64)"
		;;
esac
TEMPLATE_DEST="${AURORA_TEMPLATE:-$(kit_engine_dir)/$TEMPLATE_ASSET}"

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
kit_load_package_params
BUILD_DIR="${BUILD_DIR:-$PROJECT_ROOT/build}"
BUILD_DIR="$(kit_abspath "$BUILD_DIR")"
RPMBUILD="$BUILD_DIR/rpmbuild"
PCK_PATH="$BUILD_DIR/$PKG_FULL.pck"
SPEC_PATH="$RPMBUILD/SPECS/$PKG_FULL.spec"
LIBDIR_IN_PACKAGE="/usr/share/$PKG_FULL/lib"

kit_log "aurora-godot-port-kit $KIT_VERSION — $RPM_ARCH RPM for Aurora OS"
kit_print_params

editor=""
if editor="$(kit_find_godot 2>/dev/null)"; then :; else editor=""; fi
template=""
if template="$(kit_find_template "$TEMPLATE_ARCH" release 2>/dev/null)"; then :; else template=""; fi

if [[ -n "$editor" ]]; then
	editor_version="$("$editor" --headless --version 2>/dev/null | head -1 || true)"
else
	editor_version=""
fi

kit_detect_sdk
kit_log "build environment: $(kit_sdk_description)"
KIT_SFDK="$(kit_find_sfdk 2>/dev/null || true)"

# Fail fast before spending half an hour on a template compile.
if (( ! PCK_ONLY && ! CHECK_ONLY && ! WRITE_PRESET_ONLY )); then
	[[ -n "$editor" ]] || kit_die "Aurora-enabled Godot editor not found.
Install it with scripts/fetch_engine.sh, or set GODOT_BIN=/path/to/Godot_v4.7.2-auroraos1_linux.x86_64"
	if [[ "$KIT_SDK_MODE" == "none" ]]; then
		kit_die "no usable Aurora SDK build environment (sfdk/sb2 or SDK 5.2 Docker image).
See docs/SDK_5_2_ARCHITECTURE.md. Use --pck-only to export just the PCK."
	fi
	if [[ "$TARGET_ARCH" == "aarch64" && "$KIT_SDK_MODE" != "docker" ]]; then
		kit_die "aarch64 packaging uses rpmbuild --target aarch64-meego-linux-gnu inside the
SDK 5.2 Docker image. Legacy sfdk/sb2 mode is not supported for aarch64."
	fi
fi

if [[ -z "$template" && "$TARGET_ARCH" == "x86_64" && -n "$KIT_SDK_IMAGE" ]] && kit_has docker \
	&& docker image inspect "$KIT_SDK_IMAGE" >/dev/null 2>&1; then
	template_note="missing (can be compiled in $KIT_SDK_IMAGE)"
elif [[ -n "$template" ]]; then
	template_note="$(du -h "$template" | cut -f1)"
else
	template_note="missing"
fi

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if (( CHECK_ONLY )); then
	ready=1
	echo
	echo "Environment"
	printf '  editor            %s\n' "${editor:-MISSING}${editor_version:+  ($editor_version)}"
	printf '  %-17s %s\n' "$TARGET_ARCH template" "${template:-MISSING}  [$template_note]"
	printf '  export templates  %s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/${GODOT_TEMPLATE_VERSION:-4.7.2.stable}"
	printf '  Aurora SDK        %s\n' "$(kit_sdk_description)"
	printf '  docker            %s\n' "$(kit_has docker && printf yes || printf no)"
	printf '  patchelf          %s\n' "$(kit_has patchelf && printf yes || printf no)"
	printf '  magick/rsvg       %s\n' "$( { kit_has magick || kit_has rsvg-convert; } && printf yes || printf no)"
	echo
	[[ -n "$editor" ]] || { kit_warn "Aurora-enabled Godot editor not found (fetch_engine.sh)."; ready=0; }
	[[ -z "$PKG_PRESET_INDEX" ]] && kit_info "An AuroraOS preset will be created during the build."
	[[ -f "$PROJECT_ROOT/icon.svg" || -f "$PROJECT_ROOT/icons/86.png" ]] \
		|| { kit_warn "no icon.svg or icons/86.png in the project."; ready=0; }
	if (( PCK_ONLY )); then
		:
	else
		[[ -z "$template" ]] && { kit_warn "$TARGET_ARCH Aurora template not found."; ready=0; }
		[[ "$KIT_SDK_MODE" == "none" ]] && { kit_warn "no usable Aurora SDK build environment."; ready=0; }
		if (( BUNDLE_XKBCOMMON )); then
			if [[ "$TARGET_ARCH" == "x86_64" || -n "${AURORA_ARM64_LIB_DIR:-}" ]]; then
				kit_has patchelf || { kit_warn "patchelf is required to bundle libxkbcommon."; ready=0; }
			fi
		fi
		if [[ "$TARGET_ARCH" == "aarch64" && "$KIT_SDK_MODE" != "docker" ]]; then
			kit_warn "aarch64 packaging requires the SDK 5.2+ Docker build environment."
			ready=0
		fi
	fi
	echo
	if (( ready )); then
		kit_ok "READY"
	else
		kit_warn "NOT READY — install the missing pieces listed above."
		if (( STRICT_CHECK )); then exit 1; fi
	fi
	exit 0
fi

if (( WRITE_PRESET_ONLY )); then
	if [[ -n "$PKG_PRESET_INDEX" && "$FORCE_PRESET" != "1" ]]; then
		kit_ok "AuroraOS preset already exists (index $PKG_PRESET_INDEX, name $PKG_PRESET_NAME)."
	elif (( FORCE_PRESET )); then
		kit_write_aurora_preset --force
	else
		kit_write_aurora_preset
	fi
	exit 0
fi

# ---------------------------------------------------------------------------
# Preset bootstrap
# ---------------------------------------------------------------------------
if [[ -n "$PKG_PRESET_INDEX" ]]; then
	if (( FORCE_PRESET )); then
		kit_write_aurora_preset --force
	fi
else
	kit_write_aurora_preset
fi
kit_patch_exclude_filter
preset_name="$PKG_PRESET_NAME"
[[ -n "$preset_name" ]] || preset_name="$AURORA_PRESET_ARG"

# ---------------------------------------------------------------------------
# Template
# ---------------------------------------------------------------------------
cleanup_container() {
	local name="${AURORA_BUILD_CONTAINER:-aurora-godot-port-kit-build}"
	if kit_has docker; then
		docker rm -f "$name" >/dev/null 2>&1 || true
	fi
}
trap cleanup_container EXIT

prepare_extra() {
	local extra="$1"
	mkdir -p "$extra/include" "$extra/pkgconfig" "$extra/scons"
	if [[ ! -f "$extra/include/xkbcommon/xkbcommon.h" ]]; then
		kit_log "preparing xkbcommon 1.3.1 headers (the build image ships no -devel package)…"
		local tmp
		tmp="$(mktemp -d)"
		kit_download "https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-1.3.1.tar.gz" "$tmp/src.tgz"
		tar xzf "$tmp/src.tgz" -C "$tmp"
		cp -r "$tmp/libxkbcommon-xkbcommon-1.3.1/include/xkbcommon" "$extra/include/"
		rm -rf "$tmp"
	fi
	if [[ ! -f "$extra/pkgconfig/xkbcommon.pc" ]]; then
		cat > "$extra/pkgconfig/xkbcommon.pc" <<'PC'
prefix=/usr
exec_prefix=${prefix}
libdir=/usr/lib64
includedir=${prefix}/include

Name: xkbcommon
Description: XKB API common to servers and clients
Version: 1.3.1
Libs: -L${libdir} -lxkbcommon
Cflags: -I${includedir}
PC
	fi
	if [[ ! -d "$extra/scons/SCons" ]]; then
		kit_has python3 || kit_die "python3 is required to bootstrap SCons for the build image."
		kit_log "preparing SCons wheel for the build image…"
		python3 -m pip download scons --no-deps -d "$extra" >/dev/null \
			|| kit_die "python3 -m pip download scons failed (no network or no pip)."
		local wheel
		wheel="$(find "$extra" -maxdepth 1 -name 'scons-*.whl' | head -1)"
		[[ -n "$wheel" ]] || kit_die "SCons wheel not found in $extra"
		python3 -m zipfile -e "$wheel" "$extra/scons"
		rm -f -- "$wheel"
	fi
	cat > "$extra/scons-run.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.path.insert(0, "/opt/extra/scons")
import SCons.Script
sys.exit(SCons.Script.main())
PY
}

template_scons_args() {
	printf '%s\n' \
		platform=linuxbsd arch=x86_64 target=template_release \
		auroraos=yes use_sowrap=no udev=no speechd=no fontconfig=no \
		accesskit=no openxr=no disable_path_overrides=no \
		optimize=size debug_symbols=no
}

build_template_docker() {
	local src="$AURORA_WORKSPACE/godot-$KIT_GODOT_TAG"
	local extra="${AURORA_EXTRA_DIR:-$AURORA_WORKSPACE/extra}"
	local container="${AURORA_BUILD_CONTAINER:-aurora-godot-port-kit-build}"
	mkdir -p "$AURORA_WORKSPACE"
	if [[ ! -d "$src/.git" ]]; then
		kit_has git || kit_die "git is required to fetch the Godot fork sources."
		kit_log "cloning $KIT_GODOT_REPO ($KIT_GODOT_TAG) into $src"
		git clone --depth 1 --branch "$KIT_GODOT_TAG" "$KIT_GODOT_REPO" "$src"
	fi
	prepare_extra "$extra"
	docker rm -f "$container" >/dev/null 2>&1 || true
	kit_log "starting $KIT_SDK_IMAGE…"
	docker run -d --name "$container" \
		-v "$src:/src" -v "$extra:/opt/extra:ro" -w /src \
		"$KIT_SDK_IMAGE" sleep infinity >/dev/null
	kit_log "installing xkbcommon headers into the container rootfs…"
	docker exec "$container" bash -lc '
		set -e
		cp -r /opt/extra/include/xkbcommon /usr/include/
		ln -sf libxkbcommon.so.0.0.0 /usr/lib64/libxkbcommon.so
		cp /opt/extra/pkgconfig/xkbcommon.pc /usr/lib64/pkgconfig/
		pkg-config --modversion xkbcommon wayland-client wayland-egl wayland-cursor egl glesv2 glib-2.0 libpulse >/dev/null
	'
	kit_log "compiling the x86_64 template (-j$JOBS); this takes ~30 minutes…"
	docker exec "$container" bash -lc "cd /src && python3 /opt/extra/scons-run.py $(template_scons_args) -j$JOBS"
	local out="$src/bin/godot.linuxbsd.template_release.x86_64"
	[[ -f "$out" ]] || kit_die "scons finished but $out is missing"
	mkdir -p "$(dirname -- "$TEMPLATE_DEST")"
	install -m 0755 "$out" "$TEMPLATE_DEST"
	docker rm -f "$container" >/dev/null 2>&1 || true
}

build_template_sb2() {
	local src="$AURORA_WORKSPACE/godot-$KIT_GODOT_TAG"
	kit_has git || kit_die "git is required to fetch the Godot fork sources."
	mkdir -p "$AURORA_WORKSPACE"
	if [[ ! -d "$src/.git" ]]; then
		kit_log "cloning $KIT_GODOT_REPO ($KIT_GODOT_TAG) into $src"
		git clone --depth 1 --branch "$KIT_GODOT_TAG" "$KIT_GODOT_REPO" "$src"
	fi
	kit_log "compiling the x86_64 template in target $KIT_SDK_TARGET (-j$JOBS)…"
	if [[ "$KIT_SDK_MODE" == "sfdk" ]]; then
		(cd "$src" && "$KIT_SFDK" engine exec sb2 -t "$KIT_SDK_TARGET" \
			python3 tools/scons/scripts/scons.py $(template_scons_args) -j"$JOBS")
	else
		(cd "$src" && sb2 -t "$KIT_SDK_TARGET" \
			python3 tools/scons/scripts/scons.py $(template_scons_args) -j"$JOBS")
	fi
	mkdir -p "$(dirname -- "$TEMPLATE_DEST")"
	install -m 0755 "$src/bin/godot.linuxbsd.template_release.x86_64" "$TEMPLATE_DEST"
}

build_template() {
	if [[ "$TARGET_ARCH" != "x86_64" ]]; then
		kit_die "the $TARGET_ARCH template cannot be compiled on an x86_64 host inside the SDK image.
Fetch prebuilt auroraos_release.arm64 with scripts/fetch_engine.sh."
	fi
	case "$KIT_SDK_MODE" in
		docker) build_template_docker ;;
		sfdk)   KIT_SFDK="$(kit_find_sfdk)" || kit_die "sfdk not found"; build_template_sb2 ;;
		sb2)    build_template_sb2 ;;
		*)      kit_die "no Aurora SDK build environment; cannot compile the x86_64 template.

Options:
  * install Aurora SDK 5.2+ with the aurora-build-tools image, or
  * fetch the prebuilt auroraos_release.x86_64 with scripts/fetch_engine.sh." ;;
	esac
	template="$(kit_find_template "$TEMPLATE_ARCH" release || true)"
	[[ -n "$template" ]] || kit_die "template build finished but $TEMPLATE_ASSET is still missing"
	kit_ok "template ready: $template ($(du -h "$template" | cut -f1))"
}

KIT_GODOT_REPO="${AURORA_GODOT_REPO:-https://github.com/savegame/godot.git}"
KIT_GODOT_TAG="${AURORA_GODOT_TAG:-4.7.2-auroraos1}"
AURORA_WORKSPACE="${AURORA_WORKSPACE:-$HOME/AuroraProjects}"

if (( ! PCK_ONLY )); then
	if [[ -n "$template" ]]; then
		kit_log "using template: $template ($(du -h "$template" | cut -f1))"
		if (( FORCE_TEMPLATE )); then
			kit_log "rebuilding the template because --force-template was given"
			TEMPLATE_DEST="$template"
			build_template
		fi
	elif (( SKIP_TEMPLATE )); then
		kit_die "$TARGET_ARCH template not found and --skip-template was given.
Run scripts/fetch_engine.sh first, or drop $TEMPLATE_ASSET into one of:
  $(kit_engine_dir)
  $PROJECT_ROOT/utilities"
	else
		build_template
	fi
	kit_verify_no_x11 "$template" || kit_die "template links against X11; it must be built with auroraos=yes (Wayland-only)."
fi

# ---------------------------------------------------------------------------
# Icons
# ---------------------------------------------------------------------------
ICON_SRC="${ICON_SVG:-$PROJECT_ROOT/icon.svg}"
ICON_STAGE="$PROJECT_ROOT/icons"
(( PROJECT_ICONS )) || ICON_STAGE="$BUILD_DIR/icons"

render_icon() { # render_icon <size> <out>
	local size="$1" out="$2"
	if [[ -f "$ICON_SRC" ]]; then
		if kit_has magick; then
			magick -background none "$ICON_SRC" \
				-resize "${size}x${size}" -gravity center -extent "${size}x${size}" "$out"
		elif kit_has rsvg-convert; then
			rsvg-convert -w "$size" -h "$size" -o "$out" "$ICON_SRC"
		else
			kit_die "ImageMagick (magick) or rsvg-convert is required to render $ICON_SRC"
		fi
	elif kit_has magick; then
		kit_die "icon source not found: $ICON_SRC (create icon.svg at the project root)"
	else
		kit_die "no icon.svg and no ImageMagick to generate icons"
	fi
	[[ -s "$out" ]] || kit_die "failed to render icon $out"
}

render_icons() {
	local size out
	for size in 86 108 128 172; do
		mkdir -p "$RPMBUILD/files/usr/share/icons/hicolor/${size}x${size}/apps"
		out="$ICON_STAGE/$size.png"
		if [[ -f "$out" ]]; then
			kit_info "using existing icon: $out"
		else
			mkdir -p "$(dirname -- "$out")"
			render_icon "$size" "$out"
			kit_log "generated icon: $out"
		fi
		install -m 0644 "$out" \
			"$RPMBUILD/files/usr/share/icons/hicolor/${size}x${size}/apps/$PKG_FULL.png"
	done
}

# ---------------------------------------------------------------------------
# Build tree
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
: > "$BUILD_DIR/.gdignore"
find "$BUILD_DIR" -name '*.import' -delete 2>/dev/null || true
if (( CLEAN_BUILD )); then
	kit_log "removing previous RPM build tree"
	rm -rf -- "$RPMBUILD"
else
	# Always rebuild the payload tree: leftovers from another architecture
	# (for example a bundled x86_64 libxkbcommon) must never leak into a
	# package built for a different arch.
	rm -rf -- "$RPMBUILD/files"
fi
mkdir -p "$RPMBUILD/SPECS" "$RPMBUILD/RPMS" "$RPMBUILD/files/usr/bin" \
	"$RPMBUILD/files/usr/share/applications" \
	"$RPMBUILD/files/usr/share/$PKG_FULL/lib"

render_icons

# ---------------------------------------------------------------------------
# PCK
# ---------------------------------------------------------------------------
[[ -n "$editor" ]] || kit_die "Aurora-enabled Godot editor not found.
Install it with scripts/fetch_engine.sh, or set GODOT_BIN=/path/to/Godot_v4.7.2-auroraos1_linux.x86_64"

if (( FORCE_IMPORT )) || [[ ! -d "$PROJECT_ROOT/.godot" ]]; then
	kit_log "importing project resources (first run)…"
	if ! "$editor" --headless --path "$PROJECT_ROOT" --import; then
		# The editor occasionally crashes on the very first import of a large
		# project while the import cache is half-written; a second pass usually
		# completes it.
		kit_warn "resource import failed; retrying once…"
		"$editor" --headless --path "$PROJECT_ROOT" --import \
			|| kit_die "resource import failed twice; open the project once in the Aurora editor to see details."
	fi
fi

kit_log "exporting PCK with preset '$preset_name': $PCK_PATH"
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
	kit_die "PCK export failed (exit $export_rc). If the error is about the export preset, run with --force-preset."
fi
[[ -s "$PCK_PATH" ]] || kit_die "PCK was not created: $PCK_PATH"
pck_magic="$(head -c 4 -- "$PCK_PATH" 2>/dev/null || true)"
[[ "$pck_magic" == "GDPC" ]] || kit_warn "PCK does not start with the GDPC magic; inspect $PCK_PATH."
pck_size="$(du -h "$PCK_PATH" | cut -f1)"
kit_ok "PCK ready: $PCK_PATH ($pck_size)"
if [[ "$(stat -c %s "$PCK_PATH")" -gt $((400 * 1024 * 1024)) ]]; then
	kit_warn "PCK is larger than 400 MB; check exclude_filter and asset compression before shipping to a phone."
fi

if (( PCK_ONLY )); then
	kit_ok "PCK-only mode: done."
	exit 0
fi

# ---------------------------------------------------------------------------
# RPM payload
# ---------------------------------------------------------------------------
kit_log "staging RPM payload under $RPMBUILD/files"
install -m 0755 "$template" "$RPMBUILD/files/usr/bin/$PKG_FULL"
install -m 0644 "$PCK_PATH" "$RPMBUILD/files/usr/share/$PKG_FULL/$PKG_FULL.pck"

# libxkbcommon: the Aurora rootfs provides it, but a private copy makes the
# package work on images where the library is missing. Never a hard Requires.
copy_xkbcommon() {
	local dst="$RPMBUILD/files/usr/share/$PKG_FULL/lib"
	local sysroot=""
	local sdk_dir
	sdk_dir="$(kit_sdk_version_dir)"
	[[ -n "$sdk_dir" ]] && sysroot="$sdk_dir/targets/$RPM_TARGET"

	if [[ -n "${AURORA_ARM64_LIB_DIR:-}" && "$TARGET_ARCH" == "aarch64" ]] \
		&& compgen -G "$AURORA_ARM64_LIB_DIR/libxkbcommon.so.0*" >/dev/null; then
		cp -a "$AURORA_ARM64_LIB_DIR"/libxkbcommon.so.0* "$dst/"
		kit_log "bundled libxkbcommon from AURORA_ARM64_LIB_DIR"
		return 0
	fi
	if [[ -n "$sysroot" ]] && compgen -G "$sysroot/usr/lib64/libxkbcommon.so.0*" >/dev/null; then
		cp -a "$sysroot"/usr/lib64/libxkbcommon.so.0* "$dst/"
		kit_log "bundled libxkbcommon from the SDK sysroot"
		return 0
	fi
	if [[ "$TARGET_ARCH" == "x86_64" && -n "$KIT_SDK_IMAGE" ]] && kit_has docker \
		&& docker image inspect "$KIT_SDK_IMAGE" >/dev/null 2>&1; then
		kit_log "bundled libxkbcommon from $KIT_SDK_IMAGE"
		docker run --rm -v "$dst:/out" --entrypoint /bin/bash "$KIT_SDK_IMAGE" -lc \
			'cp -a /usr/lib64/libxkbcommon.so.0* /out/' || {
			kit_warn "could not copy libxkbcommon from the image; continuing without it."
			return 0
		}
		return 0
	fi
	if [[ "$TARGET_ARCH" == "aarch64" ]]; then
		kit_info "no aarch64 libxkbcommon available locally; the device provides it system-wide."
	else
		kit_warn "libxkbcommon not found; the package will use the system copy."
	fi
	return 0
}

finalize_binary() {
	local xkb_real
	xkb_real="$(find "$RPMBUILD/files/usr/share/$PKG_FULL/lib" -name 'libxkbcommon.so.0*' ! -type l | head -1)"
	if [[ -n "$xkb_real" && ! -e "$RPMBUILD/files/usr/share/$PKG_FULL/lib/libxkbcommon.so.0" ]]; then
		ln -sf "$(basename -- "$xkb_real")" \
			"$RPMBUILD/files/usr/share/$PKG_FULL/lib/libxkbcommon.so.0"
	fi
	if kit_has patchelf; then
		patchelf --force-rpath --set-rpath "$LIBDIR_IN_PACKAGE" "$RPMBUILD/files/usr/bin/$PKG_FULL"
		kit_log "RPATH: $(patchelf --print-rpath "$RPMBUILD/files/usr/bin/$PKG_FULL")"
	else
		kit_die "patchelf is required to point the binary at the bundled libxkbcommon.
Install it (dnf install patchelf / apt install patchelf) or pass --no-xkbcommon."
	fi
}

if (( BUNDLE_XKBCOMMON )); then
	copy_xkbcommon
	if compgen -G "$RPMBUILD/files/usr/share/$PKG_FULL/lib/libxkbcommon.so.0*" >/dev/null; then
		finalize_binary
	fi
fi

# ---------------------------------------------------------------------------
# .desktop and .spec
# ---------------------------------------------------------------------------
desktop_path="$RPMBUILD/files/usr/share/applications/$PKG_FULL.desktop"
kit_render_template "$KIT_TEMPLATES/app.desktop.in" "$desktop_path" \
	"APP_TITLE=$PKG_TITLE" \
	"APP_COMMENT=$PKG_COMMENT" \
	"PKG_NAME=$PKG_FULL" \
	"ORG=$PKG_ORG" \
	"APP=$PKG_APP" \
	"PERMISSIONS=$PKG_PERMISSIONS" \
	"ORIENTATION=$PKG_ORIENTATION" \
	"APP_CATEGORIES=$PKG_CATEGORIES"
sed -i -e '/^Comment=$/d' -e '/^Permissions=$/d' "$desktop_path"
chmod 0644 "$desktop_path"
kit_log "desktop entry: $desktop_path"

spec_summary="$PKG_TITLE"
spec_description="${APP_DESCRIPTION:-$PKG_COMMENT}"
[[ -n "$spec_description" ]] || spec_description="$PKG_TITLE — Godot game packaged for Aurora OS."
kit_render_template "$KIT_TEMPLATES/app.spec.in" "$SPEC_PATH" \
	"PKG_NAME=$PKG_FULL" \
	"SUMMARY=$spec_summary" \
	"VERSION=$PKG_VERSION" \
	"RELEASE=$PKG_RELEASE" \
	"LICENSE=$PKG_LICENSE" \
	"GROUP=$PKG_GROUP" \
	"DESCRIPTION=$spec_description"
kit_log "spec: $SPEC_PATH"

kit_info "payload: $(find "$RPMBUILD/files" -type f | wc -l) files, $(du -sh "$RPMBUILD/files" | cut -f1)"

# ---------------------------------------------------------------------------
# rpmbuild
# ---------------------------------------------------------------------------
# Remove only this architecture's previous output so building x86_64 does not
# delete an already built aarch64 package (and vice versa).
rm -rf -- "$RPMBUILD/RPMS/$RPM_ARCH"
mkdir -p "$RPMBUILD/RPMS"

rpm_path=""
case "$KIT_SDK_MODE" in
	sfdk|sb2)
		kit_log "running rpmbuild in target $KIT_SDK_TARGET"
		if [[ "$KIT_SDK_MODE" == "sfdk" ]]; then
			"$KIT_SFDK" engine exec sb2 -t "$KIT_SDK_TARGET" rpmbuild \
				--define "_topdir $RPMBUILD" -bb "$SPEC_PATH"
		else
			sb2 -t "$KIT_SDK_TARGET" rpmbuild --define "_topdir $RPMBUILD" -bb "$SPEC_PATH"
		fi
		;;
	docker)
		[[ -n "$KIT_SDK_RUN" ]] || kit_die "SDK tools/run not found; set AURORA_SDK_HOME."
		if [[ "$BUILD_DIR" != "$PROJECT_ROOT"* ]]; then
			kit_die "BUILD_DIR must be inside the project when using the SDK container (it is mounted at /workspace)."
		fi
		# tools/run joins its arguments into one string and destroys quotes, so a
		# --define "_topdir ..." argument cannot be passed directly: wrap it.
		builder="$RPMBUILD/rpmbuild.sh"
		cat > "$builder" <<-RPMSCRIPT
			#!/bin/bash
			set -euo pipefail
			exec rpmbuild --target $RPM_TARGET \\
				--define "_topdir /workspace/build/rpmbuild" \\
				-bb "/workspace/build/rpmbuild/SPECS/$PKG_FULL.spec"
		RPMSCRIPT
		chmod +x "$builder"
		kit_log "running rpmbuild in $KIT_SDK_IMAGE via tools/run"
		WORKSPACE_DIR="$PROJECT_ROOT" "$KIT_SDK_RUN" \
			bash "/workspace/build/rpmbuild/rpmbuild.sh"
		;;
	none)
		kit_die "no Aurora SDK build environment; cannot run rpmbuild.
Set up Aurora SDK 5.2+ (see docs/SDK_5_2_ARCHITECTURE.md) or use --pck-only."
		;;
esac

rpm_path="$(find "$RPMBUILD/RPMS/$RPM_ARCH" -type f -name '*.rpm' 2>/dev/null | sort | tail -1 || true)"
[[ -n "$rpm_path" ]] || rpm_path="$(find "$RPMBUILD/RPMS" -type f -name '*.rpm' 2>/dev/null | sort | tail -1 || true)"
[[ -n "$rpm_path" ]] || kit_die "rpmbuild finished but no .rpm was found under $RPMBUILD/RPMS"
kit_ok "RPM ready: $rpm_path ($(du -h "$rpm_path" | cut -f1))"
if kit_has rpm; then
	kit_log "package contents:"
	rpm -qlp "$rpm_path" | sed 's/^/  /'
else
	kit_info "install 'rpm' to inspect the package with rpm -qlp"
fi

cat <<EOF

Next steps:
  * sign and install:
      ./aurora-godot-port-kit/scripts/deploy_emulator.sh --rpm "$rpm_path"
  * for aarch64 pass --device "<name>" to install on a real device; for x86_64
    the deploy script starts the QEMU emulator automatically.
EOF

#!/usr/bin/env bash
# shellcheck shell=bash
#
# Sign an Aurora RPM with the SDK test keys and install it into the Aurora OS
# QEMU emulator (or a connected device).
#
# The emulator in Aurora SDK 5.2+ is QEMU/KVM (not VirtualBox):
#   * /dev/kvm must exist and be writable by the current user;
#   * `sfdk emulator start` launches it, `sfdk device exec` talks over SSH.
#
# Unsigned packages are rejected by the Aurora package manager (ru.omp.APM).
# Self-signed openssl certificates are rejected by rpmsign-external with
# "Failed to get certificate extensions"; the SDK's regular_key.pem /
# regular_cert.pem are the supported way.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
	cat <<'EOF'
aurora-godot-port-kit — deploy an RPM to the Aurora OS emulator

USAGE
  deploy_emulator.sh [options]

OPTIONS
      --rpm PATH          RPM to install (default: newest under build/rpmbuild/RPMS).
      --device NAME       sfdk device to use (default: first registered device).
      --emulator NAME     Emulator name to start (default: first from `sfdk emulator list`).
      --no-start          Do not start the emulator; fail if it is not reachable.
      --skip-sign         Install without signing (APM will normally reject it).
      --sign-only         Sign the RPM and exit (no emulator, no installation).
      --no-prompt         Call ru.omp.APM.Install with ShowPrompt=false.
      --wait SECONDS      How long to wait for the emulator SSH (default: 240).
      --install-wait SEC  How long to wait for APM to finish installing (default: 120).
      --logs              Follow journalctl for the package after installation.
      --check             Print resolved RPM/device/SDK and exit.
  -h, --help              Show this help.

ENVIRONMENT
  AURORA_SDK_HOME=DIR     Aurora SDK root (default: ~/AuroraOS).
  AURORA_DEVICE=NAME      Same as --device.
  AURORA_EMULATOR=NAME    Same as --emulator.
  AURORA_SIGN_KEY=FILE    Signing key (default: <SDK>/package-signing/regular_key.pem).
  AURORA_SIGN_CERT=FILE   Signing certificate (default: <SDK>/package-signing/regular_cert.pem).
  AURORA_SSH_HOST=HOST    Device SSH host override (default: parsed from sfdk).
  AURORA_SSH_PORT=PORT    Device SSH port override.
  AURORA_SSH_USER=USER    Device SSH user override (default: defaultuser).
  AURORA_SSH_KEY=FILE     Device SSH private key override.

NOTES
  * Always launch the game from the application menu, not from a shell: only
    then do Sailjail (OrganizationName/ApplicationName/Permissions) and
    [X-Aurora-Application] Orientation take effect.
  * The package manager needs the SDK test certificate. The emulator trusts it
    out of the box; a real device must be in developer mode.
EOF
}

RPM_ARG=""
DEVICE_NAME="${AURORA_DEVICE:-}"
EMULATOR_NAME="${AURORA_EMULATOR:-}"
START=1
SKIP_SIGN=0
SIGN_ONLY=0
SHOW_PROMPT=1
WAIT_SECONDS=240
INSTALL_WAIT=120
FOLLOW_LOGS=0
CHECK_ONLY=0

while (( $# > 0 )); do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--rpm) [[ $# -ge 2 ]] || kit_die "--rpm requires a path"; RPM_ARG="$2"; shift ;;
		--device) [[ $# -ge 2 ]] || kit_die "--device requires a name"; DEVICE_NAME="$2"; shift ;;
		--emulator) [[ $# -ge 2 ]] || kit_die "--emulator requires a name"; EMULATOR_NAME="$2"; shift ;;
		--no-start) START=0 ;;
		--skip-sign) SKIP_SIGN=1 ;;
		--sign-only) SIGN_ONLY=1 ;;
		--no-prompt) SHOW_PROMPT=0 ;;
		--wait) [[ $# -ge 2 ]] || kit_die "--wait requires seconds"; WAIT_SECONDS="$2"; shift ;;
		--install-wait) [[ $# -ge 2 ]] || kit_die "--install-wait requires seconds"; INSTALL_WAIT="$2"; shift ;;
		--logs) FOLLOW_LOGS=1 ;;
		--check) CHECK_ONLY=1 ;;
		*) kit_die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

PROJECT_ROOT="$(kit_project_root)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_ROOT/build}"
SDK_HOME="$(kit_sdk_home)"
KEY_PATH="${AURORA_SIGN_KEY:-$SDK_HOME/package-signing/regular_key.pem}"
CERT_PATH="${AURORA_SIGN_CERT:-$SDK_HOME/package-signing/regular_cert.pem}"
SFDK="$(kit_find_sfdk 2>/dev/null || true)"

kit_detect_sdk

# ---------------------------------------------------------------------------
# Device discovery
# ---------------------------------------------------------------------------
device_lines() {
	[[ -n "$SFDK" ]] || return 0
	timeout 60 "$SFDK" device list 2>/dev/null || true
}

DEVICE_LIST="$(device_lines)"
if [[ -z "$DEVICE_NAME" ]]; then
	DEVICE_NAME="$(sed -n 's/^#[0-9][0-9]*[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' <<<"$DEVICE_LIST" | head -1)"
fi

SSH_ENDPOINT="$(grep -oE '[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[0-9]+' <<<"$DEVICE_LIST" | head -1 || true)"
SSH_HOST="${AURORA_SSH_HOST:-}"
SSH_PORT="${AURORA_SSH_PORT:-}"
SSH_USER="${AURORA_SSH_USER:-}"
SSH_KEY="${AURORA_SSH_KEY:-}"
if [[ -n "$SSH_ENDPOINT" ]]; then
	SSH_USER="${SSH_USER:-${SSH_ENDPOINT%@*}}"
	SSH_HOST="${SSH_HOST:-${SSH_ENDPOINT#*@}}"
	SSH_HOST="${SSH_HOST%:*}"
	SSH_PORT="${SSH_PORT:-${SSH_ENDPOINT##*:}}"
fi
SSH_USER="${SSH_USER:-defaultuser}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-2223}"
if [[ -z "$SSH_KEY" ]]; then
	if [[ -f "$SDK_HOME/vmshare/ssh/private_keys/sdk" ]]; then
		SSH_KEY="$SDK_HOME/vmshare/ssh/private_keys/sdk"
	fi
fi

IS_EMULATOR=0
if [[ "$SSH_HOST" == "127.0.0.1" || "$SSH_HOST" == "localhost" || "$SSH_PORT" == "2223" ]] \
	|| [[ "$DEVICE_NAME" == *"мулятор"* || "$DEVICE_NAME" == *"mulator"* ]]; then
	IS_EMULATOR=1
fi

if [[ -z "$EMULATOR_NAME" ]]; then
	EMULATOR_NAME="$(timeout 60 "$SFDK" emulator list 2>/dev/null | awk 'NF && $1 !~ /^\[/ { print $1; exit }' || true)"
fi

# ---------------------------------------------------------------------------
# RPM resolution
# ---------------------------------------------------------------------------
newest_rpm_in() { # newest_rpm_in <dir>
	local dir="$1"
	[[ -d "$dir" ]] || return 0
	find "$dir" -maxdepth 1 -type f -name '*.rpm' -printf '%T@ %p\n' 2>/dev/null \
		| sort -n | tail -1 | cut -d' ' -f2- || true
}

find_rpm() {
	if [[ -n "$RPM_ARG" ]]; then
		[[ -f "$RPM_ARG" ]] || kit_die "RPM not found: $RPM_ARG"
		printf '%s\n' "$(kit_abspath "$RPM_ARG")"
		return 0
	fi
	local preferred="" newest=""
	if (( IS_EMULATOR )); then
		preferred="$BUILD_DIR/rpmbuild/RPMS/x86_64"
	elif [[ -n "$DEVICE_NAME" ]]; then
		preferred="$BUILD_DIR/rpmbuild/RPMS/aarch64"
	fi
	[[ -n "$preferred" ]] && newest="$(newest_rpm_in "$preferred")"
	[[ -z "$newest" ]] && newest="$(newest_rpm_in "$BUILD_DIR/rpmbuild/RPMS")"
	[[ -n "$newest" ]] || kit_die "no RPM found under $BUILD_DIR/rpmbuild/RPMS.
Build one first:
  ./aurora-godot-port-kit/scripts/build_x86_64_rpm.sh     # emulator
  ./aurora-godot-port-kit/scripts/build_aarch64_rpm.sh    # device
or pass --rpm /path/to/package.rpm"
	printf '%s\n' "$newest"
}

load_rpm_metadata() {
	RPM_PATH="$1"
	RPM_BASENAME="$(basename -- "$RPM_PATH")"
	# Derive the package name from name-version-release.arch.rpm
	PKG_FULL="${RPM_BASENAME%.rpm}"
	PKG_FULL="${PKG_FULL%.x86_64}"
	PKG_FULL="${PKG_FULL%.aarch64}"
	PKG_FULL="${PKG_FULL%.armv7hl}"
	PKG_FULL="${PKG_FULL%.noarch}"
	PKG_FULL="${PKG_FULL%-*}"
	PKG_FULL="${PKG_FULL%-*}"
	[[ -n "$PKG_FULL" ]] || kit_die "cannot derive a package name from $RPM_BASENAME"
	PKG_ORG="${PKG_FULL%.*}"
	PKG_APP="${PKG_FULL##*.}"
	RPM_ARCH=""
	case "$RPM_BASENAME" in
		*.x86_64.rpm) RPM_ARCH="x86_64" ;;
		*.aarch64.rpm) RPM_ARCH="aarch64" ;;
		*.armv7hl.rpm) RPM_ARCH="armv7hl" ;;
		*.noarch.rpm) RPM_ARCH="noarch" ;;
	esac
	[[ -n "$RPM_ARCH" ]] || kit_die "cannot detect the architecture of $RPM_BASENAME"
}

RPM_PATH="$(find_rpm)"
load_rpm_metadata "$RPM_PATH"

if (( ! SIGN_ONLY && IS_EMULATOR )) && [[ "$RPM_ARCH" != "x86_64" ]]; then
	kit_die "the selected package is $RPM_ARCH but the emulator needs x86_64:
  $RPM_PATH
Pass --rpm $BUILD_DIR/rpmbuild/RPMS/x86_64/<pkg>.x86_64.rpm"
fi
if (( ! SIGN_ONLY && ! IS_EMULATOR )) && [[ "$RPM_ARCH" == "x86_64" ]]; then
	kit_warn "selected package is x86_64; a real device needs an aarch64 package (build_aarch64_rpm.sh)."
fi


# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if (( CHECK_ONLY )); then
	cat <<EOF
RPM                $RPM_PATH ($(du -h "$RPM_PATH" | cut -f1))
Package            $PKG_FULL
Device             ${DEVICE_NAME:-<none>}
Emulator           ${EMULATOR_NAME:-<none>} (local: $IS_EMULATOR)
SSH                ${SSH_USER}@${SSH_HOST}:${SSH_PORT} key=${SSH_KEY:-none}
SDK build env      $(kit_sdk_description)
Signing key        $KEY_PATH $([[ -f "$KEY_PATH" ]] && echo '(found)' || echo '(missing)')
Signing cert       $CERT_PATH $([[ -f "$CERT_PATH" ]] && echo '(found)' || echo '(missing)')
sfdk               ${SFDK:-MISSING}
EOF
	exit 0
fi

if (( ! SIGN_ONLY )); then
	[[ -n "$SFDK" ]] || kit_die "sfdk not found. Install Aurora SDK and/or set AURORA_SDK_HOME / SFDK.
Without sfdk, sign the RPM manually and install it with the package manager."
fi

# Paths as seen by rpmsign-external: the SDK 5.2 container only sees the
# project mounted at /workspace; older sb2 targets see host paths.
mode_path() {
	if [[ "$KIT_SDK_MODE" == "docker" ]]; then
		kit_to_workspace_path "$1"
	else
		printf '%s\n' "$1"
	fi
}

# ---------------------------------------------------------------------------
# Emulator startup
# ---------------------------------------------------------------------------
sfdk_cmd() {
	"$SFDK" -c device="$DEVICE_NAME" "$@"
}

device_ready() {
	timeout 25 "$SFDK" -c device="$DEVICE_NAME" device exec true >/dev/null 2>&1
}

ensure_kvm() {
	if [[ ! -e /dev/kvm ]]; then
		kit_err "/dev/kvm is missing. The Aurora emulator is QEMU/KVM based."
		cat >&2 <<'EOF'
Load the KVM modules for your CPU:
  AMD:   sudo modprobe kvm && sudo modprobe kvm_amd
  Intel: sudo modprobe kvm && sudo modprobe kvm_intel
If the modules are missing, install the virtualization stack for your distro.
EOF
		return 1
	fi
	if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
		kit_err "/dev/kvm is not writable by $(id -un)."
		cat >&2 <<'EOF'
Quick fix for the current session:
  sudo setfacl -m u:$USER:rw /dev/kvm
Permanent fix:
  sudo usermod -aG kvm,render "$USER"   # then log out and back in
EOF
		return 1
	fi
	return 0
}

if (( ! SIGN_ONLY )) && ! device_ready; then
	[[ -n "$DEVICE_NAME" ]] || kit_die "no Aurora device registered.
Start the emulator:  ~/AuroraOS/bin/sfdk emulator start <name>
List devices:        ~/AuroraOS/bin/sfdk device list"
	if (( START )) && (( IS_EMULATOR )); then
		ensure_kvm || kit_die "cannot start the emulator without KVM access."
		kit_log "starting emulator '${EMULATOR_NAME:-$DEVICE_NAME}'…"
		"$SFDK" emulator start "${EMULATOR_NAME:-$DEVICE_NAME}" || \
			kit_warn "sfdk emulator start returned an error; waiting for the device anyway."
		deadline=$((SECONDS + WAIT_SECONDS))
		while (( SECONDS < deadline )); do
			if device_ready; then break; fi
			printf '.'
			sleep 5
		done
		printf '\n'
		device_ready || kit_die "device did not become reachable within ${WAIT_SECONDS}s.
Check the emulator window and run: sfdk device list"
		kit_ok "device is reachable: $DEVICE_NAME"
	else
		kit_die "device '$DEVICE_NAME' is not reachable (and --no-start was given or it is not an emulator)."
	fi
elif (( ! SIGN_ONLY )); then
	kit_ok "device is reachable: $DEVICE_NAME"
fi

# ---------------------------------------------------------------------------
# Signing
# ---------------------------------------------------------------------------
KEY_STAGE="$PROJECT_ROOT/build/.signing"
RPM_ABS="$(kit_abspath "$RPM_PATH")"
rpm_in_workspace="$(mode_path "$RPM_ABS")"

rpmsign_exec() {
	# rpmsign_exec <args...>; all paths must already be container-visible.
	case "$KIT_SDK_MODE" in
		docker)
			[[ -n "$KIT_SDK_RUN" ]] || return 1
			WORKSPACE_DIR="$PROJECT_ROOT" "$KIT_SDK_RUN" rpmsign-external "$@"
			;;
		sfdk)
			[[ -n "$SFDK" && -n "$KIT_SDK_TARGET" ]] || return 1
			"$SFDK" engine exec sb2 -t "$KIT_SDK_TARGET" rpmsign-external "$@"
			;;
		sb2)
			[[ -n "$KIT_SDK_TARGET" ]] || return 1
			sb2 -t "$KIT_SDK_TARGET" rpmsign-external "$@"
			;;
		*)
			if kit_has rpmsign-external; then
				rpmsign-external "$@"
			else
				return 1
			fi
			;;
	esac
}

if (( ! SKIP_SIGN )); then
	[[ -f "$KEY_PATH" ]] || kit_die "signing key not found: $KEY_PATH
Aurora SDK ships it at <SDK>/package-signing/regular_key.pem.
Pass --skip-sign to install an unsigned package (APM will reject it)."
	[[ -f "$CERT_PATH" ]] || kit_die "signing certificate not found: $CERT_PATH"

	if [[ "$KIT_SDK_MODE" == "docker" && "$rpm_in_workspace" == "$RPM_ABS" ]]; then
		kit_die "RPM must be inside the project for the SDK container to see it:
  $RPM_PATH
Move it under $PROJECT_ROOT/build/ or rebuild it there."
	fi

	if [[ "$KIT_SDK_MODE" == "docker" ]]; then
		mkdir -p "$KEY_STAGE"
		chmod 700 "$KEY_STAGE"
		install -m 600 "$KEY_PATH" "$KEY_STAGE/regular_key.pem"
		install -m 644 "$CERT_PATH" "$KEY_STAGE/regular_cert.pem"
		key_ref="$(kit_to_workspace_path "$KEY_STAGE/regular_key.pem")"
		cert_ref="$(kit_to_workspace_path "$KEY_STAGE/regular_cert.pem")"
	else
		key_ref="$KEY_PATH"
		cert_ref="$CERT_PATH"
	fi

	kit_log "signing $RPM_BASENAME with SDK test keys…"
	if ! rpmsign_exec sign -k "$key_ref" -c "$cert_ref" "$rpm_in_workspace"; then
		kit_die "rpmsign-external sign failed.
Common causes:
  * a self-signed openssl certificate (rejected with 'Failed to get certificate extensions');
    use the SDK's regular_key.pem / regular_cert.pem instead;
  * the RPM is not under the project mount (SDK 5.2 tools/run exposes it at /workspace)."
	fi

	dump_output="$(rpmsign_exec dump "$rpm_in_workspace" 2>&1 || true)"
	if grep -qi 'No signatures found' <<<"$dump_output"; then
		kit_err "rpmsign-external dump reports no signatures:"
		printf '%s\n' "$dump_output" >&2
		kit_die "signing did not take effect; refusing to install a package APM will reject."
	fi
	kit_ok "RPM signed and signature verified."
else
	kit_warn "--skip-sign: the package stays unsigned and APM will most likely reject it."
fi

if (( SIGN_ONLY )); then
	kit_ok "sign-only mode: done."
	exit 0
fi

# ---------------------------------------------------------------------------
# Copy to the device
# ---------------------------------------------------------------------------
DEVICE_RPM_PATH="/home/defaultuser/Downloads/$RPM_BASENAME"

copy_to_device() {
	if [[ "$IS_EMULATOR" == "1" || -n "$SSH_KEY" ]]; then
		[[ -f "$SSH_KEY" ]] || return 1
		kit_log "copying $RPM_BASENAME to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}:/home/defaultuser/Downloads/"
		scp -q -P "$SSH_PORT" -i "$SSH_KEY" \
			-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			-o ConnectTimeout=15 \
			"$RPM_PATH" "${SSH_USER}@${SSH_HOST}:/home/defaultuser/Downloads/" && return 0
		return 1
	fi
	return 1
}

if ! copy_to_device; then
	if (( IS_EMULATOR )); then
		kit_die "could not copy the RPM with scp.
Check the SSH key: $SSH_KEY
Override with AURORA_SSH_HOST / AURORA_SSH_PORT / AURORA_SSH_KEY."
	fi
	kit_log "no SSH key for the device; using 'sfdk deploy --manual'"
	sfdk_cmd deploy --manual "$RPM_PATH" || kit_warn "sfdk deploy --manual returned an error."
	DEVICE_RPM_PATH="/home/defaultuser/RPMS/$RPM_BASENAME"
fi

# ---------------------------------------------------------------------------
# Install through ru.omp.APM
# ---------------------------------------------------------------------------
kit_log "requesting installation through ru.omp.APM…"
prompt_value="<true>"
(( SHOW_PROMPT )) || prompt_value="<false>"
if ! sfdk_cmd device exec gdbus call -y -d ru.omp.APM -o /ru/omp/APM \
	-m ru.omp.APM.Install "$DEVICE_RPM_PATH" "{'ShowPrompt': $prompt_value}"; then
	kit_die "APM install request failed.
The package must be signed with a trusted certificate and readable by defaultuser:
  $DEVICE_RPM_PATH"
fi

if (( SHOW_PROMPT )); then
	kit_info "confirm the installation dialog on the emulator screen."
fi

kit_log "waiting for package $PKG_FULL to appear (up to ${INSTALL_WAIT}s)…"
installed=""
deadline=$((SECONDS + INSTALL_WAIT))
while (( SECONDS < deadline )); do
	installed="$(sfdk_cmd device exec rpm -q "$PKG_FULL" 2>/dev/null | tr -d '\r' | tail -1 || true)"
	[[ -n "$installed" && "$installed" == "$PKG_FULL"* ]] && break
	sleep 3
done
if [[ -n "$installed" && "$installed" == "$PKG_FULL"* ]]; then
	kit_ok "installed: $installed"
else
	kit_err "package is not installed yet."
	cat >&2 <<EOF
If the package manager showed an error, check:
  sfdk device exec journalctl -n 200 --no-pager | grep -i -E 'apm|rpm|sign'
Confirm the package is present:
  sfdk device exec ls -l "$DEVICE_RPM_PATH"
EOF
	exit 1
fi

# ---------------------------------------------------------------------------
# Launch hints and logs
# ---------------------------------------------------------------------------
cat <<EOF

Installed successfully.

HOW TO TEST
  1. Open the application menu in the emulator and tap "$PKG_FULL".
     Launching from the menu is required for Sailjail and app orientation.
  2. The game must start in the configured orientation without Wayland/EGL errors.
  3. Background the app: the game should pause, mute audio and write a save under:
       /home/defaultuser/.local/share/$PKG_ORG/$PKG_APP/
  4. Stream logs:
       sfdk -c device="$DEVICE_NAME" device exec journalctl -f -t "$PKG_FULL"

Uninstall:
  sfdk -c device="$DEVICE_NAME" device exec gdbus call -y -d ru.omp.APM -o /ru/omp/APM \\
    -m ru.omp.APM.Uninstall "$PKG_FULL" '{}'
EOF

if (( FOLLOW_LOGS )); then
	kit_log "following logs for $PKG_FULL (Ctrl+C to stop)…"
	sfdk_cmd device exec journalctl -f -t "$PKG_FULL"
fi

#!/usr/bin/env bash
# shellcheck shell=bash
#
# Thin wrapper: package an aarch64 RPM for a real Aurora OS device.
#
# The AuroraOS export plugin in the savegame/godot fork implements RPM export
# through the sb2 API, which Aurora SDK 5.2 removed. This wrapper therefore uses
# the same native packaging path as the x86_64 script:
#   * architecture-neutral .pck exported with the Aurora editor;
#   * prebuilt auroraos_release.arm64 template;
#   * rpmbuild --target aarch64-meego-linux-gnu inside the SDK build image.
#
# All options are forwarded; --help prints the shared help.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/build_x86_64_rpm.sh" --arch aarch64 "$@"

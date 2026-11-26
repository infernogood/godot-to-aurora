#!/usr/bin/env bash
# shellcheck shell=bash
#
# tests/run_modules.sh — запуск tests/test_modules.gd в headless-Godot.
#
# Собирает временный Godot-проект с каноническими путями кита
# (res://scripts/aurora/*.gd), кладёт туда test_modules.gd и запускает:
#
#   "$GODOT_BIN" --headless --path <fixture> --script res://test_modules.gd
#
# GODOT_BIN берётся из окружения, иначе ищутся godot4 и godot. Временный
# каталог (включая user:// через XDG_DATA_HOME) удаляется по trap.
#
# Запуск: GODOT_BIN=/path/to/godot bash tests/run_modules.sh
#
set -euo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TESTS_DIR/.." && pwd)"

if [[ -z "${GODOT_BIN:-}" ]]; then
	for candidate in godot4 godot; do
		if command -v "$candidate" >/dev/null 2>&1; then
			GODOT_BIN="$(command -v "$candidate")"
			break
		fi
	done
fi

if [[ -z "${GODOT_BIN:-}" ]]; then
	printf 'GODOT_BIN не задан, а godot4/godot не найдены в PATH.\n' >&2
	printf 'Укажите движок явно: GODOT_BIN=/path/to/godot bash %s\n' "$0" >&2
	exit 1
fi

if [[ ! -x "$GODOT_BIN" ]]; then
	printf 'GODOT_BIN не исполняется: %s\n' "$GODOT_BIN" >&2
	exit 1
fi

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/godot-to-aurora-modules.XXXXXX")"
trap 'rm -rf -- "$FIXTURE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$FIXTURE/scripts/aurora" "$FIXTURE/user-data"
cp -- "$REPO_ROOT"/modules/*.gd "$FIXTURE/scripts/aurora/"
cp -- "$TESTS_DIR/test_modules.gd" "$FIXTURE/test_modules.gd"

cat > "$FIXTURE/project.godot" <<'EOF'
config_version=5

[application]

config/name="godot-to-aurora-module-tests"
config/description="Headless-фикстура для tests/test_modules.gd"
EOF

printf 'fixture: %s\n' "$FIXTURE"
printf 'godot:   %s\n' "$GODOT_BIN"

rc=0
XDG_DATA_HOME="$FIXTURE/user-data" \
	"$GODOT_BIN" --headless --path "$FIXTURE" --script res://test_modules.gd || rc=$?

exit "$rc"

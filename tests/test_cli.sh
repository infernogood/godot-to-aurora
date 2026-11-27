#!/usr/bin/env bash
# shellcheck shell=bash
#
# tests/test_cli.sh — CLI-контракт кита godot-to-aurora.
#
# Проверки идут без сети, Docker, Aurora SDK и Godot: только bash, coreutils
# и сам репозиторий. Все временные каталоги создаются через mktemp -d и
# удаляются по trap, в репозитории ничего не остаётся.
#
# Запуск: bash tests/test_cli.sh (из любого каталога).
#
set -euo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TESTS_DIR/.." && pwd)"

FETCH_SCRIPT="$REPO_ROOT/scripts/fetch_engine.sh"
BUILD_X86_SCRIPT="$REPO_ROOT/scripts/build_x86_64_rpm.sh"
BUILD_ARM_SCRIPT="$REPO_ROOT/scripts/build_aarch64_rpm.sh"
DEPLOY_SCRIPT="$REPO_ROOT/scripts/deploy_emulator.sh"
COMMON_LIB="$REPO_ROOT/scripts/lib/common.sh"
VERSIONS_FILE="$REPO_ROOT/versions.env"

# Ожидаемая версия берётся из versions.env, а не дублируется в тесте.
KIT_VERSION="$(sed -n 's/^KIT_VERSION=//p' "$VERSIONS_FILE" | head -1)"
if [[ -z "$KIT_VERSION" ]]; then
	printf 'не удалось прочитать KIT_VERSION из %s\n' "$VERSIONS_FILE" >&2
	exit 1
fi
EXPECTED_VERSION="godot-to-aurora $KIT_VERSION"

# Тег Aurora-сборки Godot: из него складываются имена ассетов fetch_engine.sh.
GODOT_TAG="$(sed -n 's/^GODOT_AURORA_TAG=//p' "$VERSIONS_FILE" | head -1)"
if [[ -z "$GODOT_TAG" ]]; then
	printf 'не удалось прочитать GODOT_AURORA_TAG из %s\n' "$VERSIONS_FILE" >&2
	exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/godot-to-aurora-cli.XXXXXX")"
cleanup() {
	rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Изолированное окружение для публичных скриптов: пустой HOME, нет SDK,
# нет GODOT_BIN/Docker-переменных из окружения разработчика.
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"
KIT_ENV=(
	env -i
	"PATH=$PATH"
	"HOME=$HOME_DIR"
	"AURORA_SDK_HOME=$HOME_DIR/AuroraOS"
	"SFDK=$HOME_DIR/no-sfdk"
	"LANG=C.UTF-8"
	"TMPDIR=${TMPDIR:-/tmp}"
)

# ---------------------------------------------------------------------------
# Мини-фреймворк: PASS/FAIL, счётчики и итог.
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	printf '  PASS  %s\n' "$1"
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	printf '  FAIL  %s\n' "$1"
}

check_eq() { # check_eq <описание> <ожидалось> <получено>
	if [[ "$2" == "$3" ]]; then
		pass "$1"
	else
		fail "$1 (ожидалось: '$2', получено: '$3')"
	fi
}

check_ne() { # check_ne <описание> <не ожидалось> <получено>
	if [[ "$2" != "$3" ]]; then
		pass "$1"
	else
		fail "$1 (не ожидалось '$2')"
	fi
}

check_contains() { # check_contains <описание> <текст> <подстрока>
	if [[ "$2" == *"$3"* ]]; then
		pass "$1"
	else
		fail "$1 (в выводе нет '$3')"
	fi
}

check_regex() { # check_regex <описание> <текст> <ERE>
	if grep -qE -- "$3" <<<"$2"; then
		pass "$1"
	else
		fail "$1 (нет строки /$3/)"
	fi
}

path_exists() { # path_exists <путь> -> yes|no
	if [[ -e "$1" ]]; then
		printf 'yes'
	else
		printf 'no'
	fi
}

count_exact_lines() { # count_exact_lines <файл> <строка>
	local count
	count="$(grep -cxF -- "$2" "$1" 2>/dev/null || true)"
	printf '%s\n' "${count:-0}"
}

count_matches() { # count_matches <файл> <ERE>
	local count
	count="$(grep -cE -- "$2" "$1" 2>/dev/null || true)"
	printf '%s\n' "${count:-0}"
}

new_project() { # new_project <каталог>
	mkdir -p "$1"
	cat > "$1/project.godot" <<'EOF'
config_version=5

[application]

config/name="Smoke Game"
config/version="1.0.0"
EOF
}

# Моки sfdk/rpm/scp для deploy_emulator.sh: устройство-эмулятор, метаданные
# тестового пакета и «установленная» версия из $MOCK_INSTALLED_VERSION.
write_deploy_mocks() { # write_deploy_mocks <каталог для исполняемых файлов>
	local bindir="$1"
	mkdir -p "$bindir"

	cat > "$bindir/sfdk" <<'MOCK_SFDK'
#!/usr/bin/env bash
# Мок sfdk: одно устройство-эмулятор и запрос версии пакета на устройстве.
case "$*" in
	*"device list"*)
		printf '#0  "AuroraEmulator"\n'
		printf '    Type: эмулятор\n'
		printf '    Host name: defaultuser@127.0.0.1:2223\n'
		;;
	*"emulator list"*) printf 'AuroraEmulator\n' ;;
	*"device exec"*)
		case "$*" in
			*"rpm -q"*) printf '%s\n' "${MOCK_INSTALLED_VERSION:-1.2.3-1}" ;;
		esac
		;;
esac
exit 0
MOCK_SFDK

	cat > "$bindir/rpm" <<'MOCK_RPM'
#!/usr/bin/env bash
# Мок rpm: печатает метаданные тестового пакета по --queryformat.
format=""
previous=""
for arg in "$@"; do
	if [[ "$previous" == "--queryformat" ]]; then format="$arg"; fi
	previous="$arg"
done
case "$format" in
	*NAME*) printf '%s' "${MOCK_RPM_NAME:-ru.test.smoke}" ;;
	*ARCH*) printf '%s' "${MOCK_RPM_ARCH:-x86_64}" ;;
	*VERSION*) printf '%s' "${MOCK_RPM_VERSION:-1.2.3-1}" ;;
esac
MOCK_RPM

	cat > "$bindir/scp" <<'MOCK_SCP'
#!/usr/bin/env bash
# Мок scp: копирование на «устройство» всегда успешно.
exit 0
MOCK_SCP

	chmod +x "$bindir/sfdk" "$bindir/rpm" "$bindir/scp"
}

make_fake_elf() { # make_fake_elf <путь> aarch64|x86_64
	local path="$1" arch="$2" machine
	case "$arch" in
		aarch64) machine='\267\000' ;;
		x86_64) machine='\076\000' ;;
		*) printf 'неизвестная арх: %s\n' "$arch" >&2; return 1 ;;
	esac
	{
		printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000'
		printf '%b' "$machine"
		printf '\001\000\000\000'
		head -c 40 /dev/zero
	} > "$path"
}

# Вызов хелпера из scripts/lib/common.sh в отдельном subshell:
# изменения переменных библиотеки не утекают в тест.
kit_helper() { # kit_helper <корень проекта> <функция> [аргументы...]
	local project_root="$1" helper="$2"
	shift 2
	(
		PROJECT_ROOT="$project_root"
		BUILD_DIR="$TMP_ROOT/common-build"
		export PROJECT_ROOT BUILD_DIR
		# shellcheck disable=SC1090 # путь вычисляется, репозиторий переносим
		source "$COMMON_LIB"
		"$helper" "$@"
	)
}

# Параметры пакета из проекта, затем kit_patch_exclude_filter: функция
# работает с PKG_PRESET_INDEX и KIT_PRESET_FILE, которые заполняет
# kit_load_package_params (через GAME_DIR).
kit_patch_preset() { # kit_patch_preset <корень проекта>
	local project_root="$1"
	(
		PROJECT_ROOT="$project_root"
		GAME_DIR="$project_root"
		BUILD_DIR="$TMP_ROOT/common-build"
		export PROJECT_ROOT GAME_DIR BUILD_DIR
		# shellcheck disable=SC1090 # путь вычисляется, репозиторий переносим
		source "$COMMON_LIB"
		kit_load_package_params >/dev/null 2>&1
		kit_patch_exclude_filter
	)
}

# То же, но после kit_load_package_params печатает значение переменной PKG_*.
kit_param_value() { # kit_param_value <корень проекта> <имя переменной>
	local project_root="$1" varname="$2"
	(
		PROJECT_ROOT="$project_root"
		GAME_DIR="$project_root"
		BUILD_DIR="$TMP_ROOT/common-build"
		export PROJECT_ROOT GAME_DIR BUILD_DIR
		# shellcheck disable=SC1090 # путь вычисляется, репозиторий переносим
		source "$COMMON_LIB"
		kit_load_package_params 2>/dev/null
		printf '%s' "${!varname}"
	)
}

# ---------------------------------------------------------------------------
# 1. --help / --version всех публичных скриптов.
# ---------------------------------------------------------------------------
test_help_and_version() {
	printf '\n[1] --help и --version\n'
	local script name out rc
	local -a scripts=(
		"$FETCH_SCRIPT"
		"$BUILD_X86_SCRIPT"
		"$BUILD_ARM_SCRIPT"
		"$DEPLOY_SCRIPT"
	)
	for script in "${scripts[@]}"; do
		name="$(basename -- "$script")"

		rc=0
		out="$("${KIT_ENV[@]}" bash "$script" --version 2>&1)" || rc=$?
		check_eq "$name --version: код возврата" "0" "$rc"
		check_eq "$name --version: вывод" "$EXPECTED_VERSION" "$out"

		rc=0
		out="$("${KIT_ENV[@]}" bash "$script" --help 2>&1)" || rc=$?
		check_eq "$name --help: код возврата" "0" "$rc"
		check_contains "$name --help: есть раздел ИСПОЛЬЗОВАНИЕ" "$out" "ИСПОЛЬЗОВАНИЕ"
	done

	out="$("${KIT_ENV[@]}" bash "$BUILD_X86_SCRIPT" --help 2>&1)"
	check_contains "build --help: --skip-checksum" "$out" "--skip-checksum"
	check_contains "build --help: --strict-sdk" "$out" "--strict-sdk"
	out="$("${KIT_ENV[@]}" bash "$DEPLOY_SCRIPT" --help 2>&1)"
	check_contains "deploy --help: --strict-sdk" "$out" "--strict-sdk"
}

# ---------------------------------------------------------------------------
# 2. build_x86_64_rpm.sh --check без SDK.
# ---------------------------------------------------------------------------
test_build_check_without_sdk() {
	printf '\n[2] build_x86_64_rpm.sh --check без SDK\n'
	local proj="$TMP_ROOT/check-project"
	new_project "$proj"
	local out rc=0
	out="$("${KIT_ENV[@]}" "GAME_DIR=$proj" bash "$BUILD_X86_SCRIPT" --check 2>&1)" || rc=$?
	check_eq "--check без SDK: код возврата" "0" "$rc"
	check_contains "--check без SDK: сообщает НЕ ГОТОВО" "$out" "НЕ ГОТОВО"
	check_eq "--check ничего не создаёт в проекте" "no" "$(path_exists "$proj/build")"
}

# ---------------------------------------------------------------------------
# 3. Существующий AuroraOS-пресет сохраняется, .gitignore идемпотентен.
# ---------------------------------------------------------------------------
write_existing_preset_project() { # write_existing_preset_project <каталог>
	new_project "$1"
	cat > "$1/export_presets.cfg" <<'EOF'
[preset.0]

name="Aurora Phone"
platform="AuroraOS"
runnable=true
export_filter="all_resources"
exclude_filter=""

[preset.0.options]

package/organization="ru.test"
package/name="smoke"
package/launcher_name="Smoke"
EOF
}

test_existing_preset_and_gitignore() {
	printf '\n[3] Сохранение существующего AuroraOS-пресета и .gitignore\n'
	local proj="$TMP_ROOT/preset-project"
	write_existing_preset_project "$proj"
	local preset="$proj/export_presets.cfg"
	local gitignore="$proj/.gitignore"
	local before out rc

	before="$(md5sum "$preset" | cut -d' ' -f1)"
	rc=0
	out="$("${KIT_ENV[@]}" "GAME_DIR=$proj" bash "$BUILD_X86_SCRIPT" --write-preset 2>&1)" || rc=$?
	check_eq "--write-preset: код возврата" "0" "$rc"
	check_eq "export_presets.cfg не перезаписан" "$before" "$(md5sum "$preset" | cut -d' ' -f1)"
	check_eq "preset.1 не добавлен" "0" "$(count_matches "$preset" '^\[preset\.1\]$')"
	check_eq "name пресета сохранён" "1" "$(count_exact_lines "$preset" 'name="Aurora Phone"')"
	check_eq "package/organization сохранён" "1" "$(count_exact_lines "$preset" 'package/organization="ru.test"')"
	check_eq "package/name сохранён" "1" "$(count_exact_lines "$preset" 'package/name="smoke"')"

	check_eq ".gitignore: build/" "1" "$(count_exact_lines "$gitignore" 'build/')"
	check_eq ".gitignore: *.rpm" "1" "$(count_exact_lines "$gitignore" '*.rpm')"
	check_eq ".gitignore: export_presets.cfg.bak.*" "1" "$(count_exact_lines "$gitignore" 'export_presets.cfg.bak.*')"
	check_eq ".gitignore содержит ровно три правила" "3" "$(wc -l < "$gitignore" | tr -d ' ')"

	rc=0
	"${KIT_ENV[@]}" "GAME_DIR=$proj" bash "$BUILD_X86_SCRIPT" --write-preset >/dev/null 2>&1 || rc=$?
	check_eq "повторный --write-preset: код возврата" "0" "$rc"
	check_eq "повторный вызов не дублирует build/" "1" "$(count_exact_lines "$gitignore" 'build/')"
	check_eq "повторный вызов не дублирует *.rpm" "1" "$(count_exact_lines "$gitignore" '*.rpm')"
	check_eq "повторный вызов не дублирует export_presets.cfg.bak.*" \
		"1" "$(count_exact_lines "$gitignore" 'export_presets.cfg.bak.*')"

	rc=0
	out="$("${KIT_ENV[@]}" "GAME_DIR=$proj" bash "$BUILD_X86_SCRIPT" --check 2>&1)" || rc=$?
	check_eq "--check: код возврата" "0" "$rc"
	check_regex "--check показывает package ru.test.smoke" "$out" \
		'^[[:space:]]+package[[:space:]]+ru\.test\.smoke$'
	check_regex "--check показывает пресет Aurora Phone" "$out" \
		'^[[:space:]]+preset[[:space:]]+Aurora Phone \(индекс 0\)$'
}

# ---------------------------------------------------------------------------
# 4. fetch_engine.sh --check и --dry-run на пустых каталогах.
# ---------------------------------------------------------------------------
test_fetch_engine_empty() {
	printf '\n[4] fetch_engine.sh: пустые каталоги\n'
	local sandbox="$TMP_ROOT/fetch"
	mkdir -p "$sandbox"
	local dest="$sandbox/engine"
	local templates="$sandbox/templates"
	local out rc=0

	out="$("${KIT_ENV[@]}" bash "$FETCH_SCRIPT" --check --dest "$dest" --templates-dir "$templates" 2>&1)" || rc=$?
	check_ne "--check пустых каталогов: код возврата != 0" "0" "$rc"
	check_contains "--check пустых каталогов: предупреждение" "$out" "часть компонентов отсутствует"
	check_eq "--check не создаёт DEST" "no" "$(path_exists "$dest")"
	check_eq "--check не создаёт каталог шаблонов" "no" "$(path_exists "$templates")"

	rc=0
	out="$("${KIT_ENV[@]}" bash "$FETCH_SCRIPT" --dry-run --from-dir "$sandbox" \
		--dest "$dest" --templates-dir "$templates" 2>&1)" || rc=$?
	check_eq "--dry-run пустого источника: код возврата" "0" "$rc"
	check_contains "--dry-run: сообщает, что ничего не скачивает" "$out" "dry-run"
	check_eq "--dry-run не создаёт DEST" "no" "$(path_exists "$dest")"
	check_eq "--dry-run не создаёт каталог шаблонов" "no" "$(path_exists "$templates")"
}

# ---------------------------------------------------------------------------
# 5. Кастомный BUILD_DIR: бэкапы уходят в $BUILD_DIR/backups.
# ---------------------------------------------------------------------------
test_custom_build_dir() {
	printf '\n[5] Кастомный BUILD_DIR\n'
	local proj="$TMP_ROOT/builddir-project"
	new_project "$proj"
	cat > "$proj/export_presets.cfg" <<'EOF'
[preset.0]

name="Linux"
platform="Linux/X11"
runnable=true

[preset.0.options]

export_path="game.x86_64"
EOF
	local preset="$proj/export_presets.cfg"
	local rc=0

	"${KIT_ENV[@]}" "GAME_DIR=$proj" "BUILD_DIR=$proj/out" \
		"ORG_NAME=ru.test" "APP_NAME=smoke" \
		bash "$BUILD_X86_SCRIPT" --write-preset >/dev/null 2>&1 || rc=$?
	check_eq "--write-preset с BUILD_DIR: код возврата" "0" "$rc"
	check_eq "бэкап создан в out/backups/" "1" \
		"$(find "$proj/out/backups" -maxdepth 1 -type f -name 'export_presets.cfg.bak.*' 2>/dev/null | wc -l)"
	check_eq "в корне проекта бэкапа нет" "0" \
		"$(find "$proj" -maxdepth 1 -type f -name 'export_presets.cfg.bak.*' 2>/dev/null | wc -l)"
	check_eq "каталог build/ в проекте не создан" "no" "$(path_exists "$proj/build")"
	check_eq "новый preset.1 добавлен" "1" "$(count_matches "$preset" '^\[preset\.1\]$')"
	check_eq "существующий preset.0 сохранён" "1" "$(count_matches "$preset" '^\[preset\.0\]$')"
	check_eq "Linux-пресет не изменён" "1" "$(count_exact_lines "$preset" 'platform="Linux/X11"')"
	check_eq "новый пресет AuroraOS добавлен" "1" "$(count_exact_lines "$preset" 'platform="AuroraOS"')"
}

# ---------------------------------------------------------------------------
# 6. Экранирование и roundtrip заголовка через export_presets.cfg.
# ---------------------------------------------------------------------------
test_escaping() {
	printf '\n[6] Экранирование значений шаблонов\n'
	local out

	out="$(kit_helper "$TMP_ROOT/escape" kit_escape_spec "$(printf '100%% %%(x)\nnext')")"
	check_eq "kit_escape_spec: %% -> %%, управляющие символы убраны" \
		'100%% %%(x)next' "$out"

	out="$(kit_helper "$TMP_ROOT/escape" kit_escape_cfg 'a"b\c')"
	check_eq "kit_escape_cfg: кавычка и обратный слэш" 'a\"b\\c' "$out"

	out="$(kit_helper "$TMP_ROOT/escape" kit_escape_desktop "$(printf 'a\nb\tc')")"
	check_eq "kit_escape_desktop: без управляющих символов" "abc" "$out"

	# Обратный слэш в .desktop-значении не должен ломать строку: он удваивается.
	out="$(kit_helper "$TMP_ROOT/escape" kit_escape_desktop 'a\b')"
	check_eq "kit_escape_desktop: обратный слэш экранирован" 'a\\b' "$out"

	local escaped out_desktop="$TMP_ROOT/escape/app.desktop"
	escaped="$(kit_helper "$TMP_ROOT/escape" kit_escape_desktop 'Back\slash')"
	kit_helper "$TMP_ROOT/escape" kit_render_template \
		"$REPO_ROOT/templates/app.desktop.in" "$out_desktop" \
		"APP_TITLE=$escaped" >/dev/null
	check_eq "desktop: Name с обратным слэшем сохранён" "1" \
		"$(count_exact_lines "$out_desktop" 'Name=Back\\slash')"
	check_eq "desktop: строка Name не разорвана" "1" \
		"$(count_matches "$out_desktop" '^Name=')"
}

test_title_roundtrip() {
	printf '\n[7] Roundtrip package/launcher_name\n'
	local proj="$TMP_ROOT/title-project"
	new_project "$proj"
	local preset="$proj/export_presets.cfg"
	local title='Моя "игра" 100%'
	local expected_line='package/launcher_name="Моя \"игра\" 100%"'
	local rc=0 out

	"${KIT_ENV[@]}" "GAME_DIR=$proj" "ORG_NAME=ru.test" "APP_NAME=smoke" \
		"APP_TITLE=$title" bash "$BUILD_X86_SCRIPT" --write-preset >/dev/null 2>&1 || rc=$?
	check_eq "--write-preset с кавычками и %: код возврата" "0" "$rc"
	check_eq "launcher_name экранирован в cfg" "1" "$(count_exact_lines "$preset" "$expected_line")"
	check_eq "в cfg ровно одна строка launcher_name" "1" \
		"$(count_matches "$preset" '^package/launcher_name=')"

	rc=0
	out="$(kit_param_value "$proj" PKG_TITLE)" || rc=$?
	check_eq "kit_load_package_params: код возврата" "0" "$rc"
	check_eq "kit_load_package_params читает заголовок обратно" "$title" "$out"
}

# ---------------------------------------------------------------------------
# 8. Точный токен exclude_filter и один exclude_filter в пресете.
# ---------------------------------------------------------------------------
test_exclude_filter() {
	printf '\n[8] exclude_filter: точные токены\n'
	local out

	out="$(kit_helper "$TMP_ROOT/plain-project" kit_merge_exclude_filter 'mybuild/*')"
	check_eq "mybuild/* не считается build/*: build/* добавлен" \
		'mybuild/*,build/*' "$out"

	out="$(kit_helper "$(dirname -- "$REPO_ROOT")" kit_merge_exclude_filter 'mybuild/*')"
	local kit_dir
	kit_dir="$(basename -- "$REPO_ROOT")"
	check_eq "каталог кита добавлен, когда кит внутри проекта" \
		"mybuild/*,build/*,$kit_dir/*" "$out"

	local proj="$TMP_ROOT/exclude-project"
	new_project "$proj"
	cat > "$proj/export_presets.cfg" <<'EOF'
[preset.0]

name="Aurora Phone"
platform="AuroraOS"
runnable=true
export_filter="all_resources"
exclude_filter=""

[preset.0.options]

package/organization="ru.test"
package/name="smoke"
EOF
	local rc=0
	kit_patch_preset "$proj" >/dev/null 2>&1 || rc=$?
	check_eq "kit_patch_exclude_filter: код возврата" "0" "$rc"
	check_eq "осталась ровно одна строка exclude_filter" "1" \
		"$(count_matches "$proj/export_presets.cfg" '^exclude_filter=')"
	check_eq "exclude_filter заполнен build/*" "1" \
		"$(count_exact_lines "$proj/export_presets.cfg" 'exclude_filter="build/*"')"
}

# ---------------------------------------------------------------------------
# 9. kit_to_workspace_path: соседний каталог не попадает в /workspace.
# ---------------------------------------------------------------------------
test_workspace_path() {
	printf '\n[9] kit_to_workspace_path: границы проекта\n'
	local proj="$TMP_ROOT/workspace-project"
	mkdir -p "$proj"
	local out

	out="$(kit_helper "$proj" kit_to_workspace_path "$proj-old/build")"
	check_eq "соседний каталог -old не становится /workspace" "$proj-old/build" "$out"

	out="$(kit_helper "$proj" kit_to_workspace_path "$proj/out")"
	check_eq "путь внутри проекта нормализуется в /workspace" "/workspace/out" "$out"
}

# ---------------------------------------------------------------------------
# 10. libxkbcommon: известные версии и SHA-256.
# ---------------------------------------------------------------------------
test_xkbcommon_versions() {
	printf '\n[10] libxkbcommon: версии и SHA-256\n'
	local expected out rc
	expected="$(sed -n 's/^XKBCOMMON_SHA256=//p' "$VERSIONS_FILE" | head -1)"
	out="$(kit_helper "$TMP_ROOT/xkb" kit_xkbcommon_sha256 1.3.1)"
	check_eq "1.3.1: известный SHA-256" "$expected" "$out"
	out="$(kit_helper "$TMP_ROOT/xkb" kit_xkbcommon_sha256 1.3.1+git1)"
	check_eq "1.3.1+git1: тот же SHA-256 (packaging-суффикс RPM)" "$expected" "$out"
	rc=0
	kit_helper "$TMP_ROOT/xkb" kit_xkbcommon_sha256 1.5.0 >/dev/null 2>&1 || rc=$?
	check_ne "1.5.0: неизвестная версия отклоняется" "0" "$rc"
	out="$(kit_helper "$TMP_ROOT/xkb" kit_xkbcommon_base_version 1.3.1+git1)"
	check_eq "1.3.1+git1: базовый архив 1.3.1" "1.3.1" "$out"
}

# ---------------------------------------------------------------------------
# 11. SDK version gate: 5.2.x поддерживается, 5.1/5.3 — предупреждение.
# ---------------------------------------------------------------------------
test_sdk_version_gate() {
	printf '\n[11] SDK version gate\n'
	local proj ver sdk out rc
	proj="$TMP_ROOT/sdk-project"
	new_project "$proj"

	for ver in 5.1.3.85 5.3.0.1; do
		sdk="$TMP_ROOT/sdk-$ver"
		mkdir -p "$sdk/sdk/$ver"
		rc=0
		out="$("${KIT_ENV[@]}" "AURORA_SDK_HOME=$sdk" "GAME_DIR=$proj" \
			bash "$BUILD_X86_SCRIPT" --check 2>&1)" || rc=$?
		check_eq "SDK $ver: --check rc" "0" "$rc"
		check_contains "SDK $ver: версия показана" "$out" "$ver"
		check_contains "SDK $ver: предупреждение о серии" "$out" \
			"не входит в поддерживаемую серию"

		rc=0
		out="$("${KIT_ENV[@]}" "AURORA_SDK_HOME=$sdk" "GAME_DIR=$proj" \
			bash "$BUILD_X86_SCRIPT" --check --strict-sdk 2>&1)" || rc=$?
		check_eq "SDK $ver: --check --strict-sdk rc=1" "1" "$rc"
	done

	sdk="$TMP_ROOT/sdk-5.2.1.200"
	mkdir -p "$sdk/sdk/5.2.1.200"
	rc=0
	out="$("${KIT_ENV[@]}" "AURORA_SDK_HOME=$sdk" "GAME_DIR=$proj" \
		bash "$BUILD_X86_SCRIPT" --check 2>&1)" || rc=$?
	check_eq "SDK 5.2.1.200: --check rc" "0" "$rc"
	check_contains "SDK 5.2.1.200: версия показана" "$out" "5.2.1.200"
	check_eq "SDK 5.2.1.200: предупреждения нет" "0" \
		"$(grep -c 'не входит в поддерживаемую серию' <<<"$out" || true)"

	rc=0
	out="$("${KIT_ENV[@]}" "AURORA_SDK_HOME=$sdk" "GAME_DIR=$proj" \
		bash "$BUILD_X86_SCRIPT" --check --strict-sdk 2>&1)" || rc=$?
	check_eq "SDK 5.2.1.200: --check --strict-sdk rc" "0" "$rc"
}

# ---------------------------------------------------------------------------
# 12. build_aarch64_rpm.sh: арх-проверка, --pck-only, права.
# ---------------------------------------------------------------------------
test_aarch64_wrapper() {
	printf '\n[12] build_aarch64_rpm.sh\n'
	local proj arm x86 out rc mode
	proj="$TMP_ROOT/arm-project"
	arm="$TMP_ROOT/fake-arm64"
	x86="$TMP_ROOT/fake-x86_64"
	new_project "$proj"
	make_fake_elf "$arm" aarch64
	make_fake_elf "$x86" x86_64

	rc=0
	out="$("${KIT_ENV[@]}" "GAME_DIR=$proj" "AURORA_TEMPLATE_AARCH64=$arm" \
		bash "$BUILD_ARM_SCRIPT" --check 2>&1)" || rc=$?
	check_eq "aarch64 --check с arm64-шаблоном: rc" "0" "$rc"
	check_contains "aarch64 --check: видит AURORA_TEMPLATE_AARCH64" "$out" "$arm"
	check_contains "aarch64 --check: строка шаблона aarch64" "$out" "шаблон aarch64"

	rc=0
	out="$("${KIT_ENV[@]}" "GAME_DIR=$proj" "AURORA_TEMPLATE_AARCH64=$x86" \
		bash "$BUILD_ARM_SCRIPT" --check 2>&1)" || rc=$?
	check_eq "aarch64 --check с x86_64-шаблоном: rc" "0" "$rc"
	check_contains "aarch64 --check: x86_64-шаблон отклонён" "$out" \
		"собран для x86_64, а нужен aarch64"

	rc=0
	out="$("${KIT_ENV[@]}" "GAME_DIR=$proj" bash "$BUILD_ARM_SCRIPT" \
		--pck-only --check 2>&1)" || rc=$?
	check_eq "aarch64 --pck-only --check: rc" "0" "$rc"
	check_contains "aarch64 --pck-only: не требует шаблон" "$out" "шаблон aarch64"
	check_eq "aarch64 --pck-only: предупреждения о шаблоне нет" "0" \
		"$(grep -c 'шаблон aarch64 не найден' <<<"$out" || true)"

	rc=0
	out="$(kit_helper "$proj" kit_verify_template_arch "$arm" aarch64 2>&1)" || rc=$?
	check_eq "kit_verify_template_arch: arm64 принят" "0" "$rc"
	rc=0
	out="$(kit_helper "$proj" kit_verify_template_arch "$x86" aarch64 2>&1)" || rc=$?
	check_ne "kit_verify_template_arch: x86_64 отклонён" "0" "$rc"
	check_contains "kit_verify_template_arch: понятная ошибка" "$out" "нужен aarch64"

	if [[ -x "$BUILD_ARM_SCRIPT" ]]; then
		pass "build_aarch64_rpm.sh исполняемый"
	else
		fail "build_aarch64_rpm.sh не исполняемый"
	fi
	if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		mode="$(git -C "$REPO_ROOT" ls-files -s scripts/build_aarch64_rpm.sh | awk '{print $1}')"
		check_eq "build_aarch64_rpm.sh: режим в Git-индексе" "100755" "$mode"
	else
		pass "build_aarch64_rpm.sh: Git-индекс недоступен (пропуск)"
	fi
}

# ---------------------------------------------------------------------------
# 13. Транслитерация кириллицы при LC_ALL=C.
# ---------------------------------------------------------------------------
test_slug_under_c_locale() {
	printf '\n[13] Транслитерация под LC_ALL=C\n'
	local out
	local probe="$TMP_ROOT/slug-probe.sh"
	cat > "$probe" <<'EOF'
#!/usr/bin/env bash
source "$1"
kit_slug "$2"
EOF
	# kit_translit/kit_slug сами выставляют C.UTF-8: под LC_ALL=C bash не меняет
	# регистр кириллицы, и ассерты ниже проверяют именно это.
	out="$(env -i "PATH=$PATH" "HOME=$TMP_ROOT/slug-home" "LC_ALL=C" \
		bash "$probe" "$COMMON_LIB" "Моя Игра")"
	check_eq "kit_slug «Моя Игра» под LC_ALL=C" "moya_igra" "$out"

	out="$(env -i "PATH=$PATH" "HOME=$TMP_ROOT/slug-home" "LC_ALL=C" \
		bash "$probe" "$COMMON_LIB" "Привет МИР")"
	check_eq "kit_slug с верхним регистром под LC_ALL=C" "privet_mir" "$out"
}

# ---------------------------------------------------------------------------
# 14. export_presets.cfg с CRLF: пресет находится, файл не мусорится.
# ---------------------------------------------------------------------------
test_crlf_preset() {
	printf '\n[14] export_presets.cfg с CRLF\n'
	local proj="$TMP_ROOT/crlf-project"
	new_project "$proj"
	local preset="$proj/export_presets.cfg"
	# Так файл пишется на Windows: каждая строка заканчивается \r\n.
	{
		printf '[preset.0]\r\n\r\n'
		printf 'name="Aurora Phone"\r\n'
		printf 'platform="AuroraOS"\r\n'
		printf 'runnable=true\r\n'
		printf 'export_filter="all_resources"\r\n'
		printf 'exclude_filter=""\r\n\r\n'
		printf '[preset.0.options]\r\n\r\n'
		printf 'package/organization="ru.test"\r\n'
		printf 'package/name="smoke"\r\n'
	} > "$preset"

	local before out rc=0
	before="$(md5sum "$preset" | cut -d' ' -f1)"
	out="$("${KIT_ENV[@]}" "GAME_DIR=$proj" bash "$BUILD_X86_SCRIPT" --write-preset 2>&1)" || rc=$?
	check_eq "CRLF --write-preset: код возврата" "0" "$rc"
	check_eq "CRLF: существующий файл не перезаписан" "$before" \
		"$(md5sum "$preset" | cut -d' ' -f1)"
	check_eq "CRLF: preset.1 не добавлен" "0" "$(count_matches "$preset" '^\[preset\.1\]')"

	out="$("${KIT_ENV[@]}" "GAME_DIR=$proj" bash "$BUILD_X86_SCRIPT" --check 2>&1)"
	check_regex "CRLF: --check находит пресет Aurora Phone" "$out" \
		'^[[:space:]]+preset[[:space:]]+Aurora Phone \(индекс 0\)$'

	kit_patch_preset "$proj" >/dev/null 2>&1
	check_eq "CRLF: после patch ровно одна строка exclude_filter" "1" \
		"$(count_matches "$preset" '^exclude_filter=')"
	check_eq "CRLF: exclude_filter получил build/*" "1" \
		"$(count_exact_lines "$preset" 'exclude_filter="build/*"')"
	check_eq "CRLF: строк с \r в файле не осталось" "0" \
		"$(grep -c $'\r' "$preset" || true)"
	check_eq "CRLF: package/name сохранён" "1" \
		"$(count_exact_lines "$preset" 'package/name="smoke"')"
}

# ---------------------------------------------------------------------------
# 15. fetch_engine.sh --force с битой контрольной суммой.
# ---------------------------------------------------------------------------
test_fetch_force_bad_checksum() {
	printf '\n[15] fetch_engine.sh --force: битая контрольная сумма\n'
	local sandbox="$TMP_ROOT/fetch-force"
	local src="$sandbox/src" dest="$sandbox/dest"
	mkdir -p "$src" "$dest"
	local asset="Godot_v${GODOT_TAG}_linux.x86_64"
	printf 'рабочий бинарник\n' > "$dest/$asset"
	printf 'битая копия\n' > "$src/$asset"
	printf '%s  %s\n' \
		'0000000000000000000000000000000000000000000000000000000000000000' \
		"$asset" > "$src/SHA256SUMS"

	local before out rc=0
	before="$(md5sum "$dest/$asset" | cut -d' ' -f1)"
	out="$("${KIT_ENV[@]}" bash "$FETCH_SCRIPT" --from-dir "$src" --dest "$dest" \
		--templates-dir "$sandbox/templates" --no-templates --force --no-verify 2>&1)" || rc=$?
	check_ne "--force с битым SHA-256: код возврата != 0" "0" "$rc"
	check_contains "--force с битым SHA-256: сказано про контрольную сумму" \
		"$out" "контрольная сумма"
	check_eq "--force с битым SHA-256: рабочий файл цел" "$before" \
		"$(md5sum "$dest/$asset" | cut -d' ' -f1)"
	check_eq "--force с битым SHA-256: .part удалён" "no" \
		"$(path_exists "$dest/$asset.part")"
	check_eq "--force с битым SHA-256: в DEST только старый файл" "1" \
		"$(find "$dest" -maxdepth 1 -type f | wc -l | tr -d ' ')"
}

# ---------------------------------------------------------------------------
# 16. deploy_emulator.sh: дефолтный SSH-ключ и сверка VERSION-RELEASE.
# ---------------------------------------------------------------------------
test_deploy_check_and_version() {
	printf '\n[16] deploy_emulator.sh: ключ SDK и VERSION-RELEASE\n'
	local sandbox="$TMP_ROOT/deploy"
	local proj="$sandbox/project"
	mkdir -p "$proj" "$sandbox/sdk/vmshare/ssh/private_keys"
	new_project "$proj"
	write_deploy_mocks "$sandbox/bin"
	local key="$sandbox/sdk/vmshare/ssh/private_keys/sdk"
	: > "$key"
	local rpm_file="$sandbox/smoke.rpm"
	printf 'тестовый RPM\n' > "$rpm_file"

	local -a deploy_env=(
		env -i
		"PATH=$sandbox/bin:$PATH"
		"HOME=$sandbox/home"
		"TMPDIR=${TMPDIR:-/tmp}"
		"LANG=C.UTF-8"
		"AURORA_SDK_HOME=$sandbox/sdk"
		"SFDK=$sandbox/bin/sfdk"
		"GAME_DIR=$proj"
		"BUILD_DIR=$proj/build"
	)

	local out rc=0
	out="$("${deploy_env[@]}" bash "$DEPLOY_SCRIPT" --check --rpm "$rpm_file" 2>&1)" || rc=$?
	check_eq "deploy --check: код возврата" "0" "$rc"
	check_contains "deploy --check: найден дефолтный SSH-ключ SDK" "$out" "key=$key"
	check_regex "deploy --check: версия-релиз из rpm -qp" "$out" \
		'^Версия пакета[[:space:]]+1\.2\.3-1$'
	check_contains "deploy --check: SSH-эндпоинт из sfdk device list" "$out" \
		"defaultuser@127.0.0.1:2223"

	rc=0
	out="$("${deploy_env[@]}" "MOCK_INSTALLED_VERSION=1.2.3-1" bash "$DEPLOY_SCRIPT" \
		--rpm "$rpm_file" --skip-sign --no-start --no-prompt --install-wait 1 2>&1)" || rc=$?
	check_eq "deploy: установка при совпадении версии: код возврата" "0" "$rc"
	check_contains "deploy: ok-сообщение содержит VERSION-RELEASE" "$out" \
		"установлен: ru.test.smoke-1.2.3-1"

	# Расхождение версии-релиза не должно считаться успешной установкой.
	rc=0
	out="$("${deploy_env[@]}" "MOCK_INSTALLED_VERSION=1.2.3-9" bash "$DEPLOY_SCRIPT" \
		--rpm "$rpm_file" --skip-sign --no-start --no-prompt --install-wait 1 2>&1)" || rc=$?
	check_ne "deploy: другая версия на устройстве -> код возврата != 0" "0" "$rc"
	check_contains "deploy: показан локальный пакет" "$out" \
		"Локальный пакет: ru.test.smoke-1.2.3-1"
	check_contains "deploy: показана версия на устройстве" "$out" \
		"На устройстве:   1.2.3-9"
}

# ---------------------------------------------------------------------------
# 17. build_x86_64_rpm.sh --check: только стоковый Godot.
# ---------------------------------------------------------------------------
test_build_check_stock_godot() {
	printf '\n[17] build_x86_64_rpm.sh --check со стоковым Godot\n'
	local proj="$TMP_ROOT/stock-project" stock="$TMP_ROOT/godot-stock"
	new_project "$proj"
	# Заглушка без строки-маркера платформы: grep-детектор её не примет.
	cat > "$stock" <<'EOF'
#!/usr/bin/env bash
# Заглушка «стокового» Godot: платформы экспорта Авроры в нем нет.
if [[ "${1:-}" == "--headless" ]]; then
	printf '4.7.2.stable.official.28e3be3f5\n'
	exit 0
fi
printf 'заглушка стокового Godot\n'
EOF
	chmod +x "$stock"

	local out rc=0
	out="$("${KIT_ENV[@]}" "GAME_DIR=$proj" "GODOT_BIN=$stock" \
		bash "$BUILD_X86_SCRIPT" --check 2>&1)" || rc=$?
	check_eq "--check со стоковым Godot: код возврата" "0" "$rc"
	check_contains "--check: предупреждение про стоковый Godot" "$out" \
		"найден стоковый Godot без платформы AuroraOS"
	check_contains "--check: окружение НЕ ГОТОВО" "$out" "НЕ ГОТОВО"
}

# ---------------------------------------------------------------------------
# 18. kit_render_template: однопроходная подстановка.
# ---------------------------------------------------------------------------
test_render_template_single_pass() {
	printf '\n[18] kit_render_template: однопроходность\n'
	local dir="$TMP_ROOT/render"
	mkdir -p "$dir"
	printf 'A=@A@ B=@B@\n' > "$dir/tpl.in"

	kit_helper "$dir" kit_render_template "$dir/tpl.in" "$dir/out.txt" \
		'A=1' 'B=zzz' >/dev/null
	check_eq "render: обычная подстановка" "A=1 B=zzz" "$(cat "$dir/out.txt")"

	# Значение с @B@ не должно подставляться повторно: рендер однопроходный.
	kit_helper "$dir" kit_render_template "$dir/tpl.in" "$dir/out2.txt" \
		'A=@B@' 'B=zzz' >/dev/null
	check_eq "render: @B@ в значении остаётся литеральным" "A=@B@ B=zzz" \
		"$(cat "$dir/out2.txt")"
}

# ---------------------------------------------------------------------------
# Запуск
# ---------------------------------------------------------------------------
test_help_and_version
test_build_check_without_sdk
test_existing_preset_and_gitignore
test_fetch_engine_empty
test_custom_build_dir
test_escaping
test_title_roundtrip
test_exclude_filter
test_workspace_path
test_xkbcommon_versions
test_sdk_version_gate
test_aarch64_wrapper
test_slug_under_c_locale
test_crlf_preset
test_fetch_force_bad_checksum
test_deploy_check_and_version
test_build_check_stock_godot
test_render_template_single_pass

printf '\n----------------------------------------------------------------\n'
printf 'проверок: %d, провалов: %d\n' "$((PASS_COUNT + FAIL_COUNT))" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
	printf 'РЕЗУЛЬТАТ: FAIL\n'
	exit 1
fi
printf 'РЕЗУЛЬТАТ: OK\n'

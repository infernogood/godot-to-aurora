#!/usr/bin/env bash
# shellcheck shell=bash
#
# Подпись RPM тестовыми ключами SDK и установка в эмулятор Aurora OS
# (или на подключённое устройство).
#
# Эмулятор в Aurora SDK 5.2+ — это QEMU/KVM (не VirtualBox):
#   * нужен /dev/kvm, доступный на запись текущему пользователю;
#   * `sfdk emulator start` запускает его, `sfdk device exec` работает по SSH.
#
# Неподписанные пакеты менеджер пакетов Aurora (ru.omp.APM) отвергает.
# Самоподписанные openssl-сертификаты rpmsign-external отвергает с ошибкой
# "Failed to get certificate extensions"; поддерживаемый путь — regular_key.pem /
# regular_cert.pem из SDK.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
	cat <<'EOF'
godot-to-aurora — установка RPM в эмулятор Aurora OS

ИСПОЛЬЗОВАНИЕ
  deploy_emulator.sh [опции]

ОПЦИИ
      --rpm PATH          RPM для установки (по умолчанию — новейший в
                          build/rpmbuild/RPMS).
      --device NAME       Устройство sfdk (по умолчанию — первое из списка).
      --emulator NAME     Имя эмулятора для запуска (по умолчанию — первое из
                          `sfdk emulator list`).
      --no-start          Не запускать эмулятор; падать, если он недоступен.
      --skip-sign         Установить без подписи (APM обычно отвергнет).
      --sign-only         Только подписать RPM и выйти.
      --no-prompt         Вызывать ru.omp.APM.Install с ShowPrompt=false.
      --wait SECONDS      Сколько ждать SSH эмулятора (по умолчанию 240).
      --install-wait SEC  Сколько ждать установки в APM (по умолчанию 120).
      --logs              Следить за journalctl пакета после установки.
      --check             Показать RPM/устройство/SDK и выйти.
      --strict-sdk        Блокировать деплой, если SDK не 5.2.x (SDK_SUPPORTED_PREFIX).
  -V, --version           Напечатать версию кита и выйти.
  -h, --help              Показать эту справку.

ОКРУЖЕНИЕ
  AURORA_SDK_HOME=DIR     Корень Aurora SDK (по умолчанию ~/AuroraOS).
  AURORA_DEVICE=NAME      То же, что --device.
  AURORA_EMULATOR=NAME    То же, что --emulator.
  AURORA_SIGN_KEY=FILE    Ключ подписи (по умолчанию <SDK>/package-signing/regular_key.pem).
  AURORA_SIGN_CERT=FILE   Сертификат (по умолчанию <SDK>/package-signing/regular_cert.pem).
  AURORA_SSH_HOST=HOST    SSH-хост устройства (по умолчанию — из sfdk).
  AURORA_SSH_PORT=PORT    SSH-порт устройства.
  AURORA_SSH_USER=USER    SSH-пользователь (по умолчанию defaultuser).
  AURORA_SSH_KEY=FILE     Приватный SSH-ключ устройства.

ЗАМЕЧАНИЯ
  * Запускайте игру из меню приложений, а не из шелла: только тогда работают
    Sailjail (OrganizationName/ApplicationName/Permissions) и
    [X-Aurora-Application] Orientation.
  * Менеджеру пакетов нужен тестовый сертификат SDK: эмулятор доверяет ему
    из коробки, реальное устройство должно быть в режиме разработчика.
  * Для локального эмулятора проверка ключа хоста SSH отключена; для реальных
    устройств используется стандартная проверка known_hosts.
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
STRICT_SDK=0

while (( $# > 0 )); do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		-V|--version) kit_version_banner; exit 0 ;;
		--rpm) [[ $# -ge 2 ]] || kit_die "--rpm требует путь"; RPM_ARG="$2"; shift ;;
		--device) [[ $# -ge 2 ]] || kit_die "--device требует имя"; DEVICE_NAME="$2"; shift ;;
		--emulator) [[ $# -ge 2 ]] || kit_die "--emulator требует имя"; EMULATOR_NAME="$2"; shift ;;
		--no-start) START=0 ;;
		--skip-sign) SKIP_SIGN=1 ;;
		--sign-only) SIGN_ONLY=1 ;;
		--no-prompt) SHOW_PROMPT=0 ;;
		--wait) [[ $# -ge 2 ]] || kit_die "--wait требует секунды"; WAIT_SECONDS="$2"; shift ;;
		--install-wait) [[ $# -ge 2 ]] || kit_die "--install-wait требует секунды"; INSTALL_WAIT="$2"; shift ;;
		--logs) FOLLOW_LOGS=1 ;;
		--check) CHECK_ONLY=1 ;;
		--strict-sdk) STRICT_SDK=1 ;;
		*) kit_die "неизвестная опция: $1 (см. --help)" ;;
	esac
	shift
done

[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || kit_die "--wait должен быть целым неотрицательным числом (получено '$WAIT_SECONDS')."
[[ "$INSTALL_WAIT" =~ ^[0-9]+$ ]] || kit_die "--install-wait должен быть целым неотрицательным числом (получено '$INSTALL_WAIT')."

PROJECT_ROOT="$(kit_project_root)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_ROOT/build}"
BUILD_DIR="$(kit_abspath "$BUILD_DIR")"
SDK_HOME="$(kit_sdk_home)"
KEY_PATH="${AURORA_SIGN_KEY:-$SDK_HOME/package-signing/regular_key.pem}"
CERT_PATH="${AURORA_SIGN_CERT:-$SDK_HOME/package-signing/regular_cert.pem}"
SFDK="$(kit_find_sfdk)" || SFDK=""

kit_detect_sdk

if (( STRICT_SDK && ! KIT_SDK_SUPPORTED && ! CHECK_ONLY )); then
	kit_die "Aurora SDK ${KIT_SDK_VERSION:-?} не входит в поддерживаемую серию ${SDK_SUPPORTED_PREFIX}x.
Установите SDK $SDK_DEFAULT_VERSION или уберите --strict-sdk."
fi

# ---------------------------------------------------------------------------
# Поиск устройства
# ---------------------------------------------------------------------------
device_lines() {
	[[ -n "$SFDK" ]] || return 0
	timeout 60 "$SFDK" device list 2>/dev/null || true
}

DEVICE_LIST="$(device_lines)"
if [[ -z "$DEVICE_NAME" ]]; then
	DEVICE_NAME="$(sed -n 's/^#[0-9][0-9]*[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' <<<"$DEVICE_LIST" | head -1)"
fi

# Блок `sfdk device list` для выбранного устройства: тип (эмулятор/устройство)
# и SSH endpoint берутся только из него.
device_section() {
	local name="$1"
	[[ -n "$name" ]] || return 0
	awk -v name="$name" '
		function flush() { if (hit) printf "%s", buf; buf = ""; hit = 0 }
		/^[[:space:]]*#[0-9]+/ {
			flush()
			buf = $0 "\n"
			if (index($0, "\"" name "\"") > 0) hit = 1
			next
		}
		{ buf = buf $0 "\n" }
		END { flush() }
	' <<<"$DEVICE_LIST"
}

DEVICE_SECTION="$(device_section "$DEVICE_NAME")"
SSH_ENDPOINT="$(grep -oE '[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[0-9]+' <<<"$DEVICE_SECTION" | head -1 || true)"

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
REMOTE_DIR="/home/$SSH_USER/Downloads"

IS_EMULATOR=0
if grep -qiE 'эмулятор|emulator' <<<"$DEVICE_SECTION"; then
	IS_EMULATOR=1
fi

is_local_host() {
	case "${SSH_HOST:-}" in
		127.0.0.1|localhost|::1) return 0 ;;
		*) return 1 ;;
	esac
}

if [[ -z "$EMULATOR_NAME" && -n "$SFDK" ]]; then
	EMULATOR_NAME="$(timeout 60 "$SFDK" emulator list 2>/dev/null | awk 'NF && $1 !~ /^\[/ { print $1; exit }' || true)"
fi

# ---------------------------------------------------------------------------
# Поиск RPM
# ---------------------------------------------------------------------------
newest_rpm_in() { # newest_rpm_in <dir>
	local dir="$1"
	[[ -d "$dir" ]] || return 0
	find "$dir" -maxdepth 1 -type f -name '*.rpm' -printf '%T@ %p\n' 2>/dev/null \
		| sort -n | tail -1 | cut -d' ' -f2- || true
}

find_rpm() {
	if [[ -n "$RPM_ARG" ]]; then
		[[ -f "$RPM_ARG" ]] || kit_die "RPM не найден: $RPM_ARG"
		kit_abspath "$RPM_ARG"
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
	[[ -n "$newest" ]] || return 1
	printf '%s\n' "$newest"
}

load_rpm_metadata() {
	RPM_PATH="$1"
	RPM_BASENAME="$(basename -- "$RPM_PATH")"
	kit_has rpm || kit_die "для определения имени и архитектуры пакета нужен rpm (rpm -qp)."
	PKG_FULL="$(rpm -qp --queryformat '%{NAME}' "$RPM_PATH" 2>/dev/null)" || PKG_FULL=""
	[[ -n "$PKG_FULL" ]] || kit_die "rpm не смог прочитать имя пакета из $RPM_BASENAME"
	RPM_ARCH="$(rpm -qp --queryformat '%{ARCH}' "$RPM_PATH" 2>/dev/null)" || RPM_ARCH=""
	[[ -n "$RPM_ARCH" ]] || kit_die "rpm не смог прочитать архитектуру $RPM_BASENAME"
	PKG_ORG="${PKG_FULL%.*}"
	PKG_APP="${PKG_FULL##*.}"
}

RPM_PATH=""
RPM_BASENAME=""
PKG_FULL=""
RPM_ARCH=""
PKG_ORG=""
PKG_APP=""
if RPM_PATH="$(find_rpm)"; then
	load_rpm_metadata "$RPM_PATH"
else
	RPM_PATH=""
fi

no_rpm_message() {
	kit_die "RPM не найден под $BUILD_DIR/rpmbuild/RPMS.
Сначала соберите пакет:
  ./godot-to-aurora/scripts/build_x86_64_rpm.sh     # эмулятор
  ./godot-to-aurora/scripts/build_aarch64_rpm.sh    # устройство
или передайте --rpm /path/to/package.rpm"
}

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if (( CHECK_ONLY )); then
	if [[ -n "$RPM_PATH" ]]; then
		printf 'RPM                %s (%s)\n' "$RPM_PATH" "$(du -h "$RPM_PATH" | cut -f1)"
		printf 'Пакет              %s (%s)\n' "$PKG_FULL" "$RPM_ARCH"
	else
		printf 'RPM                <не найден>\n'
	fi
	cat <<EOF
Устройство         ${DEVICE_NAME:-<нет>}
Эмулятор           ${EMULATOR_NAME:-<нет>} (локальный: $IS_EMULATOR)
SSH                ${SSH_USER}@${SSH_HOST:-<нет>}:${SSH_PORT:-<нет>} key=${SSH_KEY:-нет}
SDK build env      $(kit_sdk_description)
SDK version        ${KIT_SDK_VERSION:-<нет>} (supported ${SDK_SUPPORTED_PREFIX}*)
Ключ подписи       $KEY_PATH $([[ -f "$KEY_PATH" ]] && printf '(есть)' || printf '(нет)')
Сертификат подписи $CERT_PATH $([[ -f "$CERT_PATH" ]] && printf '(есть)' || printf '(нет)')
sfdk               ${SFDK:-НЕТ}
EOF
	if (( STRICT_SDK && ! KIT_SDK_SUPPORTED )); then
		exit 1
	fi
	exit 0
fi

[[ -n "$RPM_PATH" ]] || no_rpm_message

if (( ! SIGN_ONLY && IS_EMULATOR )) && [[ "$RPM_ARCH" != "x86_64" ]]; then
	kit_die "выбранный пакет собран для $RPM_ARCH, а эмулятору нужен x86_64:
  $RPM_PATH
Передайте --rpm $BUILD_DIR/rpmbuild/RPMS/x86_64/<pkg>.x86_64.rpm"
fi
if (( ! SIGN_ONLY && ! IS_EMULATOR )) && [[ "$RPM_ARCH" == "x86_64" ]]; then
	kit_warn "выбран x86_64-пакет, а реальному устройству нужен aarch64 (build_aarch64_rpm.sh)."
fi

if (( ! SIGN_ONLY )); then
	[[ -n "$SFDK" ]] || kit_die "sfdk не найден. Установите Aurora SDK и/или задайте AURORA_SDK_HOME / SFDK.
Без sfdk подпишите RPM вручную и установите его менеджером пакетов."
fi

# Пути в том виде, в котором их видит rpmsign-external: контейнер SDK 5.2
# видит только проект, смонтированный в /workspace; sb2 видит пути хоста.
mode_path() {
	if [[ "$KIT_SDK_MODE" == "docker" ]]; then
		kit_to_workspace_path "$1"
	else
		printf '%s\n' "$1"
	fi
}

# ---------------------------------------------------------------------------
# Запуск эмулятора
# ---------------------------------------------------------------------------
sfdk_cmd() {
	"$SFDK" -c device="$DEVICE_NAME" "$@"
}

device_ready() {
	timeout 25 "$SFDK" -c device="$DEVICE_NAME" device exec true >/dev/null 2>&1
}

ensure_kvm() {
	if [[ ! -e /dev/kvm ]]; then
		kit_err "/dev/kvm отсутствует. Эмулятор Aurora — QEMU/KVM."
		cat >&2 <<'EOF'
Загрузите модули KVM для вашего CPU:
  AMD:   sudo modprobe kvm && sudo modprobe kvm_amd
  Intel: sudo modprobe kvm && sudo modprobe kvm_intel
Если модулей нет, установите стек виртуализации для вашего дистрибутива.
EOF
		return 1
	fi
	if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
		kit_err "/dev/kvm недоступен на запись пользователю $(id -un)."
		cat >&2 <<'EOF'
Быстрое решение для текущей сессии:
  sudo setfacl -m u:$USER:rw /dev/kvm
Постоянное решение:
  sudo usermod -aG kvm,render "$USER"   # затем перелогиньтесь
EOF
		return 1
	fi
	return 0
}

if (( ! SIGN_ONLY )) && ! device_ready; then
	[[ -n "$DEVICE_NAME" ]] || kit_die "нет зарегистрированного устройства Aurora.
Запустите эмулятор: ~/AuroraOS/bin/sfdk emulator start <name>
Список устройств:   ~/AuroraOS/bin/sfdk device list"
	if (( START )) && (( IS_EMULATOR )); then
		ensure_kvm || kit_die "без доступа к KVM эмулятор не запустить."
		kit_log "запускаю эмулятор '${EMULATOR_NAME:-$DEVICE_NAME}'…"
		"$SFDK" emulator start "${EMULATOR_NAME:-$DEVICE_NAME}" || \
			kit_warn "sfdk emulator start вернул ошибку; всё равно ждём устройство."
		deadline=$((SECONDS + WAIT_SECONDS))
		while (( SECONDS < deadline )); do
			if device_ready; then break; fi
			printf '.'
			sleep 5
		done
		printf '\n'
		device_ready || kit_die "устройство недоступно за ${WAIT_SECONDS}s.
Проверьте окно эмулятора и выполните: sfdk device list"
		kit_ok "устройство доступно: $DEVICE_NAME"
	else
		kit_die "устройство '$DEVICE_NAME' недоступно (и задан --no-start или это не эмулятор)."
	fi
elif (( ! SIGN_ONLY )); then
	kit_ok "устройство доступно: $DEVICE_NAME"
fi

# ---------------------------------------------------------------------------
# Подпись
# ---------------------------------------------------------------------------
# Ключи копируются только во временный каталог внутри BUILD_DIR (его видит
# контейнер) и гарантированно удаляются при любом выходе.
SIGN_DIR=""
cleanup_signing() {
	if [[ -n "${SIGN_DIR:-}" ]]; then
		rm -rf -- "$SIGN_DIR"
		SIGN_DIR=""
	fi
}
trap cleanup_signing EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RPM_ABS="$(kit_abspath "$RPM_PATH")"
rpm_in_workspace="$(mode_path "$RPM_ABS")"

rpmsign_exec() {
	# rpmsign_exec <args...>; все пути уже должны быть видимы контейнеру.
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
	[[ -f "$KEY_PATH" ]] || kit_die "ключ подписи не найден: $KEY_PATH
Aurora SDK кладёт его в <SDK>/package-signing/regular_key.pem.
Передайте --skip-sign, чтобы поставить неподписанный пакет (APM его отвергнет)."
	[[ -f "$CERT_PATH" ]] || kit_die "сертификат подписи не найден: $CERT_PATH"

	if [[ "$KIT_SDK_MODE" == "docker" ]]; then
		if [[ "$rpm_in_workspace" == "$RPM_ABS" ]]; then
			kit_die "RPM должен находиться внутри проекта, иначе контейнер SDK его не увидит:
  $RPM_PATH
Соберите пакет внутри $PROJECT_ROOT/build/."
		fi
		if ! kit_path_inside "$BUILD_DIR" "$PROJECT_ROOT"; then
			kit_die "BUILD_DIR должен быть внутри проекта: контейнер SDK видит только $PROJECT_ROOT (/workspace)."
		fi
		mkdir -p "$BUILD_DIR"
		SIGN_DIR="$(mktemp -d "$BUILD_DIR/.signing.XXXXXX")"
		chmod 700 "$SIGN_DIR"
		install -m 600 "$KEY_PATH" "$SIGN_DIR/regular_key.pem"
		install -m 644 "$CERT_PATH" "$SIGN_DIR/regular_cert.pem"
		key_ref="$(kit_to_workspace_path "$SIGN_DIR/regular_key.pem")"
		cert_ref="$(kit_to_workspace_path "$SIGN_DIR/regular_cert.pem")"
	else
		key_ref="$KEY_PATH"
		cert_ref="$CERT_PATH"
	fi

	kit_log "подписываю $RPM_BASENAME тестовыми ключами SDK…"
	if ! rpmsign_exec sign -k "$key_ref" -c "$cert_ref" "$rpm_in_workspace"; then
		kit_die "rpmsign-external sign завершился ошибкой.
Частые причины:
  * самоподписанный openssl-сертификат (ошибка 'Failed to get certificate extensions');
    используйте regular_key.pem / regular_cert.pem из SDK;
  * RPM не под монтированием проекта (SDK 5.2 tools/run отдаёт его как /workspace)."
	fi

	if ! dump_output="$(rpmsign_exec dump "$rpm_in_workspace" 2>&1)"; then
		kit_err "rpmsign-external dump завершился ошибкой:"
		printf '%s\n' "$dump_output" >&2
		kit_die "не удалось проверить подпись; установка отменена."
	fi
	if grep -qiE 'no signatures found|not signed|unsigned' <<<"$dump_output"; then
		kit_err "rpmsign-external dump сообщает об отсутствии подписей:"
		printf '%s\n' "$dump_output" >&2
		kit_die "подпись не применилась; APM отвергнет такой пакет."
	fi
	if ! grep -qiE 'signature|rsa|pgp|gpg' <<<"$dump_output"; then
		kit_err "в выводе rpmsign-external dump нет признаков подписи:"
		printf '%s\n' "$dump_output" >&2
		kit_die "подпись не подтверждена; установка отменена."
	fi
	kit_ok "RPM подписан, подпись проверена."
else
	kit_warn "--skip-sign: пакет останется неподписанным, APM, скорее всего, его отвергнет."
fi

if (( SIGN_ONLY )); then
	kit_ok "режим --sign-only: готово."
	exit 0
fi

# ---------------------------------------------------------------------------
# Копирование на устройство
# ---------------------------------------------------------------------------
DEVICE_RPM_PATH="$REMOTE_DIR/$RPM_BASENAME"

copy_to_device() {
	local -a ssh_opts=(-o ConnectTimeout=15)
	[[ -f "$SSH_KEY" ]] || return 1
	[[ -n "$SSH_HOST" && -n "$SSH_PORT" ]] || return 1
	# Ослабленная проверка ключа хоста — только для локального эмулятора.
	if (( IS_EMULATOR )) && is_local_host; then
		ssh_opts+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
	fi
	kit_log "копирую $RPM_BASENAME на ${SSH_USER}@${SSH_HOST}:${SSH_PORT}:$REMOTE_DIR/"
	scp -q -P "$SSH_PORT" -i "$SSH_KEY" "${ssh_opts[@]}" \
		"$RPM_PATH" "${SSH_USER}@${SSH_HOST}:$REMOTE_DIR/"
}

if ! copy_to_device; then
	if (( IS_EMULATOR )); then
		kit_die "не удалось скопировать RPM через scp.
Проверьте ключ SSH: ${SSH_KEY:-<не найден>}
Переопределяется AURORA_SSH_HOST / AURORA_SSH_PORT / AURORA_SSH_KEY."
	fi
	kit_log "нет SSH-ключа для устройства; использую 'sfdk deploy --manual'"
	sfdk_cmd deploy --manual "$RPM_PATH" || kit_warn "sfdk deploy --manual вернул ошибку."
	DEVICE_RPM_PATH="/home/$SSH_USER/RPMS/$RPM_BASENAME"
fi

# ---------------------------------------------------------------------------
# Установка через ru.omp.APM
# ---------------------------------------------------------------------------
kit_log "запрашиваю установку через ru.omp.APM…"
prompt_value="<true>"
(( SHOW_PROMPT )) || prompt_value="<false>"
if ! sfdk_cmd device exec gdbus call -y -d ru.omp.APM -o /ru/omp/APM \
	-m ru.omp.APM.Install "$DEVICE_RPM_PATH" "{'ShowPrompt': $prompt_value}"; then
	kit_die "запрос установки в APM завершился ошибкой.
Пакет должен быть подписан доверенным сертификатом и доступен defaultuser:
  $DEVICE_RPM_PATH"
fi

if (( SHOW_PROMPT )); then
	kit_info "подтвердите диалог установки на экране эмулятора."
fi

kit_log "жду появления пакета $PKG_FULL (до ${INSTALL_WAIT}s)…"
installed=""
deadline=$((SECONDS + INSTALL_WAIT))
while (( SECONDS < deadline )); do
	installed="$(sfdk_cmd device exec rpm -q "$PKG_FULL" 2>/dev/null | tr -d '\r' | tail -1 || true)"
	[[ -n "$installed" && "$installed" == "$PKG_FULL"* ]] && break
	sleep 3
done
if [[ -n "$installed" && "$installed" == "$PKG_FULL"* ]]; then
	kit_ok "установлен: $installed"
else
	kit_err "пакет пока не установлен."
	cat >&2 <<EOF
Если менеджер пакетов показал ошибку, проверьте:
  sfdk device exec journalctl -n 200 --no-pager | grep -i -E 'apm|rpm|sign'

Убедитесь, что пакет на месте:
  sfdk device exec ls -l "$DEVICE_RPM_PATH"
EOF
	exit 1
fi

# ---------------------------------------------------------------------------
# Подсказки и логи
# ---------------------------------------------------------------------------
cat <<EOF

Установка завершена.

КАК ПРОВЕРИТЬ
  1. Откройте меню приложений в эмуляторе и запустите "$PKG_FULL".
     Запуск из меню обязателен для Sailjail и ориентации приложения.
  2. Игра должна стартовать в заданной ориентации без ошибок Wayland/EGL.
  3. Сверните приложение: игра должна встать на паузу, замьютить звук и
     сохраниться в:
       /home/$SSH_USER/.local/share/$PKG_ORG/$PKG_APP/
  4. Логи:
       sfdk -c device="$DEVICE_NAME" device exec journalctl -f -t "$PKG_FULL"

Удаление:
  sfdk -c device="$DEVICE_NAME" device exec gdbus call -y -d ru.omp.APM -o /ru/omp/APM \\
    -m ru.omp.APM.Uninstall "$PKG_FULL" '{}'
EOF

if (( FOLLOW_LOGS )); then
	kit_log "слежу за логами $PKG_FULL (Ctrl+C — остановить)…"
	sfdk_cmd device exec journalctl -f -t "$PKG_FULL"
fi

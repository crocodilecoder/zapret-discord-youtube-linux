#!/usr/bin/env bash
# common.sh - общие функции для всех скриптов порта; сам не запускается
# shellcheck disable=SC2034

# пути
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$ROOT_DIR"
BIN_DIR="$ROOT_DIR/bin"
LISTS_DIR="${ZAPRET_LISTS_DIR:-$ROOT_DIR/lists}"
UTILS_DIR="${ZAPRET_UTILS_DIR:-$ROOT_DIR/utils}"

NFQWS_BIN="${ZAPRET_NFQWS:-$BIN_DIR/nfqws}"

# каталог для pidfile; в тестах переопределяется через ZAPRET_RUN_DIR
RUN_DIR="${ZAPRET_RUN_DIR:-/run/zapret-dy}"
PIDFILE="$RUN_DIR/zapret.pid"
STRATEGY_STATE_FILE="$RUN_DIR/strategy"

# номер nfqueue; на винде очереди нет вообще, там пакеты ловит windivert
ZAPRET_QNUM="${ZAPRET_QNUM:-200}"

# порты, которые уходят в nfqueue - те же, что были в --wf-tcp/--wf-udp,
# сверху добавляется диапазон игрового фильтра
ZAPRET_TCP_PORTS_BASE="${ZAPRET_TCP_PORTS_BASE:-80,443,2053,2083,2087,2096,8443}"
ZAPRET_UDP_PORTS_BASE="${ZAPRET_UDP_PORTS_BASE:-443,19294-19344,50000-50100}"

# версия стратегий upstream (как LOCAL_VERSION в service.bat)
LOCAL_VERSION_FILE="$ROOT_DIR/.service/version.txt"
# списки и версии приезжают из upstream-репозитория; своим форкам можно
# переопределить владельца/репо через ZAPRET_UPSTREAM_OWNER/REPO
UPSTREAM_OWNER="${ZAPRET_UPSTREAM_OWNER:-Flowseal}"
UPSTREAM_REPO="${ZAPRET_UPSTREAM_REPO:-zapret-discord-youtube}"
# а версия порта смотрится в том репозитории, откуда склонирован этот код
# (git remote origin); нет гита - env ZAPRET_SELF_OWNER/REPO или дефолт
SELF_OWNER="${ZAPRET_SELF_OWNER:-crocodilecoder}"
SELF_REPO="${ZAPRET_SELF_REPO:-zapret-discord-youtube-linux}"
self_repo() {
	local url path
	url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null)" || url=""
	url="${url%.git}"
	case "$url" in
		git@github.com:*)  path="${url#git@github.com:}" ;;
		*://*github.com/*) path="${url#*github.com/}" ;;
		*)                 path="" ;;
	esac
	if [ -n "$path" ] && [[ "$path" == */* ]]; then
		printf '%s' "$path"
	else
		printf '%s/%s' "$SELF_OWNER" "$SELF_REPO"
	fi
}
IPSET_SERVICE_URL="${ZAPRET_IPSET_URL:-https://raw.githubusercontent.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/refs/heads/main/.service/ipset-service.txt}"
HOSTS_SERVICE_URL="${ZAPRET_HOSTS_URL:-https://raw.githubusercontent.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/refs/heads/main/.service/hosts}"

# цветной вывод; в bat за это отвечали PrintGreen/PrintRed/PrintYellow
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
	C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'; C_RESET=$'\033[0m'
else
	C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_GRAY=""; C_RESET=""
fi

print_green()  { printf '%s\n' "${C_GREEN}$*${C_RESET}"; }
print_red()    { printf '%s\n' "${C_RED}$*${C_RESET}"; }
print_yellow() { printf '%s\n' "${C_YELLOW}$*${C_RESET}"; }
print_cyan()   { printf '%s\n' "${C_CYAN}$*${C_RESET}"; }
print_gray()   { printf '%s\n' "${C_GRAY}$*${C_RESET}"; }

# pause как в bat-никах: в терминале ждём enter, в скриптах просто идём дальше
pause() {
	if [ -t 0 ]; then
		printf 'Press ENTER to continue...'
		IFS= read -r _ || true
	else
		printf '\n'
	fi
}

require_root() {
	if [ "$(id -u)" != "0" ]; then
		print_red "[ERROR] root privileges are required (run with sudo)."
		return 1
	fi
	return 0
}

have_systemd() {
	command -v systemctl >/dev/null 2>&1 && [ -d "${ZAPRET_SYSTEMD_DIR:-/run/systemd/system}" ]
}

local_version() {
	# upstream (Flowseal) strategies version - .service/version.txt
	if [ -f "$LOCAL_VERSION_FILE" ]; then
		tr -d ' \r\n' < "$LOCAL_VERSION_FILE"
	else
		printf 'unknown'
	fi
}

port_version() {
	# this Linux port's own version - VERSION file
	if [ -f "$ROOT_DIR/VERSION" ]; then
		tr -d ' \r\n' < "$ROOT_DIR/VERSION"
	else
		printf 'unknown'
	fi
}

# качалка: curl, а если его нет - wget
http_fetch() {
	local url="$1" out="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -L -f -sS --connect-timeout 10 --max-time 60 -o "$out" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T 30 -O "$out" "$url"
	else
		print_red "[ERROR] neither curl nor wget found. Install one of them."
		return 1
	fi
}

# пользовательские списки (в service.bat - :load_user_lists)
load_user_lists() {
	local lists_path="$LISTS_DIR"
	mkdir -p "$lists_path"
	if [ ! -f "$lists_path/ipset-exclude-user.txt" ]; then
		echo "203.0.113.113/32" > "$lists_path/ipset-exclude-user.txt"
	fi
	if [ ! -f "$lists_path/list-general-user.txt" ]; then
		{
			echo "# Never leave this file empty"
			echo "domain.example.abc"
		} > "$lists_path/list-general-user.txt"
	fi
	if [ ! -f "$lists_path/list-exclude-user.txt" ]; then
		echo "domain.example.abc" > "$lists_path/list-exclude-user.txt"
	fi
}

# игровой фильтр, читается из utils/game_filter.enabled
gf_validate_item() {
	# $1 - single port or range, e.g. "443" or "1024-1934"
	local item="$1" start end
	[[ "$item" =~ ^[1-9][0-9]*(-[1-9][0-9]*)?$ ]] || return 1
	start="${item%%-*}"
	if [[ "$item" == *-* ]]; then
		end="${item#*-}"
	else
		end="$start"
	fi
	[ "${#start}" -le 5 ] && [ "${#end}" -le 5 ] || return 1
	[ "$start" -le 65535 ] && [ "$end" -le 65535 ] || return 1
	[ "$start" -le "$end" ] || return 1
	return 0
}

gf_validate_range() {
	# $1 - comma separated list of ports/ranges. Prints normalized range.
	local range="${1// /}" item
	[ -n "$range" ] || return 1
	IFS=',' read -ra items <<< "$range"
	for item in "${items[@]}"; do
		gf_validate_item "$item" || return 1
	done
	printf '%s' "$range"
	return 0
}

load_game_filter() {
	local flag_file="$UTILS_DIR/game_filter.enabled"
	GF_MODE="disabled"
	GF_TCP_RANGE="1024-65535"
	GF_UDP_RANGE="1024-65535"
	GF_STATUS="disabled"
	GF_TCP="12"
	GF_UDP="12"

	[ -f "$flag_file" ] || return 0

	local line key val tcp_cand="" udp_cand="" v
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%%$'\r'}"
		key="${line%%=*}"
		val="${line#*=}"
		case "$key" in
			[Mm][Oo][Dd][Ee]) GF_MODE="$val" ;;
			[Aa][Ll][Ll])     GF_MODE="all" ;;
			[Uu][Dd][Pp])     if [ -z "$val" ] || [ "$val" = "$key" ]; then GF_MODE="udp"; else udp_cand="$val"; fi ;;
			[Tt][Cc][Pp])     if [ -z "$val" ] || [ "$val" = "$key" ]; then GF_MODE="tcp"; else tcp_cand="$val"; fi ;;
		esac
	done < "$flag_file"

	if v="$(gf_validate_range "$tcp_cand")"; then GF_TCP_RANGE="$v"; fi
	if v="$(gf_validate_range "$udp_cand")"; then GF_UDP_RANGE="$v"; fi

	case "$(printf '%s' "$GF_MODE" | tr '[:upper:]' '[:lower:]')" in
		all)
			GF_STATUS="enabled (TCP and UDP)"
			GF_TCP="$GF_TCP_RANGE"; GF_UDP="$GF_UDP_RANGE" ;;
		tcp)
			GF_STATUS="enabled (TCP)"
			GF_TCP="$GF_TCP_RANGE"; GF_UDP="12" ;;
		udp)
			GF_STATUS="enabled (UDP)"
			GF_TCP="12"; GF_UDP="$GF_UDP_RANGE" ;;
		*)
			GF_MODE="disabled"
			GF_STATUS="disabled"
			GF_TCP="12"; GF_UDP="12" ;;
	esac
	return 0
}

save_game_filter_settings() {
	mkdir -p "$UTILS_DIR"
	{
		echo "mode=$GF_MODE"
		echo "tcp=$GF_TCP_RANGE"
		echo "udp=$GF_UDP_RANGE"
	} > "$UTILS_DIR/game_filter.enabled"
}

# Full port lists for the firewall (base ports + game filter range),
# same as --wf-tcp/--wf-udp in the bat files.
zapret_tcp_ports() { load_game_filter; printf '%s,%s' "$ZAPRET_TCP_PORTS_BASE" "$GF_TCP"; }
zapret_udp_ports() { load_game_filter; printf '%s,%s' "$ZAPRET_UDP_PORTS_BASE" "$GF_UDP"; }

# статус ipset-списка: loaded / none / any
ipset_status() {
	local list_file="$LISTS_DIR/ipset-all.txt"
	if [ ! -f "$list_file" ] || [ ! -s "$list_file" ]; then
		printf 'any'
	elif grep -qF '203.0.113.113/32' "$list_file"; then
		printf 'none'
	else
		printf 'loaded'
	fi
}

# какая стратегия поставлена; в винде это лежало в реестре,
strategy_get() {
	if [ -f "$STRATEGY_STATE_FILE" ]; then
		cat "$STRATEGY_STATE_FILE"
	fi
}

strategy_set() {
	ensure_run_dir
	printf '%s\n' "$1" > "$STRATEGY_STATE_FILE"
}

# nfqws после старта сбрасывает capabilities (включая CAP_DAC_OVERRIDE) и
# дальше ходит по диску по обычным правам, даже оставаясь root. если проект
# лежит в домашнем каталоге с правами 700 (дефолт многих дистров), списки
# не прочитаются. добавляем каталогам пути o+x - только проход, без листинга
ensure_traverse() {
	local dir="$1" p="" part m o
	dir="$(cd "$dir" 2>/dev/null && pwd)" || return 0
	IFS='/' read -ra parts <<< "$dir"
	for part in "${parts[@]}"; do
		[ -n "$part" ] || continue
		p="$p/$part"
		[ -d "$p" ] || continue
		m="$(stat -c '%a' "$p" 2>/dev/null)" || continue
		o="${m: -1}"
		if [ $((o & 1)) -ne 1 ]; then
			if chmod o+x "$p" 2>/dev/null; then
				print_yellow "chmod o+x $p  (nfqws после сброса caps иначе не прочитает списки)"
			fi
		fi
	done
}

ensure_run_dir() {
	mkdir -p "$RUN_DIR" 2>/dev/null || return 1
	chmod 777 "$RUN_DIR" 2>/dev/null || true   # pidfile пишется уже после сброса caps
}

# процесс nfqws: старт/стоп/проверки
# kill -0 врёт на зомби-процессах (в контейнерах без reaper они висят вечно),
# поэтому живость проверяем ещё и по состоянию в /proc
pid_alive() {
	local pid="$1" st
	[ -n "$pid" ] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	[ -r "/proc/$pid/stat" ] || return 0   # no procfs: trust kill -0
	st="$(cut -d' ' -f3 "/proc/$pid/stat" 2>/dev/null)"
	[ "$st" != "Z" ]
}

# живые pid-ы nfqws, зомби не считаем
list_pids() {
	local pid
	for pid in $(pgrep -x nfqws 2>/dev/null); do
		if pid_alive "$pid"; then printf '%s\n' "$pid"; fi
	done
}

nfqws_pid() {
	local pid
	if [ -f "$PIDFILE" ]; then
		pid="$(cat "$PIDFILE" 2>/dev/null)"
		if pid_alive "$pid"; then
			printf '%s' "$pid"
			return 0
		fi
	fi
	# pidfile нет или протух - ищем процесс руками, как tasklist в винде
	list_pids | head -n1
}

nfqws_is_running() {
	[ -n "$(nfqws_pid)" ]
}

nfqws_stop() {
	local pid
	pid="$(nfqws_pid)"
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null
		local i=0
		while [ $i -lt 25 ] && pid_alive "$pid"; do
			sleep 0.2
			i=$((i+1))
		done
		kill -9 "$pid" 2>/dev/null || true
	fi
	# kill anything left (matches taskkill /IM winws.exe /F)
	pkill -x nfqws 2>/dev/null || true
	rm -f "$PIDFILE"
}

# run_nfqws <strategy-name> <args...>
# Foreground run - port of `start "zapret: %~n0" /min winws.exe ...`.
# Ctrl+C stops it, just like closing the minimized window on Windows.
run_nfqws() {
	local strategy="$1"; shift
	if nfqws_is_running; then
		print_yellow "[!] nfqws is already running (pid $(nfqws_pid)). Stop it first:"
		print_yellow "    sudo $ROOT_DIR/service.sh stop"
		return 1
	fi
	if [ ! -x "$NFQWS_BIN" ]; then
		print_red "[ERROR] nfqws binary not found at $NFQWS_BIN"
		print_red "        Run ./install.sh first (it builds/downloads nfqws for Linux)."
		return 1
	fi
	load_game_filter
	load_user_lists
	ensure_traverse "$ROOT_DIR"
	ensure_traverse "$LISTS_DIR"
	ensure_traverse "$BIN_DIR"

	local fw_status
	fw_status="$("$ROOT_DIR/firewall.sh" status-quiet 2>/dev/null)" || fw_status="inactive"
	if [ "$fw_status" != "active" ]; then
		print_yellow "[!] Firewall rules are not active - traffic will NOT reach nfqws."
		print_yellow "    Apply them with: sudo $ROOT_DIR/firewall.sh start"
		print_yellow "    (or install as a service: sudo $ROOT_DIR/service.sh install)"
	fi

	strategy_set "$strategy"

	# nfqws по умолчанию сбрасывает root на uid 0x7FFFFFFF и после этого
	# не может читать списки из домашнего каталога (Permission denied).
	# winws в винде крутился под SYSTEM, так что и тут остаёмся под root;
	# кому хочется дроп привилегий - ZAPRET_DROP_ROOT=1 и доступные всем списки
	local drop_args=()
	if [ "${ZAPRET_DROP_ROOT:-0}" != "1" ]; then
		drop_args=(--uid=0:0)
	fi

	if [ "${ZAPRET_DAEMON:-0}" = "1" ]; then
		# фоновый режим для службы
		ensure_run_dir
		# без этого фейки уходят не с того интерфейса, на линуксе обязательные флаги
		"$NFQWS_BIN" --qnum="$ZAPRET_QNUM" --bind-fix4 --bind-fix6 "${drop_args[@]}" \
			--daemon --pidfile="${ZAPRET_PIDFILE:-$PIDFILE}" "$@"
		return $?
	fi

	print_cyan "=== zapret: $strategy (nfqws, queue $ZAPRET_QNUM) ==="
	print_gray "Game filter: $GF_STATUS   ipset: $(ipset_status)"
	print_gray "Press Ctrl+C to stop."
	echo

	# без этого фейки уходят не с того интерфейса, на линуксе обязательные флаги
	exec "$NFQWS_BIN" --qnum="$ZAPRET_QNUM" --bind-fix4 --bind-fix6 "${drop_args[@]}" "$@"
}

# start_daemon <strategy-file.sh> - background start used by systemd/service
start_daemon() {
	local script="$1"
	if nfqws_is_running; then
		print_yellow "nfqws is already running (pid $(nfqws_pid))."
		return 0
	fi
	ensure_run_dir
	# ZAPRET_DAEMON=1 makes strategy scripts run nfqws with --daemon --pidfile
	ZAPRET_DAEMON=1 ZAPRET_PIDFILE="$PIDFILE" "$script" >/dev/null 2>&1
	sleep 1
	if nfqws_is_running; then
		print_green "zapret started (pid $(nfqws_pid))."
		return 0
	fi
	print_red "[ERROR] failed to start nfqws. Try running the strategy script manually."
	return 1
}

# проверка обновлений репозитория
check_updates() {
	local mode="${1:-hard}"
	[ -n "${NO_UPDATE_CHECK:-}" ] && return 0
	[ -f "$UTILS_DIR/check_updates.enabled" ] || return 0

	local tmp remote="" branch url
	tmp="$(mktemp)"
	if [ -n "${ZAPRET_VERSION_URL:-}" ]; then
		http_fetch "$ZAPRET_VERSION_URL" "$tmp" 2>/dev/null && remote="$(tr -d ' \r\n' < "$tmp")"
	else
		for branch in ${ZAPRET_SELF_BRANCH:-main master}; do
			url="https://raw.githubusercontent.com/$(self_repo)/${branch}/VERSION"
			if http_fetch "$url" "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
				remote="$(tr -d ' \r\n' < "$tmp")"
				break
			fi
		done
	fi
	rm -f "$tmp"

	if [ -z "$remote" ]; then
		if [ "$mode" != "soft" ]; then
			print_yellow "Warning: failed to fetch the latest version. This warning does not affect the operation of zapret"
		fi
		return 0
	fi

	local local_v
	local_v="$(port_version)"
	if [ "$local_v" = "$remote" ]; then
		[ "$mode" != "soft" ] && print_green "Latest version installed: $local_v"
	else
		print_yellow "New version available: $remote (local: $local_v)"
		print_yellow "Release page: https://github.com/$(self_repo)/releases/tag/$remote"
		if [ "$mode" != "soft" ]; then
			print_yellow "Download page: https://github.com/$(self_repo)/releases/latest"
			if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
				xdg-open "https://github.com/$(self_repo)/releases/latest" >/dev/null 2>&1 || true
			fi
		fi
	fi
	return 0
}

# tcp timestamps: в винде netsh, тут sysctl
tcp_enable() {
	local cur
	cur="$(cat /proc/sys/net/ipv4/tcp_timestamps 2>/dev/null || echo 1)"
	if [ "$cur" != "1" ]; then
		if command -v sysctl >/dev/null 2>&1; then
			sysctl -w net.ipv4.tcp_timestamps=1 >/dev/null 2>&1 || true
		fi
	fi
}

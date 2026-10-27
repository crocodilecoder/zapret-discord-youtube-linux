#!/usr/bin/env bash
# test_zapret.sh - прогон всех стратегий с проверками, аналог utils/test zapret.ps1.
# standard: http/tls1.2/tls1.3/ping по целям из utils/targets.txt
# dpi: чекаем freeze 16-20kb постом на 64k
# отчёты складываются в "utils/test results/".
# для неинтерактивного запуска: ZAPRET_TEST_TYPE, ZAPRET_TEST_MODE, ZAPRET_TEST_CONFIGS
set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./common.sh

RESULTS_DIR="$UTILS_DIR/test results"
mkdir -p "$RESULTS_DIR"

IPSET_FLAG_FILE="$ROOT_DIR/ipset_switched.flag"
IPSET_LIST="$LISTS_DIR/ipset-all.txt"
IPSET_TEST_BACKUP="$LISTS_DIR/ipset-all.test-backup.txt"

CURL_TIMEOUT="${TEST_CURL_TIMEOUT:-4}"
DPI_TIMEOUT="${MONITOR_TIMEOUT:-5}"
DPI_RANGE="${MONITOR_RANGE:-65536}"
DPI_CUSTOM_HOST="${MONITOR_HOST:-}"
NPROC="$(nproc 2>/dev/null || echo 2)"
MAX_PARALLEL_DEFAULT=$(( NPROC * 2 )); [ "$MAX_PARALLEL_DEFAULT" -lt 8 ] && MAX_PARALLEL_DEFAULT=8; [ "$MAX_PARALLEL_DEFAULT" -gt 16 ] && MAX_PARALLEL_DEFAULT=16
DPI_MAX_PARALLEL="${MONITOR_MAX_PARALLEL:-$MAX_PARALLEL_DEFAULT}"
STD_MAX_PARALLEL="${TEST_MAX_PARALLEL:-$MAX_PARALLEL_DEFAULT}"

# ipset на время dpi-тестов переключаем в any и возвращаем назад
set_ipset_mode() {
	local mode="$1"
	if [ "$mode" = "any" ]; then
		if [ -f "$IPSET_LIST" ]; then
			cp -f "$IPSET_LIST" "$IPSET_TEST_BACKUP"
		else
			: > "$IPSET_TEST_BACKUP"
		fi
		: > "$IPSET_LIST"
	elif [ "$mode" = "restore" ]; then
		if [ -f "$IPSET_TEST_BACKUP" ]; then
			mv -f "$IPSET_TEST_BACKUP" "$IPSET_LIST"
		fi
	fi
}

cleanup_restore() {
	print_gray "[INFO] Cleaning up..."
	stop_all_nfqws
	if [ -n "${ORIGINAL_SNAPSHOT:-}" ] && [ -f "$ORIGINAL_SNAPSHOT" ]; then
		restore_nfqws_snapshot "$ORIGINAL_SNAPSHOT"
		rm -f "$ORIGINAL_SNAPSHOT"
	fi
	if [ -n "${ORIGINAL_IPSET:-}" ] && [ "$ORIGINAL_IPSET" != "any" ] && [ -f "$IPSET_TEST_BACKUP" ]; then
		print_gray "[INFO] Restoring original ipset mode..."
		set_ipset_mode restore
	fi
	rm -f "$IPSET_FLAG_FILE"
	rm -rf "$WORK_DIR"
}

wait_nfqws_ready() {
	# port of Wait-WinwsReady: up to 5 seconds
	local i=0
	while [ $i -lt 25 ]; do
		if [ -n "$(list_pids)" ]; then
			sleep 0.3
			return 0
		fi
		sleep 0.2
		i=$((i+1))
	done
	return 1
}

stop_all_nfqws() {
	# port of Stop-Zapret (taskkill winws)
	pkill -x nfqws 2>/dev/null || true
	sleep 0.3
	pkill -9 -x nfqws 2>/dev/null || true
}

# winws snapshot/restore (port of Get-WinwsSnapshot / Restore-WinwsSnapshot):
get_nfqws_snapshot() {
	local snap_file="$1" pid exe args
	: > "$snap_file"
	for pid in $(pgrep -x nfqws 2>/dev/null); do
		pid_alive "$pid" || continue
		# argv[0] из cmdline точнее: /proc/exe резолвит симлинки,
		# и мы потеряли бы имя процесса (mock лежит за симлинком)
		argv0="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -n1)"
		if [ -n "$argv0" ] && [ -x "$argv0" ]; then
			exe="$argv0"
		else
			exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)" || continue
		fi
		args="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | tail -n +2)" || continue
		{
			echo "$exe"
			echo "$args"
			echo "---"
		} >> "$snap_file"
	done
}

restore_nfqws_snapshot() {
	local snap_file="$1"
	[ -s "$snap_file" ] || return 0
	print_gray "[INFO] Restoring previously running nfqws instances..."
	local exe="" args="" line
	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$line" = "---" ]; then
			if [ -n "$exe" ] && [ -x "$exe" ]; then
				# --daemon не дописываем: в cmdline он и так есть, если
				# процесс работал демоном (а у фейков там свои аргументы)
				# shellcheck disable=SC2086
				( "$exe" $args >/dev/null 2>&1 & ) || true
			fi
			exe=""; args=""
		elif [ -z "$exe" ]; then
			exe="$line"
		else
			args="$args $line"
		fi
	done < "$snap_file"
}

# разбор targets.txt: Name = "url" или Name = "PING:ip"
declare -a TARGET_NAMES=() TARGET_URLS=() TARGET_PINGS=()

load_targets() {
	local targets_file="$UTILS_DIR/targets.txt"
	local raw_lines=()
	if [ -f "$targets_file" ]; then
		while IFS= read -r line; do
			line="${line%%$'\r'}"
			[[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*\"(.+)\"[[:space:]]*$ ]] || continue
			raw_lines+=("${BASH_REMATCH[1]}=${BASH_REMATCH[2]}")
		done < "$targets_file"
	fi
	if [ "${#raw_lines[@]}" -eq 0 ]; then
		print_gray "[INFO] targets.txt missing or empty. Using defaults."
		raw_lines=(
			"Discord Main=https://discord.com"
			"Discord Gateway=https://gateway.discord.gg"
			"Discord CDN=https://cdn.discordapp.com"
			"Discord Updates=https://updates.discord.com"
			"YouTube Web=https://www.youtube.com"
			"YouTube Short=https://youtu.be"
			"YouTube Image=https://i.ytimg.com"
			"YouTube Video Redirect=https://redirector.googlevideo.com"
			"Google Main=https://www.google.com"
			"Google Gstatic=https://www.gstatic.com"
			"Cloudflare Web=https://www.cloudflare.com"
			"Cloudflare CDN=https://cdnjs.cloudflare.com"
			"Cloudflare DNS 1.1.1.1=PING:1.1.1.1"
			"Cloudflare DNS 1.0.0.1=PING:1.0.0.1"
			"Google DNS 8.8.8.8=PING:8.8.8.8"
			"Google DNS 8.8.4.4=PING:8.8.4.4"
			"Quad9 DNS 9.9.9.9=PING:9.9.9.9"
		)
	else
		print_gray "[INFO] Loaded targets from targets.txt"
		print_gray "[INFO] Targets loaded: ${#raw_lines[@]}"
	fi

	local entry name value host
	for entry in "${raw_lines[@]}"; do
		name="${entry%%=*}"
		value="${entry#*=}"
		if [[ "$value" == PING:* ]]; then
			TARGET_NAMES+=("$name")
			TARGET_URLS+=("")
			TARGET_PINGS+=("${value#PING:}")
		else
			host="${value#http://}"; host="${host#https://}"; host="${host%%/*}"
			TARGET_NAMES+=("$name")
			TARGET_URLS+=("$value")
			TARGET_PINGS+=("$host")
		fi
	done
}

# проверка одной цели: три curl-запроса + ping
test_one_target() {
	# $1 - index; writes result lines to $WORK_DIR/std/$1
	local idx="$1"
	local name="${TARGET_NAMES[$idx]}" url="${TARGET_URLS[$idx]}" pingt="${TARGET_PINGS[$idx]}"
	local out="$WORK_DIR/std/$idx"
	local http_tokens=""

	if [ -n "$url" ]; then
		local label extra code rc stderr_file o
		stderr_file="$WORK_DIR/std/$idx.err"
		for label in HTTP TLS1.2 TLS1.3; do
			case "$label" in
				HTTP)   extra=(--http1.1) ;;
				TLS1.2) extra=(--tlsv1.2 --tls-max 1.2) ;;
				TLS1.3) extra=(--tlsv1.3 --tls-max 1.3) ;;
			esac
			o="$(curl -I -s -m "$CURL_TIMEOUT" --connect-timeout 2 -o /dev/null \
				-w '%{http_code}' --show-error "${extra[@]}" "$url" 2>"$stderr_file")"
			rc=$?
			code="$(printf '%s' "$o" | tr -d ' \n')"
			if grep -qiE 'Could not resolve host|certificate|SSL certificate problem|self[- ]?signed|certificate verify failed|unable to get local issuer' "$stderr_file" 2>/dev/null; then
				http_tokens="$http_tokens $label:SSL"
			elif [ "$rc" = "35" ] || grep -qiE 'not supported|unsupported|Unknown option' "$stderr_file" 2>/dev/null; then
				http_tokens="$http_tokens $label:UNSUP"
			elif [ "$rc" = "0" ]; then
				http_tokens="$http_tokens $label:OK"
			else
				http_tokens="$http_tokens $label:ERROR"
			fi
		done
		rm -f "$stderr_file"
	fi

	local ping_result="n/a"
	if [ -n "$pingt" ] && command -v ping >/dev/null 2>&1; then
		if ping -c1 -W1 "$pingt" >/dev/null 2>&1; then
			ping_result="OK"
		else
			ping_result="Timeout"
		fi
	elif [ -n "$pingt" ]; then
		# no ping utility: try a TCP connect for URL targets
		ping_result="n/a"
	fi

	local isurl=0
	[ -n "$url" ] && isurl=1
	{
		echo "NAME=$name"
		echo "TOKENS=$http_tokens"
		echo "PING=$ping_result"
		echo "ISURL=$isurl"
	} > "$out"
}

# dpi-часть: цели из suite hyperion-cs/dpi-checkers
dpi_fetch_targets() {
	# fills DPI_IDS, DPI_PROVIDERS, DPI_COUNTRIES, DPI_HOSTS
	local url="https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json"
	local tmp="$WORK_DIR/suite.json"
	if [ -n "$DPI_CUSTOM_HOST" ]; then
		DPI_IDS=("CUSTOM"); DPI_PROVIDERS=("Custom"); DPI_COUNTRIES=("💡"); DPI_HOSTS=("$DPI_CUSTOM_HOST")
		return 0
	fi
	if ! http_fetch "$url" "$tmp" 2>/dev/null || ! command -v python3 >/dev/null 2>&1; then
		print_yellow "[WARN] Fetch dpi suite failed."
		return 1
	fi
	local parsed
	parsed="$(python3 - "$tmp" <<'EOF'
import json,sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for e in data:
    print("\t".join([str(e.get("id","")), str(e.get("provider","")), str(e.get("country","")), str(e.get("host",""))]))
EOF
)" || return 1
	DPI_IDS=(); DPI_PROVIDERS=(); DPI_COUNTRIES=(); DPI_HOSTS=()
	while IFS=$'\t' read -r id prov country host; do
		[ -z "$id" ] && continue
		DPI_IDS+=("$id"); DPI_PROVIDERS+=("$prov"); DPI_COUNTRIES+=("$country"); DPI_HOSTS+=("$host")
	done <<< "$parsed"
	return 0
}

dpi_test_one() {
	# $1 - index; writes results to $WORK_DIR/dpi/$1
	local idx="$1"
	local id="${DPI_IDS[$idx]}" provider="${DPI_PROVIDERS[$idx]}" country="${DPI_COUNTRIES[$idx]}" host="${DPI_HOSTS[$idx]}"
	local out="$WORK_DIR/dpi/$idx"
	local payload_file="$WORK_DIR/payload.bin"
	local range_spec="0-$((DPI_RANGE-1))"
	local warned=0

	echo "TARGET=$id|$provider|$country|$host" > "$out"

	local label extra res rc code up down time status
	for label in HTTP TLS1.2 TLS1.3; do
		case "$label" in
			HTTP)   extra=(--http1.1) ;;
			TLS1.2) extra=(--tlsv1.2 --tls-max 1.2) ;;
			TLS1.3) extra=(--tlsv1.3 --tls-max 1.3) ;;
		esac
		res="$(curl --range "$range_spec" -m "$DPI_TIMEOUT" --connect-timeout 3 \
			-w '%{http_code} %{size_upload} %{size_download} %{time_total}' \
			-o /dev/null -X POST --data-binary "@$payload_file" -s \
			"${extra[@]}" "https://$host" 2>"$out.err")"
		rc=$?
		code="NA"; up=0; down=0; time="-1"
		if [[ "$res" =~ ^([0-9]{3})\ ([0-9]+)\ ([0-9]+)\ ([0-9.]+)$ ]]; then
			code="${BASH_REMATCH[1]}"; up="${BASH_REMATCH[2]}"
			down="${BASH_REMATCH[3]}"; time="${BASH_REMATCH[4]}"
		elif [ "$rc" = "35" ] || grep -qiE 'not supported|unsupported|schannel|SSL' "$out.err" 2>/dev/null; then
			code="UNSUP"
		elif [ -n "$res" ]; then
			code="ERR"
		fi

		status="OK"
		if [ "$code" = "UNSUP" ]; then
			status="UNSUPPORTED"
		elif [ "$rc" != "0" ] || [ "$code" = "ERR" ] || [ "$code" = "NA" ]; then
			status="FAIL"
		fi
		# 16-20KB freeze pattern
		if [ "$up" -gt 0 ] && [ "$down" = "0" ] && \
		   awk -v t="$time" -v to="$DPI_TIMEOUT" 'BEGIN{exit !(t>=to)}' && [ "$rc" != "0" ]; then
			status="LIKELY_BLOCKED"
			warned=1
		fi
		echo "LINE=$label|$code|$up|$down|$time|$status" >> "$out"
	done
	rm -f "$out.err"
	echo "WARNED=$warned" >> "$out"
}

# main
main() {
	# без рута тесты бессмысленны
	if [ "$(id -u)" != "0" ]; then
		print_red "[ERROR] Run as root (sudo) to execute tests"
		exit 1
	else
		print_green "[OK] Root rights detected"
	fi

	if ! command -v curl >/dev/null 2>&1; then
		print_red "[ERROR] curl not found. Install curl and rerun."
		exit 1
	else
		print_green "[OK] curl found"
	fi

	if [ ! -x "$NFQWS_BIN" ]; then
		print_red "[ERROR] nfqws binary not found ($NFQWS_BIN). Run ./install.sh first."
		exit 1
	fi

	# если прошлый запуск убили посередине - чиним ipset
	if [ -f "$IPSET_FLAG_FILE" ]; then
		print_yellow "[INFO] Detected leftover ipset switch flag. Restoring ipset..."
		set_ipset_mode restore
		rm -f "$IPSET_FLAG_FILE"
	fi

	local ORIGINAL_IPSET
	ORIGINAL_IPSET="$(ipset_status)"

	if [ "$ORIGINAL_IPSET" != "any" ]; then
		print_cyan "[INFO] Current ipset status: $ORIGINAL_IPSET"
		print_yellow "[WARNING] Ipset will be switched to 'any' for accurate DPI tests."
		print_yellow "[WARNING] If the script is killed, ipset will be restored on the next run."
	fi

	# при установленной службе тесты не запускаем, как в ps1
	if [ -f /etc/systemd/system/zapret.service ] && have_systemd && \
	   systemctl is-enabled zapret >/dev/null 2>&1; then
		print_red "[ERROR] systemd service 'zapret' is installed"
		print_red "        Remove the service before running tests:"
		print_red "        sudo $(basename "$0") ... =>  sudo service.sh remove"
		exit 1
	fi

	WORK_DIR="$(mktemp -d)"
	mkdir -p "$WORK_DIR/std" "$WORK_DIR/dpi"
	ORIGINAL_SNAPSHOT="$WORK_DIR/nfqws.snapshot"
	export NO_UPDATE_CHECK=1
	get_nfqws_snapshot "$ORIGINAL_SNAPSHOT"
	trap cleanup_restore EXIT
	trap 'print_red "[ERROR] Script interrupted. Restoring..."; exit 130' INT TERM

	# предупредить, если правила не накатаны
	if ! "$ROOT_DIR/firewall.sh" status-quiet 2>/dev/null | grep -qx active; then
		print_yellow "[WARNING] Firewall (NFQUEUE) rules are NOT active."
		print_yellow "          Tests will run, but traffic won't pass through nfqws."
		print_yellow "          Apply rules first: sudo ./firewall.sh start"
	fi

	# список стратегий в том же порядке, что даёт меню
	local -a cfg_files=()
	while IFS= read -r f; do
		cfg_files+=("$ROOT_DIR/$f")
	done < <("$ROOT_DIR/service.sh" list-strategies)

	if [ "${#cfg_files[@]}" -eq 0 ]; then
		print_red "[ERROR] No general*.sh strategy scripts found"
		exit 1
	fi

	local test_type="${ZAPRET_TEST_TYPE:-}"
	if [ -z "$test_type" ]; then
		if [ ! -t 0 ]; then
			print_red "[ERROR] Non-interactive stdin. Set ZAPRET_TEST_TYPE=standard|dpi (and ZAPRET_TEST_MODE=all|select)."
			exit 1
		fi
		while [ -z "$test_type" ]; do
			echo
			print_cyan "Select test type:"
			print_gray "  [1] Standard tests (HTTP/ping)"
			print_gray "  [2] DPI checkers (TCP 16-20 freeze)"
			local c
			IFS= read -r -p "Enter 1 or 2: " c || c=""
			case "$c" in
				1) test_type="standard" ;;
				2) test_type="dpi" ;;
				*) print_yellow "Incorrect input. Please try again." ;;
			esac
		done
	fi

	local mode="${ZAPRET_TEST_MODE:-}"
	if [ -z "$mode" ]; then
		if [ ! -t 0 ]; then
			print_red "[ERROR] Non-interactive stdin. Set ZAPRET_TEST_MODE=all|select."
			exit 1
		fi
		while [ -z "$mode" ]; do
			echo
			print_cyan "Select test run mode:"
			print_gray "  [1] All configs"
			print_gray "  [2] Selected configs"
			local c
			IFS= read -r -p "Enter 1 or 2: " c || c=""
			case "$c" in
				1) mode="all" ;;
				2) mode="select" ;;
				*) print_yellow "Incorrect input. Please try again." ;;
			esac
		done
	fi

	if [ "$mode" = "select" ]; then
		echo
		print_cyan "Available configs:"
		local i
		for i in "${!cfg_files[@]}"; do
			echo "  [$((i+1))] $(basename "${cfg_files[$i]}")"
		done
		local sel="${ZAPRET_TEST_CONFIGS:-}"
		if [ -z "$sel" ]; then
			IFS= read -r -p "Enter numbers (e.g. 1,3,5), ranges (e.g. 2-7), or mixed. '0' for all: " sel || sel="0"
		fi
		[ -z "$sel" ] && sel="0"
		if [ "$sel" != "0" ]; then
			local -a picked=()
			local part s e j
			IFS=',' read -ra parts <<< "${sel// /}"
			for part in "${parts[@]}"; do
				if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
					s="${BASH_REMATCH[1]}"; e="${BASH_REMATCH[2]}"
					(( s > e )) && { print_yellow "  [WARN] Invalid range '$part'. Skipping."; continue; }
					for (( j=s; j<=e; j++ )); do
						(( j>=1 && j<=${#cfg_files[@]} )) && picked+=("${cfg_files[$((j-1))]}")
					done
				elif [[ "$part" =~ ^[0-9]+$ ]]; then
					if (( part>=1 && part<=${#cfg_files[@]} )); then
						picked+=("${cfg_files[$((part-1))]}")
					else
						print_yellow "  [WARN] Number '$part' out of bounds."
					fi
				fi
			done
			if [ "${#picked[@]}" -gt 0 ]; then
				cfg_files=("${picked[@]}")
			else
				print_yellow "No valid configs selected, running all."
			fi
		fi
	fi

	echo
	print_cyan "============================================================"
	print_cyan "                 ZAPRET CONFIG TESTS"
	print_cyan "                 Mode: $(echo "$test_type" | tr '[:lower:]' '[:upper:]')"
	printf '%s\n' "${C_CYAN}                 Total configs: $(printf '%2d' "${#cfg_files[@]}")${C_RESET}"
	print_cyan "============================================================"

	declare -A ANALYTICS=()
	local best_config="" max_score=-1 max_ping=-1
	local results_file
	results_file="$RESULTS_DIR/test_results_$(date +%Y-%m-%d_%H-%M-%S).txt"
	: > "$results_file"

	if [ "$test_type" = "dpi" ] && [ "$ORIGINAL_IPSET" != "any" ]; then
		print_yellow "[WARNING] Ipset is in '$ORIGINAL_IPSET' mode. Switching to 'any' for accurate DPI tests..."
		set_ipset_mode any
		touch "$IPSET_FLAG_FILE"
	fi
	print_yellow "[WARNING] Tests may take several minutes to complete. Please wait..."

	if [ "$test_type" = "standard" ]; then
		load_targets
	fi
	if [ "$test_type" = "dpi" ]; then
		declare -a DPI_IDS=() DPI_PROVIDERS=() DPI_COUNTRIES=() DPI_HOSTS=()
		if ! dpi_fetch_targets; then
			print_red "[ERROR] Could not build DPI target list."
			exit 1
		fi
		head -c "$DPI_RANGE" /dev/urandom > "$WORK_DIR/payload.bin"
	fi

	local config_num=0 cfg cfg_name script_pid
	for cfg in "${cfg_files[@]}"; do
		config_num=$((config_num+1))
		cfg_name="$(basename "$cfg")"
		echo
		print_gray "------------------------------------------------------------"
		print_yellow "  [$config_num/${#cfg_files[@]}] $cfg_name"
		print_gray "------------------------------------------------------------"

		stop_all_nfqws

		echo "  > Starting config..."
		ZAPRET_DAEMON=1 ZAPRET_PIDFILE="$WORK_DIR/nfqws-$config_num.pid" \
			ZAPRET_TEST_MODE_RUN=1 "$cfg" >/dev/null 2>&1 &
		script_pid=$!

		if ! wait_nfqws_ready; then
			print_red "  > Strategy failed to start (nfqws process not found). Skipping..."
			kill "$script_pid" 2>/dev/null || true
			wait "$script_pid" 2>/dev/null || true
			continue
		fi

		if [ "$test_type" = "standard" ]; then
			rm -f "$WORK_DIR"/std/*
			local i
			# параллельно, но без фанатизма
			local running=0
			for i in "${!TARGET_NAMES[@]}"; do
				test_one_target "$i" &
				running=$((running+1))
				if [ "$running" -ge "$STD_MAX_PARALLEL" ]; then wait -n 2>/dev/null || wait; running=$((running-1)); fi
			done
			wait

			echo "  > Results:"
			local ok=0 err=0 unsup=0 ping_ok=0 ping_fail=0
			for i in "${!TARGET_NAMES[@]}"; do
				local f="$WORK_DIR/std/$i"
				[ -f "$f" ] || continue
				# shellcheck disable=SC1090
				local name tokens pingr isurl
				name="$(sed -n 's/^NAME=//p' "$f")"
				tokens="$(sed -n 's/^TOKENS=//p' "$f")"
				pingr="$(sed -n 's/^PING=//p' "$f")"
				isurl="$(sed -n 's/^ISURL=//p' "$f")"
				printf '  %-28s %s | Ping: %s\n' "$name" "$tokens" "$pingr"
				local tok
				for tok in $tokens; do
					case "$tok" in
						*:OK) ok=$((ok+1)) ;;
						*:UNSUP) unsup=$((unsup+1)) ;;
						*) err=$((err+1)) ;;
					esac
				done
				if [ "$pingr" != "Timeout" ] && [ "$pingr" != "n/a" ]; then ping_ok=$((ping_ok+1)); else ping_fail=$((ping_fail+1)); fi
				if [ "$isurl" = "1" ]; then
					echo "  $name :$tokens | Ping: $pingr" >> "$WORK_DIR/report-$config_num.txt"
				else
					echo "  $name : Ping: $pingr" >> "$WORK_DIR/report-$config_num.txt"
				fi
			done
			ANALYTICS["$cfg_name"]="HTTP OK: $ok, ERR: $err, UNSUP: $unsup, Ping OK: $ping_ok, Fail: $ping_fail"
			{
				echo "Config: $cfg_name (Type: standard)"
				cat "$WORK_DIR/report-$config_num.txt" 2>/dev/null
				echo
			} >> "$results_file"
			if [ "$ok" -gt "$max_score" ]; then
				max_score="$ok"; max_ping="$ping_ok"; best_config="$cfg_name"
			elif [ "$ok" -eq "$max_score" ] && [ "$ping_ok" -gt "$max_ping" ]; then
				max_ping="$ping_ok"; best_config="$cfg_name"
			fi
		else
			echo "  > Running DPI checkers..."
			print_gray "[INFO] Targets: ${#DPI_IDS[@]}. Range: 0-$((DPI_RANGE-1)) bytes; Timeout: ${DPI_TIMEOUT}s"
			print_gray "[INFO] Starting DPI TCP 16-20 checks (parallel: $DPI_MAX_PARALLEL)..."
			rm -f "$WORK_DIR"/dpi/*
			local warn_detected=0
			local running=0 i
			for i in "${!DPI_IDS[@]}"; do
				dpi_test_one "$i" &
				running=$((running+1))
				if [ "$running" -ge "$DPI_MAX_PARALLEL" ]; then wait -n 2>/dev/null || wait; running=$((running-1)); fi
			done
			wait

			local ok=0 fail=0 unsup=0 blocked=0
			for i in "${!DPI_IDS[@]}"; do
				local f="$WORK_DIR/dpi/$i"
				[ -f "$f" ] || continue
				local tgt line
				tgt="$(sed -n 's/^TARGET=//p' "$f")"
				local country id provider
				IFS='|' read -r id provider country _ <<< "$tgt"
				echo
				print_cyan "=== [$country][$provider] $id ==="
				while IFS= read -r line; do
					line="${line#LINE=}"
					IFS='|' read -r label code up down time status <<< "$line"
					local upkb downkb
					upkb="$(awk -v b="$up" 'BEGIN{printf "%.1f", b/1024}')"
					downkb="$(awk -v b="$down" 'BEGIN{printf "%.1f", b/1024}')"
					case "$status" in
						OK) print_green "[$label] code=$code buf_up=$up bytes ($upkb KB) buf_down=$down bytes ($downkb KB) time=${time}s status=$status"; ok=$((ok+1)) ;;
						UNSUPPORTED) print_yellow "[$label] code=$code buf_up=$up bytes ($upkb KB) buf_down=$down bytes ($downkb KB) time=${time}s status=$status"; unsup=$((unsup+1)) ;;
						LIKELY_BLOCKED) print_yellow "[$label] code=$code buf_up=$up bytes ($upkb KB) buf_down=$down bytes ($downkb KB) time=${time}s status=$status"; blocked=$((blocked+1)) ;;
						*) print_red "[$label] code=$code buf_up=$up bytes ($upkb KB) buf_down=$down bytes ($downkb KB) time=${time}s status=$status"; fail=$((fail+1)) ;;
					esac
					echo "    ${label}: code=${code}  up=${upkb} KB  down=${downkb} KB  time=${time}s  status=${status}" >> "$WORK_DIR/report-$config_num.txt"
				done < <(grep '^LINE=' "$f")
				local w
				w="$(sed -n 's/^WARNED=//p' "$f")"
				if [ "$w" = "1" ]; then
					warn_detected=1
					print_yellow "  Pattern matches 16-20KB freeze; censor likely cutting this strategy."
				else
					print_green "  No 16-20KB freeze pattern for this target."
				fi
				echo "  Target: [$country] $id ($provider)" >> "$WORK_DIR/report-$config_num.txt"
			done
			echo
			if [ "$warn_detected" = "1" ]; then
				print_red "[WARNING] Detected possible DPI TCP 16-20 blocking on one or more targets. Consider changing strategy/SNI/IP."
			else
				print_green "[OK] No 16-20KB freeze pattern detected across targets."
			fi
			ANALYTICS["$cfg_name"]="OK: $ok, FAIL: $fail, UNSUP: $unsup, BLOCKED: $blocked"
			{
				echo "Config: $cfg_name (Type: dpi)"
				cat "$WORK_DIR/report-$config_num.txt" 2>/dev/null
				echo
			} >> "$results_file"
			if [ "$ok" -gt "$max_score" ]; then
				max_score="$ok"; best_config="$cfg_name"
			fi
		fi

		stop_all_nfqws
		kill "$script_pid" 2>/dev/null || true
		wait "$script_pid" 2>/dev/null || true
	done

	echo
	print_green "All tests finished."
	echo
	print_cyan "=== ANALYTICS ==="
	local maxlen=0 k
	for k in "${!ANALYTICS[@]}"; do
		[ "${#k}" -gt "$maxlen" ] && maxlen="${#k}"
	done
	for cfg in "${cfg_files[@]}"; do
		cfg_name="$(basename "$cfg")"
		[ -n "${ANALYTICS[$cfg_name]:-}" ] || continue
		printf "${C_YELLOW}%-$((maxlen))s : %s${C_RESET}\n" "$cfg_name" "${ANALYTICS[$cfg_name]}"
		printf '%s : %s\n' "$cfg_name" "${ANALYTICS[$cfg_name]}" >> "$WORK_DIR/analytics.txt"
	done
	echo
	print_green "Best config: $best_config"
	echo "Best strategy: $best_config" >> "$WORK_DIR/analytics.txt"
	echo
	{
		echo "=== ANALYTICS ==="
		cat "$WORK_DIR/analytics.txt" 2>/dev/null
	} >> "$results_file"
	print_green "Results saved to $results_file"
}

main "$@"

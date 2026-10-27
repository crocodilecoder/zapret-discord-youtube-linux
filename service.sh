#!/usr/bin/env bash
# service.sh - менеджер, аналог виндового service.bat.
# без аргументов - меню как в оригинале, с аргументом - командный режим
# (install/remove/start/stop/status/diagnostics/..., список - ./service.sh help)
set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./common.sh

SERVICE_NAME="zapret"
UNIT_FILE="${ZAPRET_UNIT_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"

# helpers
list_strategies() {
	# порядок как в оригинальном service.bat (там сортировка powershell по
	# числам в имени): ALT, ALT2..ALT13, EXP, FAKE TLS..., SIMPLE..., general
	# восстанавливаем "виндовое" имя для ключа сортировки: general_ALT2.sh ->
	# "general (ALT2).sh", иначе локаль машины ломает порядок
	local f base mid key
	for f in "$ROOT_DIR"/general*.sh; do
		[ -f "$f" ] || continue
		base="$(basename "$f")"
		mid="${base#general_}"; mid="${mid%.sh}"
		if [ -n "$mid" ]; then
			key="general (${mid//_/ }).sh"
		else
			key="general.sh"
		fi
		# числа - с ведущими нулями, чтобы 2 шло раньше 10
		key="$(printf '%s' "$key" | sed -E 's/[0-9]+/\n&\n/g' | awk 'BEGIN{ORS=""} /^[0-9]+$/{printf "%08d", $0; next} {print}')"
		printf '%s\t%s\n' "$key" "$base"
	done | LC_ALL=C sort -t"$(printf '\t')" -k1,1 | cut -f2
}

read_choice() {
	# $1 - prompt, $2 - default. Reads a line from stdin (tty or pipe);
	# on EOF (fully non-interactive) returns the default.
	local prompt="$1" reply
	if IFS= read -r -p "$prompt" reply; then
		printf '%s' "$reply"
	else
		printf '%s' "${2:-}"
	fi
}

find_strategy_file() {
	# $1 - strategy name or path; prints resolved path
	local s="$1"
	if [ -f "$ROOT_DIR/$s" ]; then
		printf '%s' "$ROOT_DIR/$s"
	elif [ -f "$s" ]; then
		printf '%s' "$s"
	else
		return 1
	fi
}

current_strategy_file() {
	local name
	name="$(strategy_get)"
	[ -n "$name" ] || return 1
	find_strategy_file "$name"
}

unit_installed() {
	[ -f "$UNIT_FILE" ]
}

generate_unit() {
	cat > "$UNIT_FILE" <<EOF
[Unit]
Description=zapret-discord-youtube DPI bypass (Linux port)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=$PIDFILE
ExecStart=$ROOT_DIR/service.sh systemd-start
ExecStop=$ROOT_DIR/service.sh systemd-stop
Restart=on-failure
RestartSec=5s
TimeoutSec=30sec

[Install]
WantedBy=multi-user.target
EOF
}

# service control
do_start() {
	local strategy_file="$1"
	require_root || return 1

	if unit_installed && have_systemd; then
		systemctl start "$SERVICE_NAME"
		sleep 1
		if systemctl is-active --quiet "$SERVICE_NAME"; then
			print_green "Service \"$SERVICE_NAME\" started."
		else
			print_red "Service failed to start. Check: journalctl -u $SERVICE_NAME -n 50"
			return 1
		fi
		return 0
	fi

	# no systemd: plain daemon + firewall
	"$ROOT_DIR/firewall.sh" start || return 1
	if start_daemon "$strategy_file"; then
		print_green "(no systemd detected - started as a plain daemon)"
		print_yellow "Note: this will NOT survive a reboot. Consider adding to rc.local/cron @reboot:"
		print_yellow "  @reboot root $ROOT_DIR/service.sh start"
	fi
}

do_stop() {
	require_root || return 1
	if unit_installed && have_systemd; then
		systemctl stop "$SERVICE_NAME" 2>/dev/null || true
		print_green "Service \"$SERVICE_NAME\" stopped."
	else
		nfqws_stop
		"$ROOT_DIR/firewall.sh" stop >/dev/null 2>&1 || true
		print_green "zapret stopped (daemon killed, firewall rules removed)."
	fi
}

do_status() {
	local strategy
	strategy="$(strategy_get)"
	if [ -n "$strategy" ]; then print_cyan "Strategy: $strategy"; fi

	if unit_installed && have_systemd; then
		local state
		state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)" || state="inactive"
		if [ "$state" = "active" ]; then
			print_green "\"$SERVICE_NAME\" service is RUNNING."
		else
			echo "\"$SERVICE_NAME\" service is NOT running ($state)."
		fi
	fi

	if nfqws_is_running; then
		print_green "Bypass (nfqws) is RUNNING (pid $(nfqws_pid))."
	else
		print_red "Bypass (nfqws) is NOT running."
	fi

	if [ -x "$NFQWS_BIN" ]; then
		print_green "nfqws binary found: $NFQWS_BIN ($("$NFQWS_BIN" --version 2>/dev/null | head -n1))"
	else
		print_red "nfqws binary NOT found. Run ./install.sh first."
	fi

	if "$ROOT_DIR/firewall.sh" status-quiet 2>/dev/null | grep -qx active; then
		print_green "Firewall (NFQUEUE) rules are ACTIVE."
	else
		print_red "Firewall (NFQUEUE) rules are NOT active."
	fi

	load_game_filter
	echo "Game filter: $GF_STATUS   IPSet: $(ipset_status)   Updates check: $([ -f "$UTILS_DIR/check_updates.enabled" ] && echo enabled || echo disabled)"
}

# проверка "а не крутится ли уже служба" для стратегий; код 10 значит
# "служба активна, скрипт должен выйти" - в винде это делал exit /b
do_status_soft() {
	if unit_installed && have_systemd && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
		echo "\"$SERVICE_NAME\" is ALREADY RUNNING as service, use \"$0 remove\" first if you want to run a standalone script."
		tcp_enable
		exit 10
	fi
	if nfqws_is_running; then
		print_yellow "[!] nfqws is already running (pid $(nfqws_pid)). This script will refuse to start a second instance."
	fi
	tcp_enable
	exit 0
}

do_install() {
	require_root || return 1
	local choice="$1" strategy_file

	if [ -n "$choice" ]; then
		strategy_file="$(find_strategy_file "$choice")" || {
			print_red "Strategy \"$choice\" not found."
			return 1
		}
	else
		echo "Pick one of the options:"
		local count=0 f
		local -a files=()
		while IFS= read -r f; do
			count=$((count+1))
			files+=("$f")
			echo "  $count. $f"
		done < <(list_strategies)
		echo "  0. Exit"
		echo
		choice="$(read_choice "Input option (0-$count, default: 0): " "0")"
		[ -z "$choice" ] && choice=0
		if [ "$choice" = "0" ]; then return 0; fi
		if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
			print_red "Invalid choice, exiting..."
			return 1
		fi
		strategy_file="${files[$((choice-1))]}"
	fi

	local base
	base="$(basename "$strategy_file")"
	echo "Selected strategy: $base"

	tcp_enable
	strategy_set "$base"

	if have_systemd; then
		unit_installed && { systemctl stop "$SERVICE_NAME" 2>/dev/null || true; }
		generate_unit
		systemctl daemon-reload
		systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
		systemctl start "$SERVICE_NAME"
		sleep 1
		if systemctl is-active --quiet "$SERVICE_NAME"; then
			print_green "Service \"$SERVICE_NAME\" installed (autostart enabled) and started with strategy \"$base\"."
		else
			print_red "Service installed but failed to start. Check: journalctl -u $SERVICE_NAME -n 50"
			print_yellow "(обычно это ошибка применения правил фаервола - она же будет в journalctl)"
			return 1
		fi
	else
		print_yellow "systemd not detected - installing without a unit file."
		do_start "$strategy_file"
	fi
}

do_remove() {
	require_root || return 1
	if unit_installed && have_systemd; then
		systemctl stop "$SERVICE_NAME" 2>/dev/null || true
		systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
	fi
	rm -f "$UNIT_FILE"
	have_systemd && systemctl daemon-reload 2>/dev/null

	nfqws_stop
	"$ROOT_DIR/firewall.sh" stop >/dev/null 2>&1 || true
	rm -f "${STRATEGY_STATE_FILE:?}"
	print_green "Service \"$SERVICE_NAME\" removed, nfqws stopped, firewall rules cleaned."
}

# этот вход дёргает systemd
do_systemd_start() {
	tcp_enable
	local strategy_file
	if ! strategy_file="$(current_strategy_file)"; then
		strategy_file="$(list_strategies | head -n1)"
		strategy_file="$ROOT_DIR/$strategy_file"
	fi
	"$ROOT_DIR/firewall.sh" start || exit 1
	ZAPRET_DAEMON=1 ZAPRET_PIDFILE="$PIDFILE" "$strategy_file"
}

do_systemd_stop() {
	nfqws_stop
	"$ROOT_DIR/firewall.sh" stop >/dev/null 2>&1 || true
}

# меню игрового фильтра, нумерация как в оригинале
do_game_filter_menu() {
	load_game_filter
	while true; do
		load_game_filter
		clear 2>/dev/null || true
		echo "Select game filter option:"
		if [ "$GF_MODE" = "disabled" ]; then echo "  1. * Disable";     else echo "  1.   Disable"; fi
		if [ "$GF_MODE" = "all" ];      then echo "  2. * TCP and UDP"; else echo "  2.   TCP and UDP"; fi
		if [ "$GF_MODE" = "tcp" ];      then echo "  3. * TCP";         else echo "  3.   TCP"; fi
		if [ "$GF_MODE" = "udp" ];      then echo "  4. * UDP";         else echo "  4.   UDP"; fi
		echo
		echo "  5. Change TCP port range (current: $GF_TCP_RANGE)"
		echo "  6. Change UDP port range (current: $GF_UDP_RANGE)"
		echo "  7. Change TCP and UDP port ranges"
		echo
		echo "  0. Exit"
		echo
		local c
		c="$(read_choice "Select option (0-7, default: 0): " "0")"
		case "$c" in
			1) GF_MODE="disabled" ;;
			2) GF_MODE="all" ;;
			3) GF_MODE="tcp" ;;
			4) GF_MODE="udp" ;;
			5|6|7)
				echo
				local what="tcp"; [ "$c" = "6" ] && what="udp"; [ "$c" = "7" ] && what="tcp+udp"
				echo "Changing ports for $what (example: 1024-1934,1936-65535, default: 1024-65535)"
				local input v
				input="$(read_choice "Enter ports/ranges: " "")"
				if v="$(gf_validate_range "$input")"; then
					case "$c" in
						5) GF_TCP_RANGE="$v" ;;
						6) GF_UDP_RANGE="$v" ;;
						7) GF_TCP_RANGE="$v"; GF_UDP_RANGE="$v" ;;
					esac
				else
					print_red "Invalid input. Please enter valid ports/ranges."
					pause
					continue
				fi
				;;
			*) return 0 ;;
		esac
		save_game_filter_settings
		print_yellow "Restart zapret (and 'firewall.sh restart' if it is installed as service) to apply the changes"
		pause
	done
}

# то же самое из командной строки
do_game_filter_cli() {
	load_game_filter
	local sub="${1:-status}"; shift || true
	case "$sub" in
		status)  echo "Game filter: $GF_STATUS (tcp=$GF_TCP_RANGE udp=$GF_UDP_RANGE)" ;;
		disable) GF_MODE="disabled"; save_game_filter_settings; echo "Game filter disabled." ;;
		all)     GF_MODE="all"; save_game_filter_settings; echo "Game filter enabled (TCP and UDP)." ;;
		tcp)     GF_MODE="tcp"; save_game_filter_settings; echo "Game filter enabled (TCP)." ;;
		udp)     GF_MODE="udp"; save_game_filter_settings; echo "Game filter enabled (UDP)." ;;
		range-tcp)
			gf_validate_range "${1:-}" >/dev/null || { print_red "Invalid range."; return 1; }
			GF_TCP_RANGE="$(gf_validate_range "$1")"; save_game_filter_settings
			echo "TCP range set to $GF_TCP_RANGE (mode: $GF_MODE)" ;;
		range-udp)
			gf_validate_range "${1:-}" >/dev/null || { print_red "Invalid range."; return 1; }
			GF_UDP_RANGE="$(gf_validate_range "$1")"; save_game_filter_settings
			echo "UDP range set to $GF_UDP_RANGE (mode: $GF_MODE)" ;;
		range-all)
			gf_validate_range "${1:-}" >/dev/null || { print_red "Invalid range."; return 1; }
			GF_TCP_RANGE="$(gf_validate_range "$1")"; GF_UDP_RANGE="$GF_TCP_RANGE"; save_game_filter_settings
			echo "TCP+UDP range set to $GF_TCP_RANGE (mode: $GF_MODE)" ;;
		*) print_red "Unknown game-filter command: $sub"; return 1 ;;
	esac
	print_yellow "Restart zapret to apply the changes."
}

# переключение режима ipset: loaded -> none -> any -> loaded
do_ipset_switch() {
	local list_file="$LISTS_DIR/ipset-all.txt"
	local backup_file="$list_file.backup"
	local status
	status="$(ipset_status)"

	case "$status" in
		loaded)
			echo "Switching to none mode..."
			mv -f "$list_file" "$backup_file"
			echo "203.0.113.113/32" > "$list_file"
			;;
		none)
			echo "Switching to any mode..."
			: > "$list_file"
			;;
		any)
			echo "Switching to loaded mode..."
			if [ -f "$backup_file" ]; then
				mv -f "$backup_file" "$list_file"
			else
				print_red "Error: no backup to restore. Update list from service menu first (update-ipset)."
				return 1
			fi
			;;
	esac
	echo "IPSet status is now: $(ipset_status)"
}

# вкл/выкл автопроверку обновлений
do_check_updates_switch() {
	local flag="$UTILS_DIR/check_updates.enabled"
	if [ ! -f "$flag" ]; then
		echo "Enabling check updates..."
		mkdir -p "$UTILS_DIR"
		echo "ENABLED" > "$flag"
	else
		echo "Disabling check updates..."
		rm -f "$flag"
	fi
}

# подмена активных фейков: ACTIVE_DISCORD_UDP.bin / ACTIVE_GAME_UDP.bin
do_replace_fakes() {
	local bin_path="$BIN_DIR"
	if [ ! -d "$bin_path" ]; then
		print_red "Error: bin folder not found."
		return 1
	fi
	command -v sha256sum >/dev/null 2>&1 || { print_red "sha256sum not found"; return 1; }

	local -a fake_files=() fake_names=() fake_hashes=()
	local discord_hash="" game_hash="" f base h
	local current_discord="(not found)" current_game="(not found)"

	for f in "$bin_path"/ACTIVE_DISCORD_UDP.bin "$bin_path"/ACTIVE_GAME_UDP.bin; do
		[ -f "$f" ] || continue
		h="$(sha256sum "$f" | awk '{print $1}')"
		case "$(basename "$f")" in
			ACTIVE_DISCORD_UDP.bin) discord_hash="$h" ;;
			ACTIVE_GAME_UDP.bin)    game_hash="$h" ;;
		esac
	done

	while IFS= read -r f; do
		base="$(basename "$f" .bin)"
		case "$base" in ACTIVE_*) continue ;; esac
		fake_files+=("$f")
		fake_names+=("$base")
		fake_hashes+=("$(sha256sum "$f" | awk '{print $1}')")
	done < <(find "$bin_path" -maxdepth 1 -name '*.bin' | sort)

	if [ "${#fake_files[@]}" -eq 0 ]; then
		echo "No .bin files were found in the bin folder."
		return 0
	fi

	local i
	for i in "${!fake_hashes[@]}"; do
		[ -n "$discord_hash" ] && [ "${fake_hashes[$i]}" = "$discord_hash" ] && current_discord="${fake_names[$i]}"
		[ -n "$game_hash" ] && [ "${fake_hashes[$i]}" = "$game_hash" ] && current_game="${fake_names[$i]}"
	done

	while true; do
		echo
		echo "Enter the fake type number and the fake file number to replace it with."
		echo "Example: 1 4 (replaces Discord UDP with fake file under number 4)"
		echo "         2 1 (replaces GameFilter UDP with fake file under number 1)"
		echo
		echo "Press ENTER or 0 to return."
		echo
		echo "  ----------------------------------------"
		echo
		echo "Fake types:"
		echo "  1. Discord UDP     (current: $current_discord)"
		echo "  2. GameFilter UDP  (current: $current_game)"
		echo
		echo "Fake files:"
		for i in "${!fake_names[@]}"; do echo "  $((i+1)). ${fake_names[$i]}"; done
		echo
		local choice
		choice="$(read_choice "Enter choice: " "")"
		[ -z "$choice" ] && return 0
		[ "$choice" = "0" ] && return 0

		local ftype fnum
		ftype="$(awk '{print $1}' <<< "$choice")"
		fnum="$(awk '{print $2}' <<< "$choice")"

		local active_file=""
		case "$ftype" in
			1) active_file="$bin_path/ACTIVE_DISCORD_UDP.bin" ;;
			2) active_file="$bin_path/ACTIVE_GAME_UDP.bin" ;;
			*) print_red "Invalid fake type."; pause; continue ;;
		esac
		if ! [[ "$fnum" =~ ^[0-9]+$ ]] || [ "$fnum" -lt 1 ] || [ "$fnum" -gt "${#fake_files[@]}" ]; then
			print_red "Invalid fake file number."
			pause
			continue
		fi
		local src="${fake_files[$((fnum-1))]}"
		if cp -f "$src" "$active_file"; then
			print_green "Active fake file replaced successfully ($(basename "$src") -> $(basename "$active_file"))."
			[ "$ftype" = "1" ] && current_discord="${fake_names[$((fnum-1))]}"
			[ "$ftype" = "2" ] && current_game="${fake_names[$((fnum-1))]}"
		else
			print_red "Failed to replace the active fake file."
		fi
		pause
	done
}

# то же из cli, для скриптов
do_replace_fakes_cli() {
	local which="${1:-}" what="${2:-}"
	if [ -z "$which" ] || [ -z "$what" ]; then
		print_red "Usage: replace-fakes-cli <discord|game> <fake-file.bin>"
		return 1
	fi
	local dst
	case "$which" in
		discord) dst="$BIN_DIR/ACTIVE_DISCORD_UDP.bin" ;;
		game)    dst="$BIN_DIR/ACTIVE_GAME_UDP.bin" ;;
		*) print_red "Type must be discord|game"; return 1 ;;
	esac
	local src="$BIN_DIR/$what"
	[ -f "$src" ] || { print_red "File not found: $src"; return 1; }
	cp -f "$src" "$dst" && print_green "Replaced $(basename "$dst") with $what"
}

# обновление списков ipset и /etc/hosts с гитхаба
do_ipset_update() {
	local list_file="$LISTS_DIR/ipset-all.txt"
	echo "Updating ipset-all..."
	local tmp
	tmp="$(mktemp)"
	if http_fetch "$IPSET_SERVICE_URL" "$tmp"; then
		if [ -s "$tmp" ]; then
			mv -f "$tmp" "$list_file"
			print_green "Finished: $(grep -cv '^$' "$list_file") subnets."
		else
			rm -f "$tmp"
			print_red "Downloaded file is empty, keeping old list."
			return 1
		fi
	else
		rm -f "$tmp"
		print_red "Failed to download the list (network error)."
		return 1
	fi
}

do_hosts_update() {
	local hosts_file="/etc/hosts"
	local tmp
	tmp="$(mktemp)"
	echo "Checking hosts file..."
	if ! http_fetch "${HOSTS_SERVICE_URL}?t=$RANDOM$RANDOM" "$tmp"; then
		rm -f "$tmp"
		print_red "Failed to download hosts file from repository"
		print_yellow "Copy hosts file manually from $HOSTS_SERVICE_URL"
		return 1
	fi

	local first_line last_line needs_update=0
	first_line="$(head -n1 "$tmp")"
	last_line="$(tail -n1 "$tmp")"
	grep -qF -- "$first_line" "$hosts_file" 2>/dev/null || { echo "First line from repository not found in hosts file"; needs_update=1; }
	grep -qF -- "$last_line"  "$hosts_file" 2>/dev/null || { echo "Last line from repository not found in hosts file";  needs_update=1; }

	if [ "$needs_update" = "1" ]; then
		echo
		print_yellow "Hosts file needs to be updated."
		print_yellow "Missing entries:"
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			grep -qF -- "$line" "$hosts_file" 2>/dev/null || echo "  $line"
		done < "$tmp"
		echo
		local c="n"
		if [ -t 0 ]; then
			c="$(read_choice "Append them to /etc/hosts automatically? (backup will be created) (Y/N, default: N): " "n")"
		else
			c="${ZAPRET_HOSTS_AUTO:-n}"
		fi
		case "$c" in
			[yY]*)
				require_root || { rm -f "$tmp"; return 1; }
				cp -f "$hosts_file" "${hosts_file}.zapret-backup"
				local append_tmp
				append_tmp="$(mktemp)"
				{
					echo "# zapret-discord-youtube begin"
					while IFS= read -r line; do
						[ -z "$line" ] && continue
						grep -qF -- "$line" "$hosts_file" 2>/dev/null || echo "$line"
					done < "$tmp"
					echo "# zapret-discord-youtube end"
				} > "$append_tmp"
				cat "$append_tmp" >> "$hosts_file"
				rm -f "$append_tmp"
				print_green "Entries appended to $hosts_file (backup: ${hosts_file}.zapret-backup)."
				;;
			*)
				print_yellow "Saved downloaded file to: $tmp"
				print_yellow "Copy needed lines to $hosts_file manually (sudoedit $hosts_file)."
				return 0
				;;
		esac
	else
		print_green "Hosts file is up to date"
	fi
	rm -f "$tmp"
}

# диагностика: всё, что можно проверить на линуксе без win-специфики
clear_discord_cache() {
	# $1 - process name pattern, $2 - display name, $3 - config dir
	local pname="$1" dname="$2" dir="$3" d
	if pgrep -f "$pname" >/dev/null 2>&1; then
		echo "$dname is running, closing..."
		if pkill -f "$pname" 2>/dev/null; then
			print_green "$dname was successfully closed"
		else
			print_red "Unable to close $dname!"
		fi
		sleep 1
	fi
	if [ -d "$dir" ]; then
		for d in "Cache" "Code Cache" "GPUCache"; do
			if [ -d "$dir/$d" ]; then
				if rm -rf "${dir:?}/${d:?}" 2>/dev/null; then
					print_green "Successfully deleted $dir/$d"
				else
					print_red "Failed to delete $dir/$d"
				fi
			else
				print_red "$dir/$d does not exist"
			fi
		done
	fi
}

do_diagnostics() {
	print_green "Zapret is installed in: '$ROOT_DIR'"
	echo

	# root
	if [ "$(id -u)" = "0" ]; then
		print_green "Root privileges check passed"
	else
		print_yellow "[?] Not running as root - some checks and actions will be limited"
	fi
	echo

	# nfqws binary
	if [ -x "$NFQWS_BIN" ]; then
		print_green "nfqws binary check passed ($("$NFQWS_BIN" --version 2>/dev/null | head -n1))"
	else
		print_red "[X] nfqws binary NOT found at $NFQWS_BIN. Run ./install.sh"
	fi
	echo

	# kernel netfilter queue support
	local nfq_ok=0
	if [ -f /proc/net/netfilter/nfnetlink_queue ]; then
		nfq_ok=1
	elif [ -d "/lib/modules/$(uname -r)" ] && \
	     { find "/lib/modules/$(uname -r)" -name 'nfnetlink_queue*' 2>/dev/null | grep -q . || \
	       grep -qE 'NFNETLINK_QUEUE=(y|m)' "/boot/config-$(uname -r)" 2>/dev/null; }; then
		nfq_ok=1
	fi
	if [ "$nfq_ok" = "1" ]; then
		print_green "NFQUEUE kernel support check passed"
	else
		print_red "[X] NFQUEUE support not found. Check that your kernel has"
		print_red "    NETFILTER_NETLINK_QUEUE / nfnetlink_queue module (standard on distro kernels)."
	fi
	echo

	# TCP timestamps (port of the netsh timestamps check)
	local ts
	ts="$(cat /proc/sys/net/ipv4/tcp_timestamps 2>/dev/null || echo unknown)"
	if [ "$ts" = "1" ]; then
		print_green "TCP timestamps check passed"
	else
		print_yellow "[?] TCP timestamps are disabled ($ts). Enabling timestamps..."
		if sysctl -w net.ipv4.tcp_timestamps=1 >/dev/null 2>&1; then
			print_green "TCP timestamps successfully enabled"
		else
			print_red "[X] Failed to enable TCP timestamps (need root)"
		fi
	fi
	echo

	# firewall rules
	if "$ROOT_DIR/firewall.sh" status-quiet 2>/dev/null | grep -qx active; then
		print_green "Firewall (NFQUEUE) rules check passed"
		local qs
		qs="$(queue_stats 2>/dev/null || true)"
		[ -n "$qs" ] && echo "  $qs"
	else
		print_red "[X] Firewall rules are NOT active - traffic will not reach nfqws"
		print_red "    Fix: sudo $ROOT_DIR/firewall.sh start"
	fi
	echo

	# nfqws process
	if nfqws_is_running; then
		print_green "Bypass (nfqws) is RUNNING (pid $(nfqws_pid))."
	else
		print_red "[X] Bypass (nfqws) is NOT running."
	fi
	echo

	# proxy (env based on Linux)
	if [ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}" ]; then
		print_yellow "[?] Proxy environment variables are set: http_proxy=${http_proxy:-} https_proxy=${https_proxy:-}"
		print_yellow "Make sure it's valid or unset them if you don't use a proxy"
	else
		print_green "Proxy check passed"
	fi
	echo

	# DNS / DoH hints
	if grep -qE '^DNS(OverTLS|SEC)=|DNS=.*#' /etc/systemd/resolved.conf 2>/dev/null; then
		print_green "Secure DNS check passed (systemd-resolved)"
	else
		print_yellow "[?] Make sure you have configured secure DNS in a browser with some non-default DNS service provider"
	fi
	echo

	# hosts file
	if grep -qiE 'youtube\.com|youtu\.be' /etc/hosts 2>/dev/null; then
		print_yellow "[?] Your hosts file contains entries for youtube.com or youtu.be. This may cause problems with YouTube access"
	else
		print_green "Hosts file check passed"
	fi
	echo

	# conflicting bypasses (processes)
	local conflicts="" p
	for p in goodbyedpi GoodbyeDPI winws nfqws tpws byedpi spoofdpi; do
		if [ "$p" = "nfqws" ]; then continue; fi
		if pgrep -x "$p" >/dev/null 2>&1; then
			conflicts="$conflicts $p"
		fi
	done
	# other zapret installations
	local other_zapret tmp_pids my_pid pid
	tmp_pids="$(mktemp)"
	my_pid="$(nfqws_pid)"
	for pid in $(pgrep -f 'nfqws|tpws' 2>/dev/null); do
		[ "$pid" = "$my_pid" ] && continue
		pid_alive "$pid" || continue
		readlink "/proc/$pid/exe" 2>/dev/null
	done > "$tmp_pids"
	other_zapret="$(grep -v "^${NFQWS_BIN}$" "$tmp_pids" 2>/dev/null | sort -u)"
	rm -f "$tmp_pids"
	if [ -n "$conflicts$other_zapret" ]; then
		print_red "[X] Conflicting bypass processes found:$conflicts"
		[ -n "$other_zapret" ] && print_red "    Other nfqws/tpws binaries: $other_zapret"
		print_red "    Stop them before using this zapret installation."
	else
		print_green "Conflicting bypass check passed"
	fi
	echo

	# conflicting systemd units
	if have_systemd; then
		local units
		units="$(systemctl list-units --all 2>/dev/null | grep -iE 'goodbyedpi|zapret' | grep -v "$SERVICE_NAME" || true)"
		if [ -n "$units" ]; then
			print_yellow "[?] Other zapret-like systemd units found:"
			# shellcheck disable=SC2086  # тут нужен word splitting, по одному юниту на строку
			printf '    %s\n' $units
		else
			print_green "Conflicting services check passed"
		fi
		echo
	fi

	# VPN
	if ip -o link 2>/dev/null | grep -qiE 'wg[0-9]|tun[0-9]|tap[0-9]|wireguard|openvpn'; then
		print_yellow "[?] VPN interfaces found: $(ip -o link 2>/dev/null | grep -iE 'wg[0-9]|tun[0-9]|tap[0-9]' | awk -F': ' '{print $2}' | tr '\n' ' ')"
		print_yellow "Some VPNs can conflict with zapret. Make sure that all VPNs are disabled if bypass doesn't work"
	else
		print_green "VPN check passed"
	fi
	echo

	# Cyrillic path (same check as Windows version)
	if printf '%s' "$ROOT_DIR" | grep -qP '[\x{0430}-\x{044F}\x{0410}-\x{042F}\x{0451}\x{0401}]' 2>/dev/null || \
	   printf '%s' "$ROOT_DIR" | LC_ALL=C grep -q $'[\xd0\xd1]' 2>/dev/null; then
		print_yellow "[?] The path where Zapret is installed contains Cyrillic characters"
		print_yellow "If bypass doesn't work, try to move Zapret to another directory, for example /opt/zapret-dy"
	else
		print_green "Cyrillic path check passed"
	fi
	echo

	# cloud sync dirs (analog of the OneDrive check)
	case "$ROOT_DIR" in
		*Dropbox*|*OneDrive*|*"Google Drive"*|*Yandex.Disk*|*"Яндекс.Диск"*)
			print_red "[X] Zapret is installed in a cloud-sync folder"
			print_red "If bypass doesn't work, move Zapret to another directory, for example /opt/zapret-dy"
			;;
		*) print_green "Cloud-sync folder check passed" ;;
	esac
	echo

	# Discord cache clearing (interactive)
	local c="y"
	if [ -t 0 ]; then
		c="$(read_choice "Do you want to clear the Discord cache? (Y/N) (default: Y) " "y")"
	else
		c="${ZAPRET_CLEAR_CACHE:-n}"
	fi
	case "$c" in
		[yY]*)
			local found=0 u d
			for u in /home/* /root; do
				[ -d "$u" ] || continue
				for d in "$u/.config/discord" "$u/.config/discordptb" "$u/.config/discordcanary" "$u/.config/discorddevelopment"; do
					if [ -d "$d" ]; then
						found=1
						clear_discord_cache "[Dd]iscord" "Discord ($d)" "$d"
					fi
				done
			done
			# flatpak installs
			if [ -d /var/lib/flatpak/app/com.discordapp.Discord ]; then
				found=1
				print_yellow "[?] Flatpak Discord detected. Clear cache via: flatpak run --command=sh com.discordapp.Discord"
			fi
			[ "$found" = "0" ] && print_red "Discord installations were not found"
			;;
	esac
	echo
}

# запуск тестов стратегий (аналог пункта 12 меню)
do_run_tests() {
	if [ ! -x "$ROOT_DIR/test_zapret.sh" ]; then
		chmod +x "$ROOT_DIR/test_zapret.sh" 2>/dev/null || true
	fi
	exec "$ROOT_DIR/test_zapret.sh" "$@"
}

# меню, нумерация пунктов один в один с service.bat
show_menu() {
	load_game_filter
	local strategy
	strategy="$(strategy_get)"

	clear 2>/dev/null || true
	echo
	echo "  ZAPRET SERVICE MANAGER v$(port_version) (upstream v$(local_version))"
	echo "  ${strategy:+Strategy: $strategy}"
	echo "  ----------------------------------------"
	echo
	echo "  :: SERVICE"
	echo "     1. Install Service"
	echo "     2. Remove Services"
	echo "     3. Check Status"
	echo
	echo "  :: SETTINGS"
	echo "     4. Game Filter         [$GF_STATUS]"
	echo "     5. IPSet Filter        [$(ipset_status)]"
	echo "     6. Auto-Update Check   [$([ -f "$UTILS_DIR/check_updates.enabled" ] && echo enabled || echo disabled)]"
	echo "     7. Replace active fakes"
	echo
	echo "  :: UPDATES"
	echo "     8. Update IPSet List"
	echo "     9. Update Hosts File"
	echo "     10. Check for Updates"
	echo
	echo "  :: TOOLS"
	echo "     11. Run Diagnostics"
	echo "     12. Run Tests"
	echo
	echo "  ----------------------------------------"
	echo "     0. Exit"
	echo
}

do_menu() {
	check_updates soft &
	while true; do
		show_menu
		local c
		c="$(read_choice "   Select option (0-12): " "0")"
		case "$c" in
			1)  clear 2>/dev/null; do_install ""; pause ;;
			2)  clear 2>/dev/null; do_remove; pause ;;
			3)  clear 2>/dev/null; do_status; pause ;;
			4)  do_game_filter_menu ;;
			5)  clear 2>/dev/null; do_ipset_switch; pause ;;
			6)  clear 2>/dev/null; do_check_updates_switch; pause ;;
			7)  clear 2>/dev/null; do_replace_fakes ;;
			8)  clear 2>/dev/null; do_ipset_update; pause ;;
			9)  clear 2>/dev/null; do_hosts_update; pause ;;
			10) clear 2>/dev/null; check_updates hard; pause ;;
			11) clear 2>/dev/null; do_diagnostics; pause ;;
			12) clear 2>/dev/null; do_run_tests; exit $? ;;
			0)  exit 0 ;;
			*)  : ;;
		esac
	done
}

# разбор командной строки
main() {
	local cmd="${1:-menu}"
	if [ $# -gt 0 ]; then shift; fi
	case "$cmd" in
		menu|"")           do_menu ;;
		install)           do_install "${1:-}" ;;
		remove|uninstall)  do_remove ;;
		start)
			require_root || exit 1
			# shellcheck disable=SC2046
			sf="$(current_strategy_file)" || sf="$ROOT_DIR/$(list_strategies | head -n1)"
			do_start "$sf" ;;
		stop)              do_stop ;;
		restart)
			do_stop; sleep 1
			# shellcheck disable=SC2046
			sf="$(current_strategy_file)" || sf="$ROOT_DIR/$(list_strategies | head -n1)"
			do_start "$sf" ;;
		status)            do_status ;;
		status_zapret)     do_status_soft ;;
		check_updates|check-updates) check_updates "${1:-hard}" ;;
		load_game_filter)  load_game_filter; echo "GameFilterTCP=$GF_TCP"; echo "GameFilterUDP=$GF_UDP"; echo "Status: $GF_STATUS" ;;
		load_user_lists)   load_user_lists; echo "User lists OK" ;;
		game-filter|game_switch) do_game_filter_cli "$@" ;;
		ipset-status)      ipset_status; echo ;;
		ipset-switch|ipset_switch) do_ipset_switch ;;
		check-updates-switch) do_check_updates_switch ;;
		update-ipset|ipset-update) do_ipset_update ;;
		update-hosts|hosts-update) do_hosts_update ;;
		diagnostics)       do_diagnostics ;;
		run-tests|tests)   do_run_tests "$@" ;;
		replace-fakes)     do_replace_fakes ;;
		replace-fakes-cli) do_replace_fakes_cli "$@" ;;
		list-strategies)   list_strategies ;;
		systemd-start)     do_systemd_start ;;
		systemd-stop)      do_systemd_stop ;;
		firewall)          exec "$ROOT_DIR/firewall.sh" "$@" ;;
		help|-h|--help)
			cat <<'EOF'
service.sh - менеджер, аналог виндового service.bat

  sudo ./service.sh                     меню (пункты 0-12, как в оригинале)
  sudo ./service.sh install [strat.sh]  поставить службу systemd (или демон)
  sudo ./service.sh remove              убрать службу, остановить, почистить правила
  sudo ./service.sh start|stop|restart|status
  sudo ./service.sh diagnostics         проверка окружения
  sudo ./service.sh run-tests           тесты стратегий (test_zapret.sh)
  sudo ./service.sh game-filter ...     игровой фильтр (status/disable/all/tcp/udp/range-*)
  sudo ./service.sh ipset-switch        режим ipset: loaded -> none -> any
  sudo ./service.sh update-ipset        свежий список ipset-all из upstream
  sudo ./service.sh update-hosts        проверить/дополнить /etc/hosts
  sudo ./service.sh replace-fakes       подмена активных фейков *.bin
  ./service.sh check-updates            проверка обновлений репозитория
  ./service.sh list-strategies          список стратегий по порядку
  sudo ./service.sh firewall ...        правила фаервола (start/stop/status/print)
EOF
			;;
		*) print_red "Unknown command: $cmd (try 'help')"; exit 1 ;;
	esac
}

main "$@"

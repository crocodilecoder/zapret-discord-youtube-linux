#!/usr/bin/env bash
# firewall.sh - заводит трафик в nfqueue, где его ждёт nfqws.
# на винде пакеты ловил windivert (--wf-tcp/--wf-udp), тут это делает фаервол.
# использование: firewall.sh {start|stop|restart|status|print|nft-script}
set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./common.sh

CHAIN="ZAPRET_DY"
DESYNC_MARK="${ZAPRET_DESYNC_MARK:-0x40000000}"   # как в upstream zapret
QNUM="$ZAPRET_QNUM"
FW_BACKEND="${ZAPRET_FW:-auto}"                   # auto|iptables|nft, кому что нравится
ROUTER_MODE="${ZAPRET_ROUTER:-0}"                 # 1 = крутить и FORWARD (машина-шлюз)
ROUTER_IFACE="${ZAPRET_ROUTER_IFACE:-}"           # внешний интерфейс в режиме шлюза

IPT=""
IPT6=""

# iptables -m multiport понимает диапазоны только через двоеточие,
# а у нас они везде через дефис (как в --wf-udp у winws) - приводим к виду iptables
to_ipt_ports() {
	printf '%s' "$1" | sed -E 's/([0-9]+)-([0-9]+)/\1:\2/g'
}

detect_backend() {
	case "$FW_BACKEND" in
		iptables) IPT="iptables"; IPT6="ip6tables" ;;
		nft)      IPT="nft" ;;
		auto|"")
			if command -v iptables >/dev/null 2>&1 && iptables -nL OUTPUT >/dev/null 2>&1; then
				IPT="iptables"
				IPT6="ip6tables"
			elif command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
				IPT="nft"
			else
				return 1
			fi
			;;
		*) print_red "Unknown ZAPRET_FW=$FW_BACKEND"; return 1 ;;
	esac
	return 0
}

# iptables backend
ipt_chain_exists() {
	$IPT -t mangle -nL "$CHAIN" >/dev/null 2>&1
}

ipt_flush_chain() {
	# detach then flush, so re-running start is always clean
	$IPT -t mangle -D OUTPUT -j "$CHAIN" 2>/dev/null || true
	if [ "$ROUTER_MODE" = "1" ]; then
		$IPT -t mangle -D FORWARD -j "$CHAIN" 2>/dev/null || true
		$IPT6 -t mangle -D FORWARD -j "$CHAIN" 2>/dev/null || true
	fi
	$IPT6 -t mangle -D OUTPUT -j "$CHAIN" 2>/dev/null || true
	$IPT -t mangle -F "$CHAIN" 2>/dev/null || true
	$IPT6 -t mangle -F "$CHAIN" 2>/dev/null || true
	$IPT -t mangle -X "$CHAIN" 2>/dev/null || true
	$IPT6 -t mangle -X "$CHAIN" 2>/dev/null || true
}

ipt_start() {
	local tcp udp
	tcp="$(to_ipt_ports "$(zapret_tcp_ports)")"
	udp="$(to_ipt_ports "$(zapret_udp_ports)")"

	ipt_flush_chain
	$IPT  -t mangle -N "$CHAIN" || return 1
	$IPT6 -t mangle -N "$CHAIN" 2>/dev/null || true

	# пакеты, которые nfqws впрыснул обратно, не ловим - на них метка
	$IPT  -t mangle -A "$CHAIN" -m mark --mark "$DESYNC_MARK/$DESYNC_MARK" -j RETURN
	$IPT6 -t mangle -A "$CHAIN" -m mark --mark "$DESYNC_MARK/$DESYNC_MARK" -j RETURN 2>/dev/null || true

	# connbytes: десинк нужен только на первых пакетах соединения, дальше не трогам
	local cb=""
	if [ "${ZAPRET_CONNBYTES:-1}" = "1" ] && \
	   $IPT -t mangle -A "$CHAIN" -p tcp -m connbytes --connbytes 1:4 \
		--connbytes-dir both --connbytes-mode packets -j RETURN 2>/dev/null; then
		$IPT -t mangle -D "$CHAIN" -p tcp -m connbytes --connbytes 1:4 \
			--connbytes-dir both --connbytes-mode packets -j RETURN 2>/dev/null
		cb="-m connbytes --connbytes 1:4 --connbytes-dir both --connbytes-mode packets"
	fi

	local common_rules=(
		"-p tcp -m multiport --dports $tcp"
		"-p udp -m multiport --dports $udp"
	)
	local r
	for r in "${common_rules[@]}"; do
		# shellcheck disable=SC2086
		$IPT  -t mangle -A "$CHAIN" $r $cb -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
		# shellcheck disable=SC2086
		$IPT6 -t mangle -A "$CHAIN" $r $cb -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true
	done

	$IPT  -t mangle -A OUTPUT  -j "$CHAIN" || return 1
	$IPT6 -t mangle -A OUTPUT  -j "$CHAIN" 2>/dev/null || true
	if [ "$ROUTER_MODE" = "1" ]; then
		$IPT  -t mangle -A FORWARD -j "$CHAIN" || true
		$IPT6 -t mangle -A FORWARD -j "$CHAIN" 2>/dev/null || true
	fi

	# connmark для autottl-схем, как в upstream
	$IPT  -t mangle -A POSTROUTING -m mark --mark "$DESYNC_MARK/$DESYNC_MARK" -j CONNMARK --or-mark "$DESYNC_MARK" 2>/dev/null || true
	$IPT6 -t mangle -A POSTROUTING -m mark --mark "$DESYNC_MARK/$DESYNC_MARK" -j CONNMARK --or-mark "$DESYNC_MARK" 2>/dev/null || true
	$IPT  -t mangle -A PREROUTING -j CONNMARK --restore-mark --mask "$DESYNC_MARK" 2>/dev/null || true
	$IPT6 -t mangle -A PREROUTING -j CONNMARK --restore-mark --mask "$DESYNC_MARK" 2>/dev/null || true
	return 0
}

ipt_stop() {
	ipt_flush_chain
	$IPT  -t mangle -D POSTROUTING -m mark --mark "$DESYNC_MARK/$DESYNC_MARK" -j CONNMARK --or-mark "$DESYNC_MARK" 2>/dev/null || true
	$IPT6 -t mangle -D POSTROUTING -m mark --mark "$DESYNC_MARK/$DESYNC_MARK" -j CONNMARK --or-mark "$DESYNC_MARK" 2>/dev/null || true
	$IPT  -t mangle -D PREROUTING -j CONNMARK --restore-mark --mask "$DESYNC_MARK" 2>/dev/null || true
	$IPT6 -t mangle -D PREROUTING -j CONNMARK --restore-mark --mask "$DESYNC_MARK" 2>/dev/null || true
	return 0
}

ipt_status() {
	ipt_chain_exists && $IPT -t mangle -S OUTPUT 2>/dev/null | grep -qF -- "-j $CHAIN"
}

# nft backend (pure nft, for distros without iptables-nft)
nft_table() { echo "table inet zapret_dy"; }

nft_start() {
	local tcp udp setdef
	tcp="$(zapret_tcp_ports | sed 's/,/, /g')"
	udp="$(zapret_udp_ports | sed 's/,/, /g')"
	nft delete table inet zapret_dy 2>/dev/null || true
	setdef="{ type inet_service; elements = { $tcp } }"
	nft -f - <<EOF || return 1
table inet zapret_dy {
	set tcp_ports $setdef
	set udp_ports { type inet_service; elements = { $udp } }
	chain output {
		type filter hook output priority mangle; policy accept;
		meta mark and $DESYNC_MARK == $DESYNC_MARK counter accept
		tcp dport @tcp_ports counter queue num $QNUM bypass
		udp dport @udp_ports counter queue num $QNUM bypass
	}
}
EOF
	return 0
}

nft_stop() {
	nft delete table inet zapret_dy 2>/dev/null || true
	return 0
}

nft_status() {
	nft list table inet zapret_dy >/dev/null 2>&1
}

nft_script() {
	# print a standalone nft script (for manual use / other frontends)
	local tcp udp
	tcp="$(zapret_tcp_ports | sed 's/,/, /g')"
	udp="$(zapret_udp_ports | sed 's/,/, /g')"
	cat <<EOF
#!/usr/sbin/nft -f
table inet zapret_dy {
	set tcp_ports { type inet_service; elements = { $tcp } }
	set udp_ports { type inet_service; elements = { $udp } }
	chain output {
		type filter hook output priority mangle; policy accept;
		meta mark and $DESYNC_MARK == $DESYNC_MARK counter accept
		tcp dport @tcp_ports counter queue num $QNUM bypass
		udp dport @udp_ports counter queue num $QNUM bypass
	}
}
EOF
}

fw_start() {
	if ! detect_backend; then
		print_red "[ERROR] no working firewall backend found (iptables/nft)."
		print_red "        Need root rights and kernel netfilter support."
		return 1
	fi
	case "$IPT" in
		nft) nft_start ;;
		*)   ipt_start ;;
	esac
}

fw_stop() {
	if ! detect_backend; then return 0; fi
	case "$IPT" in
		nft) nft_stop ;;
		*)   ipt_stop ;;
	esac
}

fw_status() {
	detect_backend || return 1
	case "$IPT" in
		nft) nft_status ;;
		*)   ipt_status ;;
	esac
}

queue_stats() {
	if [ -r /proc/net/netfilter/nfnetlink_queue ]; then
		awk -v q="$QNUM" '$1==q { printf "queue %s: peer_pid=%s queued=%d dropped=%d\n", $1, $3, $5, $6 }' \
			/proc/net/netfilter/nfnetlink_queue
	fi
}

cmd="${1:-help}"
case "$cmd" in
	start)
		require_root || exit 1
		load_game_filter
		if fw_start; then
			print_green "Firewall rules applied (queue $QNUM, TCP: $(zapret_tcp_ports), UDP: $(zapret_udp_ports))."
		else
			print_red "Failed to apply firewall rules."
			exit 1
		fi
		;;
	stop)
		require_root || exit 1
		fw_stop
		print_green "Firewall rules removed."
		;;
	restart)
		require_root || exit 1
		fw_stop
		load_game_filter
		if fw_start; then
			print_green "Firewall rules re-applied (queue $QNUM)."
		else
			exit 1
		fi
		;;
	status)
		if fw_status; then
			print_green "Firewall rules are ACTIVE (backend: $IPT, queue $QNUM)."
			case "$IPT" in
				nft) nft list table inet zapret_dy 2>/dev/null | sed 's/^/  /' ;;
				*)   $IPT -t mangle -S "$CHAIN" 2>/dev/null | sed 's/^/  /' ;;
			esac
			queue_stats | sed 's/^/  /'
		else
			print_yellow "Firewall rules are NOT active. Run: sudo $0 start"
			exit 1
		fi
		;;
	status-quiet)
		# машинный вывод для скриптов: active|inactive
		if fw_status; then echo active; else echo inactive; fi
		;;
	print)
		load_game_filter
		echo "# Backend: ${IPT:-auto-detect at runtime}"
		load_game_filter
		echo "# TCP ports: $(zapret_tcp_ports)"
		echo "# UDP ports: $(zapret_udp_ports)"
		if [ "${IPT:-auto}" = "nft" ] || [ "$FW_BACKEND" = "nft" ]; then
			nft_script
		else
			tcp="$(to_ipt_ports "$(zapret_tcp_ports)")"
			udp="$(to_ipt_ports "$(zapret_udp_ports)")"
			cat <<EOF
iptables -t mangle -N $CHAIN
iptables -t mangle -A $CHAIN -m mark --mark $DESYNC_MARK/$DESYNC_MARK -j RETURN
iptables -t mangle -A $CHAIN -p tcp -m multiport --dports $tcp -j NFQUEUE --queue-num $QNUM --queue-bypass
iptables -t mangle -A $CHAIN -p udp -m multiport --dports $udp -j NFQUEUE --queue-num $QNUM --queue-bypass
iptables -t mangle -A OUTPUT -j $CHAIN
# (same for ip6tables)
EOF
		fi
		;;
	nft-script)
		load_game_filter
		nft_script
		;;
	help|*)
		cat <<EOF
zapret-discord-youtube firewall manager (Linux port of WinDivert capture)

Usage: $0 {start|stop|restart|status|print|nft-script}

  start       apply NFQUEUE rules (queue $QNUM) for zapret ports
  stop        remove the rules
  restart     re-apply (needed after game filter changes)
  status      show current rules and queue statistics
  print       show equivalent iptables commands without applying
  nft-script  show equivalent nftables script

Environment:
  ZAPRET_QNUM=NFQUEUE number (default 200)
  ZAPRET_FW=auto|iptables|nft (default auto)
  ZAPRET_ROUTER=1 also process FORWARD chain (gateway mode)
  ZAPRET_CONNBYTES=0 disable connbytes optimization
EOF
		;;
esac

#!/usr/bin/env bash
# mocks/env.sh - creates a sandbox with fake systemctl/iptables/nfqws/sysctl
# and exports ZAPRET_* overrides. Source it from test scripts.
# Usage: . mocks/env.sh ; setup_mock_env
setup_mock_env() {
	MOCK_ROOT="$(mktemp -d)"
	MOCK_BIN="$MOCK_ROOT/bin"
	MOCK_BIN_NONSYS="$MOCK_ROOT/bin-nosys"
	MOCK_RUN="$MOCK_ROOT/run"
	MOCK_ETC="$MOCK_ROOT/etc"
	mkdir -p "$MOCK_BIN" "$MOCK_BIN_NONSYS" "$MOCK_RUN/systemd/system" "$MOCK_ETC/systemd/system"

	# ---- iptables / ip6tables mock (log + tiny state) ----------------------
	cat > "$MOCK_BIN/iptables" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
log="${MOCK_LOG_DIR:-/tmp}/$name.log"
state="${MOCK_STATE_DIR:-/tmp}/$name.state"
mkdir -p "$(dirname "$log")"
printf '%s\n' "$*" >> "$log"
args="$*"
# query modes used by firewall.sh detect/status
case "$args" in
	*"-nL OUTPUT"*)    exit 0 ;;
	*"-S OUTPUT"*)     grep -E '^-A OUTPUT .*-j ZAPRET_DY' "$state" 2>/dev/null; exit $? ;;
	*"-nL ZAPRET_DY"*) grep -qE '^-N ZAPRET_DY' "$state" 2>/dev/null; exit $? ;;
	*"-S ZAPRET_DY"*)  grep -E '^-A ZAPRET_DY' "$state" 2>/dev/null; exit $? ;;
esac
if [[ "$args" == *"-N ZAPRET_DY"* ]]; then
	echo "-N ZAPRET_DY" >> "$state"; exit 0
fi
if [[ "$args" == *"-A OUTPUT -j ZAPRET_DY"* ]]; then
	echo "-A OUTPUT -j ZAPRET_DY" >> "$state"; exit 0
fi
if [[ "$args" == *"-D OUTPUT -j ZAPRET_DY"* ]]; then
	grep -v '^-A OUTPUT -j ZAPRET_DY$' "$state" > "$state.t" 2>/dev/null
	mv "$state.t" "$state" 2>/dev/null
	exit 0
fi
if [[ "$args" == *"-A FORWARD -j ZAPRET_DY"* ]]; then
	echo "-A FORWARD -j ZAPRET_DY" >> "$state"; exit 0
fi
if [[ "$args" == *"-D FORWARD -j ZAPRET_DY"* ]]; then
	grep -v '^-A FORWARD -j ZAPRET_DY$' "$state" > "$state.t" 2>/dev/null
	mv "$state.t" "$state" 2>/dev/null
	exit 0
fi
if [[ "$args" == *"-F ZAPRET_DY"* || "$args" == *"-X ZAPRET_DY"* ]]; then
	grep -vE '^-N ZAPRET_DY$|^-A ZAPRET_DY' "$state" > "$state.t" 2>/dev/null
	mv "$state.t" "$state" 2>/dev/null
	exit 0
fi
# connbytes probe must fail on the mock ("module not available")
if [[ "$args" == *"connbytes"* ]]; then
	exit 1
fi
if [[ "$args" == *"-A ZAPRET_DY"* ]]; then
	echo "$args" | sed 's/^-t mangle -A ZAPRET_DY/-A ZAPRET_DY/' >> "$state"
	exit 0
fi
if [[ "$args" == *"-D ZAPRET_DY"* ]]; then
	exit 0
fi
exit 0
EOF
	chmod +x "$MOCK_BIN/iptables"
	cp "$MOCK_BIN/iptables" "$MOCK_BIN/ip6tables"

	# ---- systemctl mock (stateful; start => runs unit ExecStart) -----------
	cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
state="${MOCK_STATE_DIR:-/tmp}/systemctl.state"
unit_dir="${MOCK_ETC:-/etc}/systemd/system"
touch "$state"
is_active() { grep -qx "active $1" "$state"; }
set_active() {
	grep -v "^active $1$" "$state" > "$state.t" 2>/dev/null
	mv "$state.t" "$state"
	echo "active $1" >> "$state"
}
set_inactive() {
	grep -v "^active $1$" "$state" > "$state.t" 2>/dev/null
	mv "$state.t" "$state"
}
case "$1" in
	is-active)
		if [ "$2" = "--quiet" ]; then
			unit="$3"
			is_active "$unit" && exit 0 || exit 3
		else
			if is_active "$2"; then echo active; else echo inactive; exit 3; fi
		fi ;;
	is-enabled)
		[ -f "$unit_dir/$2.service" ] || exit 1
		echo enabled ;;
	start)
		unit="$unit_dir/$2.service"
		[ -f "$unit" ] || { echo "Unit $2.service not found." >&2; exit 5; }
		cmd="$(sed -n 's/^ExecStart=//p' "$unit")"
		if [ -n "$cmd" ]; then
			# shellcheck disable=SC2086
			if $cmd >/dev/null 2>&1; then set_active "$2"; else exit 1; fi
		else
			set_active "$2"
		fi
		;;
	stop)
		unit="$unit_dir/$2.service"
		if [ -f "$unit" ]; then
			cmd="$(sed -n 's/^ExecStop=//p' "$unit")"
			# shellcheck disable=SC2086
			[ -n "$cmd" ] && $cmd >/dev/null 2>&1
		fi
		set_inactive "$2" ;;
	enable|disable|daemon-reload|daemon-reexec|list-units) exit 0 ;;
	*) exit 0 ;;
esac
EOF
	chmod +x "$MOCK_BIN/systemctl"

	# ---- nft mock (records invocations; accepts -c syntax check) ------------
	cat > "$MOCK_BIN/nft" <<'EOF'
#!/usr/bin/env bash
log="${MOCK_LOG_DIR:-/tmp}/nft.log"
state="${MOCK_STATE_DIR:-/tmp}/nft.state"
printf '%s\n' "$*" >> "$log"
args="$*"
if [[ "$args" == "-f -" || "$args" == "-f -"* ]]; then
	cat > /dev/null
	echo "table inet zapret_dy { }" > "$state"
	exit 0
fi
if [[ "$args" == "-c -f "* ]]; then
	# syntax-check mode: validate braces balance of the given file
	file="${args##*-f }"
	if [ -f "$file" ]; then
		awk 'BEGIN{d=0} {n=gsub(/{/,"{"); m=gsub(/}/,"}"); d+=n-m} END{exit (d==0)?0:1}' "$file" && exit 0
		exit 1
	fi
	exit 0
fi
case "$1" in
	list)   [ -f "$state" ] || exit 1; cat "$state"; exit 0 ;;
	delete) rm -f "$state"; exit 0 ;;
	*)      exit 0 ;;
esac
EOF
	chmod +x "$MOCK_BIN/nft"

	# ---- sysctl mock --------------------------------------------------------
	cat > "$MOCK_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "sysctl $*" >> "${MOCK_LOG_DIR:-/tmp}/sysctl.log"
case "$1" in
	-w) echo "${2//= = /}" | tr -d ' ' ;;
	*)  echo "net.ipv4.tcp_timestamps = 1" ;;
esac
exit 0
EOF
	chmod +x "$MOCK_BIN/sysctl"

	# ---- fake nfqws (daemonizes: forks a process named 'nfqws') -------------
	cat > "$MOCK_ROOT/nfqws-mock" <<'EOF'
#!/usr/bin/env bash
PF=""
daemon=0
for a in "$@"; do
	case "$a" in
		--version) echo "mock-nfqws test version"; exit 0 ;;
		--dry-run) exit 0 ;;
		--pidfile=*) PF="${a#--pidfile=}" ;;
		--daemon) daemon=1 ;;
	esac
done
run() {
	if [ -n "$PF" ]; then echo $1 > "$PF"; fi
	# exec a binary whose FILE NAME is exactly 'nfqws' (symlink to sleep),
	# so /proc/pid/comm == "nfqws" and pgrep/pkill -x match it like the real one
	self="$(readlink -f "$0")"
	exec "$(dirname "$self")/helper/nfqws" 3600 </dev/null >/dev/null 2>&1
}
if [ "$daemon" = "1" ]; then
	( run "$BASHPID" & )
	sleep 0.3
	exit 0
fi
run "$BASHPID"
EOF
	chmod +x "$MOCK_ROOT/nfqws-mock"
	# a real file named exactly 'nfqws' (-> sleep) for comm-based process matching
	mkdir -p "$MOCK_ROOT/helper"
	ln -sf "$(command -v sleep)" "$MOCK_ROOT/helper/nfqws"

	# bin-nosys: same mocks but WITHOUT systemctl (simulates a system without systemd)
	for m in iptables ip6tables sysctl nft; do cp "$MOCK_BIN/$m" "$MOCK_BIN_NONSYS/$m"; done
	cp "$MOCK_ROOT/nfqws-mock" "$MOCK_BIN_NONSYS/nfqws-mock"

	export MOCK_ROOT MOCK_BIN MOCK_BIN_NONSYS MOCK_RUN MOCK_ETC
	export MOCK_LOG_DIR="$MOCK_ROOT/logs"
	export MOCK_STATE_DIR="$MOCK_ROOT/state"
	mkdir -p "$MOCK_LOG_DIR" "$MOCK_STATE_DIR"
	export PATH="$MOCK_BIN:$PATH"
	export ZAPRET_RUN_DIR="$MOCK_RUN/zapret-dy"
	export ZAPRET_UNIT_FILE="$MOCK_ETC/systemd/system/zapret.service"
	export ZAPRET_SYSTEMD_DIR="$MOCK_RUN/systemd/system"
}

cleanup_mock_env() {
	if [ -n "${MOCK_ROOT:-}" ] && [ -d "$MOCK_ROOT" ]; then
		rm -rf "$MOCK_ROOT"
	fi
}

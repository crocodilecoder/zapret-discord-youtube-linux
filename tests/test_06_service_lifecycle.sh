#!/usr/bin/env bash
# test_06_service_lifecycle.sh - full service lifecycle against mocks:
# install/start/stop/restart/remove via fake systemctl + fake nfqws daemon,
# standalone strategy run, non-systemd daemon mode, menu smoke.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_utils.sh
# shellcheck disable=SC1091
. ./mocks/env.sh

setup_mock_env
trap 'pkill -x nfqws 2>/dev/null; cleanup_mock_env' EXIT

SVC="$ROOT/service.sh"

# live_nfqws_count - zombie-safe count of running 'nfqws' processes
live_nfqws_count() {
	local n=0 d c st
	for d in /proc/[0-9]*; do
		c="$(cat "$d/comm" 2>/dev/null)" || continue
		if [ "$c" = "nfqws" ]; then
			st="$(cut -d' ' -f3 "$d/stat" 2>/dev/null)"
			[ "$st" != "Z" ] && n=$((n+1))
		fi
	done
	printf '%s' "$n"
}
export ZAPRET_NFQWS="$MOCK_ROOT/nfqws-mock"
export NO_UPDATE_CHECK=1
PIDFILE="$ZAPRET_RUN_DIR/zapret.pid"
UNIT="$ZAPRET_UNIT_FILE"
IPTLOG="$MOCK_LOG_DIR/iptables.log"

echo "== install (systemd mode) =="
out="$(timeout 60 "$SVC" install general.sh 2>&1)"; rc=$?
assert_ok "install rc" "$rc"
assert_file_contains "unit file generated" "$UNIT" '^ExecStart=.*service\.sh systemd-start'
assert_file_contains "unit PIDFile" "$UNIT" "^PIDFile=$PIDFILE"
assert_eq "mock systemctl: active" "active" "$(systemctl is-active zapret)"
assert_file_contains "pidfile created" "$PIDFILE" '^[0-9]+$'
pid="$(cat "$PIDFILE")"
if [ "$(live_nfqws_count)" -ge 1 ]; then ok "nfqws (mock) running pid=$pid"; else bad "nfqws (mock) not running"; fi
assert_file_contains "firewall rules applied" "$IPTLOG" -- '-j NFQUEUE --queue-num 200'
assert_eq "strategy recorded" "general.sh" "$(cat "$ZAPRET_RUN_DIR/strategy")"

echo "== status =="
out="$(timeout 60 "$SVC" status 2>&1)"
assert_contains "status: service RUNNING" "$out" "service is RUNNING"
assert_contains "status: nfqws RUNNING"   "$out" "Bypass (nfqws) is RUNNING"
assert_contains "status: strategy"        "$out" "Strategy: general.sh"
assert_contains "status: firewall"        "$out" "Firewall (NFQUEUE) rules are ACTIVE"

echo "== stop =="
timeout 60 "$SVC" stop >/dev/null 2>&1; assert_ok "stop rc" $?
sleep 0.3
if [ "$(live_nfqws_count)" -ge 1 ]; then bad "nfqws still running after stop"; else ok "nfqws stopped"; fi
st="$(systemctl is-active zapret 2>/dev/null)" || st="inactive"; assert_eq "systemd inactive after stop" "inactive" "$st"
assert_file_contains "firewall detached on stop" "$IPTLOG" -- '-D OUTPUT -j ZAPRET_DY'

echo "== start / restart =="
timeout 60 "$SVC" start >/dev/null 2>&1; assert_ok "start rc" $?
if [ -f "$PIDFILE" ]; then ok "pidfile recreated"; else bad "no pidfile after start"; fi
timeout 60 "$SVC" restart >/dev/null 2>&1; assert_ok "restart rc" $?
if [ -f "$PIDFILE" ] && [ "$(live_nfqws_count)" -ge 1 ]; then ok "running after restart"; else bad "not running after restart"; fi

echo "== standalone strategy must refuse while service is active =="
NO_UPDATE_CHECK=1 timeout 60 "$ROOT/general.sh" > "$MOCK_ROOT/standalone.out" 2>&1
sa_rc=$?
if [ "$sa_rc" = "0" ] || [ "$sa_rc" = "10" ]; then ok "general.sh aborts while service active (rc=$sa_rc)"; else bad "general.sh rc=$sa_rc"; fi
assert_contains "prints ALREADY RUNNING notice" "$(cat "$MOCK_ROOT/standalone.out")" "ALREADY RUNNING"

echo "== remove =="
timeout 60 "$SVC" remove >/dev/null 2>&1; assert_ok "remove rc" $?
if [ ! -f "$UNIT" ]; then ok "unit file removed"; else bad "unit file still present"; fi
sleep 0.3
if [ "$(live_nfqws_count)" -ge 1 ]; then bad "nfqws still running after remove"; else ok "nfqws killed on remove"; fi
if [ ! -f "$ZAPRET_RUN_DIR/strategy" ]; then ok "strategy state cleared"; else bad "strategy state left"; fi
echo "== non-systemd daemon mode =="
(
	# clean PATH without systemctl and without the systemd marker dir => no systemd
	unset ZAPRET_SYSTEMD_DIR
	export PATH="$MOCK_BIN_NONSYS:/usr/bin:/bin"
	export ZAPRET_NFQWS="$MOCK_ROOT/nfqws-mock"
	timeout 60 "$SVC" install general.sh > "$MOCK_ROOT/nosys.out" 2>&1
)
rc=$?
assert_ok "install without systemd rc" "$rc"
assert_contains "mentions daemon mode" "$(cat "$MOCK_ROOT/nosys.out")" "plain daemon"
if [ -f "$PIDFILE" ] && [ "$(live_nfqws_count)" -ge 1 ]; then ok "daemon running (pidfile)"; else bad "daemon not running"; fi
assert_file_contains "firewall applied in daemon mode" "$IPTLOG" -- '-j NFQUEUE --queue-num 200'
timeout 60 "$SVC" stop >/dev/null 2>&1
sleep 0.3
if [ "$(live_nfqws_count)" -ge 1 ]; then bad "daemon still running after stop"; else ok "daemon stopped"; fi
echo "== second instance refused =="
ZAPRET_DAEMON=1 ZAPRET_PIDFILE="$PIDFILE" timeout 60 "$ROOT/general.sh" >/dev/null 2>&1
sleep 0.5
if [ -f "$PIDFILE" ]; then ok "first instance started"; else bad "first instance failed"; fi
out="$(NO_UPDATE_CHECK=1 timeout 60 "$ROOT/general.sh" 2>&1)"; rc=$?
assert_fail "second standalone instance refused" "$rc"
assert_contains "refusal message" "$out" "already running"
pkill -x nfqws 2>/dev/null; sleep 0.3

echo "== menu smoke (non-interactive) =="
printf '3\n\n0\n' | timeout 60 "$SVC" > "$MOCK_ROOT/menu.out" 2>&1
assert_eq "menu exit 0" "0" "$?"
menu_out="$(cat "$MOCK_ROOT/menu.out")"
ver="$(tr -d ' \r\n' < "$ROOT/.service/version.txt")"
assert_contains "menu shows version" "$menu_out" "ZAPRET SERVICE MANAGER v$(tr -d ' \r\n' < "$ROOT/VERSION") (upstream v$ver)"
assert_contains "menu shows status page" "$menu_out" "Bypass (nfqws) is NOT running"

echo "== list-strategies for install menu =="
out="$(timeout 30 "$SVC" list-strategies)"
assert_eq "22 strategies" "22" "$(printf '%s\n' "$out" | wc -l)"

summary

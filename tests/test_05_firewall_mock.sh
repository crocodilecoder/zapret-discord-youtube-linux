#!/usr/bin/env bash
# test_05_firewall_mock.sh - firewall.sh against the iptables mock:
# verifies generated rule set (NFQUEUE, marks, ports, IPv6, router mode, stop).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_utils.sh
# shellcheck disable=SC1091
. ./mocks/env.sh

setup_mock_env
trap 'pkill -x nfqws 2>/dev/null; cleanup_mock_env' EXIT

FW="$ROOT/firewall.sh"
export ZAPRET_NFQWS="$MOCK_ROOT/nfqws-mock"
export ZAPRET_QNUM=200

echo "== start (default ports) =="
out="$("$FW" start 2>&1)"; rc=$?
assert_ok "firewall start rc" "$rc"

LOG="$MOCK_LOG_DIR/iptables.log"
assert_file_contains "chain created"            "$LOG" '^-t mangle -N ZAPRET_DY$'
assert_file_contains "desync-mark RETURN"       "$LOG" -- '-m mark --mark 0x40000000/0x40000000 -j RETURN'
assert_file_contains "tcp NFQUEUE q200"         "$LOG" -- '-p tcp -m multiport --dports 80,443,2053,2083,2087,2096,8443,12 -j NFQUEUE --queue-num 200 --queue-bypass'
assert_file_contains "udp NFQUEUE q200"         "$LOG" -- '-p udp -m multiport --dports 443,19294:19344,50000:50100,12 -j NFQUEUE --queue-num 200 --queue-bypass'
assert_file_contains "hook into OUTPUT"         "$LOG" '^-t mangle -A OUTPUT -j ZAPRET_DY$'
assert_file_contains "connmark save"            "$LOG" -- '-t mangle -A POSTROUTING -m mark --mark 0x40000000/0x40000000 -j CONNMARK --or-mark 0x40000000'
LOG6="$MOCK_LOG_DIR/ip6tables.log"
assert_file_contains "ipv6 chain created"       "$LOG6" '^-t mangle -N ZAPRET_DY$'
assert_file_contains "ipv6 tcp NFQUEUE"         "$LOG6" -- '-p tcp -m multiport --dports 80,443'
assert_file_contains "ipv6 OUTPUT hook"         "$LOG6" '^-t mangle -A OUTPUT -j ZAPRET_DY$'
assert_file_not_contains "no connbytes (mock probe failed)" "$LOG" 'connbytes.*-j NFQUEUE'

echo "== status =="
assert_eq "status-quiet active" "active" "$("$FW" status-quiet)"
out="$("$FW" status 2>&1)"; assert_contains "status text" "$out" "ACTIVE"

echo "== stop =="
: > "$LOG"
"$FW" stop >/dev/null 2>&1; assert_ok "firewall stop rc" $?
assert_file_contains "detach OUTPUT" "$LOG" -- '-t mangle -D OUTPUT -j ZAPRET_DY'
assert_eq "status-quiet inactive" "inactive" "$("$FW" status-quiet)"

echo "== game filter changes port list =="
mkdir -p "$ROOT/utils"
GF_FILE="$ROOT/utils/game_filter.enabled"
gf_backup=""
[ -f "$GF_FILE" ] && { gf_backup="$(cat "$GF_FILE")"; }
printf 'mode=all\ntcp=1024-1934\nudp=2000-3000\n' > "$GF_FILE"
: > "$LOG"
"$FW" start >/dev/null 2>&1; assert_ok "start with game filter rc" $?
assert_file_contains "tcp ports include game range" "$LOG" -- '--dports 80,443,2053,2083,2087,2096,8443,1024:1934 '
assert_file_contains "udp ports include game range" "$LOG" -- '--dports 443,19294:19344,50000:50100,2000:3000 '
if [ -n "$gf_backup" ]; then printf '%s' "$gf_backup" > "$GF_FILE"; else rm -f "$GF_FILE"; fi

echo "== router mode adds FORWARD =="
: > "$LOG"
ZAPRET_ROUTER=1 "$FW" start >/dev/null 2>&1; assert_ok "router start rc" $?
assert_file_contains "FORWARD hooked" "$LOG" '^-t mangle -A FORWARD -j ZAPRET_DY$'
ZAPRET_ROUTER=1 "$FW" stop >/dev/null 2>&1
assert_file_contains "FORWARD detached on stop" "$LOG" '^-t mangle -D FORWARD -j ZAPRET_DY$'

echo "== print/nft-script don't touch the firewall =="
: > "$LOG"
out="$("$FW" print 2>&1)"; assert_ok "print rc" $?
assert_contains "print shows NFQUEUE" "$out" "NFQUEUE"
if [ ! -s "$LOG" ]; then ok "print applied nothing"; else bad "print modified firewall"; fi
out="$("$FW" nft-script 2>&1)"; assert_ok "nft-script rc" $?
assert_contains "nft script has queue" "$out" "queue num 200 bypass"

echo "== nft backend (mock) =="
: > "$MOCK_LOG_DIR/nft.log" 2>/dev/null || true
out="$(ZAPRET_FW=nft "$FW" start 2>&1)"; rc=$?
assert_ok "nft start rc" "$rc"
# shellcheck disable=SC2016  # literal regex, no expansion intended
assert_file_contains "nft table applied" "$MOCK_LOG_DIR/nft.log" '^-f -$'
assert_eq "nft status active" "active" "$(ZAPRET_FW=nft "$FW" status-quiet)"
out="$(ZAPRET_FW=nft "$FW" status 2>&1)"
assert_contains "nft status text" "$out" "ACTIVE"
ZAPRET_FW=nft "$FW" stop >/dev/null 2>&1
assert_file_contains "nft table deleted" "$MOCK_LOG_DIR/nft.log" '^delete table inet zapret_dy$'
assert_eq "nft status inactive" "inactive" "$(ZAPRET_FW=nft "$FW" status-quiet)"

# nft script syntax: comma-separated elements + real nft -c (parse)
nft_file="$MOCK_ROOT/zapret-test.nft"
"$FW" nft-script > "$nft_file"
assert_file_contains "elements comma separated" "$nft_file" 'elements = . 80, 443'
if command -v nft >/dev/null 2>&1; then
	if nft -c -f "$nft_file" 2>/dev/null; then
		ok "real nft -c validates the script"
	else
		# sandbox: netlink cache init may fail with EPERM - that's environmental
		errs="$(nft -c -f "$nft_file" 2>&1 | grep -v 'cache initialization' || true)"
		if [ -z "$errs" ]; then ok "real nft -c: only sandbox netlink limitation"; else bad "nft -c errors: $errs"; fi
	fi
fi
rm -f "$nft_file"

echo "== non-root error path =="
out="$(setpriv --reuid=65534 --regid=65534 --clear-groups env PATH="$PATH" "$FW" start 2>&1)"; rc=$?
assert_fail "start refused without root" "$rc"
assert_contains "root error message" "$out" "root"

summary

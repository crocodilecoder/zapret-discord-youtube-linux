#!/usr/bin/env bash
# test_08_e2e_pipeline.sh - end-to-end run of test_zapret.sh:
# local HTTP server + mock nfqws daemon; verifies the whole pipeline:
# config enumeration -> start/stop of strategies -> curl checks ->
# analytics -> best config -> report file -> snapshot restore.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_utils.sh
# shellcheck disable=SC1091
. ./mocks/env.sh

setup_mock_env
trap 'pkill -x nfqws 2>/dev/null; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null; cleanup_mock_env; rm -rf "$tmp"' EXIT
tmp="$(mktemp -d)"

export NO_UPDATE_CHECK=1
export ZAPRET_NFQWS="$MOCK_ROOT/nfqws-mock"
cp -r "$ROOT/utils" "$tmp/utils"
export ZAPRET_UTILS_DIR="$tmp/utils"
export ZAPRET_RUN_DIR="$MOCK_RUN/zapret-dy"

# --- local HTTP server (127.0.0.1) -----------------------------------------
mkdir -p "$tmp/www"
echo "test-ok" > "$tmp/www/index.html"
python3 -m http.server 18080 --bind 127.0.0.1 --directory "$tmp/www" >"$tmp/http.log" 2>&1 &
SRV_PID=$!
sleep 1
if ! kill -0 "$SRV_PID" 2>/dev/null; then
	bad "local HTTP server failed to start"; cat "$tmp/http.log"; summary
fi
ok "local HTTP server on 127.0.0.1:18080"

# --- targets fixture --------------------------------------------------------
cat > "$tmp/utils/targets.txt" <<EOF
# test targets
Local_HTTP = "http://127.0.0.1:18080/"
Local_HTTPS = "https://127.0.0.1:18080/"
Local_Ping = "PING:127.0.0.1"
EOF

# --- pre-start a mock nfqws to test snapshot/restore ------------------------
"$MOCK_ROOT/nfqws-mock" --daemon --qnum=777 --pidfile="$tmp/pre.pid"
sleep 0.5
if [ -f "$tmp/pre.pid" ] && kill -0 "$(cat "$tmp/pre.pid")" 2>/dev/null; then
	ok "pre-existing nfqws instance started (for snapshot test)"
	PRE_PID="$(cat "$tmp/pre.pid")"
else
	bad "could not start pre-existing mock instance"
	PRE_PID=""
fi

# --- run the tester on configs 1 and 3 --------------------------------------
ZAPRET_TEST_TYPE=standard ZAPRET_TEST_MODE=select ZAPRET_TEST_CONFIGS="1,3" \
	TEST_CURL_TIMEOUT=3 \
	"$ROOT/test_zapret.sh" > "$tmp/test.out" 2>&1
rc=$?
assert_ok "test_zapret.sh rc" "$rc"

out="$(cat "$tmp/test.out")"
assert_contains "banner shown"        "$out" "ZAPRET CONFIG TESTS"
assert_contains "mode STANDARD"       "$out" "Mode: STANDARD"
assert_contains "two configs"         "$out" "Total configs:  2"
cfg1="$( "$ROOT/service.sh" list-strategies | sed -n 1p )"
cfg3="$( "$ROOT/service.sh" list-strategies | sed -n 3p )"
assert_contains "config 1 tested"     "$out" "[1/2] $cfg1"
assert_contains "config 3 tested"     "$out" "[2/2] $cfg3"
assert_contains "HTTP target OK"      "$out" "HTTP:OK"
assert_contains "ping result present" "$out" "Ping:"
assert_contains "analytics section"   "$out" "=== ANALYTICS ==="
assert_contains "best config chosen"  "$out" "Best config:"

# report file written into utils/test results (fixture copy)
report="$(find "$tmp/utils/test results" -name 'test_results_*.txt' 2>/dev/null | head -n1)"
if [ -n "$report" ]; then
	ok "report file created: $(basename "$report")"
	assert_file_contains "report has config lines" "$report" '^Config: general.*\(Type: standard\)'
	assert_file_contains "report has analytics"    "$report" 'Best strategy:'
else
	bad "no report file in test results dir"
fi

# --- snapshot restore: the pre-started instance should be alive again --------
sleep 1
if [ -n "${PRE_PID:-}" ]; then
	if pgrep -x nfqws >/dev/null 2>&1; then
		ok "pre-existing nfqws instance restored after tests"
	else
		bad "snapshot restore did not bring nfqws back"
	fi
fi
pkill -x nfqws 2>/dev/null
sleep 0.3

echo "== non-interactive guard =="
out="$( "$ROOT/test_zapret.sh" < /dev/null 2>&1 )"; rc=$?
assert_fail "exits with error when no env prompts and no tty" "$rc"
assert_contains "explains env vars" "$out" "ZAPRET_TEST_TYPE"

summary

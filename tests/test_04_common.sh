#!/usr/bin/env bash
# test_04_common.sh - unit tests for common.sh functions
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_utils.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export ZAPRET_RUN_DIR="$tmp/run"
export ZAPRET_LISTS_DIR="$tmp/lists"
export ZAPRET_UTILS_DIR="$tmp/utils"
mkdir -p "$ZAPRET_RUN_DIR" "$ZAPRET_LISTS_DIR" "$ZAPRET_UTILS_DIR"

# shellcheck disable=SC1091
. "$ROOT/common.sh"

echo "== gf_validate_range =="
v="$(gf_validate_range "1024-65535")"; assert_ok "valid range 1024-65535" $?
assert_eq "normalized" "1024-65535" "$v"
gf_validate_range "1024-1934,1936-65535" >/dev/null; assert_ok "multi range" $?
gf_validate_range "443" >/dev/null; assert_ok "single port" $?
gf_validate_range "0-100" >/dev/null;   assert_fail "port 0 rejected" $?
gf_validate_range "70000" >/dev/null;   assert_fail "port >65535 rejected" $?
gf_validate_range "200-100" >/dev/null; assert_fail "reversed range rejected" $?
gf_validate_range "abc" >/dev/null;     assert_fail "garbage rejected" $?
gf_validate_range "" >/dev/null;        assert_fail "empty rejected" $?
gf_validate_range "10-20-30" >/dev/null; assert_fail "double dash rejected" $?

echo "== load_game_filter =="
load_game_filter
assert_eq "no flag file -> disabled" "disabled" "$GF_MODE"
assert_eq "GF_TCP default 12" "12" "$GF_TCP"
assert_eq "GF_UDP default 12" "12" "$GF_UDP"

printf 'mode=all\ntcp=1024-1934\nudp=2000-3000\n' > "$ZAPRET_UTILS_DIR/game_filter.enabled"
load_game_filter
assert_eq "mode=all parsed"  "all" "$GF_MODE"
assert_eq "tcp range parsed" "1024-1934" "$GF_TCP"
assert_eq "udp range parsed" "2000-3000" "$GF_UDP"
assert_eq "status all" "enabled (TCP and UDP)" "$GF_STATUS"

printf 'mode=tcp\ntcp=5000-6000\nudp=1024-65535\n' > "$ZAPRET_UTILS_DIR/game_filter.enabled"
load_game_filter
assert_eq "mode=tcp: GF_TCP set" "5000-6000" "$GF_TCP"
assert_eq "mode=tcp: GF_UDP=12" "12" "$GF_UDP"

printf 'mode=udp\ntcp=1024-65535\nudp=7777\n' > "$ZAPRET_UTILS_DIR/game_filter.enabled"
load_game_filter
assert_eq "mode=udp: GF_TCP=12" "12" "$GF_TCP"
assert_eq "mode=udp: GF_UDP set" "7777" "$GF_UDP"

printf 'mode=all\ntcp=99999\nudp=2000-3000\n' > "$ZAPRET_UTILS_DIR/game_filter.enabled"
load_game_filter
assert_eq "invalid tcp falls back to default" "1024-65535" "$GF_TCP"

# bat-style file with lone keywords: "all" line means mode=all
printf 'all\ntcp=1500-2500\n' > "$ZAPRET_UTILS_DIR/game_filter.enabled"
load_game_filter
assert_eq "bare 'all' line -> mode all" "all" "$GF_MODE"
rm -f "$ZAPRET_UTILS_DIR/game_filter.enabled"

echo "== save_game_filter_settings =="
GF_MODE="udp"; GF_TCP_RANGE="1024-65535"; GF_UDP_RANGE="4000-5000"
save_game_filter_settings
assert_file_contains "saved mode" "$ZAPRET_UTILS_DIR/game_filter.enabled" '^mode=udp$'
assert_file_contains "saved udp"  "$ZAPRET_UTILS_DIR/game_filter.enabled" '^udp=4000-5000$'
load_game_filter
assert_eq "roundtrip mode" "udp" "$GF_MODE"
assert_eq "roundtrip udp"  "4000-5000" "$GF_UDP"
rm -f "$ZAPRET_UTILS_DIR/game_filter.enabled"

echo "== load_user_lists =="
load_user_lists
assert_file_contains "ipset-exclude-user created" "$ZAPRET_LISTS_DIR/ipset-exclude-user.txt" '203\.0\.113\.113/32'
assert_file_contains "list-general-user created"  "$ZAPRET_LISTS_DIR/list-general-user.txt" 'domain\.example\.abc'
assert_file_contains "list-exclude-user created"  "$ZAPRET_LISTS_DIR/list-exclude-user.txt" 'domain\.example\.abc'
echo "my.domain.test" >> "$ZAPRET_LISTS_DIR/list-general-user.txt"
load_user_lists
assert_file_contains "user content preserved" "$ZAPRET_LISTS_DIR/list-general-user.txt" 'my\.domain\.test'

echo "== ipset_status =="
echo "1.2.3.0/24" > "$ZAPRET_LISTS_DIR/ipset-all.txt"
assert_eq "loaded" "loaded" "$(ipset_status)"
echo "203.0.113.113/32" > "$ZAPRET_LISTS_DIR/ipset-all.txt"
assert_eq "none" "none" "$(ipset_status)"
: > "$ZAPRET_LISTS_DIR/ipset-all.txt"
assert_eq "any (empty)" "any" "$(ipset_status)"
rm -f "$ZAPRET_LISTS_DIR/ipset-all.txt"
assert_eq "any (missing)" "any" "$(ipset_status)"

echo "== strategy state =="
strategy_set "general_ALT5.sh"
assert_eq "strategy_get" "general_ALT5.sh" "$(strategy_get)"

echo "== port lists =="
ports="$(zapret_tcp_ports)"
assert_eq "tcp ports default" "80,443,2053,2083,2087,2096,8443,12" "$ports"
ports="$(zapret_udp_ports)"
assert_eq "udp ports default" "443,19294-19344,50000-50100,12" "$ports"
printf 'mode=all\ntcp=1024-1934\nudp=2000-3000\n' > "$ZAPRET_UTILS_DIR/game_filter.enabled"
ports="$(zapret_tcp_ports)"
assert_eq "tcp ports with game filter" "80,443,2053,2083,2087,2096,8443,1024-1934" "$ports"
ports="$(zapret_udp_ports)"
assert_eq "udp ports with game filter" "443,19294-19344,50000-50100,2000-3000" "$ports"

echo "== local_version =="
assert_eq "version from .service/version.txt" "$(tr -d ' \r\n' < "$ROOT/.service/version.txt")" "$(local_version)"

echo "== ensure_traverse (home 700 -> 701) =="
td="$tmp/h700/a"; mkdir -p "$td"; chmod 700 "$tmp/h700"; chmod 755 "$td"
ensure_traverse "$td" >/dev/null 2>&1
assert_eq "каталог 700 стал 701 (проход без листинга)" "701" "$(stat -c %a "$tmp/h700")"
assert_eq "каталог с o+x не тронут" "755" "$(stat -c %a "$td")"

echo "== list_strategies ordering (natural sort like powershell in service.bat) =="
mapfile -t strategies < <("$ROOT/service.sh" list-strategies)
assert_eq "count = 22" "22" "${#strategies[@]}"
assert_eq "first = general_ALT.sh (like 1. general (ALT).bat in win menu)" "general_ALT.sh" "${strategies[0]}"
assert_eq "last = general.sh (like 22. general.bat)" "general.sh" "${strategies[${#strategies[@]}-1]}"
# ALT2 must come before ALT10 (numeric sort, not lexicographic)
i2=-1; i10=-1
for i in "${!strategies[@]}"; do
	[ "${strategies[$i]}" = "general_ALT2.sh" ]  && i2=$i
	[ "${strategies[$i]}" = "general_ALT10.sh" ] && i10=$i
done
if [ "$i2" -lt "$i10" ] && [ "$i2" -ge 0 ]; then ok "ALT2 sorted before ALT10"; else bad "ALT2 ($i2) vs ALT10 ($i10) ordering"; fi

summary

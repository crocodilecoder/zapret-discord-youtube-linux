#!/usr/bin/env bash
# test_07_utils_menu.sh - service.sh utility functions:
# ipset-switch, game-filter CLI, replace-fakes-cli, update-ipset,
# update-hosts, check-updates, diagnostics (with file:// fixtures).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_utils.sh
# shellcheck disable=SC1091
. ./mocks/env.sh

setup_mock_env
trap 'pkill -x nfqws 2>/dev/null; cleanup_mock_env; rm -rf "$tmp"' EXIT
tmp="$(mktemp -d)"

SVC="$ROOT/service.sh"
export NO_UPDATE_CHECK=1
export ZAPRET_NFQWS="$MOCK_ROOT/nfqws-mock"

# work on copies of lists/utils so the repo files stay untouched
cp -r "$ROOT/lists" "$tmp/lists"
cp -r "$ROOT/utils" "$tmp/utils"
export ZAPRET_LISTS_DIR="$tmp/lists"
export ZAPRET_UTILS_DIR="$tmp/utils"

echo "== ipset-switch cycle (loaded -> none -> any -> loaded) =="
echo "1.2.3.0/24" > "$tmp/lists/ipset-all.txt"
rm -f "$tmp/lists/ipset-all.txt.backup"
out="$("$SVC" ipset-switch 2>&1)"
assert_eq "now none" "none" "$("$SVC" ipset-status)"
assert_file_contains "backup saved" "$tmp/lists/ipset-all.txt.backup" '^1\.2\.3\.0/24$'
out="$("$SVC" ipset-switch 2>&1)"
assert_eq "now any" "any" "$("$SVC" ipset-status)"
out="$("$SVC" ipset-switch 2>&1)"
assert_eq "now loaded again" "loaded" "$("$SVC" ipset-status)"
assert_file_contains "restored content" "$tmp/lists/ipset-all.txt" '^1\.2\.3\.0/24$'

echo "== game-filter CLI =="
"$SVC" game-filter all >/dev/null 2>&1
assert_file_contains "mode=all saved" "$tmp/utils/game_filter.enabled" '^mode=all$'
out="$("$SVC" load_game_filter 2>/dev/null)"
assert_contains "GF_TCP=range" "$out" "GameFilterTCP=1024-65535"
"$SVC" game-filter range-tcp "1024-1934,1936-65535" >/dev/null 2>&1
assert_file_contains "custom tcp range" "$tmp/utils/game_filter.enabled" '^tcp=1024-1934,1936-65535$'
out="$("$SVC" game-filter range-udp "99999" 2>&1)"; rc=$?
assert_fail "invalid range rejected" "$rc"
"$SVC" game-filter udp >/dev/null 2>&1
out="$("$SVC" load_game_filter 2>/dev/null)"
assert_contains "udp mode: TCP stays 12" "$out" "GameFilterTCP=12"
assert_contains "udp mode: UDP range" "$out" "GameFilterUDP=1024-65535"
"$SVC" game-filter disable >/dev/null 2>&1
assert_file_contains "disabled saved" "$tmp/utils/game_filter.enabled" '^mode=disabled$'
rm -f "$tmp/utils/game_filter.enabled"

echo "== replace-fakes-cli (real bin files, with backup/restore) =="
B1="$ROOT/bin/ACTIVE_DISCORD_UDP.bin"
B2="$ROOT/bin/ACTIVE_GAME_UDP.bin"
cp "$B1" "$tmp/discord.orig"; cp "$B2" "$tmp/game.orig"
h0="$(sha256sum "$B1" | awk '{print $1}')"
"$SVC" replace-fakes-cli discord quic_initial_www_google_com.bin >/dev/null 2>&1; assert_ok "replace discord rc" $?
h1="$(sha256sum "$B1" | awk '{print $1}')"
h_target="$(sha256sum "$ROOT/bin/quic_initial_www_google_com.bin" | awk '{print $1}')"
assert_eq "discord fake replaced" "$h_target" "$h1"
"$SVC" replace-fakes-cli game stun2.bin >/dev/null 2>&1; assert_ok "replace game rc" $?
assert_eq "game fake replaced" "$(sha256sum "$ROOT/bin/stun2.bin" | awk '{print $1}')" "$(sha256sum "$B2" | awk '{print $1}')"
out="$("$SVC" replace-fakes-cli discord no_such_file.bin 2>&1)"; rc=$?
assert_fail "missing file rejected" "$rc"
cp "$tmp/discord.orig" "$B1"; cp "$tmp/game.orig" "$B2"
assert_eq "originals restored" "$h0" "$(sha256sum "$B1" | awk '{print $1}')"

echo "== update-ipset (file:// fixture) =="
printf '9.9.9.0/24\n8.8.8.0/24\n' > "$tmp/ipset-fixture.txt"
ZAPRET_IPSET_URL="file://$tmp/ipset-fixture.txt" "$SVC" update-ipset > "$tmp/upd.out" 2>&1
assert_ok "update-ipset rc" $?
assert_file_contains "list replaced" "$tmp/lists/ipset-all.txt" '^8\.8\.8\.0/24$'
assert_contains "reports subnet count" "$(cat "$tmp/upd.out")" "2 subnets"
ZAPRET_IPSET_URL="file:///nonexistent/x.txt" "$SVC" update-ipset >/dev/null 2>&1
assert_fail "update-ipset failure detected" $?
assert_file_contains "old list kept on failure" "$tmp/lists/ipset-all.txt" '^8\.8\.8\.0/24$'

echo "== check-updates (file:// fixtures) =="
touch "$tmp/utils/check_updates.enabled"
ver="$(tr -d ' \r\n' < "$ROOT/VERSION")"
echo "$ver" > "$tmp/version-same.txt"
out="$(env -u NO_UPDATE_CHECK ZAPRET_VERSION_URL="file://$tmp/version-same.txt" "$SVC" check-updates 2>&1)"
assert_contains "same version message" "$out" "Latest version installed: $ver"
echo "99.99.99" > "$tmp/version-new.txt"
out="$(env -u NO_UPDATE_CHECK ZAPRET_VERSION_URL="file://$tmp/version-new.txt" "$SVC" check-updates 2>&1)"
assert_contains "new version message" "$out" "New version available: 99.99.99"
assert_contains "release link" "$out" "releases/tag/99.99.99"
rm -f "$tmp/utils/check_updates.enabled"
out="$(env -u NO_UPDATE_CHECK ZAPRET_VERSION_URL="file://$tmp/version-new.txt" "$SVC" check-updates 2>&1)"
if printf '%s' "$out" | grep -q "New version"; then bad "check disabled but still checked"; else ok "check_updates.enabled flag respected"; fi
touch "$tmp/utils/check_updates.enabled"

echo "== update-hosts (file:// fixture + /etc/hosts backup/restore) =="
cp /etc/hosts "$tmp/hosts.orig"
printf '140.82.121.3 github.com\n146.75.22.132 objects.githubusercontent.com\n' > "$tmp/hosts-fixture.txt"
ZAPRET_HOSTS_URL="file://$tmp/hosts-fixture.txt" ZAPRET_HOSTS_AUTO=y "$SVC" update-hosts > "$tmp/hosts.out" 2>&1
assert_ok "update-hosts rc" $?
if grep -qF '140.82.121.3 github.com' /etc/hosts; then ok "entries appended to /etc/hosts"; else bad "entries not appended"; fi
if [ -f /etc/hosts.zapret-backup ]; then ok "backup created"; else bad "no backup created"; fi
out="$(ZAPRET_HOSTS_URL="file://$tmp/hosts-fixture.txt" "$SVC" update-hosts 2>&1)"
assert_contains "second run: up to date" "$out" "up to date"
cp "$tmp/hosts.orig" /etc/hosts
rm -f /etc/hosts.zapret-backup

echo "== diagnostics (mocked env, no cache clearing) =="
out="$(ZAPRET_CLEAR_CACHE=n "$SVC" diagnostics 2>&1)"; rc=$?
assert_ok "diagnostics rc" "$rc"
assert_contains "install path shown"  "$out" "Zapret is installed in"
assert_contains "tcp timestamps check" "$out" "TCP timestamps"
assert_contains "firewall check"       "$out" "Firewall"
assert_contains "cyrillic check"       "$out" "Cyrillic path check passed"

echo "== help =="
out="$("$SVC" help 2>&1)"
assert_contains "help mentions install" "$out" "install"

summary

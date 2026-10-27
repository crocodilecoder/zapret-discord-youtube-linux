#!/usr/bin/env bash
# test_01_shellcheck.sh - static analysis: bash -n + shellcheck for all ported scripts
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_utils.sh

echo "== bash -n (syntax) =="
syntax_fail=0
while IFS= read -r f; do
	if ! bash -n "$f" 2>/tmp/synerr; then
		bad "syntax: $f"; cat /tmp/synerr
		syntax_fail=1
	fi
done < <(find "$ROOT" -name '*.sh' -not -path '*/mocks/*' -not -path '*/win_bats/*')
[ "$syntax_fail" = "0" ] && ok "syntax of all .sh files"
bash -n "$TESTS_DIR/mocks/env.sh" && ok "syntax: mocks/env.sh"

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
	cd "$ROOT" || exit 1   # .shellcheckrc lives here
	while IFS= read -r f; do
		if shellcheck -x "$f" > /tmp/sc.out 2>&1; then
			ok "shellcheck: $(basename "$f")"
		else
			bad "shellcheck: $f"
			sed 's/^/      /' /tmp/sc.out | head -20
		fi
	done < <(find "$ROOT" -name '*.sh' -not -path '*/mocks/*' -not -path '*/win_bats/*' | sort)
	# mocks are test infrastructure - check without -x (sourced libs unavailable)
	if shellcheck "$TESTS_DIR/mocks/env.sh" > /tmp/sc.out 2>&1; then
		ok "shellcheck: mocks/env.sh"
	else
		bad "shellcheck: mocks/env.sh"
		sed 's/^/      /' /tmp/sc.out | head -20
	fi
	# windows reference bats (if present) are excluded from find above automatically
	# since they live in tools/win_bats and are .bat, not .sh
else
	echo "  (shellcheck not installed - skipped)"
fi

summary

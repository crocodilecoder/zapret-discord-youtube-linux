#!/usr/bin/env bash
# tests/test_utils.sh - shared assertion helpers
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$TESTS_DIR")"
# compatibility aliases used across test scripts
LINUX_DIR="$ROOT"
REPO_ROOT="$ROOT"

PASS=0; FAIL=0; FAILURES=""

ok()   { PASS=$((PASS+1)); printf '  \033[32m[ok]\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES="$FAILURES\n  $1"; printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }

assert_eq() { # $1 desc, $2 expected, $3 actual
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected='$2' actual='$3')"; fi
}
assert_ok() { # $1 desc, $2 rc
	if [ "$2" = "0" ]; then ok "$1"; else bad "$1 (rc=$2)"; fi
}
assert_fail() { # $1 desc, $2 rc
	if [ "$2" != "0" ]; then ok "$1"; else bad "$1 (expected non-zero rc)"; fi
}
assert_contains() { # $1 desc, $2 haystack, $3 needle
	if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi
}
assert_file_contains() { # $1 desc, $2 file, $3 pattern(ERE)
	if [ -f "$2" ] && grep -qE -- "$3" "$2"; then ok "$1"; else bad "$1 (pattern '$3' not in $2)"; fi
}
assert_file_not_contains() { # $1 desc, $2 file, $3 pattern(ERE)
	if [ ! -f "$2" ] || ! grep -qE -- "$3" "$2"; then ok "$1"; else bad "$1 (pattern '$3' unexpectedly in $2)"; fi
}

summary() {
	echo
	if [ "$FAIL" = "0" ]; then
		printf '\033[32mALL %d CHECKS PASSED\033[0m\n' "$PASS"
		exit 0
	else
		printf '\033[31m%d CHECKS FAILED\033[0m (%d passed):%b\n' "$FAIL" "$PASS" "$FAILURES"
		exit 1
	fi
}

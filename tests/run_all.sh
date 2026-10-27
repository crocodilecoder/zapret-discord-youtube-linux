#!/usr/bin/env bash
# run_all.sh - run the whole verification suite for the Linux port.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

FAILED=0
for t in test_01_shellcheck.sh \
         test_02_args_equivalence.py \
         test_03_dryrun.sh \
         test_04_common.sh \
         test_05_firewall_mock.sh \
         test_06_service_lifecycle.sh \
         test_07_utils_menu.sh \
         test_08_e2e_pipeline.sh; do
	echo
	echo "############ $t ############"
	case "$t" in
		*.py) python3 "$t" ;;
		*)    bash "$t" ;;
	esac
	rc=$?
	if [ "$rc" != "0" ]; then
		FAILED=$((FAILED+1))
		echo ">>> $t FAILED (rc=$rc)"
	else
		echo ">>> $t PASSED"
	fi
done

echo
if [ "$FAILED" = "0" ]; then
	echo "=========== ALL TEST SUITES PASSED ==========="
	exit 0
else
	echo "=========== $FAILED TEST SUITE(S) FAILED ==========="
	exit 1
fi

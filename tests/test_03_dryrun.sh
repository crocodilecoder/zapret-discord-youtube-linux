#!/usr/bin/env bash
# test_03_dryrun.sh - runs the REAL nfqws binary in --dry-run mode with the
# arguments of every generated strategy (verifies that the ported argument
# sets are accepted by nfqws: options, hostlists, ipsets, fake files).
#
# Method: strategy scripts are executed for real, but ZAPRET_NFQWS points to
# a dumper wrapper that records the final argument vector; then the real
# nfqws is invoked with those args plus --dry-run.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./test_utils.sh

NFQWS="$ROOT/bin/nfqws"
if [ ! -x "$NFQWS" ]; then
	echo "nfqws binary not found at $NFQWS - run ./install.sh first."
	echo "SKIP"; exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# argument dumper
cat > "$tmp/dump-nfqws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ZAPRET_ARG_DUMP"
EOF
chmod +x "$tmp/dump-nfqws"

export NO_UPDATE_CHECK=1
export ZAPRET_NFQWS="$tmp/dump-nfqws"
export ZAPRET_RUN_DIR="$tmp/run"
mkdir -p "$ZAPRET_RUN_DIR"

total=0; okc=0
for script in "$ROOT"/general*.sh; do
	name="$(basename "$script")"
	dump="$tmp/args-$(echo "$name" | tr -c 'A-Za-z0-9_.-' '_')"
	ZAPRET_ARG_DUMP="$dump" bash "$script" >/dev/null 2>&1 || true
	if [ ! -s "$dump" ]; then
		bad "$name: could not capture args (strategy did not reach nfqws)"
		total=$((total+1))
		continue
	fi

	# strip the runtime prologue added by run_nfqws
	mapfile -t args < <(grep -v -e '^--qnum=' -e '^--bind-fix4$' -e '^--bind-fix6$' -e '^--daemon$' -e '^--pidfile=' -e '^--uid=' "$dump")

	# expected number of strategy profiles = count of --new + 1 (last profile has no --new)
	expected_profiles=$(( $(grep -cx -- '--new' "$dump") + 1 ))

	"$NFQWS" --dry-run --qnum=200 --bind-fix4 --bind-fix6 "${args[@]}" > "$tmp/dry.out" 2>&1
	rc=$?
	total=$((total+1))
	# In capability-restricted sandboxes capset() fails and nfqws exits 1
	# AFTER all parameters were successfully validated ("setpcap: Operation
	# not permitted"). Treat that specific case as a pass.
	if [ "$rc" != "0" ] && grep -q "setpcap: Operation not permitted" "$tmp/dry.out" && \
	   ! grep -qiE "unknown|invalid|unrecognized|error|failed" <(grep -v "setpcap" "$tmp/dry.out"); then
		rc=0
		sandbox_note=" (sandbox: capset unavailable)"
	else
		sandbox_note=""
	fi
	if [ "$rc" = "0" ]; then
		profiles="$(grep -o 'we have [0-9]* user defined desync profile' "$tmp/dry.out" | grep -o '[0-9]*' || echo 0)"
		if [ "$profiles" = "$expected_profiles" ]; then
			ok "$name: nfqws accepts all ${#args[@]} args, $profiles profiles$sandbox_note"
			okc=$((okc+1))
		else
			bad "$name: profile count mismatch (expected $expected_profiles, got $profiles)"
		fi
	else
		bad "$name: nfqws dry-run failed (rc=$rc)"
		sed 's/^/      /' "$tmp/dry.out" | head -8
	fi
done

echo "checked $total strategies, $okc accepted by nfqws"
summary

#!/usr/bin/env bash
# verify_binaries.sh - check bin/nfqws and bin/ip2net against BINARIES.sha256,
# show build info and runtime dependencies.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; R=$'\033[0m'
[ -t 1 ] || { GREEN=""; RED=""; YELLOW=""; R=""; }

rc=0
if command -v sha256sum >/dev/null 2>&1 && [ -f BINARIES.sha256 ]; then
	if sha256sum -c BINARIES.sha256 2>/dev/null; then
		echo "${GREEN}[OK] checksums match BINARIES.sha256${R}"
	else
		echo "${RED}[X] checksum MISMATCH (see above)${R}"
		rc=1
	fi
else
	echo "${YELLOW}[?] sha256sum or BINARIES.sha256 not available - skipped${R}"
fi

for b in bin/nfqws bin/ip2net; do
	if [ -x "$b" ]; then
		echo
		echo "== $b =="
		file "$b" 2>/dev/null || true
		[ "$b" = "bin/nfqws" ] && "$b" --version 2>/dev/null | head -n1
		if command -v ldd >/dev/null 2>&1; then
			echo "runtime dependencies:"
			ldd "$b" 2>/dev/null | sed 's/^/  /'
			missing="$(ldd "$b" 2>/dev/null | grep -c 'not found' || true)"
			if [ "$missing" != "0" ]; then
				echo "${RED}[X] some libraries are missing - run ./install.sh${R}"
				rc=1
			fi
		fi
	else
		echo "${RED}[X] $b not found or not executable - run ./install.sh${R}"
		rc=1
	fi
done

echo
if [ "$rc" = "0" ]; then
	echo "${GREEN}Verification passed.${R}"
	echo "Note: bin/nfqws is built from bol-van/zapret v72.13 (GPLv3)."
	echo "Rebuild it yourself any time:  sudo FORCE_REBUILD=1 ./install.sh"
else
	echo "${RED}Verification FAILED.${R}"
fi
exit "$rc"

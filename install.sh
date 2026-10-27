#!/usr/bin/env bash
# install.sh - ставит зависимости и кладёт nfqws в bin/.
# бинарник уже лежит в репозитории, так что обычно ставятся только рантайм-либы;
# пересобрать с нуля из исходников bol-van/zapret: sudo FORCE_REBUILD=1 ./install.sh
# (или --from-git для сборки с master, ZAPRET_VERSION=... для другого релиза)
set -eu

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./common.sh

ZAPRET_UPSTREAM_REPO="https://github.com/bol-van/zapret"
ZAPRET_VERSION="${ZAPRET_VERSION:-v72.13}"   # с этого релиза собран бинарник в bin/
USE_GIT=0
[ "${1:-}" = "--from-git" ] && USE_GIT=1

say()  { print_cyan "==> $*"; }
die()  { print_red "[ERROR] $*"; exit 1; }

detect_pkg_sets() {
	if command -v apt-get >/dev/null 2>&1; then echo debian
	elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then echo rhel
	elif command -v pacman >/dev/null 2>&1; then echo arch
	elif command -v zypper >/dev/null 2>&1; then echo suse
	elif command -v apk >/dev/null 2>&1; then echo alpine
	elif command -v xbps-install >/dev/null 2>&1; then echo void
	else echo unknown; fi
}

# 0. sanity
require_root || exit 1

# 1. dependencies
install_pkgs() {
	local runtime="$1" build="$2"
	say "Installing runtime dependencies..."
	if command -v apt-get >/dev/null 2>&1; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq || true
		# shellcheck disable=SC2086
		apt-get install -y -qq $runtime || die "apt-get install failed"
		if [ -n "$build" ]; then
			say "Installing build dependencies..."
			# shellcheck disable=SC2086
			apt-get install -y -qq $build || die "apt-get install failed"
		fi
	elif command -v dnf >/dev/null 2>&1; then
		# shellcheck disable=SC2086
		dnf install -y $runtime $build || die "dnf install failed"
	elif command -v yum >/dev/null 2>&1; then
		# shellcheck disable=SC2086
		yum install -y $runtime $build || die "yum install failed"
	elif command -v pacman >/dev/null 2>&1; then
		# shellcheck disable=SC2086
		pacman -Sy --noconfirm $runtime $build || die "pacman install failed"
	elif command -v zypper >/dev/null 2>&1; then
		# shellcheck disable=SC2086
		zypper --noninteractive install $runtime $build || die "zypper install failed"
	elif command -v apk >/dev/null 2>&1; then
		# shellcheck disable=SC2086
		apk add --no-cache $runtime $build || die "apk add failed"
	elif command -v xbps-install >/dev/null 2>&1; then
		# shellcheck disable=SC2086
		xbps-install -Sy $runtime $build || die "xbps-install failed"
	else
		print_yellow "[!] Unknown package manager. Install manually:"
		print_yellow "    runtime: $runtime"
		[ -n "$build" ] && print_yellow "    build:   $build"
	fi
}

need_build=1
if [ -x "$NFQWS_BIN" ] && [ -z "${FORCE_REBUILD:-}" ]; then
	need_build=0
fi

case "$(detect_pkg_sets)" in
	debian)
		install_pkgs "libnetfilter-queue1 libmnl0 zlib1g curl wget ipset iptables procps kmod ca-certificates" \
			"$([ "$need_build" = 1 ] && echo "gcc make libc6-dev libnetfilter-queue-dev libmnl-dev zlib1g-dev libcap-dev git")" ;;
	rhel)
		install_pkgs "libnetfilter_queue libmnl zlib curl wget ipset iptables procps-ng kmod ca-certificates" \
			"$([ "$need_build" = 1 ] && echo "gcc make libnetfilter_queue-devel libmnl-devel zlib-devel libcap-devel git")" ;;
	arch)
		install_pkgs "libnetfilter_queue libmnl zlib curl wget ipset iptables procps-ng kmod ca-certificates" \
			"$([ "$need_build" = 1 ] && echo "base-devel git")" ;;
	suse)
		install_pkgs "libnetfilter_queue1 libmnl0 zlib libcurl4 wget ipset iptables procps kmod ca-certificates" \
			"$([ "$need_build" = 1 ] && echo "gcc make libnetfilter_queue-devel libmnl-devel zlib-devel libcap-devel git")" ;;
	alpine)
		install_pkgs "libnetfilter_queue libmnl zlib curl wget ipset iptables procps kmod ca-certificates" \
			"$([ "$need_build" = 1 ] && echo "build-base git")" ;;
	void)
		install_pkgs "libnetfilter_queue libmnl zlib curl wget ipset iptables procps-ng kmod ca-certificates" \
			"$([ "$need_build" = 1 ] && echo "gcc make libnetfilter_queue-devel libmnl-devel zlib-devel libcap-devel git")" ;;
	*)
		install_pkgs "" "" ;;
esac

# 2. get + build zapret (nfqws)
BUILD_DIR="${ZAPRET_BUILD_DIR:-/tmp/zapret-build-$$}"

if [ "$need_build" = "0" ]; then
	print_green "nfqws already present: $NFQWS_BIN ($("$NFQWS_BIN" --version 2>/dev/null | head -n1))"
	print_yellow "Use FORCE_REBUILD=1 $0 to rebuild."
	command -v git >/dev/null 2>&1 || print_yellow "(git not found - only needed for --from-git builds)"
else
	command -v git >/dev/null 2>&1 || die "git not found. Install git first."
	mkdir -p "$BUILD_DIR"
	if [ "$USE_GIT" = "1" ]; then
		say "Cloning $ZAPRET_UPSTREAM_REPO (master)..."
		git clone --depth 1 "$ZAPRET_UPSTREAM_REPO" "$BUILD_DIR/zapret" \
			|| die "git clone failed"
	else
		say "Downloading upstream zapret $ZAPRET_VERSION sources..."
		TARBALL="$BUILD_DIR/zapret.tar.gz"
		http_fetch "$ZAPRET_UPSTREAM_REPO/releases/download/$ZAPRET_VERSION/zapret-$ZAPRET_VERSION.tar.gz" "$TARBALL" \
			|| http_fetch "$ZAPRET_UPSTREAM_REPO/archive/refs/tags/$ZAPRET_VERSION.tar.gz" "$TARBALL" \
			|| die "download failed"
		tar -xzf "$TARBALL" -C "$BUILD_DIR" || die "extract failed"
		SRC_DIR="$(find "$BUILD_DIR" -maxdepth 1 -type d -name 'zapret*' ! -path "$BUILD_DIR" | head -n1)"
		[ -n "$SRC_DIR" ] || die "source dir not found after extract"
		mv "$SRC_DIR" "$BUILD_DIR/zapret"
	fi

	say "Building nfqws..."
	make -C "$BUILD_DIR/zapret/nfq" clean >/dev/null 2>&1 || true
	make -C "$BUILD_DIR/zapret/nfq" -j"$(nproc 2>/dev/null || echo 2)" \
		|| die "nfqws build failed"
	say "Building ip2net (helper for building ip lists)..."
	make -C "$BUILD_DIR/zapret/ip2net" -j"$(nproc 2>/dev/null || echo 2)" \
		|| print_yellow "[!] ip2net build failed (optional), continuing"

	mkdir -p "$BIN_DIR"
	install -m 0755 "$BUILD_DIR/zapret/nfq/nfqws" "$BIN_DIR/nfqws" || die "failed to install nfqws into $BIN_DIR"
	if [ -f "$BUILD_DIR/zapret/ip2net/ip2net" ]; then
		install -m 0755 "$BUILD_DIR/zapret/ip2net/ip2net" "$BIN_DIR/ip2net"
	fi
	rm -rf "$BUILD_DIR"
	print_green "Installed: $BIN_DIR/nfqws ($("$BIN_DIR/nfqws" --version 2>/dev/null | head -n1))"
fi

# 3. permissions + user lists
chmod +x "$ROOT_DIR"/*.sh 2>/dev/null || true
load_user_lists
print_green "User lists initialized in $LISTS_DIR"

# 4. kernel modules hint
if command -v modprobe >/dev/null 2>&1; then
	modprobe nfnetlink_queue 2>/dev/null || true
	modprobe iptable_mangle  2>/dev/null || true
	modprobe ip6table_mangle 2>/dev/null || true
fi
if [ ! -f /proc/net/netfilter/nfnetlink_queue ] && \
   ! lsmod 2>/dev/null | grep -q nfnetlink_queue; then
	print_yellow "[!] nfnetlink_queue is not loaded now. It will normally load on demand"
	print_yellow "    when firewall.sh applies NFQUEUE rules (requires a standard distro kernel)."
fi

echo
print_green "Installation complete."
echo
echo "Next steps:"
echo "  1) quick standalone run (foreground, Ctrl+C to stop):"
echo "       sudo $ROOT_DIR/firewall.sh start"
echo "       sudo $ROOT_DIR/general.sh"
echo "  2) or install as a service (systemd; autostart on boot):"
echo "       sudo $ROOT_DIR/service.sh install"
echo "  3) interactive manager menu:"
echo "       sudo $ROOT_DIR/service.sh"
echo "  4) run strategy tests:"
echo "       sudo $ROOT_DIR/test_zapret.sh"
echo
echo "See README.md for details."

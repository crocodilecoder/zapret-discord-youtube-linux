#!/usr/bin/env bash
# uninstall.sh - гасит службу, процесс и правила фаервола.
# бинарник в bin/ не трогает - удалите руками, если совсем не нужен
set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./common.sh

require_root || exit 1

./service.sh remove

if [ -x "$BIN_DIR/nfqws" ]; then
	print_yellow "nfqws binary kept at $BIN_DIR/nfqws (remove manually if desired)."
fi
print_green "Uninstall finished."

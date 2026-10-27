#!/usr/bin/env bash
# general_ALT5.sh - линуксовый вариант "general (ALT5).bat".
# аргументы nfqws перенесены из bat один в один; windivert-ключи выкинуты,
# на линуксе пакеты в nfqueue заводит firewall.sh.
# запуск в терминале, остановка - ctrl+c.
# NOT RECOMMENDED
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./common.sh

BIN="$BIN_DIR/"
LISTS="$LISTS_DIR/"

# если служба уже крутится - выходим (в батнике это делал exit /b)
"$ROOT_DIR/service.sh" status_zapret
[ $? -eq 10 ] && exit 0
# фоном проверяем обновления, не мешая запуску
check_updates soft
# игровой фильтр проставляет GF_TCP/GF_UDP
load_game_filter
# создаём user-списки, если их ещё нет
load_user_lists
echo

run_nfqws "general_ALT5.sh" \
    --filter-udp=443 "--hostlist=${LISTS}list-general.txt" "--hostlist=${LISTS}list-general-user.txt" "--hostlist-exclude=${LISTS}list-exclude.txt" "--hostlist-exclude=${LISTS}list-exclude-user.txt" "--ipset-exclude=${LISTS}ipset-exclude.txt" "--ipset-exclude=${LISTS}ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 "--dpi-desync-fake-quic=${BIN}quic_initial_www_google_com.bin" --new \
    --filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake "--dpi-desync-fake-discord=${BIN}ACTIVE_DISCORD_UDP.bin" "--dpi-desync-fake-stun=${BIN}ACTIVE_DISCORD_UDP.bin" --dpi-desync-repeats=6 --new \
    --filter-l3=ipv4 --filter-tcp=80,443,2053,2083,2087,2096,8443 "--ipset-exclude=${LISTS}ipset-exclude.txt" "--ipset-exclude=${LISTS}ipset-exclude-user.txt" --dpi-desync=syndata,multidisorder --new \
    "--filter-tcp=$GF_TCP" "--ipset=${LISTS}ipset-all.txt" "--ipset-exclude=${LISTS}ipset-exclude.txt" "--ipset-exclude=${LISTS}ipset-exclude-user.txt" --dpi-desync=syndata,multidisorder --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n4 --new \
    --filter-udp=443 "--ipset=${LISTS}ipset-all.txt" "--hostlist-exclude=${LISTS}list-exclude.txt" "--hostlist-exclude=${LISTS}list-exclude-user.txt" "--ipset-exclude=${LISTS}ipset-exclude.txt" "--ipset-exclude=${LISTS}ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 "--dpi-desync-fake-quic=${BIN}quic_initial_www_google_com.bin" --new \
    "--filter-udp=$GF_UDP" "--ipset=${LISTS}ipset-all.txt" "--ipset-exclude=${LISTS}ipset-exclude.txt" "--ipset-exclude=${LISTS}ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=14 --dpi-desync-any-protocol=1 "--dpi-desync-fake-unknown-udp=${BIN}ACTIVE_GAME_UDP.bin" --dpi-desync-cutoff=n3

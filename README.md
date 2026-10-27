# zapret-discord-youtube для линукса

Порт виндового zapret-discord-youtube на линукс: те же 22 стратегии, тот же
менеджер с меню, те же списки и фейки, только вместо `winws.exe` с windivert-ом
работает `nfqws` с nfqueue, а bat-ники стали шелл-скриптами.

## Быстрый старт

```bash
sudo ./install.sh          # зависимости; nfqws уже лежит в bin/, соберётся только если нужно
sudo ./service.sh install  # служба systemd, спросит какую стратегию ставить
sudo ./service.sh          # менеджер, меню как в оригинале (пункты 0-12)
```

или руками, без службы:

```bash
sudo ./firewall.sh start   # правила nfqueue
sudo ./general.sh          # в терминале, ctrl+c - стоп
```

Прогнать все стратегии с проверками (аналог `utils/test zapret.ps1`):

```bash
sudo ./test_zapret.sh
```

Нужны: рут, bash, curl или wget, iptables (или nftables) и обычное
дистрибутивное ядро с nfnetlink_queue — оно есть почти везде.
Пакетные менеджеры: apt, dnf/yum, pacman, zypper, apk, xbps.

## Что где лежит

```
general*.sh        стратегии, по одной на каждый general*.bat
service.sh         менеджер: меню, служба, диагностика, обновления
firewall.sh        правила, которыми трафик заводится в nfqueue
test_zapret.sh     тесты стратегий
common.sh          общие функции, сам не запускается
install.sh         зависимости + nfqws
bin/               nfqws, ip2net и фейк-пакеты *.bin (те же, что на винде)
lists/             списки хостов и ip, плюс ваши *-user.txt
utils/             targets.txt для тестов, флаги game_filter/check_updates
tests/             тесты и заметки по проверке (VERIFICATION.md)
tools/             конвертер bat->sh, проверка бинарников, эталонные .bat
```

## Как это работает

На винде winws сам ловит пакеты windivert-ом (`--wf-tcp`, `--wf-udp`).
На линуксе так нельзя, поэтому пакеты в очередь nfqueue заводит фаервол:
`firewall.sh` вешает свою цепочку `ZAPRET_DY` в mangle OUTPUT и шлёт туда
tcp/udp с нужных портов (те же порты, что были в `--wf-tcp/--wf-udp`).
`--queue-bypass` оставляет интернет живым, даже если nfqws не поднят.
Пакеты с меткой десинка обратно в очередь не попадают. Есть ipv6-ветка,
режим шлюза (`ZAPRET_ROUTER=1`) и чистый nft-бэкенд (`ZAPRET_FW=nft`).

Дальше всё как в оригинале: один процесс nfqws со всеми профилями стратегии,
первый совпавший `--filter-*` выигрывает.

## Мелочи

- игровой фильтр, переключение ipset, подмена фейков, обновление hosts и
  списка ipset — всё в меню `service.sh` или через cli (`./service.sh help`);
- после правки диапазонов игрового фильтра правила надо переналожить:
  `sudo ./firewall.sh restart`;
- переменные: `ZAPRET_QNUM` (номер очереди, по умолчанию 200), `ZAPRET_FW`,
  `ZAPRET_ROUTER`, `ZAPRET_CONNBYTES=0`, `NO_UPDATE_CHECK=1`,
  `FORCE_REBUILD=1` для пересборки nfqws;
- без systemd (контейнеры и т.п.) служба работает демоном с pidfile,
  автозапуск тогда руками через cron `@reboot`;
- если проект лежит в домашнем каталоге с правами 700 (дефолт Kali и др.),
  скрипт сам добавит каталогам пути `o+x`: nfqws после сброса capabilities
  ходит по диску по обычным правам и иначе не прочитал бы списки;
- check updates смотрит версию порта в вашем репозитории на github
  (определяется по `git remote origin`, либо `ZAPRET_SELF_OWNER`/`ZAPRET_SELF_REPO`),
  а списки и hosts тянутся из flowseal, там они и обновляются.

## Тесты

`./tests/run_all.sh` прогоняет всё, что можно проверить без реального DPI:
shellcheck, сравнение аргументов bat/sh, `nfqws --dry-run` на всех стратегиях,
юнит-тесты, фаервол и службу на моках, e2e-прогон тестера с локальным сервером.
Подробности и список того, что проверить на живой машине — `tests/VERIFICATION.md`.

Бинарник `bin/nfqws` собран из релиза v72.13 [bol-van/zapret](https://github.com/bol-van/zapret);
суммы в `BINARIES.sha256`, проверить — `./tools/verify_binaries.sh`,
пересобрать — `sudo FORCE_REBUILD=1 ./install.sh`.

## Обновление после апстрима

Скопируйте свежие `.bat`, `lists/`, `.service/` и `*.bin` из апстрима
(инструкция в `tools/win_bats/README.md`), затем:

```bash
python3 tools/convert_bats.py tools/win_bats .
./tests/run_all.sh
```

Если порт пригодился и хочется поддержать автора — btc:
`bc1quec7r6y09tpy72fpz4qtpqpsj9tlmdregwuluw`

вдохновился работой flowseal/zapret-discord-youtube, стратегии и списки оттуда же.

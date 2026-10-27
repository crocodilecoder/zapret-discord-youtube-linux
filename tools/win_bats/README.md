# Эталонные bat-ники

Копия general*.bat из [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube)
(версия — в `../../.service/version.txt`). Нужны для двух вещей:

1. `../convert_bats.py` генерит из них наши general_*.sh (аргументы 1:1);
2. `../../tests/test_02_args_equivalence.py` сверяет, что при переносе
   ничего не потерялось.

После обновления апстрима скопируйте сюда свежие `.bat` (а также списки,
`.service/` и `*.bin` в соответствующие каталоги), затем из корня репозитория:

```bash
python3 tools/convert_bats.py tools/win_bats .
./tests/run_all.sh
```

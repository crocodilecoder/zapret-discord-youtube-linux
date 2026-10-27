#!/usr/bin/env python3
"""
convert_bats.py - генерит general_*.sh из виндовых general_*.bat.

Перенос механический: вытаскиваем командную строку winws.exe из bat-ника
(со склейкой переносов через ^), выкидываем windivert-ключи --wf-tcp/--wf-udp
(на линуксе этим занимается firewall.sh), меняем %BIN%/%LISTS%/%GameFilter*%
на шелловые переменные, убираем bat-эскейпы (^!). Порядок аргументов не
трогаем - он и есть стратегия.

Эталонные .bat лежат в tools/win_bats (копия из Flowseal/zapret-discord-youtube);
после обновления upstream скопируйте свежие .bat туда и запустите:
    python3 tools/convert_bats.py tools/win_bats .

Использование: python3 convert_bats.py [каталог_с_bat] [куда_класть_sh]
"""
import os
import re
import sys


def name_mapping(bat_name: str) -> str:
    """'general (ALT5).bat' -> 'general_ALT5.sh'"""
    base = bat_name[:-4] if bat_name.lower().endswith(".bat") else bat_name
    base = base.replace(" (", "_").replace(")", "").replace("(", "").replace(" ", "_")
    return base + ".sh"


def extract_winws_command(text: str):
    """Return (header_comments, command_string) parsed from bat content."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")

    # collect all '::' comments except technical ones
    comments = []
    for ln in lines:
        s = ln.strip()
        if s.startswith("::"):
            body = s[2:].strip()
            if body and "65001" not in body and "437" not in body:
                comments.append(body)

    # find the start line with winws.exe and join '^' continuations
    cmd_lines = []
    capturing = False
    for ln in lines:
        if not capturing:
            if "winws.exe" in ln:
                capturing = True
            else:
                continue
        cmd_lines.append(ln)
        if not ln.rstrip().endswith("^"):
            break

    if not cmd_lines:
        return comments, None

    joined = ""
    for ln in cmd_lines:
        stripped = ln.rstrip()
        if stripped.endswith("^"):
            joined += stripped[:-1]
        else:
            joined += stripped
            break

    # cut everything up to the winws.exe invocation:
    # start ... "%BIN%winws.exe" <args>  ->  find the closing quote after the exe
    idx = joined.find("winws.exe")
    joined = joined[idx:]
    sp = joined.find(" ")
    if sp != -1:
        joined = "winws.exe" + joined[sp:]
    return comments, joined


def tokenize(cmd: str):
    """Split command line into tokens, respecting double quotes (bat rules).
    Quotes are removed; '^' escapes the next character literally."""
    tokens = []
    cur = []
    in_quotes = False
    has = False  # current token exists (even if empty string)
    i = 0
    while i < len(cmd):
        ch = cmd[i]
        if ch == "^" and i + 1 < len(cmd):
            cur.append(cmd[i + 1])
            has = True
            i += 2
            continue
        if ch == '"':
            in_quotes = not in_quotes
            has = True
            i += 1
            continue
        if ch in " \t" and not in_quotes:
            if has:
                tokens.append("".join(cur))
            cur = []
            has = False
            i += 1
            continue
        cur.append(ch)
        has = True
        i += 1
    if has:
        tokens.append("".join(cur))
    return tokens


def convert_token(tok: str):
    """Convert one winws token to its nfqws bash equivalent."""
    if tok == "winws.exe":
        return None
    # drop windows-only WinDivert capture options
    if tok.startswith("--wf-tcp") or tok.startswith("--wf-udp"):
        return None
    # variable substitutions
    tok = tok.replace("%BIN%", "${BIN}")
    tok = tok.replace("%LISTS%", "${LISTS}")
    tok = tok.replace("%GameFilterTCP%", "$GF_TCP")
    tok = tok.replace("%GameFilterUDP%", "$GF_UDP")
    return tok


def shell_quote(tok: str) -> str:
    """Quote a token for bash.
    Tokens containing $VAR ($BIN/$LISTS/$GF_TCP/$GF_UDP) must stay expandable,
    so double quotes are used (no ` or " ever appear in these bat files;
    '!' inside double quotes is safe in non-interactive bash)."""
    if re.fullmatch(r"[A-Za-z0-9_./:=,+@{}-]+", tok):
        return tok
    return '"' + tok + '"'


HEADER = """#!/usr/bin/env bash
# {sh_name} - линуксовый вариант "{bat_name}".
# аргументы nfqws перенесены из bat один в один; windivert-ключи выкинуты,
# на линуксе пакеты в nfqueue заводит firewall.sh.
# запуск в терминале, остановка - ctrl+c.
{extra}set -u
cd "$(dirname "${{BASH_SOURCE[0]}}")" || exit 1
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

run_nfqws "{sh_name}" \\
{args}
"""


def render_script(bat_name: str, comments, tokens) -> str:
    sh_name = name_mapping(bat_name)
    strategy = sh_name[:-3]

    # rebuild arg lines: each '--new' terminates a strategy profile line
    arg_groups = []
    cur = []
    for t in tokens:
        cur.append(shell_quote(t))
        if t == "--new":
            arg_groups.append(cur)
            cur = []
    if cur:
        arg_groups.append(cur)

    args = " \\\n".join("    " + " ".join(g) for g in arg_groups)

    extra = "".join(f"# {c}\n" for c in comments)
    return HEADER.format(sh_name=sh_name, bat_name=bat_name, extra=extra,
                         strategy=strategy, args=args)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    outdir = sys.argv[2] if len(sys.argv) > 2 else "."
    os.makedirs(outdir, exist_ok=True)

    bats = sorted(
        f for f in os.listdir(root)
        if f.lower().endswith(".bat") and not f.lower().startswith("service")
    )
    if not bats:
        print(f"no .bat strategy files found in {root}", file=sys.stderr)
        sys.exit(1)

    for bat in bats:
        path = os.path.join(root, bat)
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        comments, cmd = extract_winws_command(text)
        if cmd is None:
            print(f"WARN: {bat}: no winws.exe command found, skipped", file=sys.stderr)
            continue
        tokens = tokenize(cmd)
        converted = [c for c in (convert_token(t) for t in tokens) if c is not None]
        sh = render_script(bat, comments, converted)
        out = os.path.join(outdir, name_mapping(bat))
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(sh)
        os.chmod(out, 0o755)
        print(f"{bat} -> {os.path.relpath(out, root)}  ({len(converted)} args)")


if __name__ == "__main__":
    main()

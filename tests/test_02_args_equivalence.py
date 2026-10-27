#!/usr/bin/env bash
# tests/test_02_args_equivalence.py - verifies that every generated general*.sh
# passes EXACTLY the same nfqws argument sequence as its source .bat passed to
# winws.exe (minus the Windows-only --wf-* capture options and the runtime
# --qnum/--bind-fix* prologue added by run_nfqws), with variables expanded
# identically.
#
# Method: ZAPRET_NFQWS points to a dumper wrapper; the strategy script is
# executed for real (all variable expansion happens in bash), the wrapper
# records the final argument vector.
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import convert_bats as cb  # noqa: E402


def make_dumper(path):
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            "#!/usr/bin/env bash\n"
            "# dump all args, one per line\n"
            'printf "%s\\n" "$@" > "$ZAPRET_ARG_DUMP"\n'
        )
    os.chmod(path, 0o755)


def bat_args(bat_path, gf_tcp, gf_udp):
    with open(bat_path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    _, cmd = cb.extract_winws_command(text)
    if cmd is None:
        return None
    toks = cb.tokenize(cmd)
    out = []
    for t in toks:
        c = cb.convert_token(t)
        if c is None:
            continue
        c = c.replace("${BIN}", os.path.join(ROOT, "bin") + "/")
        c = c.replace("${LISTS}", os.path.join(ROOT, "lists") + "/")
        c = c.replace("$GF_TCP", gf_tcp)
        c = c.replace("$GF_UDP", gf_udp)
        out.append(c)
    return out


def sh_args(sh_path, env):
    dump = env["ZAPRET_ARG_DUMP"]
    if os.path.exists(dump):
        os.unlink(dump)
    r = subprocess.run(["bash", sh_path], capture_output=True, env=env)
    if not os.path.exists(dump):
        sys.stderr.write(r.stdout.decode(errors="replace") + r.stderr.decode(errors="replace"))
        return None
    with open(dump, encoding="utf-8") as f:
        args = [ln for ln in f.read().split("\n") if ln != ""]
    # strip the runtime prologue added by run_nfqws:
    # --qnum=N --bind-fix4 --bind-fix6 [--daemon --pidfile=...]
    while args and (args[0].startswith("--qnum") or args[0] in ("--bind-fix4", "--bind-fix6", "--daemon")
                    or args[0].startswith("--pidfile") or args[0].startswith("--uid")):
        args.pop(0)
    return args


WIN_BATS = os.path.join(ROOT, "tools", "win_bats")


def main():
    if not os.path.isdir(WIN_BATS):
        print("SKIP: tools/win_bats (Windows reference .bat files) not present")
        sys.exit(0)
    failures = 0
    checked = 0
    tmp = "/tmp/zapret_argtest"
    os.makedirs(tmp, exist_ok=True)
    dumper = os.path.join(tmp, "nfqws-dump")
    make_dumper(dumper)

    base_env = dict(os.environ)
    base_env.update({
        "ZAPRET_NFQWS": dumper,
        "NO_UPDATE_CHECK": "1",
        "ZAPRET_RUN_DIR": os.path.join(tmp, "run"),
    })
    os.makedirs(base_env["ZAPRET_RUN_DIR"], exist_ok=True)

    for bat in sorted(f for f in os.listdir(WIN_BATS) if f.lower().endswith(".bat")):
        if bat.lower().startswith("service"):
            continue
        sh = cb.name_mapping(bat)
        sh_path = os.path.join(ROOT, sh)
        if not os.path.exists(sh_path):
            print(f"[FAIL] {sh}: not generated")
            failures += 1
            continue
        for gf_tcp, gf_udp, tag in (("12", "12", "gamefilter off"),
                                    ("1024-65535", "2000-3000", "gamefilter on")):
            env = dict(base_env)
            env["ZAPRET_ARG_DUMP"] = os.path.join(tmp, f"dump-{sh}-{tag.replace(' ', '_')}")
            # game filter state is read from utils/game_filter.enabled; emulate
            # via a temporary UTILS_DIR
            utils = os.path.join(tmp, "utils-" + tag.replace(" ", "_"))
            os.makedirs(utils, exist_ok=True)
            if gf_tcp == "12":
                gf_file = os.path.join(utils, "game_filter.enabled")
                if os.path.exists(gf_file):
                    os.unlink(gf_file)
            else:
                with open(os.path.join(utils, "game_filter.enabled"), "w") as f:
                    f.write(f"mode=all\ntcp={gf_tcp}\nudp={gf_udp}\n")
            env["ZAPRET_UTILS_DIR"] = utils

            a = bat_args(os.path.join(WIN_BATS, bat), gf_tcp, gf_udp)
            b = sh_args(sh_path, env)
            checked += 1
            if a is None or b is None:
                print(f"[FAIL] {sh} ({tag}): extraction error")
                failures += 1
                continue
            if a == b:
                print(f"[ok] {sh} ({tag}): {len(a)} args identical")
            else:
                failures += 1
                print(f"[FAIL] {sh} ({tag}): args differ")
                for i, (x, y) in enumerate(zip(a, b)):
                    if x != y:
                        print(f"   pos {i}: bat={x!r} sh={y!r}")
                if len(a) != len(b):
                    print(f"   length: bat={len(a)} sh={len(b)}")
    print()
    if failures:
        print(f"{failures} FAILURES out of {checked} comparisons")
        sys.exit(1)
    print(f"ALL {checked} ARG SETS IDENTICAL")
    sys.exit(0)


if __name__ == "__main__":
    main()

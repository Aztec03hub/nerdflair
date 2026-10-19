#!/usr/bin/env python3
"""hover-highlight-e2e.py - a readout on the MAIN status line is highlighted
while its card is open, like the band's own, and put back cell for cell.

Runs nfpty around a stand-in engine that draws a coloured status line, inside
its OWN private tmux server (nothing on the user's server or screen). The
pointer is sent as the SGR motion report a terminal would send. The screen is
read with `capture-pane -e` and compared per cell: text, colour, attributes.
"""
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mklayout  # noqa: E402

SOCK = f"nf-hl-{os.getpid()}"
ROW = 48
HLBG = "2;31;41;55"        # the band's LIT background, as 48;<this>

FAKE = r'''
import os, sys, time
os.system("stty raw -echo")  # fixed string, no input: safe
G = "\U000f024b"
sys.stdout.write("\033[2J\033[48;1H  " + G + " nerdflair \033[0m· \033[38;2;200;100;50m\U000f062c main\033[0m · \033[38;5;33;3mx y\033[0m")
sys.stdout.write("\033[?1000h\033[?1003h\033[?1006h"); sys.stdout.flush()
while True:
    time.sleep(0.1)
'''


def tmux(*a):
    return subprocess.run(["tmux", "-L", SOCK, *a], capture_output=True, text=True).stdout


def cells(line):
    """[(char, state)] for one capture-pane -e line; state is a frozenset of facts."""
    st, out = {}, []
    for m in re.finditer(r"\x1b\[([0-9;:]*)m|(.)", line, re.S):
        if m.group(2) is not None:
            out.append((m.group(2), frozenset(st.items())))
            continue
        p = (m.group(1) or "0").split(";")
        i = 0
        while i < len(p):
            n = p[i]
            if n in ("", "0"):
                st = {}
            elif n in ("38", "48"):
                k = 5 if p[i + 1] == "2" else 3
                st["fg" if n == "38" else "bg"] = ";".join(p[i + 1:i + k])
                i += k - 1
            elif n == "39":
                st.pop("fg", None)
            elif n == "49":
                st.pop("bg", None)
            elif n == "22":
                st.pop("1", None)
            else:
                st[n] = 1
            i += 1
    return out


def row(target):
    return tmux("capture-pane", "-e", "-p", "-t", target, "-S", str(ROW - 1), "-E", str(ROW - 1)).split("\n")[0]


def main():
    errlog = tempfile.mktemp(prefix="nf-hl-", suffix=".log")
    fake = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
    fake.write(FAKE)
    fake.close()
    tmux("new-session", "-d", "-x", "120", "-y", "50", "-s", "hl",
         f"NFPTY_ERRLOG={errlog} CLAUDE_BIN=/usr/bin/python3 python3 {HERE}/nfpty.py {fake.name}")
    target = "hl"
    fails = 0

    def check(label, ok, detail=""):
        nonlocal fails
        print(f"  {'PASS' if ok else 'FAIL'}  {label}{'' if ok else '  ' + detail}")
        fails += not ok

    def hover(col, r=ROW):
        tmux("send-keys", "-t", target, "-l", f"\033[<35;{col};{r}M")
        time.sleep(0.7)

    def lit(cs, i):
        return ("bg", HLBG) in cs[i][1] and ("1", 1) in cs[i][1]

    try:
        time.sleep(2)
        base = cells(row(target))
        plain = "".join(c for c, _ in base).rstrip()
        segs = mklayout.pieces(plain)
        check("stand-in drew its status line", len(segs) >= 2, plain)
        for col, w, text in segs[:2]:
            hover(col + w // 2)
            during = cells(row(target))
            check(f"{text!r}: card open", bool(re.search(r"╭─ \S", tmux("capture-pane", "-p", "-t", target))))
            inside = set(range(col - 1, col - 1 + w))
            check(f"{text!r}: its {w} cells carry the highlight, keep text and fg",
                  all(lit(during, i) and during[i][0] == base[i][0]
                      and dict(during[i][1]).get("fg") == dict(base[i][1]).get("fg") for i in inside),
                  str([during[i] for i in sorted(inside)][:2]))
            check(f"{text!r}: no other cell changed",
                  all(during[i] == base[i] for i in range(len(base)) if i not in inside))
            hover(3, 3)
            time.sleep(0.5)
            check(f"{text!r}: restored cell for cell after leaving", cells(row(target)) == base)
        (ca, wa, _), (cb, wb, _) = segs[0], segs[1]
        hover(ca + wa // 2)
        hover(cb + wb // 2)
        now = cells(row(target))
        on = [i for i in range(len(now)) if lit(now, i)]
        check("A to B: exactly B is highlighted", on == list(range(cb - 1, cb - 1 + wb)), str(on))
        hover(3, 3)
        time.sleep(0.5)
        check("after B: restored", cells(row(target)) == base)
    finally:
        tmux("kill-server")
        os.unlink(fake.name)
    try:
        with open(errlog) as f:
            logged = f.read().strip()
        os.unlink(errlog)
    except FileNotFoundError:
        logged = ""
    check("healthy run logged no degradation", not logged, logged)
    print(f"\nhover-highlight-e2e: {'FAIL' if fails else 'PASS'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

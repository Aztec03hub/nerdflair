#!/usr/bin/env python3
"""hover-highlight-e2e.py - a readout on the MAIN status line is highlighted
while its card is open, like the band's own, and put back cell for cell.

Runs nfpty around a stand-in engine that draws a coloured status line, each
scenario in its OWN private tmux server (nothing on the user's server or
screen). The pointer is sent as the SGR motion report a terminal would send.
The screen is read with `capture-pane -e` and compared per cell: text, colour,
attributes. Scenarios: the basic hover and A-to-B move; a dialog drawn over the
line with the pointer still; the line shifting while the pointer rests; the
shadow screen dying; a resize; SIGTERM; and NFPTY_SHADOW=0.
"""
import glob
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mklayout  # noqa: E402

ROW = 48
INK = "2;31;41;55"         # dark bold text on the lit cells: 38;<this>
OLDBG = "2;31;41;55"       # the first attempt's fill: same colour as the terminal's background, invisible
LITSEQ = "38;" + INK

FAKE = r'''
import os, signal, subprocess, sys, time
subprocess.run(["stty", "raw", "-echo"])
flag = sys.argv[1]
G = "\U000f024b"
def mode():
    try:
        return open(flag).read().strip() or "status"
    except OSError:
        return "status"
def status(pad):
    sys.stdout.write("\033[2J\033[48;1H  " + G + " nerdflair" + pad + " \033[0m· \033[38;2;200;100;50m\U000f062c main\033[0m · \033[38;5;33;3mx y\033[0m")
def dialog():
    sys.stdout.write("\033[2J\033[44;1H Bash command - from the general-purpose agent\033[45;1H Do you want to proceed?\033[48;1H" + " " * 80)
def draw():
    m = mode()
    {"dialog": dialog, "shift": lambda: status("XXXXXX")}.get(m, lambda: status(""))()
    sys.stdout.write("\033[?1000h\033[?1003h\033[?1006h"); sys.stdout.flush()
    return m
signal.signal(signal.SIGWINCH, lambda *_: draw())
shown = draw()
while True:
    if mode() != shown:
        shown = draw()
    time.sleep(0.1)
'''


class Run:
    """One nfpty + stand-in engine in its own private tmux server."""

    def __init__(self, name, env=""):
        self.sock = f"nf-hl-{name}-{os.getpid()}"
        self.dir = tempfile.mkdtemp(prefix="nf-hl-")
        self.flag = os.path.join(self.dir, "flag")
        self.errlog = os.path.join(self.dir, "err.log")
        self.fake = os.path.join(self.dir, "fake.py")
        with open(self.fake, "w") as f:
            f.write(FAKE)
        self.tmux("new-session", "-d", "-x", "120", "-y", "50", "-s", "hl",
                  f"XDG_RUNTIME_DIR={self.dir} NFPTY_ERRLOG={self.errlog} {env} CLAUDE_BIN=/usr/bin/python3 "
                  f"python3 {HERE}/nfpty.py {self.fake} {self.flag}")
        self.tmux("set", "-g", "remain-on-exit", "on")
        time.sleep(2)

    def tmux(self, *a):
        return subprocess.run(["tmux", "-L", self.sock, *a], capture_output=True, text=True).stdout

    def row(self):
        return cells(self.tmux("capture-pane", "-e", "-p", "-t", "hl", "-S", str(ROW - 1), "-E", str(ROW - 1)).split("\n")[0])

    def screen_has_lit(self):
        return LITSEQ in self.tmux("capture-pane", "-e", "-p", "-t", "hl").replace(";", ";").replace("\x1b[48;2;31;41;55m", LITSEQ)

    def card(self):
        return bool(re.search(r"╭─ \S", self.tmux("capture-pane", "-p", "-t", "hl")))

    def hover(self, col, r=ROW, wait=0.7):
        self.tmux("send-keys", "-t", "hl", "-l", f"\033[<35;{col};{r}M")
        time.sleep(wait)

    def mode(self, m):
        with open(self.flag, "w") as f:
            f.write(m)

    def log(self):
        try:
            with open(self.errlog) as f:
                return f.read().strip()
        except FileNotFoundError:
            return ""

    def close(self):
        self.tmux("kill-server")


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


def accent(text):
    """The readout's own card accent, as the fill 48;<this> uses it."""
    return "2;%d;%d;%d" % tuple(mklayout.classify(text)[2])


def lit(cs, i, bg=None):
    """Lit = dark bold ink; with `bg`, on exactly that accent fill. Never the old invisible fill."""
    d = dict(cs[i][1])
    return (d.get("fg") == INK and ("1", 1) in cs[i][1] and d.get("bg") != OLDBG
            and (bg is None or d.get("bg") == bg))


def lit_idx(cs):
    return [i for i in range(len(cs)) if lit(cs, i)]


fails = 0


def check(label, ok, detail=""):
    global fails
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{'' if ok else '  ' + detail}")
    fails += not ok


def pieces_of(cs):
    return mklayout.pieces("".join(c for c, _ in cs).rstrip())


def basic():
    print("basic hover and A-to-B")
    r = Run("basic")
    try:
        base = r.row()
        segs = pieces_of(base)
        check("stand-in drew its status line", len(segs) >= 3, str(segs))
        fills = []
        for col, w, text in segs[:3]:
            r.hover(col + w // 2)
            during = r.row()
            check(f"{text!r}: card open", r.card())
            inside = set(range(col - 1, col - 1 + w))
            bg = accent(text)
            check(f"{text!r}: its {w} cells are 48;{bg} fill, 38;{INK} bold ink, text kept",
                  all(lit(during, i, bg) and during[i][0] == base[i][0] for i in inside),
                  str([during[i] for i in sorted(inside)][:2]))
            fills.append(bg)
            check(f"{text!r}: no other cell changed",
                  all(during[i] == base[i] for i in range(len(base)) if i not in inside))
            r.hover(3, 3, 0.8)
            check(f"{text!r}: restored cell for cell after leaving", r.row() == base)
        check("readouts with different accents get different fills (folder/branch share one; the generic readout does not)", len(set(fills)) >= 2 and fills[0] != fills[2], str(fills))
        check("the accent is not the invisible old fill", OLDBG not in fills)
        (ca, wa, _), (cb, wb, _) = segs[0], segs[1]
        r.hover(ca + wa // 2)
        r.hover(cb + wb // 2)
        check("A to B: exactly B is highlighted", lit_idx(r.row()) == list(range(cb - 1, cb - 1 + wb)), str(lit_idx(r.row())))
        r.hover(3, 3, 0.8)
        check("after B: restored", r.row() == base)
        check("healthy run logged no degradation", not r.log(), r.log())
    finally:
        r.close()


def dialog():
    print("dialog over the line, pointer still")
    r = Run("dialog")
    try:
        col, w, _ = pieces_of(r.row())[1]
        r.hover(col + w // 2)
        check("card open with the highlight on", r.card() and bool(lit_idx(r.row())))
        r.mode("dialog")                      # no pointer movement from here on
        time.sleep(1.5)
        check("no highlighted cell left anywhere on the dialog screen", not r.screen_has_lit())
        check("the card closed without a pointer move", not r.card())
        r.mode("status")
        time.sleep(1.2)
        r.hover(col + w // 2)
        check("status line back: highlight and card work again", r.card() and bool(lit_idx(r.row())))
    finally:
        r.close()


def shift():
    print("status line shifts while the pointer rests")
    r = Run("shift")
    try:
        col, w, _ = pieces_of(r.row())[1]
        r.hover(col + w // 2)
        r.mode("shift")
        time.sleep(1.5)
        now = r.row()
        ncol, nw, _ = pieces_of(now)[1]
        check("the readout really moved", ncol != col, f"{col} {ncol}")
        check("highlight moved with it: exactly its new cells", lit_idx(now) == list(range(ncol - 1, ncol - 1 + nw)),
              f"{lit_idx(now)} want {ncol - 1}..{ncol - 2 + nw}")
        r.hover(3, 3, 0.8)
        check("after leaving: no highlight left", not lit_idx(r.row()))
    finally:
        r.close()


def shadow_dies():
    print("shadow screen dies while highlighted")
    r = Run("shdead")
    try:
        base = r.row()
        col, w, _ = pieces_of(base)[1]
        r.hover(col + w // 2)
        check("highlight on", bool(lit_idx(r.row())))
        socks = glob.glob(os.path.join(r.dir, "nf-shadow-*", "s"))
        check("found the shadow's tmux socket", len(socks) == 1, str(socks))
        if socks:
            subprocess.run(["tmux", "-S", socks[0], "kill-server"], capture_output=True)
        r.hover(3, 3, 1.2)
        check("highlight gone and cells restored from the saved copy", r.row() == base,
              str(lit_idx(r.row())))
        check("it said so", "highlight" in r.log() or "shadow" in r.log(), r.log())
    finally:
        r.close()


def resized():
    print("resize while highlighted")
    r = Run("resize")
    try:
        col, w, _ = pieces_of(r.row())[1]
        r.hover(col + w // 2)
        check("highlight on", bool(lit_idx(r.row())))
        r.tmux("resize-window", "-t", "hl", "-x", "100", "-y", "50")
        time.sleep(1.5)
        check("no highlight left after the resize (the engine repainted)", not r.screen_has_lit())
        check("healthy run logged no degradation", not r.log(), r.log())
    finally:
        r.close()


def sigterm():
    print("SIGTERM while highlighted")
    r = Run("term")
    try:
        base = r.row()
        col, w, _ = pieces_of(base)[1]
        r.hover(col + w // 2)
        check("highlight on", bool(lit_idx(r.row())))
        subprocess.run(["pkill", "-TERM", "-f", f"nfpty.py {r.fake}"])
        time.sleep(1.5)
        check("no highlight left after the wrapper was terminated", not r.screen_has_lit())
    finally:
        r.close()


def no_shadow():
    print("NFPTY_SHADOW=0 with a card open")
    r = Run("noshadow", env="NFPTY_SHADOW=0")
    try:
        base = r.row()
        col, w, _ = pieces_of(base)[1]
        r.hover(col + w // 2)
        check("card opens", r.card())
        check("nothing highlighted (no shadow to read the cells from)", not lit_idx(r.row()))
        r.hover(3, 3, 0.8)
        check("row unchanged afterwards", r.row() == base)
        log = r.log()
        check("the startup note says the shadow is off, and no extra highlight line", "NFPTY_SHADOW=0" in log and "highlight" not in log, log)
    finally:
        r.close()


def main():
    for t in (basic, dialog, shift, shadow_dies, resized, sigterm, no_shadow):
        t()
    print(f"\nhover-highlight-e2e: {'FAIL' if fails else 'PASS'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    main()

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
TAIL = " \033[0m· \033[38;2;200;100;50m\U000f062c main\033[0m · \033[38;5;33;3mx y\033[0m"
R = int(sys.argv[2]) if len(sys.argv) > 2 else 48
def status(pad, clear="\033[2J", tail=TAIL):
    sys.stdout.write(clear + "\033[%d;1H  " % R + G + " nerdflair" + pad + tail)
def body(pad="XXXXXX"):
    return "  " + G + " nerdflair" + pad + TAIL
E = "\033"
def w_split():
    sys.stdout.write(E + "[48;1H"); sys.stdout.flush(); time.sleep(0.4); sys.stdout.write(body())
# The same shifted line, reached by cursor moves and erases that do not look like "ESC[48;1H text".
WRITES = {
    "w_cup": lambda: sys.stdout.write(E + "[48H" + body()),
    "w_vpa": lambda: sys.stdout.write(E + "[48d" + E + "[1G" + body()),
    "w_split": w_split,
    "w_k": lambda: sys.stdout.write(E + "[48d" + E + "[1G" + E + "[K" + body()),
    "w_2k": lambda: sys.stdout.write(E + "[48d" + E + "[2K" + E + "[1G" + body()),
    "w_j": lambda: sys.stdout.write(E + "[48d" + E + "[0J" + E + "[1G" + body()),
    "w_ind": lambda: sys.stdout.write(E + "[47d" + E + "D" + E + "[1G" + body()),
    "w_cud": lambda: sys.stdout.write(E + "[45d" + E + "[3B" + E + "[1G" + body()),
    # The three forms that fooled the cursor-tracking attempt (removed): wide chars then a relative move,
    # a deferred wrap then up, and a far column. No guessing is done now, so they are plain regressions.
    "w_wide": lambda: sys.stdout.write(E + "[47d" + E + "[1G" + "\u4e2d" * 30 + E + "[1B" + E + "[1G" + body()),
    "w_wrap": lambda: sys.stdout.write(E + "[49d" + E + "[1G" + "x" * 120 + E + "[1A" + E + "[1G" + body()),
    "w_far": lambda: sys.stdout.write(E + "[48d" + E + "[999C" + "Z"),
    "w_alt": lambda: sys.stdout.write(E + "[?1049h" + E + "[?1049l" + E + "[48d" + E + "[1G" + body()),
}
def altswitch():                      # a pager: alt screen on, alt screen off, the status row never redrawn
    sys.stdout.write(E + "[?1049h" + E + "[2J" + E + "[1;1Hpager"); sys.stdout.flush(); time.sleep(0.8)
    sys.stdout.write(E + "[?1049l")
def dialog():
    sys.stdout.write("\033[2J\033[44;1H Bash command - from the general-purpose agent\033[45;1H Do you want to proceed?\033[48;1H" + " " * 80)
def draw():
    m = mode()
    if m in WRITES:
        WRITES[m](); sys.stdout.flush()
        return m
    if m == "altswitch":
        altswitch(); sys.stdout.flush()
        return m
    if m == "wide":
        status("", tail=" \033[0m· \u4e2d\u6587\u5b57 ab")
        sys.stdout.write("\033[?1000h\033[?1003h\033[?1006h"); sys.stdout.flush()
        return m
    DUP = " \033[0m· q one · q one"
    {"dialog": dialog, "shift": lambda: status("XXXXXX"), "dup": lambda: status("", tail=DUP),
     "dupshift": lambda: status("XXXXXX", tail=DUP), "dupone": lambda: status("", tail=" \033[0m· q one")}.get(m, lambda: status(""))()
    sys.stdout.write("\033[?1000h\033[?1003h\033[?1006h"); sys.stdout.flush()
    return m
signal.signal(signal.SIGWINCH, lambda *_: draw())
shown = draw()
while True:
    if mode() != shown:
        shown = draw()
    elif shown == "exit":
        subprocess.Popen(["sleep", "30"])      # a descendant keeps the pty slave open: no EIO, the waitpid path
        sys.exit(0)
    elif shown == "firehose":          # lots of output on other rows, and every key read is timestamped
        import select
        for i in range(40):
            sys.stdout.write("\033[%d;1H" % (5 + i % 20) + "f" * 110)
        sys.stdout.flush()
        if select.select([0], [], [], 0)[0]:
            os.read(0, 4096)
            with open(flag + ".keys", "a") as kf:
                kf.write("%f\n" % time.time())
    elif shown == "tickother":         # a spinner on another row only
        sys.stdout.write("\033[%d;1H" % (10 if R > 10 else 1) + "|/-\\"[int(time.time() * 10) % 4]); sys.stdout.flush()
    elif shown == "tick":              # a ticking band: the same line again every ~0.1 s
        status("", clear=""); sys.stdout.flush()
    time.sleep(0.005 if shown == "firehose" else 0.1)
'''


class Run:
    """One nfpty + stand-in engine in its own private tmux server."""

    def __init__(self, name, env="", count=False, rows=50, row=ROW):
        self.rows, self.rown = rows, row
        self.sock = f"nf-hl-{name}-{os.getpid()}"
        self.dir = tempfile.mkdtemp(prefix="nf-hl-")
        self.flag = os.path.join(self.dir, "flag")
        self.errlog = os.path.join(self.dir, "err.log")
        self.fake = os.path.join(self.dir, "fake.py")
        self.spawnlog = os.path.join(self.dir, "spawns")
        if count:      # a tmux that logs each start, ahead of the real one on the wrapper's PATH
            os.makedirs(os.path.join(self.dir, "shim"))
            shim = os.path.join(self.dir, "shim", "tmux")
            with open(shim, "w") as f:
                f.write(f'#!/bin/sh\necho x >> "{self.spawnlog}"\nexec {subprocess.run(["which", "tmux"], capture_output=True, text=True).stdout.strip()} "$@"\n')
            os.chmod(shim, 0o755)
            open(self.spawnlog, "w").close()
            env += f" PATH={os.path.join(self.dir, 'shim')}:$PATH"
        with open(self.fake, "w") as f:
            f.write(FAKE)
        self.tmux("new-session", "-d", "-x", "120", "-y", str(self.rows), "-s", "hl",
                  f"XDG_RUNTIME_DIR={self.dir} NFPTY_ERRLOG={self.errlog} {env} CLAUDE_BIN=/usr/bin/python3 "
                  f"python3 {HERE}/nfpty.py {self.fake} {self.flag} {self.rown}")
        self.tmux("set", "-g", "remain-on-exit", "on")
        time.sleep(2)

    def tmux(self, *a):
        return subprocess.run(["tmux", "-L", self.sock, *a], capture_output=True, text=True).stdout

    def row(self):
        return cells(self.tmux("capture-pane", "-e", "-p", "-t", "hl", "-S", str(self.rown - 1), "-E", str(self.rown - 1)).split("\n")[0])

    def screen_has_lit(self):
        return LITSEQ in self.tmux("capture-pane", "-e", "-p", "-t", "hl").replace(";", ";").replace("\x1b[48;2;31;41;55m", LITSEQ)

    def spawns(self):
        with open(self.spawnlog) as f:
            return len(f.read().split())

    def card(self):
        return bool(re.search(r"╭─ \S", self.tmux("capture-pane", "-p", "-t", "hl")))

    def hover(self, col, r=None, wait=0.7):
        r = r or self.rown
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
        time.sleep(2.0)
        check("no highlighted cell left anywhere on the dialog screen", not r.screen_has_lit())
        check("the card closed without a pointer move", not r.card())
        r.mode("status")
        time.sleep(1.2)
        r.hover(col + w // 2)
        check("status line back: highlight and card work again", r.card() and bool(lit_idx(r.row())))
    finally:
        r.close()


def dialog_ticking():
    print("dialog over a line the engine keeps redrawing (a rate-limited layout read must not paint it)")
    r = Run("tick")
    try:
        col, w, _ = pieces_of(r.row())[1]
        bad = 0
        cycles = 16
        for i in range(cycles):
            r.mode("tick")
            time.sleep(0.5)
            r.hover(col + w // 2, wait=0.3 + 0.04 * i)       # vary the phase against the 0.15 s layout limit
            r.mode("dialog")                                 # drawn once, pointer still   # the repair is spaced out (REFRESH, more when tmux is slow): allow for it
            time.sleep(2.0)
            if r.screen_has_lit() or r.card():
                bad += 1
            r.hover(3, 3, 0.2)
        check(f"zero lit cells on the dialog and the card closed, in {cycles} cycles", bad == 0, f"{bad} of {cycles} cycles bad")
    finally:
        r.close()


def shift_generic():
    print("a readout without a card id follows when the line shifts")
    r = Run("shiftg")
    try:
        col, w, text = pieces_of(r.row())[2]
        r.hover(col + w // 2)
        r.mode("shift")
        time.sleep(1.5)
        now = r.row()
        ncol, nw, ntext = pieces_of(now)[2]
        check("the generic readout really moved", ncol != col and ntext == text, f"{col} {ncol}")
        check("highlight followed it", lit_idx(now) == list(range(ncol - 1, ncol - 1 + nw)), str(lit_idx(now)))
        check("its card is still open", r.card())
    finally:
        r.close()


def dup_text():
    print("two id-less readouts with the same text: the nearest one is followed")
    r = Run("dup")
    try:
        r.mode("dup")
        time.sleep(1.2)
        segs = pieces_of(r.row())
        same = [p for p in segs if p[2] == "q one"]
        check("two equal-text readouts drawn", len(same) == 2, str(segs))
        col, w, _ = same[1]
        r.hover(col + w // 2)
        r.mode("dupshift")
        time.sleep(1.5)
        now = r.row()
        same = [p for p in pieces_of(now) if p[2] == "q one"]
        ncol, nw, _ = same[1]
        check("highlight stays on the SECOND readout after the shift", lit_idx(now) == list(range(ncol - 1, ncol - 1 + nw)),
              f"{lit_idx(now)} want {ncol - 1}..{ncol - 2 + nw}")
    finally:
        r.close()


def exit_path():
    print("the engine exits but a descendant holds the pty (the waitpid path): no highlight left")
    r = Run("exitp")
    try:
        col, w, _ = pieces_of(r.row())[1]
        r.hover(col + w // 2)
        check("highlight on", bool(lit_idx(r.row())))
        r.mode("exit")
        time.sleep(2.5)
        check("no lit cell after the wrapper exited", not r.screen_has_lit())
    finally:
        r.close()


def tracked_writes():
    print("engine rewrites the highlighted row in many forms: the highlight is back on the readout's cells")
    for case in WRITE_CASES:
        r = Run("w" + case)
        try:
            col, w, _ = pieces_of(r.row())[0]
            r.hover(col + w // 2)
            check("highlight on, card open", bool(lit_idx(r.row())) and r.card())
            r.mode("w_" + case)
            time.sleep(1.5)
            now = r.row()
            ncol, nw, _ = pieces_of(now)[0]
            check(f"w_{case}: the highlight is on the readout's cells after the engine rewrote the row",
                  lit_idx(now) == list(range(ncol - 1, ncol - 1 + nw)), f"{lit_idx(now)} want {ncol - 1}..{ncol - 2 + nw}")
        finally:
            r.close()


def cost_bounded():
    print("cost while a card is open is bounded; quiet engine and no card cost nothing; a rewrite is repaired fast")
    r = Run("cost", count=True)
    try:
        col, w, _ = pieces_of(r.row())[1]
        r.mode("tick")
        time.sleep(1.0)
        a = r.spawns()
        time.sleep(3.0)
        check("no card, ticking engine: zero tmux spawns", r.spawns() == a, f"{r.spawns() - a}")
        r.mode("tickother")
        time.sleep(0.5)
        r.hover(col + w // 2, wait=1.5)
        a = r.spawns()
        time.sleep(6.0)
        rate = (r.spawns() - a) / 6.0
        print(f"        measured: {rate:.1f} tmux spawns/s with a card open and a spinner on another row")
        check("card open, spinner on another row: at most 6 tmux spawns/s", rate <= 6, f"{rate:.1f}/s")
        r.mode("status")
        time.sleep(1.5)
        r.hover(col + w // 2, wait=1.5)
        a = r.spawns()
        time.sleep(3.0)
        check("card open, quiet engine: zero tmux spawns", r.spawns() == a, f"{r.spawns() - a}")
        r.mode("w_cup")                       # the highlighted row is rewritten
        time.sleep(0.5)
        now = r.row()
        ncol, nw, _ = pieces_of(now)[1]
        check("highlight restored within 0.5 s of the row being rewritten",
              lit_idx(now) == list(range(ncol - 1, ncol - 1 + nw)), str(lit_idx(now)))
    finally:
        r.close()


def tiny_terminal():
    print("the card covers its own readout's row (tiny terminal): no highlight, and no runaway tmux reads")
    r = Run("tiny", count=True, rows=4, row=3)
    try:
        segs = pieces_of(r.row())
        check("stand-in drew its status line in the 4-row window", len(segs) >= 2, str(segs))
        col, w, _ = segs[1]
        r.mode("tickother")
        r.hover(col + w // 2, wait=1.5)
        check("card open", r.card())
        check("no highlight (the card sits on that row)", not lit_idx(r.row()) and "covers its own readout" in r.log(), r.log())
        a = r.spawns()
        time.sleep(5.0)
        rate = (r.spawns() - a) / 5.0
        print(f"        measured: {rate:.1f} tmux spawns/s")
        check("ticking engine: at most 6 tmux spawns/s", rate <= 6, f"{rate:.1f}/s")
    finally:
        r.close()


def failed_switch_cost():
    print("moving A to B while the shadow is dead: the failed highlight must not leave the re-read running every turn")
    r = Run("deadcost", count=True)
    try:
        segs = pieces_of(r.row())
        (ca, wa, _), (cb, wb, _) = segs[0], segs[1]
        r.mode("tickother")
        time.sleep(0.5)
        r.hover(ca + wa // 2, wait=1.0)
        check("highlight on A", bool(lit_idx(r.row())))
        socks = glob.glob(os.path.join(r.dir, "nf-shadow-*", "s"))
        if socks:
            subprocess.run(["tmux", "-S", socks[0], "kill-server"], capture_output=True)
        r.hover(cb + wb // 2, wait=1.5)
        a = r.spawns()
        time.sleep(5.0)
        rate = (r.spawns() - a) / 5.0
        print(f"        measured: {rate:.1f} tmux spawns/s")
        check("with the highlight failing and the engine ticking: at most 6 tmux spawns/s", rate <= 6, f"{rate:.1f}/s")
        check("nothing left lit", not r.screen_has_lit())
    finally:
        r.close()


def alt_screen():
    print("the engine switches to the alt screen and back while a card is up: nothing stays lit")
    r = Run("alt")
    try:
        base = r.row()
        col, w, _ = pieces_of(base)[1]
        r.hover(col + w // 2)
        check("highlight on", bool(lit_idx(r.row())))
        r.mode("altswitch")
        time.sleep(2.5)
        check("after the return the row is as it was, with no card and nothing lit (both were taken down first)",
              r.row() == base and not r.card() and not r.screen_has_lit(), f"lit {lit_idx(r.row())} card {r.card()}")
        r.hover(col + w // 2, wait=1.0)
        check("hovering again brings the card and the highlight back", r.card() and bool(lit_idx(r.row())))
        r.hover(3, 3, 1.0)
        check("and leaving takes both down", not r.card() and not r.screen_has_lit())
    finally:
        r.close()


def wide_readout():
    print("a readout with double-width characters")
    r = Run("wide")
    try:
        r.mode("wide")
        time.sleep(1.2)
        now = r.row()
        txt = "".join(c for c, _ in now)
        i = txt.index("\u4e2d")
        seg = [p for p in pieces_of(now) if "\u4e2d" in p[2]]
        check("stand-in drew the wide readout", len(seg) == 1, txt)
        col, w, text = seg[0]
        r.hover(col + 1, wait=1.0)
        lit_txt = "".join(c for k, (c, _) in enumerate(r.row()) if lit(r.row(), k))
        check("the highlight covers exactly the readout's characters", lit_txt == text, f"{lit_txt!r} want {text!r}")
        r.hover(3, 3, 0.8)
        check("restored cell for cell", r.row() == now)
    finally:
        r.close()


def dup_vanishes():
    print("the hovered twin vanishes: the card closes, it does not jump to the other")
    r = Run("dupgone")
    try:
        r.mode("dup")
        time.sleep(1.2)
        same = [p for p in pieces_of(r.row()) if p[2] == "q one"]
        col, w, _ = same[1]
        r.hover(col + w // 2)
        check("card open on the second twin", r.card())
        r.mode("dupone")
        time.sleep(1.5)
        check("card closed and nothing lit", not r.card() and not r.screen_has_lit())
    finally:
        r.close()


WRITE_CASES = ("cup", "vpa", "split", "k", "2k", "j", "ind", "cud", "wide", "wrap", "far")


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
    for t in (basic, dialog, dialog_ticking, shift, shift_generic, dup_text, dup_vanishes, tracked_writes, tiny_terminal, failed_switch_cost, alt_screen, wide_readout, cost_bounded, exit_path, shadow_dies, resized, sigterm, no_shadow):
        t()
    print(f"\nhover-highlight-e2e: {'FAIL' if fails else 'PASS'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    main()

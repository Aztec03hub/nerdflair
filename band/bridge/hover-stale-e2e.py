#!/usr/bin/env python3
"""hover-stale-e2e.py - when the engine redraws a row under an open card, taking
the card down must show the NEW row, not the one from when it opened.

Runs nfpty in its own tmux window around a stand-in engine that draws a status
line and a line of text in the rows the card covers, then (on a flag file)
rewrites that line while the card is up. The card is closed and the row read.

With the shadow screen (the default) the row restores to the new text. The
control runs the same sequence with NFPTY_SHADOW=0, where the old behaviour is
to restore what was saved at open: it must show the OLD text, which proves the
test can fail and that the shadow is what fixes it.
"""
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WIN = "nf-stale"
FLAG = "/tmp/nf-stale.flag"
ROW = 46                     # inside the card (rows 45-47, columns from 4), which sits just above the status line on row 48

FAKE = r'''
import os, sys, time
os.system("stty raw -echo")  # fixed string, no input: safe
F, G = "/tmp/nf-stale.flag", "\U000f024b"
def draw(word):
    sys.stdout.write("\033[46;6H" + word.ljust(12)); sys.stdout.flush()
sys.stdout.write("\033[2J\033[48;1H  " + G + " nerdflair · \U000f062c main · x")
sys.stdout.write("\033[?1000h\033[?1003h\033[?1006h"); draw("alpha")
shown = "alpha"
while True:
    want = open(F).read().strip() if os.path.exists(F) else "alpha"
    if want != shown:
        draw(want); shown = want
    time.sleep(0.05)
'''


def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout


def run(shadow):
    """Returns the text of ROW after the card has been opened, the engine has
    rewritten the row under it, and the card has been closed."""
    with open(FLAG, "w") as f:
        f.write("alpha")
    fake = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False,
                                       dir=os.path.expanduser("~/.claude"))
    fake.write(FAKE)
    fake.close()
    tmux("kill-window", "-t", WIN)
    tmux("new-window", "-d", "-n", WIN,
         f"NFPTY_SHADOW={1 if shadow else 0} CLAUDE_BIN=/usr/bin/python3 python3 {HERE}/nfpty.py {fake.name}")
    target = f"{tmux('display-message', '-p', '-t', WIN, '#{session_name}').strip()}:{WIN}"
    try:
        time.sleep(2)
        tmux("send-keys", "-t", target, "-l", "\033[<35;6;48M")        # onto "nerdflair"
        time.sleep(0.6)
        screen = tmux("capture-pane", "-p", "-t", target)
        if not re.search(r"╭─ \S", screen):
            return "NO CARD OPENED"
        if os.environ.get("E2E_DEBUG"):
            rows = screen.split("\n")
            print("   card rows", [i + 1 for i, r in enumerate(rows) if "╭" in r or "╰" in r], file=sys.stderr)
        with open(FLAG, "w") as f:
            f.write("bravo")                                           # the engine redraws the covered row
        time.sleep(0.8)
        tmux("send-keys", "-t", target, "-l", "\033[<35;3;3M")         # pointer leaves
        time.sleep(0.8)
        screen = tmux("capture-pane", "-p", "-t", target)
        if re.search(r"╭─ \S", screen):
            return "CARD STILL OPEN"
        return screen.split("\n")[ROW - 1].strip()
    finally:
        tmux("kill-window", "-t", target)
        os.unlink(fake.name)
        os.unlink(FLAG)


def main():
    if not os.environ.get("TMUX"):
        sys.exit("run this inside tmux")
    fails = 0
    for label, shadow, want in (("with the shadow screen", True, "bravo"),
                                ("control, shadow off (old behaviour)", False, "alpha")):
        got = run(shadow)
        ok = got == want
        fails += not ok
        print(f"  {'PASS' if ok else 'FAIL'}  {label}: restored row reads {got!r} (want {want!r})")
    print(f"\nhover-stale-e2e: {'FAIL' if fails else 'PASS'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

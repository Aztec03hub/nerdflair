#!/usr/bin/env python3
"""hover-linger-e2e.py - how long does a card stay up after the pointer is far away?

Same stand-in engine as hover-covered-e2e.py. Scenarios, each measuring seconds
from "pointer moved far away" until the card is gone (capped at 8 s):
  direct  : onto a readout (card opens), then straight far away
  crossed : onto a readout, across the CARD, then far away
  card-rest: onto a readout, onto the card, then NO more reports at all
"""
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WIN = "nf-linger"
FAKE = r'''
import os, sys, time
os.system("stty raw -echo")  # fixed string, no input: safe
G = "\U000f024b"
sys.stdout.write("\033[2J\033[48;1H  " + G + " nerdflair · \U000f062c main · x")
sys.stdout.write("\033[?1000h\033[?1003h\033[?1006h"); sys.stdout.flush()
while True:
    time.sleep(1)
'''


def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout


def card(target):
    return bool(re.search(r"╭─ \S", tmux("capture-pane", "-p", "-t", target)))


def hover(target, col, row):
    tmux("send-keys", "-t", target, "-l", f"\033[<35;{col};{row}M")


def scenario(name):
    fake = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False, dir=os.path.expanduser("~/.claude"))
    fake.write(FAKE)
    fake.close()
    tmux("kill-window", "-t", WIN)
    tmux("new-window", "-d", "-n", WIN, f"CLAUDE_BIN=/usr/bin/python3 python3 {HERE}/nfpty.py {fake.name}")
    target = f"{tmux('display-message', '-p', '-t', WIN, '#{session_name}').strip()}:{WIN}"
    try:
        time.sleep(2)
        hover(target, 6, 48)
        time.sleep(0.6)
        if not card(target):
            return "card never opened"
        if name in ("crossed", "card-rest"):
            for c in (8, 12, 16):                   # across the card, which sits just above row 48
                hover(target, c, 46)
                time.sleep(0.1)
            if not card(target):
                return "card closed while the pointer was ON it"
        if name == "typing":
            tmux("send-keys", "-t", target, "-l", "x")          # typing takes it down at once
            t0 = time.monotonic()
        elif name in ("readout-rest", "card-rest"):
            t0 = time.monotonic()
        if name in ("card-rest", "readout-rest", "typing"):
            pass                                    # t0 set above: no pointer move at all
        else:
            hover(target, 3, 3)                     # far away
            t0 = time.monotonic()
        while time.monotonic() - t0 < 8:
            if not card(target):
                return f"{time.monotonic() - t0:.2f}s"
            time.sleep(0.1)
        return ">8s (still open)"
    finally:
        tmux("kill-window", "-t", target)
        os.unlink(fake.name)


# (scenario, min seconds, max seconds) from "pointer far away" to "card gone";
# a pointer resting still ON the card must keep it up (no report, long watchdog)
EXPECT = {"direct": (0.0, 1.0), "crossed": (0.0, 1.0), "typing": (0.0, 1.0),
          "card-rest": (8.0, 8.0), "readout-rest": (8.0, 8.0)}


def main():
    if not os.environ.get("TMUX"):
        sys.exit("run this inside tmux")
    fails = 0
    for name, (lo, hi) in EXPECT.items():
        got = scenario(name)
        if got.startswith(">8s"):
            ok = lo == 8.0
        elif got.startswith("card closed") or got.startswith("card never"):
            ok = False
        else:
            try:
                ok = lo <= float(got.rstrip("s")) <= hi
            except ValueError:
                ok = False
        fails += not ok
        print(f"  {'PASS' if ok else 'FAIL'}  {name:10s} card gone after {got} (allowed {lo}-{hi}s; >8s means still up)")
    print(f"\nhover-linger: {'FAIL' if fails else 'PASS'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

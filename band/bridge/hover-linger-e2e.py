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
import shlex
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import leakcheck  # noqa: E402

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


def errlog_must_be_empty():
    """A healthy run absorbs nothing: the bridge's error log must not exist or be empty.
    Anything in it is a degradation that happened, and the e2e treats it as a failure."""
    try:
        with open(ERRLOG) as f:
            # the harness kills the window while a card may be up: the guard's own 'terminal write failed' line is that teardown, not a degradation
            text = "\n".join(ln for ln in f.read().splitlines() if "terminal write failed" not in ln).strip()
    except FileNotFoundError:
        text = ""
    print(f"  {'PASS' if not text else 'FAIL'}  healthy run logged no degradation" + ("" if not text else "\n" + text))
    return bool(text)


def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout


def card(target):
    return bool(re.search(r"╭─ \S", tmux("capture-pane", "-p", "-t", target)))


def hover(target, col, row):
    tmux("send-keys", "-t", target, "-l", f"\033[<35;{col};{row}M")


def scenario(name):
    fake = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False, dir=leakcheck.e2e_tmp())
    fake.write(FAKE)
    fake.close()
    tmux("kill-window", "-t", WIN)
    tmux("new-window", "-d", "-n", WIN, f"NFPTY_ERRLOG={shlex.quote(ERRLOG)} CLAUDE_BIN=/usr/bin/python3 python3 {HERE}/nfpty.py {fake.name}")
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
        leakcheck.file(fake.name)    # SystemExit mid-scenario still removes it


# (scenario, min seconds, max seconds) from "pointer far away" to "card gone";
# a pointer resting still ON the card must keep it up (no report, long watchdog)
EXPECT = {"direct": (0.0, 1.0), "crossed": (0.0, 1.0), "typing": (0.0, 1.0),
          "card-rest": (8.0, 8.0), "readout-rest": (8.0, 8.0)}


def main():
    global ERRLOG
    if not os.environ.get("TMUX"):
        sys.exit("run this inside tmux")
    leakcheck.install()
    ERRLOG = leakcheck.file(os.path.join(leakcheck.e2e_tmp(), "nf-linger.errlog"))   # made after the tmux check: no dir leaks on an early exit
    fails = 0
    try:
        os.unlink(ERRLOG)
    except FileNotFoundError:
        pass
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
    fails += errlog_must_be_empty()
    print(f"\nhover-linger: {'FAIL' if fails else 'PASS'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""hover-covered-e2e.py - a dialog drawn over the status line must leave no
hoverable region behind.

Runs nfpty in its own tmux window around a stand-in for Claude Code that draws
a status line, then (on a signal file) clears the screen and draws a
permission-style dialog in its place. The pointer is put on the same cell
before and after. Before, a card must open. After, none may, and when the
status line is drawn back the card must work again.

A stand-in rather than the real thing because a permission prompt cannot be
raised on demand in a session that bypasses permissions; what the wrapper
sees, bytes on the pty, is the same.
"""
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WIN = "nf-covered"

FAKE = r'''
import os, sys, time
os.system("stty raw -echo")  # fixed string, no input: safe
F, G = "/tmp/nf-covered.flag", "\U000f024b"
def status():
    sys.stdout.write("\033[2J\033[48;1H  " + G + " nerdflair · \U000f062c main · x")
    sys.stdout.write("\033[?1000h\033[?1003h\033[?1006h"); sys.stdout.flush()
def dialog():
    sys.stdout.write("\033[2J\033[44;1H Bash command · from the general-purpose agent\033[45;1H Do you want to proceed?")
    sys.stdout.flush()
status()
shown = "status"
while True:
    want = open(F).read().strip() if os.path.exists(F) else "status"
    if want != shown:
        (dialog if want == "dialog" else status)(); shown = want
    time.sleep(0.1)
'''


def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout


def card_open(target):
    return bool(re.search(r"╭─ \S", tmux("capture-pane", "-p", "-t", target)))


def main():
    if not os.environ.get("TMUX"):
        sys.exit("run this inside tmux")
    flag = "/tmp/nf-covered.flag"
    with open(flag, "w") as f:
        f.write("status")
    fake = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False,
                                       dir=os.path.expanduser("~/.claude"))
    fake.write(FAKE)
    fake.close()
    tmux("kill-window", "-t", WIN)
    tmux("new-window", "-d", "-n", WIN,
         f"CLAUDE_BIN=/usr/bin/python3 python3 {HERE}/nfpty.py {fake.name}")
    target = f"{tmux('display-message', '-p', '-t', WIN, '#{session_name}').strip()}:{WIN}"
    fails = 0

    def check(label, want):
        nonlocal fails
        tmux("send-keys", "-t", target, "-l", "\033[<35;6;48M")     # on "nerdflair"
        time.sleep(0.6)
        got = card_open(target)
        print(f"  {'PASS' if got == want else 'FAIL'}  {label}: card {'open' if got else 'closed'}")
        fails += got != want
        tmux("send-keys", "-t", target, "-l", "\033[<35;3;3M")
        time.sleep(0.6)

    try:
        time.sleep(2)
        check("status line drawn", True)
        with open(flag, "w") as f:
            f.write("dialog")
        time.sleep(1)
        check("dialog over the status line", False)
        check("dialog still up, second hover", False)
        with open(flag, "w") as f:
            f.write("status")
        time.sleep(1)
        check("status line drawn back", True)
    finally:
        tmux("kill-window", "-t", target)
        os.unlink(fake.name)
        os.unlink(flag)
    print(f"\nhover-covered-e2e: {'FAIL' if fails else 'PASS'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

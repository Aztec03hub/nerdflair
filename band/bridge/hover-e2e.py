#!/usr/bin/env python3
"""hover-e2e.py - start a real Claude Code under the wrapper in its own tmux
window, hover every readout it draws, and check the card that opens is the
right one. Run from inside tmux; it never selects the window, so it does not
take the screen from whoever is using it.

What it proves, and what it does not. It sends the same SGR motion report the
terminal would, through tmux, into the pane's input, so the whole path under
test is real: nfpty reading the pointer, mklayout finding the readout, the card
being painted, and the backdrop being put back afterwards. It cannot prove how
the terminal emulator itself renders the cells; a screenshot does that.
"""
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mklayout  # noqa: E402

WIN = "nf-e2e"


def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout


def screen(target):
    return tmux("capture-pane", "-p", "-t", target)


def main():
    if not os.environ.get("TMUX"):
        sys.exit("run this inside tmux")
    shim = os.path.expanduser("~/.nerdflair/bin")
    tmux("kill-window", "-t", WIN)
    tmux("new-window", "-d", "-n", WIN, "-c", os.path.expanduser("~/nerdflair"),
         f"PATH={shim}:$PATH claude --dangerously-skip-permissions")
    target = f"{tmux('display-message', '-p', '-t', WIN, '#{session_name}').strip()}:{WIN}"
    try:
        for _ in range(60):
            time.sleep(1)
            s = screen(target)
            if "bypass permissions" in s and re.search(r"\d+/\d+", s):
                break
        else:
            sys.exit("claude did not come up")
        time.sleep(3)                       # let the band and layout settle
        segs = mklayout.build(target)
        if not segs:
            sys.exit("no readouts found on the status line")
        bad = 0
        for s in segs:
            col = s["x"] + s["w"] // 2 + int(os.environ.get("NF_E2E_SHIFT", "0"))  # SHIFT: positive control, must FAIL
            tmux("send-keys", "-t", target, "-l", f"\033[<35;{col};{s['row']}M")
            time.sleep(0.5)
            scr = screen(target)
            ok = bool(re.search(r"╭─ " + re.escape(s["title"]) + r" ─", scr))
            print(f"  {'PASS' if ok else 'FAIL'}  {s['title']:<28} col {col:>3} row {s['row']}")
            bad += not ok
            # off the band, long enough for the panel to be taken down
            tmux("send-keys", "-t", target, "-l", "\033[<35;3;3M")
            time.sleep(0.6)
            after = screen(target)
            if "╭─" in after.split("\n", 40)[-1] and s["title"] in after:
                print(f"  FAIL  {s['title']}: panel still up after leaving")
                bad += 1
        print(f"\nhover-e2e: {'FAIL' if bad else 'PASS'} ({len(segs)} readouts)")
        sys.exit(1 if bad else 0)
    finally:
        tmux("kill-window", "-t", target)


if __name__ == "__main__":
    main()

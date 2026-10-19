#!/usr/bin/env python3
"""winshot-demo.py - show the status-line hover highlight in the REAL terminal.

Starts a real Claude Code, under THIS worktree's wrapper, in a new detached tmux
window of the server you run it from (it never selects the window). It then
waits until the person selects that window, and only then drives the pointer and
captures the terminal window with winshot: baseline, hover A, hover B, away.

Nothing is sent to the desktop. The pointer is simulated by writing SGR mouse
reports into that one pane with tmux send-keys, the same bytes a terminal sends.

  python3 winshot-demo.py OUTDIR [TERMINAL_EXE_SUBSTRING]
Writes OUTDIR/ready when the window is up (select it now), OUTDIR/done when the
captures are finished and the window is gone.
"""
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mklayout  # noqa: E402

WIN = "nfhl"


def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout


def main():
    out = sys.argv[1]
    exe = sys.argv[2] if len(sys.argv) > 2 else "wezterm"
    os.makedirs(out, exist_ok=True)
    if not os.environ.get("TMUX"):
        sys.exit("run this inside tmux")
    # A private shim dir whose `hover` link points at THIS worktree's bridge, so
    # the branch under test is what runs, not the installed copy.
    shim = os.path.join(out, "shim")
    os.makedirs(os.path.join(shim, "bin"), exist_ok=True)
    hv = os.path.join(HERE, "..", "hover")
    for f in ("claude-shim", "nf-log.sh", "nf-tmux-heal", "nf-tmux-watch"):
        src = os.path.join(hv, f)
        if os.path.exists(src):
            dst = os.path.join(shim, "bin", "claude" if f == "claude-shim" else f)
            shutil.copy(src, dst)
            os.chmod(dst, 0o755)
    link = os.path.join(shim, "hover")
    if not os.path.islink(link):
        os.symlink(HERE, link)
    tmux("kill-window", "-t", WIN)
    sess = tmux("display-message", "-p", "#{session_name}").strip()
    tmux("new-window", "-d", "-n", WIN, "-c", os.path.expanduser("~/nerdflair"),
         f"umask 022; PATH={shim}/bin:$PATH claude --dangerously-skip-permissions")
    target = f"{sess}:{WIN}"
    try:
        for _ in range(90):
            time.sleep(1)
            s = tmux("capture-pane", "-p", "-t", target)
            if "bypass permissions" in s and re.search(r"\d+/\d+", s):
                break
        else:
            sys.exit("claude did not come up")
        time.sleep(3)
        segs = mklayout.build(target)
        if not segs:
            sys.exit("no readouts found on the status line")
        by = {s["title"]: s for s in segs}
        pick = [by[t] for t in ("Token throughput", "MCP health") if t in by]
        pick = (pick + [s for s in segs if s not in pick])[:2]
        open(os.path.join(out, "ready"), "w").write(
            "A=%s B=%s\n" % (pick[0]["title"], pick[1]["title"]))
        # Wait for the person to select the window; never select it ourselves.
        for _ in range(1800):
            if tmux("display-message", "-p", "-t", target, "#{window_active}").strip() == "1":
                break
            time.sleep(0.5)
        else:
            sys.exit("window was never selected")
        time.sleep(1.5)

        def shot(name):
            p = subprocess.run(["winshot", "--exe", exe, "-o", os.path.join(out, name + ".png")],
                               capture_output=True, text=True)
            open(os.path.join(out, name + ".txt"), "w").write(
                tmux("capture-pane", "-p", "-e", "-t", target) + "\n---\n" + p.stdout + p.stderr)

        def hover(seg):
            col = seg["x"] + seg["w"] // 2
            tmux("send-keys", "-t", target, "-l", f"\033[<35;{col};{seg['row']}M")
            time.sleep(1.0)

        shot("1-baseline")
        hover(pick[0]); shot("2-hover-A")
        hover(pick[1]); shot("3-hover-B")
        tmux("send-keys", "-t", target, "-l", "\033[<35;3;3M")
        time.sleep(1.0); shot("4-away")
    finally:
        tmux("kill-window", "-t", target)
        open(os.path.join(out, "done"), "w").write("done\n")


if __name__ == "__main__":
    main()

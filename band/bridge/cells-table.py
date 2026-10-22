#!/usr/bin/env python3
"""cells() against tmux 3.4 itself. Every sequence in TABLE is printed in a private tmux server (own socket, TMUX
unset) and the cursor advance is read back; `mklayout.cells` must equal it. Run: python3 cells-table.py
(skips with exit 0 and a note if tmux is missing). `--measure` prints the measured widths instead of asserting.
The renderer itself only emits Nerd Font glyphs, ASCII, box/arrow symbols and the ellipsis; the rest guards the
readout names a user can type (folder, branch)."""
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import leakcheck  # noqa: E402
import mklayout  # noqa: E402

M, W, G, B = "\U0001f468", "\U0001f469", "\U0001f467", "\U0001f466"      # man woman girl boy
Z, V16 = "‍", "️"
RI = lambda c: chr(0x1F1E6 + ord(c) - 65)      # regional indicator
TABLE = [
    ("ascii", "abc"), ("cjk", "漢字"), ("emoji", "\U0001f600"), ("accent", "é"),
    ("nerd icon", "\U000f024b "), ("box+arrow+ellipsis", "─│←⏵…"),
    ("zwj2", M + Z + W), ("zwj3 family", M + Z + W + Z + G), ("zwj4 family", M + Z + W + Z + G + Z + B),
    ("zwj5 chain", M + Z + W + Z + G + Z + B + Z + M), ("trailing zwj", M + Z), ("zwj between ascii", "a" + Z + "b"),
    ("emoji zwj ascii", M + Z + "b"), ("zwj after cjk", "漢" + Z + "x"),
    ("heart vs16", "❤" + V16), ("keycap", "1" + V16 + "⃣"), ("coffee vs16", "☕" + V16),
    ("skin tone", "\U0001f44d\U0001f3fd"), ("one flag", RI("U") + RI("S")), ("two flags", RI("U") + RI("S") + RI("D") + RI("E")),
    ("three flags", RI("U") + RI("S") + RI("D") + RI("E") + RI("F") + RI("R")),
    ("zwj narrow vs16", M + Z + "❤" + V16), ("ascii zwj emoji", "a" + Z + M),
]


def measure(seqs):
    sock, d = leakcheck.tmux_L(f"nf-cells-{os.getpid()}"), leakcheck.mkdtemp("nf-cells-")
    env = {k: v for k, v in os.environ.items() if k != "TMUX"}
    t = lambda *a: subprocess.run(["tmux", "-L", sock, "-f", "/dev/null", *a], capture_output=True, text=True, env=env).stdout
    out = {}
    try:
        t("new-session", "-d", "-x", "80", "-y", "30", "-s", "s", "-n", "w0", "sleep 600")
        for i, (name, seq) in enumerate(seqs):
            f = os.path.join(d, f"{i}.txt")
            with open(f, "w", encoding="utf-8") as fh:
                fh.write(seq)
            t("new-window", "-t", "s:", "-n", f"w{i + 1}", f"cat {f}; sleep 600")
        for i, (name, seq) in enumerate(seqs):
            for _ in range(50):
                v = t("display-message", "-p", "-t", f"s:w{i + 1}", "#{cursor_x}").strip()
                if v.isdigit() and int(v) > 0:
                    break
                time.sleep(0.1)
            out[name] = int(v) if v.isdigit() else None
    finally:
        t("kill-server")
    return out


def main():
    try:
        got = measure(TABLE)
    except FileNotFoundError:
        print("cells-table: tmux not found, skipped")
        return 0
    bad = 0
    for name, seq in TABLE:
        mine = mklayout.cells(seq)
        if "--measure" in sys.argv:
            print(f"{name:22} tmux {got[name]}  cells() {mine}")
        elif mine != got[name]:
            bad += 1
            print(f"  FAIL  {name}: tmux draws {got[name]} cells, cells() says {mine}")
    print("cells-table: " + ("FAIL" if bad else "PASS") + f" ({len(TABLE)} sequences, tmux {subprocess.run(['tmux', '-V'], capture_output=True, text=True).stdout.strip()})")
    return 1 if bad else 0


if __name__ == "__main__":
    leakcheck.install()
    sys.exit(main())

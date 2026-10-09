#!/usr/bin/env python3
"""hoverdemo.py - the band with real hover popups, end to end.

WHAT THIS IS FOR. The painter is settled: an overlay is escape sequences
written to a pane's tty. The open problem is getting a hover OUT of Claude
Code, which raises no hover hook. This demo stands in for that one missing
piece and nothing else: it owns the mouse itself, so the hover source is
local, and everything downstream (hit-testing a readout, placing a panel,
painting it, erasing it) is the real thing.

So what you see here is what the band will do once the hover arrives over the
bridge. Swap the input and the rest is unchanged.

Mouse mode 1003 is "any event": the terminal reports motion with no button
held, which is what a hover IS. 1006 asks for SGR encoding, which gives
coordinates as decimal text (ESC[<btn;col;rowM) instead of the original
byte-packed form that breaks past column 223.
"""
import os
import re
import signal
import sys
import termios
import tty

ESC = "\033"
RESET = f"{ESC}[0m"
DIM = f"{ESC}[38;5;244m"
LIT = f"{ESC}[48;5;236m"

# id, label, accent, title, body lines
SEGMENTS = [
    ("rc", "⬤ RC on", "38;5;114", "Remote Control",
     ["a Remote Control bridge is attached to this session",
      "anything typed there runs here, in this working directory"]),
    ("folder", "󰉋 nerdflair · 󰘬 main", "38;5;111", "Folder and branch",
     ["workspace.project_dir, else current_dir",
      "branch from git rev-parse, cached 5s"]),
    ("model", " Opus 5", "38;5;141", "Model and effort",
     ["model.display_name, else model.id",
      "effort.level, after any silent downgrade"]),
    ("burn", "󰈸 $2.88/h", "38;5;215", "Burn rate",
     ["dollars per hour across EVERY session, last 60 minutes",
      "sums positive increments, so a reset cannot erase it",
      "suppressed when the newest sample is over 3 minutes old"]),
    ("limits", "5h 28%/1h51m", "38;5;114", "Plan rate limits",
     ["5h and 7d windows from the payload's rate_limits",
      "Anthropic's own server-side metering, not an estimate"]),
    ("block", " $9414.51", "38;5;183", "Repo total",
     ["everything this repo has cost over 30 days",
      "max cumulative cost per session, summed"]),
]

SEP = " · "


class Screen:
    def __init__(self):
        self.tty = open("/dev/tty", "w")
        self.rows, self.cols = self._size()
        self.band_row = self.rows - 2
        self.layout = []          # (id, x, w, idx)
        self.shown = None         # index of the panel on screen
        self.panel_rect = None    # (x, y, w, h) so we can erase exactly

    def _size(self):
        sz = os.get_terminal_size()
        return sz.lines, sz.columns

    def w(self, s):
        self.tty.write(s)
        self.tty.flush()

    def draw_base(self):
        """The whole screen: a fake transcript plus the band."""
        out = [f"{ESC}[2J"]
        for r in range(1, self.rows - 3):
            out.append(f"{ESC}[{r};1H{DIM}  transcript line {r}, "
                       f"this is what the panel floats over{RESET}")
        out.append(self._band())
        out.append(f"{ESC}[{self.rows};1H{DIM}  move the pointer over a "
                   f"readout. q to quit.{RESET}")
        self.w("".join(out))

    def _band(self):
        """Draw the band and record where each readout sits."""
        self.layout = []
        x = 3
        parts = [f"{ESC}[{self.band_row};1H{ESC}[2K"]
        for i, (sid, label, accent, _t, _b) in enumerate(SEGMENTS):
            if i:
                parts.append(f"{DIM}{SEP}{RESET}")
                x += len(SEP)
            parts.append(f"{ESC}[{accent}m{label}{RESET}")
            self.layout.append((sid, x, len(label), i))
            x += len(label)
        return f"{ESC}[{self.band_row};3H" + "".join(parts[1:])

    def hit(self, col, row):
        """Which readout is under the pointer, if any."""
        if row != self.band_row:
            return None
        for sid, x, w, idx in self.layout:
            if x <= col < x + w:
                return idx
        return None

    def erase_panel(self):
        """Repaint only what the panel covered. We know the rect, and the
        content under it is ours, so this is exact rather than a full clear
        that would flicker the whole screen."""
        if not self.panel_rect:
            return
        px, py, pw, ph = self.panel_rect
        out = []
        for r in range(py, py + ph):
            if 1 <= r < self.rows - 3:
                text = (f"  transcript line {r}, this is what the panel "
                        f"floats over")
                seg = text[px - 1:px - 1 + pw].ljust(pw)
                out.append(f"{ESC}[{r};{px}H{DIM}{seg}{RESET}")
            else:
                out.append(f"{ESC}[{r};{px}H{' ' * pw}")
        self.w("".join(out))
        self.panel_rect = None

    def show_panel(self, idx, col):
        _sid, _label, accent, title, body = SEGMENTS[idx]
        w = max(len(title) + 6, max(len(b) for b in body) + 4)
        w = min(w, self.cols - 4)
        h = len(body) + 2
        x = max(1, min(col - 2, self.cols - w - 1))
        y = self.band_row - h            # sits just above the band
        if y < 1:
            y = self.band_row + 1

        if self.panel_rect and self.panel_rect != (x, y, w, h):
            self.erase_panel()

        acc = f"{ESC}[{accent}m"
        out = [f"{ESC}[s", f"{ESC}[?25l"]
        rule = "─" * (w - len(title) - 5)
        out.append(f"{ESC}[{y};{x}H{acc}╭─ {ESC}[1m{title}{ESC}[22m {rule}╮{RESET}")
        for i, line in enumerate(body):
            out.append(f"{ESC}[{y+1+i};{x}H{acc}│{RESET} "
                       f"{line:<{w-4}} {acc}│{RESET}")
        out.append(f"{ESC}[{y+h-1};{x}H{acc}╰{'─' * (w-2)}╯{RESET}")
        out += [f"{ESC}[?25h", f"{ESC}[u"]
        self.w("".join(out))
        self.panel_rect = (x, y, w, h)
        self.shown = idx

    def highlight(self, idx):
        """Light the hovered readout, exactly as the engine's own hover does."""
        parts = []
        for sid, x, w, i in self.layout:
            label = SEGMENTS[i][1]
            accent = SEGMENTS[i][2]
            style = f"{LIT}{ESC}[1m" if i == idx else ""
            parts.append(f"{ESC}[{self.band_row};{x}H{style}{ESC}[{accent}m"
                         f"{label}{RESET}")
        self.w("".join(parts))


MOUSE = re.compile(r"\033\[<(\d+);(\d+);(\d+)([Mm])")


def main():
    scr = Screen()
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)

    def restore(*_):
        scr.w(f"{ESC}[?1003l{ESC}[?1006l{ESC}[?25h{ESC}[2J{ESC}[H")
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.exit(0)

    signal.signal(signal.SIGTERM, restore)
    try:
        tty.setraw(fd)
        # 1003 = report motion with no button held, i.e. hover.
        # 1006 = SGR encoding, so columns past 223 still work.
        scr.w(f"{ESC}[?1003h{ESC}[?1006h")
        scr.draw_base()
        buf = ""
        while True:
            ch = os.read(fd, 1024).decode("utf-8", "replace")
            if not ch:
                break
            if "q" in ch:
                break
            buf += ch
            last = None
            for m in MOUSE.finditer(buf):
                last = m
            if last is None:
                buf = buf[-32:]
                continue
            buf = buf[last.end():]
            col, row = int(last.group(2)), int(last.group(3))
            idx = scr.hit(col, row)
            if idx is None:
                if scr.shown is not None:
                    scr.erase_panel()
                    scr.shown = None
                    scr.highlight(-1)
            elif idx != scr.shown:
                scr.highlight(idx)
                scr.show_panel(idx, scr.layout[idx][1])
    finally:
        restore()


if __name__ == "__main__":
    main()

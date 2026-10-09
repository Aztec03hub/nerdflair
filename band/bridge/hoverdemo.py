#!/usr/bin/env python3
"""hoverdemo.py - the band with real hover popups, end to end.

WHAT THIS IS FOR. The painter is settled: an overlay is escape sequences
written to a pane's tty. The open problem is getting a hover OUT of Claude
Code, which raises no hover hook. This demo stands in for that one missing
piece and nothing else: it owns the mouse itself, so the hover source is
local, and everything downstream (hit-testing a readout, placing a panel,
painting it, animating it, erasing it) is the real thing.

Mouse mode 1003 is "any event": the terminal reports motion with no button
held, which is what a hover IS. 1006 asks for SGR encoding, which gives
coordinates as decimal text (ESC[<btn;col;rowM) instead of the original
byte-packed form that breaks past column 223.
"""
import os
import re
import select
import signal
import sys
import termios
import tty

ESC = "\033"
RESET = f"{ESC}[0m"
DIM = f"{ESC}[38;5;244m"
LIT = f"{ESC}[48;5;236m"

# Accents are RGB, not palette indexes, because the shine BLENDS them toward
# white and you cannot interpolate a 256-colour index.
# id, label, accent rgb, title, body lines
SEGMENTS = [
    ("rc", "⬤ RC on", (122, 222, 150), "Remote Control",
     ["a Remote Control bridge is attached to this session",
      "anything typed there runs here, in this working directory"]),
    ("folder", "󰉋 nerdflair · 󰘬 main", (125, 180, 255), "Folder and branch",
     ["workspace.project_dir, else current_dir",
      "branch from git rev-parse, cached 5s"]),
    ("model", " Opus 5", (196, 181, 253), "Model and effort",
     ["model.display_name, else model.id",
      "effort.level, after any silent downgrade"]),
    ("burn", "󰈸 $2.88/h", (251, 146, 60), "Burn rate",
     ["dollars per hour across EVERY session, last 60 minutes",
      "sums positive increments, so a reset cannot erase it",
      "suppressed when the newest sample is over 3 minutes old"]),
    ("limits", "5h 28%/1h51m", (122, 222, 150), "Plan rate limits",
     ["5h and 7d windows from the payload's rate_limits",
      "Anthropic's own server-side metering, not an estimate"]),
    ("block", " $9414.51", (216, 180, 254), "Repo total",
     ["everything this repo has cost over 30 days",
      "max cumulative cost per session, summed"]),
]

SEP = " · "

# The shine. A bright head with a tail fading back to the accent, travelling
# clockwise around the border. TRAIL is in cells; FPS is what the terminal can
# carry comfortably over a pty without the paint becoming the bottleneck.
TRAIL = 14
FPS = 28
FRAME = 1.0 / FPS


def rgb(c):
    return f"{ESC}[38;2;{c[0]};{c[1]};{c[2]}m"


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


class Screen:
    def __init__(self):
        self.tty = open("/dev/tty", "w")
        self.rows, self.cols = self._size()
        self.band_row = self.rows - 2
        self.layout = []          # (id, x, w, idx)
        self.shown = None         # index of the panel on screen
        self.panel_rect = None    # (x, y, w, h) so we can erase exactly
        self.path = []            # border cells, clockwise: (row, col, char)
        self.accent = (255, 255, 255)
        self.head = 0

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
        parts = []
        for i, (sid, label, accent, _t, _b) in enumerate(SEGMENTS):
            if i:
                parts.append(f"{DIM}{SEP}{RESET}")
                x += len(SEP)
            parts.append(f"{rgb(accent)}{label}{RESET}")
            self.layout.append((sid, x, len(label), i))
            x += len(label)
        return f"{ESC}[{self.band_row};1H{ESC}[2K{ESC}[{self.band_row};3H" + "".join(parts)

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
        self.path = []

    def _build_path(self, x, y, w, h, title):
        """Every border cell, clockwise from the top-left corner.

        The title sits IN the top rule, so its characters are part of the
        path: the shine passes over the lettering instead of stopping dead at
        it, which is the whole point of running the highlight round an
        outline rather than drawing a moving dash."""
        top = "╭─ " + title + " " + "─" * (w - len(title) - 5) + "╮"
        bottom = "╰" + "─" * (w - 2) + "╯"
        path = []
        for i, ch in enumerate(top):                 # left to right
            path.append((y, x + i, ch))
        for r in range(1, h - 1):                    # right side, downward
            path.append((y + r, x + w - 1, "│"))
        for i, ch in enumerate(reversed(bottom)):    # right to left
            path.append((y + h - 1, x + w - 1 - i, ch))
        for r in range(h - 2, 0, -1):                # left side, upward
            path.append((y + r, x, "│"))
        return path

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

        acc = rgb(accent)
        out = [f"{ESC}[s", f"{ESC}[?25l"]
        for i, line in enumerate(body):              # interior first
            out.append(f"{ESC}[{y+1+i};{x}H{acc}│{RESET} "
                       f"{line:<{w-4}} {acc}│{RESET}")
        self.w("".join(out))

        self.accent = accent
        self.path = self._build_path(x, y, w, h, title)
        self.head = 0
        self.panel_rect = (x, y, w, h)
        self.shown = idx
        self.paint_border(full=True)
        self.w(f"{ESC}[?25h{ESC}[u")

    def paint_border(self, full=False):
        """One frame of the shine.

        Only the cells whose brightness CHANGED are rewritten: the comet
        window plus the two cells it has just left. Repainting the whole
        outline every frame is ~140 cells of escapes at 28fps, which is a
        waste of a pty; this is about a fifth of that."""
        if not self.path:
            return
        n = len(self.path)
        white = (255, 255, 255)
        idxs = range(n) if full else [
            (self.head - k) % n for k in range(-2, TRAIL + 1)
        ]
        out = [f"{ESC}[s", f"{ESC}[?25l"]
        for i in idxs:
            row, col, ch = self.path[i]
            d = (self.head - i) % n
            if d < TRAIL:
                # Squared falloff: a tight bright head and a long soft tail,
                # which reads as a glint rather than a moving blob.
                t = (1.0 - d / TRAIL) ** 2
                colour = lerp(self.accent, white, min(1.0, t * 1.15))
                bold = f"{ESC}[1m" if t > 0.72 else ""
            else:
                colour, bold = self.accent, ""
            out.append(f"{ESC}[{row};{col}H{bold}{rgb(colour)}{ch}{RESET}")
        out += [f"{ESC}[?25h", f"{ESC}[u"]
        self.w("".join(out))

    def tick(self):
        if not self.path:
            return
        self.head = (self.head + 1) % len(self.path)
        self.paint_border()

    def highlight(self, idx):
        """Light the hovered readout, exactly as the engine's own hover does."""
        parts = []
        for sid, x, w, i in self.layout:
            label = SEGMENTS[i][1]
            accent = SEGMENTS[i][2]
            style = f"{LIT}{ESC}[1m" if i == idx else ""
            parts.append(f"{ESC}[{self.band_row};{x}H{style}{rgb(accent)}"
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
        scr.w(f"{ESC}[?1003h{ESC}[?1006h")
        scr.draw_base()
        buf = ""
        while True:
            # Wait for input OR the next animation frame, whichever comes
            # first. A blocking read would freeze the shine between pointer
            # movements, which is when it most needs to be running.
            ready, _, _ = select.select([fd], [], [], FRAME)
            if not ready:
                scr.tick()
                continue
            ch = os.read(fd, 4096).decode("utf-8", "replace")
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

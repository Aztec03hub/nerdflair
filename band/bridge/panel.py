"""panel.py - the floating panel and its two glints.

Extracted from hoverdemo.py so the demo and the pty wrapper paint the same
thing. Everything terminal-specific is behind one `write` callable, because
the demo writes to /dev/tty while the wrapper writes into the stream it is
already relaying to the real terminal.
"""

ESC = "\033"
RESET = f"{ESC}[0m"

# The shine. A bright head with a tail fading back to the accent. TRAIL is in
# cells; FPS is what the terminal carries comfortably over a pty without the
# paint becoming the bottleneck.
TRAIL = 14
FPS = 28
# Frames the panel rests, lit but still, between sweeps.
REST = 26
FRAME = 1.0 / FPS


def rgb(c):
    return f"{ESC}[38;2;{c[0]};{c[1]};{c[2]}m"


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


class Panel:
    """One floating panel at a time, painted as absolute-positioned escapes.

    The panel is not in anyone's layout: it is written at explicit cursor
    positions with the cursor saved and restored around every batch, so the
    program underneath never learns it happened and never reflows.
    """

    def __init__(self, write, rows, cols, backdrop=None):
        self.write = write
        # What the program underneath had drawn where the panel goes, so it
        # can be put back. Taking the panel down without this leaves a hole:
        # we relay that program's output but never model it, so we cannot
        # reconstruct those cells, and asking it to repaint does not work.
        # Needed on EVERY erase, not just the final hide: switching from one
        # readout to another abandons the first panel's rect too, which is
        # the bug where whichever readout you were not hovering sat there as
        # a black rectangle.
        self.backdrop = backdrop
        self.rows = rows
        self.cols = cols
        # Whether the engine currently shows its cursor. Our paints hide it
        # while drawing and must hand it back as they found it, not force it on.
        self.cursor_visible = True
        self.rect = None          # (x, y, w, h), so we can erase exactly
        self.paths = []           # two runs of border cells: (row, col, char)
        self.accent = (255, 255, 255)
        self.head = 0
        self.shown = None         # id of what is on screen
        self.body = []            # kept so the panel can be repainted whole
        self.title = ""

    def _build_paths(self, x, y, w, h, title):
        """TWO runs, both starting at the top-left corner and ending at the
        bottom-right, so the glints diverge and meet.

          A: along the top edge, then down the right edge.
          B: down the left edge, then along the bottom edge.

        Each is a LINE, not a loop: the head runs off the end at the far
        corner and the panel settles until the next pass. A single circling
        highlight reads as a marquee; two meeting at a corner reads as light
        catching an edge.

        The title sits IN the top rule, so its characters are part of run A
        and the glint passes over the lettering instead of stopping dead at
        it."""
        top = "╭─ " + title + " " + "─" * max(0, w - len(title) - 5) + "╮"
        bottom = "╰" + "─" * (w - 2) + "╯"

        a = [(y, x + i, ch) for i, ch in enumerate(top)]
        a += [(y + r, x + w - 1, "│") for r in range(1, h - 1)]
        a.append((y + h - 1, x + w - 1, "╯"))

        b = [(y, x, "╭")]
        b += [(y + r, x, "│") for r in range(1, h - 1)]
        b += [(y + h - 1, x + i, ch) for i, ch in enumerate(bottom)]
        return [a, b]

    def _show_cursor(self):
        return f"{ESC}[?25h" if self.cursor_visible else ""

    def show(self, sid, title, body, accent, anchor_col, anchor_row):
        """Place a panel just above `anchor_row`, left-aligned near
        `anchor_col` but kept on screen."""
        if self.shown == sid and self.rect:
            return                        # already up, let it shine
        w = min(self.cols - 4,
                max(len(title) + 6, max(len(b) for b in body) + 4))
        w = max(w, 12)
        # Clipped to the card, not left to run over its right edge: on a
        # terminal narrower than the text the border would otherwise break.
        title = title[:max(1, w - 6)]
        body = [b[:w - 4] for b in body]
        h = len(body) + 2
        x = max(1, min(anchor_col - 2, self.cols - w - 1))
        y = anchor_row - h
        if y < 1:
            y = anchor_row + 1
        # Never off the bottom: the restore would then write past the last
        # row and scroll the screen.
        if y + h - 1 > self.rows:
            y = max(1, self.rows - h + 1)

        if self.rect:
            self.erase()
        if self.backdrop:
            self.backdrop.save(y, h)      # AFTER the old panel is gone

        self.accent = accent
        self.body = list(body)
        self.title = title
        self.paths = self._build_paths(x, y, w, h, title)
        self.head = 0
        self.rect = (x, y, w, h)
        self.shown = sid
        self.redraw()

    def redraw(self):
        """The whole panel, interior and border, in ONE write.

        Atomicity is the point, not tidiness. This runs when something else
        has just painted over the region, and on the busy part of the screen
        that happens many times a second. Emitting the interior and the
        border as separate writes lets the terminal render the moment between
        them, which is a panel with its middle restored and its edges still
        missing: the flicker is that intermediate state being drawn, not the
        repaint being slow.
        """
        if not self.rect:
            return
        x, y, w, _h = self.rect
        acc = rgb(self.accent)
        out = [f"{ESC}[s", f"{ESC}[?25l"]
        for i, line in enumerate(self.body):
            out.append(f"{ESC}[{y+1+i};{x}H{acc}│{RESET} "
                       f"{line:<{w-4}} {acc}│{RESET}")
        out.append(self._border(full=True))
        out += [self._show_cursor(), f"{ESC}[u"]
        self.write("".join(out))

    def reset(self):
        """Forget the panel WITHOUT painting. For a resize: the rows we saved
        and the rect belong to the old geometry, and writing them into the new
        one would paint stale cells over what the engine is about to redraw."""
        self.rect = None
        self.paths = []
        self.shown = None
        self.body = []
        if self.backdrop:
            self.backdrop.rows = None

    def erase(self):
        """Put back what the panel covered, in one write."""
        if not self.rect:
            return
        x, y, w, h = self.rect
        under = self.backdrop.restore() if self.backdrop else None
        if under is None:
            # No snapshot: blanking is all that is left. This leaves a hole
            # until the program underneath repaints, so it is the fallback,
            # not the design.
            under = "".join(f"{ESC}[{r};{x}H{' ' * w}"
                            for r in range(y, y + h))
        self.write(f"{ESC}[s{ESC}[?25l" + under + self._show_cursor() + f"{ESC}[u")
        self.rect = None
        self.paths = []
        self.shown = None
        self.body = []

    def paint(self, full=False):
        """One frame of the two shines, written on its own."""
        if not self.paths:
            return
        self.write(f"{ESC}[s{ESC}[?25l" + self._border(full)
                   + self._show_cursor() + f"{ESC}[u")

    def _border(self, full=False):
        """The border cells as escapes, for the caller to write.

        Only the cells whose brightness CHANGED are emitted: each comet
        window plus the two cells it has just left. Repainting both outlines
        every frame is ~140 cells of escapes at 28fps, which is a waste of a
        pty for about a fifth of the benefit."""
        if not self.paths:
            return ""
        white = (255, 255, 255)
        out = []
        for path in self.paths:
            n = len(path)
            if full:
                idxs = range(n)
            else:
                # Clamped, not wrapped: these runs are lines, so there is no
                # cell "behind" the start and none past the end.
                idxs = range(max(0, self.head - TRAIL - 2),
                             min(n - 1, self.head) + 1)
            for i in idxs:
                row, col, ch = path[i]
                d = self.head - i
                if 0 <= d < TRAIL:
                    # Squared falloff: a tight bright head and a long soft
                    # tail, which reads as a glint rather than a moving blob.
                    t = (1.0 - d / TRAIL) ** 2
                    colour = lerp(self.accent, white, min(1.0, t * 1.15))
                    bold = f"{ESC}[1m" if t > 0.72 else ""
                else:
                    colour, bold = self.accent, ""
                out.append(f"{ESC}[{row};{col}H{bold}{rgb(colour)}{ch}{RESET}")
        return "".join(out)

    def advance(self):
        """Move both heads on by one frame, without painting.

        Separate from painting because the caller sometimes has to repaint
        the whole panel for an unrelated reason (something drew over it), and
        the shine must keep running in that case rather than freezing for as
        long as the interference lasts.

        They start at the same corner, so one counter drives both; the
        shorter run simply finishes first. Returns True when the sweep has
        just restarted, which needs a full repaint to clear the old trail.
        """
        if not self.paths:
            return False
        longest = max(len(p) for p in self.paths)
        # Run until the tail of the longest has cleared its last cell, hold
        # the panel quiet for REST frames, then sweep again.
        if self.head > longest + TRAIL + REST:
            self.head = 0
            return True
        self.head += 1
        return False

    def tick(self):
        """One frame: advance, then paint only what changed."""
        if not self.paths:
            return
        self.paint(full=self.advance())


def demo():
    """Self-check: the geometry, which is the only part that can be wrong
    without a terminal to look at."""
    seen = []
    p = Panel(seen.append, rows=50, cols=200)
    p.show("x", "Title", ["one", "two"], (1, 2, 3), anchor_col=10,
           anchor_row=40)
    assert p.rect
    x, y, w, h = p.rect
    assert h == 4, h                       # 2 body lines plus two rules
    assert y + h == 40, (y, h)             # sits immediately above the anchor
    a, b = p.paths
    assert a[0][:2] == (y, x), a[0]        # both runs start at the same corner
    assert b[0][:2] == (y, x), b[0]
    assert a[-1][:2] == (y + h - 1, x + w - 1), a[-1]   # and end at the far one
    assert b[-1][:2] == (y + h - 1, x + w - 1), b[-1]
    assert len(set(a)) == len(a)           # no cell painted twice in a run
    # The shine advances on its own and restarts exactly once per cycle,
    # which is what keeps it running while something else repaints the panel.
    restarts = sum(p.advance() for _ in range(len(a) + TRAIL + REST + 2))
    assert restarts == 1, restarts
    assert p.head == 0, p.head

    # Switching from one readout to another must ask for a repaint of the
    # rect it abandons. Without this the old panel's area stays blank: the
    # bug where whichever readout you were NOT hovering sat there as a black
    # hole. Asserted on the SWITCH, not only on the hide, because the hide
    # path always had it and the switch path is what was missing.
    class FakeBackdrop:
        def __init__(self):
            self.saves, self.restores = [], 0

        def save(self, y, h):
            self.saves.append((y, h))

        def restore(self):
            self.restores += 1
            return f"{ESC}[1;1Hunder"

    bd = FakeBackdrop()
    out = []
    q = Panel(out.append, rows=50, cols=200, backdrop=bd)
    q.show("a", "A", ["one"], (1, 2, 3), 10, 40)
    assert bd.saves == [(37, 3)] and bd.restores == 0, (bd.saves, bd.restores)
    q.show("b", "B", ["two"], (4, 5, 6), 120, 40)
    assert bd.restores == 1, bd.restores        # the first rect was restored
    assert len(bd.saves) == 2, bd.saves         # and the second one saved
    assert bd.saves[1][0] == 37                 # saved AFTER the old is gone
    q.erase()
    assert bd.restores == 2, bd.restores
    q.erase()                               # nothing up: nothing to restore
    assert bd.restores == 2, bd.restores
    assert "under" in out[-1]               # the restore really went out

    # With no backdrop the erase must still clear its own rect rather than
    # leaving the panel on screen.
    out2 = []
    n = Panel(out2.append, rows=50, cols=200)
    n.show("a", "A", ["one"], (1, 2, 3), 10, 40)
    n.erase()
    assert "     " in out2[-1], out2[-1]

    # A repaint is ONE write, so the terminal can never render a panel with
    # its interior back and its border still missing.
    writes = []
    r = Panel(writes.append, rows=50, cols=200)
    r.show("c", "C", ["body"], (7, 8, 9), 10, 40)
    assert len(writes) == 1, len(writes)

    # A card wider than the terminal is clipped to it, and one anchored on the
    # last rows stays on screen.
    nb = []
    t = Panel(nb.append, rows=20, cols=30)
    t.show("n", "A very long title indeed", ["x" * 80], (1, 2, 3), 29, 20)
    tx, ty, tw, th = t.rect
    assert tx + tw - 1 <= 30 and ty >= 1 and ty + th - 1 <= 20, t.rect
    assert all(len(line) <= tw - 4 for line in t.body), t.body
    assert len(t.title) <= tw - 6, t.title
    # Reset forgets without painting, and a later show starts clean.
    before = len(nb)
    t.reset()
    assert t.rect is None and len(nb) == before, "reset must not write"

    p.erase()
    assert p.rect is None and p.shown is None
    print("panel ok")


if __name__ == "__main__":
    demo()

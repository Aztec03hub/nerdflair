#!/usr/bin/env python3
"""nfpty.py - run Claude Code behind a pty we own, and float hover panels.

WHY THIS AND NOT AN INJECTOR
----------------------------
Three earlier routes to the hover event are all closed, and each was closed by
a measurement rather than a guess:

  * The engine clamps absolutely-positioned boxes to the live frame and lets
    later siblings overdraw them, so an in-engine floating card cannot exist.
  * LD_PRELOAD cannot see the engine's I/O: Bun issues write syscalls itself
    rather than through libc. A positive control proved the counter sound
    before its zero was believed.
  * The inspector attaches and `Runtime.evaluate` works, but the engine does
    not read the terminal through `process.stdin`: with a call counter armed
    on `.read()`, a burst of injected motion produced reads=0, isRaw
    undefined, and zero `readable` listeners.

What is left is the one place every byte must pass: the pty itself. We hold
the master, Claude Code gets the slave, and nothing is patched, injected or
read off the screen. A Claude Code update cannot break this, because it
touches nothing inside Claude Code.

           terminal ──keys──> nfpty ──keys──> claude (pty slave)
           terminal <─cells── nfpty <─cells── claude

HOW THE HOVER IS OBTAINED
-------------------------
A hover is motion with no button held, which a terminal only reports in mouse
mode 1003 ("any event"). Claude Code asks for 1000, 1002, 1003 and 1006
itself (measured), so the terminal already reports plain motion and nothing in
the output stream is rewritten. The motion-only reports are READ in passing
and forwarded unchanged, so the engine keeps its own hover behaviour.

WHAT IS UNDER A CARD
--------------------
A card is painted over the real screen, so the real screen cannot say what is
beneath it. Every byte the engine writes is therefore also fed to a private
tmux pane (shadow.py), which parses it into the engine's own screen, with no
card on it. The rows a card covers are saved from there and read again when
the card goes away, and the status-line layout is scanned from there.
"""
import array
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import tty

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mklayout  # noqa: E402
from panel import FRAME, Panel  # noqa: E402
from shadow import Shadow  # noqa: E402
import nflog  # noqa: E402
from nflog import note_once, note_rate  # noqa: E402

ESC = "\033"

# SGR mouse reports (mode 1006): ESC [ < btn ; col ; row (M|m).
MOUSE = re.compile(rb"\033\[<(\d+);(\d+);(\d+)([Mm])")
# Motion is bit 5 (32); the low two bits are the button, 3 meaning "none".
# 35 = 32|3 is therefore motion with nothing held, which is a hover.
HOVER_BTN = 35
# Bytes the terminal itself sends that are not the user typing: focus in/out,
# bracketed-paste markers are NOT here (a paste is typing), device replies.
TERMINAL_NOISE = re.compile(
    rb"\033\[I"                                   # focus in (focus OUT is handled separately: it hides)
    rb"|\033\[[?>][0-9;]*c|\033\[[0-9;]*c"          # device attributes replies
    rb"|\033\[\??[0-9]+;[0-9]+R"                    # cursor position report. Shift-F3 (ESC[1;2R) is byte-identical to a valid one and is taken as noise: unavoidable, rare
    rb"|\033\[\?[0-9;]*\$y|\033\[\?[0-9]+u"        # mode report, kitty keyboard query reply
    rb"|\033\][^\a\033]*(?:\a|\033\\)"            # OSC replies (colours)
    rb"|\033P[^\033]*\033\\"                        # DCS replies (XTVERSION)
    rb"|\033\[8;[0-9]+;[0-9]+t"                      # window size report
)
FOCUS_OUT = b"\033[O"

# MEASURED: Claude Code sets 1000h, 1002h, 1003h and 1006h itself, so the
# terminal already reports plain motion and nothing in the output stream needs
# rewriting. The modes are logged rather than changed, because if that ever
# stops being true a silent hover would otherwise be unexplainable.

# How long the pointer must stay off a readout before the panel comes down.
# Long enough to cross the gap between two readouts without the panel
# blinking, short enough that leaving the band feels immediate.
HIDE_AFTER = 0.25
# With no pointer report this long, a card is taken down (the pointer left the
# window: terminals send nothing then). A pointer resting on the card still
# sends nothing, so this is also how long a card stays while you read it, and
# after WATCHDOG_ON_CARD with the pointer still resting the card goes and only
# a pointer move brings it back (a still pointer cannot be told from a gone one).
WATCHDOG = 4.0
# Longer when the last report was ON the card: the pointer is probably resting
# there while it is read. Leaving the window from the card is rarer (the card
# sits above the status line, away from the window edge).
WATCHDOG_ON_CARD = 20.0
# Except where the pointer is likely to LEAVE the window: on the edge rows and
# columns the long grace does not apply (leaving downwards off the status line
# is the common exit).
EDGE = 1


def winsize(fd):
    try:
        b = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
        rows, cols = struct.unpack("HHHH", b)[:2]
    except (OSError, ValueError) as e:      # ValueError: an fd that is already closed
        note_once("winsize", f"TIOCGWINSZ failed on fd {fd} ({e}): assuming a 50x200 terminal")
        rows, cols = 50, 200
    if not rows or not cols:
        note_once("winsize-zero", f"the terminal reports {rows}x{cols}: assuming 50 rows / 200 columns where it says 0")
    return (rows or 50), (cols or 200)


def set_winsize(fd, rows, cols):
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ,
                    array.array("h", [rows, cols, 0, 0]))
    except (OSError, ValueError) as e:
        note_once("set-winsize", f"TIOCSWINSZ failed on fd {fd} ({e}): the pty size was not applied")


class Backdrop:
    """The rows a panel is about to cover, kept so they can be put back.

    WHY NOT ASK THE ENGINE. A SIGWINCH carrying no size change is a no-op for
    it, so the nudge that looks like a redraw request does nothing and the
    abandoned rect stays blank. WHY NOT MODEL IT OURSELVES: that is a
    terminal emulator, and we would be writing one to recover information
    tmux has already parsed.

    This is not screen-scraping for events. It runs twice per panel, on show
    and on hide, never per pointer movement, and what it reads is only ever
    written straight back.

    Whole lines are captured rather than the panel's columns, because cutting
    a column range out of a line full of escape sequences means parsing them,
    and putting a whole line back is exact by construction.
    """

    def __init__(self, pane, shadow=None):
        self.pane = pane
        self.shadow = shadow
        self.rows = None
        self.top = 0
        self.span = None
        self.note = None        # optional debug sink: note(str)
        self.settled = lambda: True   # False while our own writes are still queued

    def save(self, y, h):
        self.rows = None
        self.deferred = False
        if not self.pane:
            return
        self.span = (y, h)
        # capture-pane numbers the visible pane from 0, screen rows from 1.
        span = ["-e", "-S", str(y - 1), "-E", str(y + h - 2)]
        # The engine's own screen first: it has none of our cards on it, so
        # what is saved is what the engine last drew, and restoring it later
        # shows the CURRENT status line, not the one from when the card opened.
        r = self.shadow.capture(*span) if self.shadow is not None else None
        if r is None and self.shadow is not None and self.shadow.ok:
            note_rate("backdrop-live-fallback", "backdrop: the shadow screen could not answer, reading the live pane "
                                                "(a card may restore leftovers of an earlier card)")
        if r is None:
            if not self.settled():
                # The live pane may still show a card whose erase is queued, and
                # saving it would restore that card as "the screen" later. Say so
                # to the caller, which declines to open until the queue drains.
                self.deferred = True
                return
            try:
                r = subprocess.run(
                    ["tmux", "capture-pane", "-p", *span, "-t", self.pane],
                    capture_output=True, encoding="utf-8", errors="replace", timeout=0.5)
            except (OSError, subprocess.SubprocessError) as e:
                note_rate("backdrop-save-tmux", f"backdrop: tmux capture-pane failed ({type(e).__name__}: {e}); "
                                                "the card will blank its area when it closes")
                return
        if r.returncode != 0:
            note_rate("backdrop-save-rc", f"backdrop: tmux capture-pane exit {r.returncode}: "
                                          f"{r.stderr.strip() or 'no output'}; the card will blank its area when it closes")
        if r.returncode == 0:
            self.rows = r.stdout.split("\n")[:h]
            self.top = y

    def restore(self):
        """The escapes that put those rows back, or None if we have none."""
        if not self.rows:
            return None
        # Read the rows again NOW from the engine's own screen: anything the
        # engine drew under the card while it was up is in there, and the rows
        # saved at open are not. The saved ones remain the fallback.
        if self.shadow is not None and self.span:
            y, h = self.span
            r = self.shadow.capture("-e", "-S", str(y - 1), "-E", str(y + h - 2))
            if self.note:
                self.note(f"restore shadow={'none' if r is None else 'ok'} ok={self.shadow.ok} "
                          f"clean={self.shadow.clean} rows={None if r is None else len(r.stdout.split(chr(10))[:h])}")
            if r is not None:
                self.rows = r.stdout.split("\n")[:h]
            else:
                note_rate("restore-stale", "backdrop: the shadow screen could not answer at erase time; restored the rows "
                                           "saved when the card opened (the status line may show an old value until it repaints)")
        out = []
        for i, line in enumerate(self.rows):
            # Clear to end of line first: the captured text stops at the last
            # non-blank cell, so without this the tail of the panel survives.
            out.append(f"{ESC}[{self.top + i};1H{ESC}[2K{line}{ESC}[0m")
        self.rows = None
        return "".join(out)


class Layout:
    """Where each readout sits, recomputed as it moves.

    Not published once and cached: the columns shift whenever a figure
    changes width, so a token count gaining a digit moves everything after
    it, and a layout fixed at startup would open the wrong card within
    seconds.

    It is rebuilt only while hover is actually happening, so an idle session
    spends nothing, and at most every MIN_INTERVAL. It IS rebuilt while a
    panel is up: the status line keeps changing under a panel, and a layout
    frozen at the moment the panel opened sent the pointer to the wrong
    readout the moment the figures shifted. The rows the panel covers show the
    panel rather than the status line, so those rows alone are skipped and
    keep what was known about them.
    """

    MIN_INTERVAL = 0.15

    def __init__(self, pane, shadow=None):
        self.pane = pane
        self.shadow = shadow
        self.at = 0.0
        self.backoff_until = 0.0     # tmux answered slowly: no reads until then
        self.segs = []

    @property
    def paused(self):
        """True while reads are suspended after a slow tmux answer: the layout
        is then too old to OPEN a card from."""
        return time.monotonic() < self.backoff_until

    def refresh(self, covered=(), force=False):
        """`force` skips the rate limit (never the slow-read backoff): used
        before OPENING a card, so the readout under the pointer is judged on
        the screen as it is now, not as it was up to MIN_INTERVAL ago."""
        now = time.monotonic()
        if not self.pane or now < self.backoff_until or (not force and now - self.at < self.MIN_INTERVAL):
            return
        self.at = now
        fresh, truth = mklayout.build_ex(self.pane, skip=covered, shadow=self.shadow)
        # tmux is read on the relay loop, so a slow answer is typing lag. If
        # it took long, stop asking for a while rather than stall again. This
        # comes BEFORE the unreadable check: a hung tmux times out (0.5 s) and
        # returns None, and must engage the backoff or every hover blocks the
        # relay for 0.5 s.
        if time.monotonic() - now > 0.3:
            self.backoff_until = time.monotonic() + 5.0
            note_rate("layout-slow", f"layout: the screen read took {time.monotonic() - now:.2f}s on the relay loop; "
                                     "hover is paused for 5 s")
        if fresh is None:
            return              # unreadable, not empty: keep what we knew (already logged by mklayout)
        # An EMPTY read is an answer, not a failure to keep the old layout
        # through: it means something (a permission prompt, a dialog) is
        # drawn over the status line. Keeping the last good layout there made
        # invisible regions open cards over the dialog. Only the rows a panel
        # of ours is covering are carried over, since they show the panel.
        # Read from the engine's own screen nothing is covered, so nothing is
        # carried; read from the live pane the covered rows show the card.
        keep = () if truth else covered
        self.segs = [s for s in self.segs if s["row"] in keep] + fresh

    def hit(self, col, row):
        """The readout under the pointer, if the pointer is on one.

        Each readout carries its own row: the status line is more than one
        line, and a single band row would have left everything on the other
        lines unhoverable.
        """
        for s in self.segs:
            if s["row"] == row and s["x"] <= col < s["x"] + s["w"]:
                return s
        return None


RESET = f"{ESC}[0m"
# The band plugin's hover look (register.tsx: bold on LIT #1f2937): the same on the main status line.
HL = f"{ESC}[1m{ESC}[48;2;31;41;55m"
_TOK = re.compile(r"(\x1b\[[0-9;:]*m)|(\x1b\[[0-9;:?]*[@-~])|(.)", re.S)


def cut(line, x, w, hl=""):
    """Escapes that paint the cells [x, x+w) (1-based) of one `capture-pane -e`
    line, keeping each cell's own colours and adding `hl` on top. Only the SGR
    state is tracked, so the cells are repainted exactly as the engine had them
    (hl="" restores). Cells past the end of a trimmed line are painted blank.
    A double-width character that touches either edge is included whole, so
    nothing is ever half-painted (the range then grows by up to a cell a side)."""
    state, col, start, out = "", 1, x, []
    for m in _TOK.finditer(line):
        if col >= x + w:
            break
        sgr, other, ch = m.groups()
        if sgr:
            state = "" if sgr in (f"{ESC}[m", RESET) else state + sgr
            if out:
                out.append(sgr + hl)
        elif ch is not None:
            cw = mklayout.cells(ch)
            if col + cw > x:
                if not out:
                    start = col
                    out.append(RESET + state + hl)
                out.append(ch)
            col += cw
    if not out:
        out.append(RESET + state + hl)
        col = x
    out.append(" " * max(0, x + w - col))
    # ESC[s / ESC[u (in _paint) save the attributes as well as the cursor in tmux, where this
    # runs; the RESET here relies on that, as Panel's paints do.
    return f"{ESC}[{{row}};{start}H" + "".join(out) + RESET


class Highlight:
    """The readout under an open card, painted like the band's own hover.

    Painted from outside the engine (tty writes), with the cells read from the
    shadow screen, which has the engine's true content and attributes and none
    of our paint. It follows `sync(key)` where key is (row, x, w) of the readout
    whose card is up, or None: one readout at a time, and None (or any other
    key) puts the cells back from a fresh read, falling back to the copy taken
    when the highlight went on so it can never be left stuck.

    Whether the key is still RIGHT (the readout may have moved, or a dialog
    covered the line) is the caller's job: it re-reads the layout and passes the
    answer in. This class only paints what it is told.
    """

    REFRESH = 0.1
    BACKOFF = 1.0

    def __init__(self, write, shadow, cursor=lambda: ""):
        self.write, self.shadow, self.cursor = write, shadow, cursor
        self.cur = None
        self.plain = ""
        self.last = 0.0
        self.retry_at = 0.0     # after a failed on(): no new attempt before this

    def _cells(self, key):
        row, x, w = key
        r = self.shadow.capture("-e", "-S", str(row - 1), "-E", str(row - 1)) if self.shadow is not None else None
        if r is None:
            return None
        line = r.stdout.split("\n")[0]
        return (cut(line, x, w, HL).replace("{row}", str(row), 1), cut(line, x, w).replace("{row}", str(row), 1))

    def _paint(self, s, keep=False):
        self.write(f"{ESC}[s{ESC}[?25l{s}{self.cursor()}{ESC}[u", keep=keep)

    def on(self, key):
        now = time.monotonic()
        if now < self.retry_at:
            return
        got = self._cells(key)
        if got is None:
            self.retry_at = now + self.BACKOFF
            # NFPTY_SHADOW=0 / a failed start is a choice already announced at startup.
            if self.shadow is not None:
                note_rate("highlight-degrade", "highlight: the shadow screen could not answer, so the readout is not "
                                               "highlighted (its card still works)")
            return
        self.cur, self.plain, self.last = key, got[1], now
        self._paint(got[0])

    def off(self):
        if self.cur is None:
            return
        got = self._cells(self.cur)
        if got is None:
            note_rate("highlight-restore", "highlight: the shadow screen could not answer at restore time; put back the "
                                           "cells saved when the highlight went on (the readout may show an old value until it repaints)")
            plain = self.plain
        else:
            plain = got[1]
        self.cur = None
        self._paint(plain, keep=True)

    def sync(self, key):
        if key == self.cur:
            return
        self.off()
        if key is not None:
            self.on(key)

    def refresh(self):
        """The engine repainted: put the highlight back over what it drew.
        ponytail: any engine output while a card is up costs a tmux read per REFRESH, and the
        highlight is off between the engine's write and that repaint (up to REFRESH, a blink).
        Both are bounded to card-open time; filter on the chunk touching the row if it shows."""
        now = time.monotonic()
        if self.cur is None or now - self.last < self.REFRESH:
            return
        got = self._cells(self.cur)
        self.last = now
        if got is None:
            note_rate("highlight-refresh", "highlight: the shadow screen could not answer, so the highlight was not "
                                           "repainted after the engine drew (it may be missing until the next read)")
            return
        self.plain = got[1]
        self._paint(got[0])

    def forget(self):
        """Geometry changed: the engine repaints everything, so write nothing."""
        self.cur = None


CURSOR = re.compile(rb"\033\[\?25([hl])")
MODE = re.compile(rb"\033\[\?(1000|1002|1003|1006|1015)([hl])")


def note_modes(chunk, log=None):
    if log is not None:
        # Which mouse modes the engine asks for is a fact about the engine,
        # not a guess we should make: without it there is no telling whether
        # a silent hover means "no motion reported" or "motion not matched".
        for m in MODE.finditer(chunk):
            log.write(f"mode {m.group(1).decode()}{m.group(2).decode()}\n")
        log.flush()


def split_hovers(buf):
    """Note the motion-only reports in an input chunk, forwarding everything.

    Returns (forward, hovers, tail). The engine asks the terminal for mode
    1003 itself, so it already receives motion and uses it for its own hover
    highlighting; swallowing those reports would take that away to add ours.
    We only READ them in passing.

    `tail` is a possibly-partial escape sequence at the end, held back so a
    report split across two reads is not mangled: forwarding half of one
    would corrupt the engine's input.
    """
    forward = bytearray()
    hovers = []
    i = 0
    while True:
        m = MOUSE.search(buf, i)
        if not m:
            break
        forward += buf[i:m.start()]
        forward += m.group(0)
        if int(m.group(1)) == HOVER_BTN:
            hovers.append((int(m.group(2)), int(m.group(3))))
        i = m.end()
    rest = buf[i:]
    # A trailing fragment is only held if it could still become a mouse
    # report. Anything else (a keystroke, a paste) goes through at once.
    cut = rest.rfind(ESC.encode() + b"[<")
    # A real report is under 24 bytes. A longer "fragment" is not one, and
    # holding it would swallow the user's typing (the engine may not have a
    # mouse mode on at all).
    if cut >= 0 and len(rest) - cut < 24 and not MOUSE.match(rest, cut):
        return bytes(forward + rest[:cut]), hovers, rest[cut:]
    return bytes(forward + rest), hovers, b""


def incomplete_tail(data):
    """How many bytes at the end of `data` are unfinished: the larger of an
    unfinished UTF-8 character and an unfinished escape sequence. They are
    computed independently because a partial character can sit inside an
    unfinished sequence (a window title with a glyph in it)."""
    return max(_utf8_tail(data), _escape_tail(data))


def _utf8_tail(data):
    """How many bytes at the end of `data` are an unfinished escape sequence
    or UTF-8 character; 0 if it ends on a boundary."""
    # UTF-8: a lead byte whose continuation bytes have not all arrived.
    for k in (1, 2, 3):
        if len(data) < k:
            break
        c = data[-k]
        if 0x80 <= c < 0xC0:
            continue
        if c >= 0xC0:
            need = 2 if c < 0xE0 else 3 if c < 0xF0 else 4
            if k < need:
                return k
        break
    return 0


def _escape_tail(data):
    i = data.rfind(b"\x1b")
    if i < 0:
        return 0
    rest = data[i + 1:]
    if not rest:
        return 1                                       # a bare ESC
    c = rest[0]
    if c == 0x5b:                                      # CSI: ends on 0x40-0x7e
        done = any(0x40 <= b <= 0x7e for b in rest[1:])
    elif c in b"]P_^X":                                # OSC, DCS, APC, PM, SOS
        done = b"\x07" in rest or b"\x1b\\" in rest
    elif 0x20 <= c <= 0x2f:                            # ESC ( B and friends
        done = len(rest) >= 2
    elif c == 0x4f:                                    # SS3
        done = len(rest) >= 2
    else:
        done = True
    return 0 if done else len(data) - i


def trim_pending(pending, limit=64):
    """Cut a backed-up write queue to `limit`, in place and in order: the
    oldest droppable frames go first, writes marked keep (the erases) never
    do, and what remains still runs in the sequence it was queued."""
    i = 0
    while len(pending) > limit and i < len(pending):
        if pending[i][1]:
            i += 1
        else:
            del pending[i]


class Stream:
    """Tracks whether the engine's output is on a sequence boundary, across
    chunks: a sequence split over three reads is still unfinished after the
    second."""

    def __init__(self):
        self.carry = b""
        self.cursor = None      # last ESC[?25h/l seen: True shown, None unknown

    def feed(self, data):
        """Returns True if it is safe to write something of our own now."""
        buf = self.carry + data
        # Scanned over carry+data: a show/hide split across two reads is
        # whole here, and the carry (an unfinished tail) cannot already hold
        # a complete match, so nothing is counted twice.
        m = CURSOR.findall(buf)
        if m:
            self.cursor = m[-1] == b"h"
        n = incomplete_tail(buf)
        # A tail this long is not a sequence; do not hold the panel hostage.
        # A sequence longer than 4096 bytes is not one a terminal emits in
        # practice; past that we call the stream clean rather than hold every
        # paint behind an escape that may never end.
        if n > 4096:
            note_once("seq-cap", "the engine's output held an unfinished escape sequence over 4096 bytes: "
                                 "treated as clean so our paints are not held back (they may land inside it)")
        self.carry = buf[-n:] if 0 < n <= 4096 else b""
        return n == 0 or n > 4096


IDLE = 0.25     # wake rate with nothing to animate; still bounds reaping and the tail timeout


def select_timeout(active, hide_at, tail, pending, quitting):
    """FRAME while anything is animating or waiting on a clock, IDLE otherwise:
    an idle session used to wake 28 times a second for nothing."""
    return FRAME if (active or hide_at is not None or tail or pending or quitting) else IDLE


def write_all(fd, data):
    """os.write returns a short count when a signal lands mid-write of a large
    paste; the rest must still go. (A child that stops reading its input while
    we block here is not something a TUI does; it reads stdin continuously.)"""
    while data:
        data = data[os.write(fd, data):]


def ends_clean(data):
    return incomplete_tail(data) == 0


def selfcheck():
    """The two stream transforms, which are the only logic that can be wrong
    without a terminal to look at. Both are falsifiable in both directions:
    a hover must be taken AND a click must survive."""
    nflog.ERRLOG = os.devnull           # a selfcheck must not write the real log
    e = ESC.encode()
    # Motion is noted and still forwarded, so the engine's own hover keeps
    # working; a press is noted as no hover.
    both = e + b"[<35;12;49M" + e + b"[<0;12;49M"
    fwd, hov, tail = split_hovers(both)
    assert hov == [(12, 49)], hov
    assert fwd == both, fwd
    assert tail == b""
    # Keystrokes around a hover are preserved in order and byte for byte.
    keys = b"ab" + e + b"[<35;5;5M" + b"cd"
    fwd, hov, tail = split_hovers(keys)
    assert fwd == keys, fwd
    assert hov == [(5, 5)]
    # A report split across two reads is held, not mangled.
    fwd, hov, tail = split_hovers(e + b"[<35;12;4")
    assert fwd == b"" and hov == [] and tail == e + b"[<35;12;4", (fwd, tail)
    fwd, hov, _ = split_hovers(tail + b"9M")
    assert hov == [(12, 49)], hov
    # An escape that is not a mouse report is not held back.
    fwd, hov, tail = split_hovers(e + b"[A")
    assert fwd == e + b"[A" and tail == b"", (fwd, tail)
    # Output is relayed byte for byte, and the modes are only noted.
    import io
    log = io.StringIO()
    assert note_modes(e + b"[?1003h" + e + b"[?1006h", log) is None
    assert log.getvalue() == "mode 1003h\nmode 1006h\n", log.getvalue()
    # Painting waits for a clean boundary in the engine's stream.
    assert ends_clean(b"abc") and ends_clean(b"\x1b[0m") and ends_clean(b"\x1b[38;2;1;2;3mx")
    assert not ends_clean(b"abc\x1b") and not ends_clean(b"abc\x1b[38;2;1")
    assert not ends_clean("é".encode()[:1]) and ends_clean("é".encode())
    assert not ends_clean(b"\x1b]0;title") and ends_clean(b"\x1b]0;title\x07")
    assert not ends_clean(b"\x1b(") and ends_clean(b"\x1b(B") and not ends_clean(b"\x1bP1$r")
    # Overflow keeps erases and the ORDER of what remains: a redraw queued
    # before an erase must still run before it, or the card stays as a ghost.
    q = [("redraw", False)] + [("frame", False)] * 70 + [("erase", True), ("late", False)]
    trim_pending(q, limit=5)
    names = [w for w, _k in q]
    assert "erase" in names and names.index("erase") < names.index("late"), names
    assert len(q) == 5 and names.count("frame") == 3, names     # trimmed to the limit, oldest frames first
    # A sequence split over THREE reads is unfinished until the last one.
    st = Stream()
    assert st.feed(b"x\x1b[38;2") is False
    assert st.feed(b";1;2") is False, "the middle chunk has no ESC and is still inside the sequence"
    assert st.feed(b"mok") is True
    assert Stream().feed(b"plain") is True
    # A glyph inside an OSC title, split mid-character, is still inside the OSC.
    st = Stream()
    assert st.feed(b"\x1b]0;" + "\U000f024b".encode()[:2]) is False
    assert st.feed("\U000f024b".encode()[2:] + b" title") is False, "still inside the OSC after the glyph completes"
    assert st.feed(b"\x07") is True
    # What is terminal noise (does not count as typing) and what is typing.
    for raw, noise in [(b"\x1b[I", 1), (b"\x1b[?62;4c", 1), (b"\x1b[12;40R", 1), (b"\x1b]11;rgb:1/2/3\x07", 1),
                       (b"\x1bP>|x\x1b\\", 1), (b"\x1b[?0u", 1), (b"\x1b[Z", 0), (b"c", 0), (b"\x1b[A", 0),
                       (b"\x1bi", 0), (b"x", 0), (b"\x1b[O", 0)]:
        assert (TERMINAL_NOISE.sub(b"", raw) == b"") == bool(noise), (raw, TERMINAL_NOISE.sub(b"", raw))
    # A card is judged on a FRESH layout: force skips the rate limit but never the
    # slow-read backoff (a stalled tmux must not be asked again at once).
    calls = []
    real_ex = mklayout.build_ex
    try:
        mklayout.build_ex = lambda _p, skip=(), shadow=None: (calls.append(1) or [], False)
        lay2 = Layout("%0")
        lay2.refresh()
        lay2.refresh()
        assert len(calls) == 1, "the rate limit holds without force"
        lay2.refresh(force=True)
        assert len(calls) == 2, "force bypasses the rate limit"
        lay2.backoff_until = time.monotonic() + 5
        lay2.refresh(force=True)
        assert len(calls) == 2 and lay2.paused, "force must not bypass the slow-read backoff"
    finally:
        mklayout.build_ex = real_ex
    # A card is not opened while a card's erase is still queued and the live pane
    # is the only source (it would save the old card as the "screen" to restore).
    queue = [("erase", True)]
    bd = Backdrop("%0", shadow=None)
    bd.settled = lambda: not queue
    wrote = []
    pn = Panel(lambda t, keep=False: wrote.append(t), 50, 200, backdrop=bd, keeps=True)
    pn.show("a", "T", ["body"], (1, 2, 3), 10, 20)
    assert pn.shown is None and pn.rect is None and not wrote and bd.deferred, "deferred while unsettled"
    queue.clear()
    real_run = subprocess.run
    try:
        subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a, 0, stdout="\n".join(["row"] * 5), stderr="")
        pn.show("a", "T", ["body"], (1, 2, 3), 10, 20)
    finally:
        subprocess.run = real_run
    assert pn.shown == "a" and pn.rect, "opens once the queue has drained"
    # L5: an idle session sleeps long; anything animating or on a clock does not.
    assert select_timeout(None, None, b"", [], None) == IDLE
    for args in ((True, None, b"", [], None), (None, 1.0, b"", [], None), (None, None, b"x", [], None),
                 (None, None, b"", [("w", False)], None), (None, None, b"", [], 15)):
        assert select_timeout(*args) == FRAME, args
    # L3: a short write is continued, not dropped.
    real_write, sent = os.write, []
    try:
        os.write = lambda fd, d: (sent.append(bytes(d[:3])), min(3, len(d)))[1]
        write_all(1, b"abcdefgh")
    finally:
        os.write = real_write
    assert b"".join(sent) == b"abcdefgh", sent
    # L9: a bug in hover code is absorbed ONCE, loudly, and disables hover; the
    # relay (the caller) keeps going. Control: without the guard it raises.
    saved_log, nflog.ERRLOG = nflog.ERRLOG, os.devnull
    try:
        hits, cleaned = [], []
        g = Guard(lambda: None, lambda: cleaned.append(1))
        g.run("boom", lambda: hits.append(1) or 1 / 0)
        g.run("again", lambda: hits.append(1))
        assert g.ok is False and hits == [1] and cleaned == [1], (g.ok, hits, cleaned)
        try:
            (lambda: 1 / 0)()
            raise AssertionError("control: the bug must raise unguarded")
        except ZeroDivisionError:
            pass
    finally:
        nflog.ERRLOG = saved_log
    # Cursor hide/show split across reads is still seen (the per-chunk scan
    # it replaced missed both halves), and the last one wins.
    st = Stream()
    st.feed(b"x\x1b[?2"); assert st.cursor is None
    st.feed(b"5l"); assert st.cursor is False, "hide split over two reads"
    st.feed(b"\x1b[?25"); st.feed(b"h"); assert st.cursor is True, "show split before the final byte"
    st.feed(b"\x1b[?25l\x1b[?25h"); assert st.cursor is True, "last in a chunk wins"
    assert not CURSOR.findall(b"x\x1b[?2") and not CURSOR.findall(b"5l"), "control: per-chunk scan misses it"
    # A "mouse report" fragment that is too long to be one is not held back.
    junk = b"\x1b[<" + b"1" * 40
    assert split_hovers(junk) == (junk, [], b""), "an overlong fragment must pass through"
    # The layout FOLLOWS the status line: a readout that moved is found at its
    # new column, and the rows a panel covers keep what was known about them.
    seg = lambda i, row, x: {"id": i, "row": row, "x": x, "w": 5}  # noqa: E731
    shots = [[seg("a", 3, 10), seg("b", 3, 30), seg("c", 4, 5)],
             [seg("a", 3, 10), seg("b", 3, 36)],        # b moved; row 4 covered
             ]
    real = mklayout.build_ex
    try:
        mklayout.build_ex = lambda _pane, skip=(), shadow=None: (shots.pop(0), shadow is not None)
        lay = Layout("%0")
        lay.MIN_INTERVAL = 0
        lay.refresh()
        assert lay.hit(31, 3)["id"] == "b"
        lay.refresh(covered={4})
        assert lay.hit(31, 3) is None and lay.hit(37, 3)["id"] == "b", \
            "a moved readout must be found at its new column, not the old"
        assert lay.hit(6, 4)["id"] == "c", "a covered row keeps its old readouts"
        # Something drawn over the whole status line: no region may survive.
        shots.append([])
        lay.refresh()
        assert lay.segs == [] and lay.hit(37, 3) is None, \
            "a covered status line must leave no hoverable regions"
    finally:
        mklayout.build_ex = real
    # The highlight: cut() keeps each cell's own colours, adds the look on top, and the
    # same cut without it restores exactly.
    line = f"ab{ESC}[38;5;9mXY{ESC}[0m cd{ESC}[1;32mEF"
    on, off = cut(line, 3, 2, HL), cut(line, 3, 2)
    assert on == f"{ESC}[{{row}};3H{RESET}{ESC}[38;5;9m{HL}XY{RESET}", repr(on)
    assert off == f"{ESC}[{{row}};3H{RESET}{ESC}[38;5;9mXY{RESET}", repr(off)
    assert HL not in off
    mid = cut(line, 4, 4, HL)       # an SGR inside the range gets the look re-applied after it
    assert mid.count(HL) == 2, mid
    assert f"{ESC}[1;32m{HL}EF" in cut(line, 8, 3, HL) or f"{ESC}[1;32m{HL}EF" in cut(line, 8, 2, HL), cut(line, 8, 2, HL)
    assert cut("ab", 5, 3, HL).endswith("   " + RESET), "cells past a trimmed line are painted blank"

    class FakeShadow:
        def __init__(self, text):
            self.text = text

        def capture(self, *a):
            return None if self.text is None else type("R", (), {"stdout": self.text})

    wr = []
    sh = FakeShadow(line)
    h = Highlight(lambda s, keep=False: wr.append((s, keep)), sh)
    h.sync((2, 3, 2))
    assert h.cur == (2, 3, 2) and HL in wr[-1][0] and "XY" in wr[-1][0], wr
    sh.text = None                    # the shadow dies while it is on: still taken down, from the saved copy
    h.sync(None)
    assert h.cur is None and HL not in wr[-1][0] and wr[-1][1] is True and "XY" in wr[-1][0], wr[-1]
    n = len(wr)
    h.sync((2, 3, 2))
    assert h.cur is None and len(wr) == n, "an unreadable shadow degrades: nothing painted, nothing stuck"
    h.sync((2, 3, 2))
    assert h.cur is None and len(wr) == n, "after a failed on(), no retry inside the backoff"
    sh.text = line
    h.retry_at = 0.0
    h.sync((2, 3, 2)); h.sync((2, 8, 3))        # A -> B: A is restored, then B painted
    assert h.cur == (2, 8, 3) and HL not in wr[-2][0] and HL in wr[-1][0], wr[-2:]
    h.forget()
    assert h.cur is None
    # Wide characters at the range edges are included whole, never half-painted.
    wide = f"a{ESC}[31m\u4e2d\u6587{ESC}[0mz"          # a, two 2-cell chars (cols 2-3, 4-5), z at 6
    assert cut(wide, 3, 2).startswith(f"{ESC}[{{row}};2H") and "\u4e2d\u6587" in cut(wide, 3, 2), \
        "a wide char spilling into the range at its left edge is included whole"
    assert "\u6587" in cut(wide, 2, 3) and cut(wide, 2, 3).count("\u4e2d") == 1 and "z" not in cut(wide, 2, 3), \
        "a wide char starting on the last cell is included whole"
    assert cut(wide, 6, 1).count("z") == 1 and "\u6587" not in cut(wide, 6, 1)
    assert cut("", 4, 2, HL).endswith("  " + RESET), "empty line: blank cells with the look"
    assert cut(line, 1, 1) .count("a") == 1, "range of one cell"
    print("nfpty ok")


def degrade(where, dbg=None):
    """A bug in hover or panel code must not end the user's claude session.
    This is the one place an exception is absorbed, and it is loud: the
    traceback goes to a log that is never rotated away silently and to NFPTY_LOG,
    and the caller turns hover OFF for the rest of the session so the bug cannot
    repeat 28 times a second. Relaying the engine's output carries on."""
    import traceback
    text = f"{time.strftime('%Y-%m-%d %H:%M:%S')} nfpty: {where} failed, hover disabled\n{traceback.format_exc()}"
    nflog._write(text)          # to the log, or to stderr if the log cannot be written: never nowhere
    if dbg:
        dbg.write(text)


def kill_child(pid, sig):
    """Signal the child. ESRCH (already gone) is the normal race and silent;
    anything else (EPERM...) means the signal did not arrive and is logged."""
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        pass
    except OSError as e:
        note_once(f"kill-{sig}", f"could not send signal {sig} to child {pid}: {e}")


class Guard:
    """Runs decoration code. The first exception turns it off for good (see
    degrade), so one bug costs the cards, not the session."""

    def __init__(self, get_dbg, cleanup):
        self.ok = True
        self.get_dbg, self.cleanup = get_dbg, cleanup

    def run(self, what, fn, *args):
        if not self.ok:
            return
        try:
            fn(*args)
        except Exception:
            self.ok = False
            degrade(what, self.get_dbg())
            try:
                self.cleanup()
            except Exception:
                degrade(f"{what} cleanup (a card may be left painted)", self.get_dbg())


def main():
    argv = sys.argv[1:]
    if argv[:1] == ["--nfpty-selfcheck"]:
        selfcheck()
        return
    # Popped, not read: the shim hands the real path over by environment, and
    # every tool claude launches would otherwise inherit it.
    claude = os.environ.pop("CLAUDE_BIN", None) or ""
    if not claude:
        claude = "claude"
        note_once("claude-bin-default", "CLAUDE_BIN not set: running 'claude' from PATH "
                                        f"({__import__('shutil').which('claude') or 'not found'})")

    # Say so BEFORE the TUI owns the screen if tmux cannot be reached: layout
    # and backdrop both depend on it, and without it hover fails silently.
    sock = (os.environ.get("TMUX") or "").split(",")[0]
    try:
        ok = subprocess.run(["tmux", "display-message", "-p", "-t",
                             os.environ.get("TMUX_PANE") or "", "ok"],
                            capture_output=True, timeout=2).returncode == 0
    except (OSError, subprocess.SubprocessError):
        ok = False
    if os.environ.get("TMUX") and not ok:
        msg = f"tmux unreachable (socket {sock or '?'}); hover panels will not work. Run nf-tmux-heal, or restart tmux."
        note_once("tmux-unreachable", msg)             # the log, not only the terminal
        sys.stderr.write(f"nfpty: {msg}\n")

    stdin_fd = sys.stdin.fileno()
    pane0 = os.environ.get("TMUX_PANE")
    rows, cols = winsize(stdin_fd)
    if not pane0:
        # No pane means no layout and no backdrop: hover cannot work at all.
        msg = "TMUX_PANE is not set: hover panels are disabled (nfpty is not running inside a tmux pane)"
        note_once("no-tmux-pane", msg)
        sys.stderr.write(f"nfpty: {msg}\n")          # startup: the TUI does not own the screen yet
    if os.environ.get("NFPTY_SHADOW", "1") == "0":
        note_once("shadow-env-off", "NFPTY_SHADOW=0: the shadow screen is disabled by the environment; cards read the live pane")
    shadow = Shadow(rows, cols) if pane0 and os.environ.get("NFPTY_SHADOW", "1") != "0" else None
    if shadow is not None and not shadow.ok:
        # Not silent: without it cards restore stale rows again, and that is
        # otherwise indistinguishable from "working".
        msg = f"shadow screen unavailable ({shadow.why or 'unknown'}); reading the live pane"
        note_once("shadow-start", msg)
        sys.stderr.write(f"nfpty: {msg}\n")          # startup: visible before the TUI starts
        shadow = None                  # no private tmux: read the live pane as before
    resized = [True]            # read the size once after the handler exists, so a resize in the gap is not lost

    def on_winch(*_):
        resized[0] = True

    signal.signal(signal.SIGWINCH, on_winch)
    rows, cols = winsize(stdin_fd)
    resized[0] = False
    try:
        pid, master = pty.fork()
    except BaseException:
        if shadow is not None:
            shadow.close()                          # the shim may now exec plain claude: leave no tmux server behind
        raise
    if pid == 0:                                    # child: become claude
        os.environ["NFPTY"] = "1"
        set_winsize(0, rows, cols)          # before exec: it must never read 0x0 (logs by itself if it fails)
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)   # Python ignores it; the child must not inherit that
        try:
            os.execvp(claude, [claude] + argv)
        except OSError as e:
            sys.stderr.write(f"nfpty: cannot run {claude}: {e}\n")
            os._exit(127)

    set_winsize(master, rows, cols)
    resized[0] = True           # a resize that landed during the fork is applied by the loop

    out = sys.stdout.buffer

    painted = [0]

    # Our writes go into the engine's own byte stream, so they wait until the
    # last chunk we relayed ended on a sequence boundary (see ends_clean).
    clean = [True]
    pending: list = []
    stream = Stream()
    unclean_since = [0.0]

    def flush_pending():
        if pending and clean[0]:
            out.write("".join(w for w, _keep in pending).encode())
            out.flush()
            pending.clear()

    def write(s, keep=False):
        painted[0] += len(s)
        pending.append((s, keep))
        flush_pending()

    dbg = None
    if os.environ.get("NFPTY_LOG"):
        try:
            dbg = open(os.environ["NFPTY_LOG"], "a", buffering=1)
            nflog.set_debug_sink(dbg)
        except OSError as e:
            note_once("nfpty-log", f"cannot open NFPTY_LOG={os.environ['NFPTY_LOG']} ({e}): debug logging off")

    pane = os.environ.get("TMUX_PANE")
    panel = Panel(write, rows, cols, backdrop=Backdrop(pane, shadow), keeps=True)
    layout = Layout(pane, shadow)
    hl = Highlight(write, shadow, lambda: panel._show_cursor())
    shown_seg = [None]          # the readout the open card belongs to
    hl_dirty = [False]          # the engine drew since the highlight was painted
    panel.backdrop.note = (lambda m: dbg.write(m + "\n")) if dbg else None
    panel.backdrop.settled = lambda: not pending
    panel.warn = note_once

    old = None
    try:
        old = termios.tcgetattr(stdin_fd)
        tty.setraw(stdin_fd)
    except termios.error as e:
        # ENOTTY is "not a terminal" (a pipe, a test): relay anyway, by design. Anything else is not.
        if (e.args[0] if e.args else None) != errno.ENOTTY:
            note_once("tcgetattr", f"cannot read or set the terminal mode ({e}): input may not be raw")

    tail = b""
    tail_since = [0.0]
    status_box = [None]
    quit_sig = [None]

    quit_at = [0.0]

    def on_term(sig, _frame):
        if status_box[0] is not None:
            return                    # already reaped: the pid may be reused
        if quit_sig[0] is None:           # the FIRST signal starts the clock
            quit_at[0] = time.monotonic()
        quit_sig[0] = sig
        kill_child(pid, sig)             # the child decides how to die

    for sg in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sg, on_term)
    last = time.monotonic()
    # When to take the panel down, if the pointer stays away.
    hide_at: list = [None]
    last_motion = [0.0]         # when the pointer last reported; the watchdog below uses it
    on_card = [False]           # whether that last report was on the card OR on the readout that opens it
    retry = [None]              # (col, row, t) of a hover whose card was deferred
    drops: dict = {}            # deliberate degradations, counted and reported once at exit
    at_edge = [False]           # last report was on an edge row/column: the pointer is probably leaving

    def _drop_card():
        try:
            panel.erase()         # a card left up with hover off would stay for ever
        finally:
            panel.reset()
            try:
                hl.off()          # a highlight left on would be stuck for ever
            finally:
                flush_pending()
    guard = Guard(lambda: dbg, _drop_card)
    guarded = guard.run

    def on_hover(hovers):
        col0, row0 = hovers[-1]
        retry[0] = None
        at_edge[0] = row0 >= rows - EDGE or col0 <= EDGE or col0 >= cols - EDGE + 1
        last_motion[0] = time.monotonic()
        on_card[0] = bool(panel.rect and panel.rect[0] <= col0 < panel.rect[0] + panel.rect[2]
                          and panel.rect[1] <= row0 < panel.rect[1] + panel.rect[3])
        if on_card[0]:
            # On the card itself: keep it, whatever is read under it. Any pending
            # hide is cancelled UNLESS typing already made it due. If the reports
            # simply stop (the pointer left the terminal window) the watchdog in
            # the main loop takes the card down; nothing is armed here, so moving
            # off the card later is judged on its own, by the branch below.
            if hide_at[0] is None or hide_at[0] > time.monotonic():
                hide_at[0] = None
            return
        covered = (set(range(panel.rect[1], panel.rect[1] + panel.rect[3]))
                   if panel.rect else set())
        layout.refresh(covered)
        col, row = hovers[-1]      # only the latest position
        hit = layout.hit(col, row)
        on_card[0] = hit is not None     # resting on a readout is resting on the card's trigger: long grace...
        if dbg:
            dbg.write(f"hover {col},{row} "
                      f"hit={hit['id'] if hit else None} "
                      f"shown={panel.shown} rect={panel.rect} "
                      f"painted={painted[0]}\n")
        # HYSTERESIS. Leaving a readout does not hide the panel at
        # once: crossing a gap between readouts, or clipping the
        # row above for one event, used to erase and rebuild it,
        # which restarted the shine from the first corner every
        # time the pointer twitched. The hide is scheduled and
        # cancelled if the pointer comes back.
        if hit is None:
            # Off the card and off every readout: it goes soon. min(), not
            # "if none": a longer timer left from an earlier state must not
            # keep it up while the pointer is somewhere else entirely.
            if panel.shown:
                due = time.monotonic() + HIDE_AFTER
                if hide_at[0] is None or hide_at[0] > due:
                    hide_at[0] = due
        else:
            hide_at[0] = None          # back on a readout
            if hit["id"] == panel.shown:
                shown_seg[0] = hit     # follows the readout when the line shifts
            if hit["id"] != panel.shown:
                # Opening or switching: judge the readout on the screen as it is
                # NOW (the cached layout may be MIN_INTERVAL old), and not at
                # all from a layout suspended by a slow tmux read.
                if layout.paused:
                    note_once("layout-paused", "tmux answered slowly; opening cards is paused for 5 s")
                    return
                layout.refresh(covered, force=True)
                hit = layout.hit(col, row)
                if hit is None:
                    return              # the readout moved away from under the pointer
                panel.show(hit["id"], hit["title"], hit["body"],
                           tuple(hit["rgb"]), hit["x"],
                           hit["row"])
                shown_seg[0] = hit if panel.shown == hit["id"] else None
                if panel.shown != hit["id"]:
                    retry[0] = (col, row, time.monotonic())   # deferred: try again once the queue drains

    try:
        while True:
            if resized[0]:
                resized[0] = False
                rows, cols = winsize(stdin_fd)
                set_winsize(master, rows, cols)
                panel.rows, panel.cols = rows, cols
                if shadow is not None:
                    shadow.resize(rows, cols)
                panel.reset()         # its rect and saved rows are in the old geometry
                hl.forget()

            ready, _, _ = select.select([stdin_fd, master], [], [],
                                        select_timeout(panel.shown or panel.rect, hide_at[0], tail, pending, quit_sig[0]))

            # A descendant of the child (an MCP server, say) can still hold
            # the slave after it exits, so EIO never comes. Ask directly.
            if status_box[0] is None:
                done, st = os.waitpid(pid, os.WNOHANG)
                if done:
                    status_box[0] = st
                    # The child may have written its last words between the
                    # select above and the reap; look again before giving up.
                    ready, _, _ = select.select([stdin_fd, master], [], [], 0)
            if status_box[0] is not None and master not in ready:
                break

            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError as e:
                    if e.errno == errno.EIO:
                        break         # the child closed the slave: it exited
                    raise
                if not data:
                    break
                guarded("note_modes", note_modes, data, dbg)
                out.write(data)
                out.flush()
                clean[0] = stream.feed(data)
                if shadow is not None:
                    # The engine's bytes only, never ours, and the boundary
                    # flag of THESE bytes (not the previous chunk's).
                    shadow.feed(data, clean[0])
                if not clean[0] and not unclean_since[0]:
                    unclean_since[0] = time.monotonic()
                if clean[0]:
                    unclean_since[0] = 0.0
                if stream.cursor is not None:
                    panel.cursor_visible = stream.cursor
                flush_pending()
                # The engine has just repainted its frame, which covers where
                # the panel floats. Being last in the chain is the whole
                # advantage of sitting here: repaint on top of it and the
                # panel always wins, with no cooperation from the engine.
                #
                # IMMEDIATELY, in the same breath as the chunk that damaged
                # it. Deferring to the next frame leaves the panel visibly
                # broken for up to 36ms every time, which on the busy right
                # hand side of the band (where the engine's token bar sits
                # under the panel and repaints constantly) reads as a
                # flicker. The repaint is a single write, so the terminal
                # cannot render a half-restored panel; it costs about 2KB
                # against the engine's own frame.
                if panel.rect:
                    guarded("panel.redraw", panel.redraw)
                hl_dirty[0] = hl.cur is not None

            if stdin_fd in ready:
                try:
                    data = os.read(stdin_fd, 65536)
                except OSError as e:
                    if e.errno in (errno.EAGAIN, errno.EINTR):
                        continue          # a shared non-blocking tty is not end of input
                    if e.errno != errno.EIO:      # EIO: the terminal hung up, the normal end
                        note_once("stdin-read", f"stdin read failed ({e}): treating it as the terminal going away and ending the session")
                    break
                if not data:
                    break
                fwd, hovers, tail = split_hovers(tail + data)
                tail_since[0] = time.monotonic()
                typed = False
                if fwd:
                    write_all(master, fwd)
                    if MOUSE.search(fwd):
                        last_motion[0] = time.monotonic()    # any mouse report: the pointer is still in the window
                    # Typing takes a card down: nothing tells us the pointer left.
                    typed = bool(MOUSE.sub(b"", TERMINAL_NOISE.sub(b"", fwd).replace(FOCUS_OUT, b"")))
                    if FOCUS_OUT in fwd and panel.shown:
                        typed = True               # focus left the terminal (alt-tab): the card must not stay over the next window
                if hovers:
                    guarded("hover", on_hover, hovers)
                # AFTER the hovers: a keystroke and a motion report in one read
                # used to have the hover cancel the typing-hide.
                if typed and panel.shown:
                    hide_at[0] = time.monotonic()

            now = time.monotonic()

            # A card whose opening was deferred (the screen was not settled) is
            # opened once our write queue has drained, if the pointer has not
            # moved since: nothing else would trigger it while the pointer rests.
            if retry[0] is not None and not pending and clean[0]:
                col_r, row_r, t_r = retry[0]
                retry[0] = None
                if now - t_r < 1.0:
                    guarded("hover", on_hover, [(col_r, row_r)])

            # A held fragment that never completes is not a mouse report, and
            # is dropped rather than typed into the engine as stray text.
            if tail and now - tail_since[0] > 0.3:
                drops["held input fragment dropped (never became a mouse report)"] = drops.get("held input fragment dropped (never became a mouse report)", 0) + 1
                tail = b""

            # An engine that stalls inside a sequence must not hold our paints
            # (and a panel stuck on screen) hostage for ever.
            if pending and not clean[0] and unclean_since[0] and now - unclean_since[0] > 0.5:
                clean[0] = True
                unclean_since[0] = 0.0
                drops["forced 'clean' after a 0.5 s unfinished sequence"] = drops.get("forced 'clean' after a 0.5 s unfinished sequence", 0) + 1
                flush_pending()
            if len(pending) > 64:
                # Drop old frames, never the writes that put rows back: an
                # erase lost here leaves a ghost the panel thinks is gone.
                before = len(pending)
                trim_pending(pending)
                drops["animation frames trimmed from a backed-up queue"] = drops.get("animation frames trimmed from a backed-up queue", 0) + before - len(pending)

            # A forwarded signal the child ignores must not trap us here.
            if quit_sig[0] is not None and status_box[0] is None and now - quit_at[0] > 2.0:
                note_once("sigkill", f"child {pid} ignored signal {quit_sig[0]} for 2 s: sent SIGKILL")
                kill_child(pid, signal.SIGKILL)

            # Watchdog: a card up with no pointer report for WATCHDOG seconds (the
            # pointer left the window, so no more reports come) is taken down.
            if panel.shown and hide_at[0] is None and last_motion[0] and now - last_motion[0] > (WATCHDOG_ON_CARD if (on_card[0] and not at_edge[0]) else WATCHDOG):
                hide_at[0] = now
            if hide_at[0] is not None and now >= hide_at[0]:
                hide_at[0] = None
                # erase() puts back the rows saved from tmux. It does not ask
                # the engine to repaint: a SIGWINCH with no size change is a
                # no-op for it, which is why the old version left holes.
                guarded("panel.erase", panel.erase)

            def sync_hl():
                if panel.shown and hl_dirty[0] and now - hl.last >= hl.REFRESH:
                    # The engine drew while a card is up: is its readout still there, and where?
                    # (a dialog over the line, or a figure that changed width, with the pointer still)
                    covered = set(range(panel.rect[1], panel.rect[1] + panel.rect[3])) if panel.rect else set()
                    layout.refresh(covered)
                    cur_seg = next((s for s in layout.segs if s["id"] == panel.shown), None)
                    if cur_seg is None:
                        hide_at[0] = now          # gone: the card goes with it, through the normal erase
                        shown_seg[0] = None
                    else:
                        shown_seg[0] = cur_seg
                seg = shown_seg[0] if panel.shown else None
                if seg and panel.rect and panel.rect[1] <= seg["row"] < panel.rect[1] + panel.rect[3]:
                    note_once("highlight-card-over-row", "highlight: the card covers its own readout's row "
                                                         "(terminal too small); not highlighting")
                    seg = None
                hl.sync((seg["row"], seg["x"], seg["w"]) if seg else None)
                if hl_dirty[0] and hl.cur is not None and now - hl.last >= hl.REFRESH:
                    hl_dirty[0] = False
                    hl.refresh()
            guarded("highlight", sync_hl)

            if now - last >= FRAME:
                last = now
                # The head moves every frame whatever else is going on, so a
                # burst of engine repaints does not freeze the shine; only
                # HOW MUCH gets repainted depends on the interference.
                guarded("panel.paint", lambda: panel.paint(full=panel.advance()))
    finally:
        # Whatever the exit path, leave the terminal usable: the engine resets
        # its own mouse modes on a clean exit, and on a crash nobody does.
        try:
            if status_box[0] is None:
                hl.off()          # the engine is still up: put its cells back (an exited one may have cleared the screen)
        except OSError as e:
            if e.errno not in (errno.EIO, errno.EPIPE):
                note_once("exit-highlight", f"could not take the highlight down on exit ({e})")
        except Exception as e:
            note_once("exit-highlight", f"could not take the highlight down on exit ({type(e).__name__}: {e})")
        try:
            clean[0] = True
            flush_pending()
            out.write(b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?25h")
            out.flush()
        except (OSError, ValueError) as e:
            # EIO/EPIPE here is the terminal having hung up (the window was closed):
            # the normal way a session ends, and nothing is left to reset.
            if getattr(e, "errno", None) not in (errno.EIO, errno.EPIPE):
                note_once("exit-reset-write", f"could not write the terminal reset on exit ({e}): mouse reporting/cursor may be left on")
        if old is not None:
            try:
                termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old)
            except (termios.error, OSError) as e:
                # The reap below still must run. EIO is the terminal having gone
                # (nothing to restore); anything else may leave it in raw mode.
                if (e.args[0] if e.args else None) not in (errno.EIO, errno.EBADF):
                    note_once("exit-tcsetattr", f"could not restore the terminal mode on exit ({e}): the terminal may be left in raw mode")
        try:
            os.close(master)
        except OSError as e:
            note_once("exit-close-master", f"closing the pty master failed ({e})")
        if shadow is not None:
            shadow.close()
        for what, n in drops.items():
            if n:
                note_once("drops-" + what[:20], f"{n} x {what} this session")

    # The loop is over: a late TERM/HUP must not reach a pid we are about to
    # (or already did) reap, so the handlers go back to their defaults.
    for sg in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sg, signal.SIG_DFL)
    status = status_box[0]
    if status is None:
        # The terminal went away (stdin EOF) or we are being shut down: give
        # the child a moment, then stop waiting for one that ignores SIGHUP.
        deadline = time.monotonic() + 2.0
        while status is None and time.monotonic() < deadline:
            done, st = os.waitpid(pid, os.WNOHANG)
            if done:
                status = st
                status_box[0] = st
            else:
                time.sleep(0.05)
        if status is None:
            note_once("sigkill-final", f"child {pid} did not exit within 2 s of the terminal going away: sent SIGKILL")
            kill_child(pid, signal.SIGKILL)
            _, status = os.waitpid(pid, 0)
            status_box[0] = status
    code = os.waitstatus_to_exitcode(status)
    sys.exit(128 - code if code < 0 else code)     # shell convention: 128 + signal


if __name__ == "__main__":
    main()

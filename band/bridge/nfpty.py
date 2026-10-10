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

ESC = "\033"

# SGR mouse reports (mode 1006): ESC [ < btn ; col ; row (M|m).
MOUSE = re.compile(rb"\033\[<(\d+);(\d+);(\d+)([Mm])")
# Motion is bit 5 (32); the low two bits are the button, 3 meaning "none".
# 35 = 32|3 is therefore motion with nothing held, which is a hover.
HOVER_BTN = 35

# MEASURED: Claude Code sets 1000h, 1002h, 1003h and 1006h itself, so the
# terminal already reports plain motion and nothing in the output stream needs
# rewriting. The modes are logged rather than changed, because if that ever
# stops being true a silent hover would otherwise be unexplainable.

# How long the pointer must stay off a readout before the panel comes down.
# Long enough to cross the gap between two readouts without the panel
# blinking, short enough that leaving the band feels immediate.
HIDE_AFTER = 0.25


def winsize(fd):
    try:
        b = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
        rows, cols = struct.unpack("HHHH", b)[:2]
    except OSError:
        rows, cols = 50, 200
    return (rows or 50), (cols or 200)


def set_winsize(fd, rows, cols):
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ,
                    array.array("h", [rows, cols, 0, 0]))
    except OSError:
        pass


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

    def save(self, y, h):
        self.rows = None
        if not self.pane:
            return
        self.span = (y, h)
        # capture-pane numbers the visible pane from 0, screen rows from 1.
        span = ["-e", "-S", str(y - 1), "-E", str(y + h - 2)]
        # The engine's own screen first: it has none of our cards on it, so
        # what is saved is what the engine last drew, and restoring it later
        # shows the CURRENT status line, not the one from when the card opened.
        r = self.shadow.capture(*span) if self.shadow is not None else None
        if r is None:
            try:
                r = subprocess.run(
                    ["tmux", "capture-pane", "-p", *span, "-t", self.pane],
                    capture_output=True, encoding="utf-8", errors="replace", timeout=0.5)
            except (OSError, subprocess.SubprocessError):
                return
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
            if r is not None:
                self.rows = r.stdout.split("\n")[:h]
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
        self.segs = []

    def refresh(self, covered=()):
        now = time.monotonic()
        if not self.pane or now - self.at < self.MIN_INTERVAL:
            return
        self.at = now
        fresh, truth = mklayout.build_ex(self.pane, skip=covered, shadow=self.shadow)
        # tmux is read on the relay loop, so a slow answer is typing lag. If
        # it took long, stop asking for a while rather than stall again.
        if time.monotonic() - now > 0.3:
            self.at = time.monotonic() + 5.0
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
    global ERRLOG
    saved_log, ERRLOG = ERRLOG, os.devnull
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
        ERRLOG = saved_log
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
    print("nfpty ok")


ERRLOG = os.path.expanduser("~/.local/state/nerdflair/nfpty-error.log")


def degrade(where, dbg=None):
    """A bug in hover or panel code must not end the user's claude session.
    This is the one place an exception is absorbed, and it is loud: the
    traceback goes to a log that is never rotated away silently and to NFPTY_LOG,
    and the caller turns hover OFF for the rest of the session so the bug cannot
    repeat 28 times a second. Relaying the engine's output carries on."""
    import traceback
    text = f"{time.strftime('%Y-%m-%d %H:%M:%S')} nfpty: {where} failed, hover disabled\n{traceback.format_exc()}"
    try:
        os.makedirs(os.path.dirname(ERRLOG), exist_ok=True)
        with open(ERRLOG, "a") as f:
            f.write(text)
    except OSError:
        pass
    if dbg:
        dbg.write(text)


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
                pass


def main():
    argv = sys.argv[1:]
    if argv[:1] == ["--nfpty-selfcheck"]:
        selfcheck()
        return
    # Popped, not read: the shim hands the real path over by environment, and
    # every tool claude launches would otherwise inherit it.
    claude = os.environ.pop("CLAUDE_BIN", None) or "claude"

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
        sys.stderr.write(f"nfpty: tmux unreachable (socket {sock or '?'}); hover "
                         "panels will not work. Run nf-tmux-heal, or restart tmux.\n")

    stdin_fd = sys.stdin.fileno()
    pane0 = os.environ.get("TMUX_PANE")
    rows, cols = winsize(stdin_fd)
    shadow = Shadow(rows, cols) if pane0 and os.environ.get("NFPTY_SHADOW", "1") != "0" else None
    if shadow is not None and not shadow.ok:
        shadow = None                  # no private tmux: read the live pane as before
    resized = [True]            # read the size once after the handler exists, so a resize in the gap is not lost

    def on_winch(*_):
        resized[0] = True

    signal.signal(signal.SIGWINCH, on_winch)
    rows, cols = winsize(stdin_fd)
    resized[0] = False
    pid, master = pty.fork()
    if pid == 0:                                    # child: become claude
        os.environ["NFPTY"] = "1"
        try:
            set_winsize(0, rows, cols)      # before exec: it must never read 0x0
        except OSError:
            pass
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
        dbg = open(os.environ["NFPTY_LOG"], "a", buffering=1)

    pane = os.environ.get("TMUX_PANE")
    panel = Panel(write, rows, cols, backdrop=Backdrop(pane, shadow), keeps=True)
    layout = Layout(pane, shadow)

    old = None
    try:
        old = termios.tcgetattr(stdin_fd)
        tty.setraw(stdin_fd)
    except termios.error:
        pass                      # not a tty (a pipe, a test): relay anyway

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
        try:
            os.kill(pid, sig)            # the child decides how to die
        except OSError:
            pass

    for sg in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sg, on_term)
    last = time.monotonic()
    # When to take the panel down, if the pointer stays away.
    hide_at: list = [None]
    guard = Guard(lambda: dbg, lambda: panel.reset())
    guarded = guard.run

    def on_hover(hovers):
        covered = (set(range(panel.rect[1], panel.rect[1] + panel.rect[3]))
                   if panel.rect else set())
        layout.refresh(covered)
        col, row = hovers[-1]      # only the latest position
        hit = layout.hit(col, row)
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
            if panel.shown and hide_at[0] is None:
                hide_at[0] = time.monotonic() + HIDE_AFTER
        else:
            hide_at[0] = None          # back on a readout
            if hit["id"] != panel.shown:
                panel.show(hit["id"], hit["title"], hit["body"],
                           tuple(hit["rgb"]), hit["x"],
                           hit["row"])

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
                note_modes(data, dbg)
                out.write(data)
                out.flush()
                if shadow is not None:
                    shadow.feed(data)         # the engine's bytes only, never ours
                clean[0] = stream.feed(data)
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

            if stdin_fd in ready:
                try:
                    data = os.read(stdin_fd, 65536)
                except OSError as e:
                    if e.errno in (errno.EAGAIN, errno.EINTR):
                        continue          # a shared non-blocking tty is not end of input
                    break
                if not data:
                    break
                fwd, hovers, tail = split_hovers(tail + data)
                tail_since[0] = time.monotonic()
                if fwd:
                    write_all(master, fwd)
                    # Typing takes a card down: nothing tells us the pointer left.
                    if panel.shown and MOUSE.sub(b"", fwd):
                        hide_at[0] = time.monotonic()
                if hovers:
                    guarded("hover", on_hover, hovers)

            now = time.monotonic()

            # A held fragment that never completes is not a mouse report, and
            # is dropped rather than typed into the engine as stray text.
            if tail and now - tail_since[0] > 0.3:
                tail = b""

            # An engine that stalls inside a sequence must not hold our paints
            # (and a panel stuck on screen) hostage for ever.
            if pending and not clean[0] and unclean_since[0] and now - unclean_since[0] > 0.5:
                clean[0] = True
                unclean_since[0] = 0.0
                flush_pending()
            if len(pending) > 64:
                # Drop old frames, never the writes that put rows back: an
                # erase lost here leaves a ghost the panel thinks is gone.
                trim_pending(pending)

            # A forwarded signal the child ignores must not trap us here.
            if quit_sig[0] is not None and status_box[0] is None and now - quit_at[0] > 2.0:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass

            if hide_at[0] is not None and now >= hide_at[0]:
                hide_at[0] = None
                # erase() puts back the rows saved from tmux. It does not ask
                # the engine to repaint: a SIGWINCH with no size change is a
                # no-op for it, which is why the old version left holes.
                guarded("panel.erase", panel.erase)

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
            clean[0] = True
            flush_pending()
            out.write(b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?25h")
            out.flush()
        except (OSError, ValueError):
            pass
        if old is not None:
            try:
                termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old)
            except (termios.error, OSError):
                pass                  # the terminal is gone; the reap below still must run
        try:
            os.close(master)
        except OSError:
            pass
        if shadow is not None:
            shadow.close()

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
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
            _, status = os.waitpid(pid, 0)
            status_box[0] = status
    code = os.waitstatus_to_exitcode(status)
    sys.exit(128 - code if code < 0 else code)     # shell convention: 128 + signal


if __name__ == "__main__":
    main()

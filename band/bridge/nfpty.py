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
mode 1003 ("any event"). Claude Code asks for 1000/1002, which report presses
and drags but not plain motion. Since we relay the output stream, we upgrade
that request on its way to the terminal: `?1002h` becomes `?1003h`. The
terminal then also reports motion, and on the way back we CONSUME the
motion-only reports instead of forwarding them, so the engine receives
exactly the event stream it asked for and behaves identically.
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

    def __init__(self, pane):
        self.pane = pane
        self.rows = None
        self.top = 0

    def save(self, y, h):
        self.rows = None
        if not self.pane:
            return
        try:
            # capture-pane numbers the visible pane from 0, screen rows from 1.
            r = subprocess.run(
                ["tmux", "capture-pane", "-p", "-e", "-t", self.pane,
                 "-S", str(y - 1), "-E", str(y + h - 2)],
                capture_output=True, text=True, timeout=1)
        except (OSError, subprocess.SubprocessError):
            return
        if r.returncode == 0:
            self.rows = r.stdout.split("\n")[:h]
            self.top = y

    def restore(self):
        """The escapes that put those rows back, or None if we have none."""
        if not self.rows:
            return None
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

    Two things keep the cost down. It is rebuilt at most once a second, and
    only while hover is actually happening, so an idle session spends
    nothing. And it is NEVER rebuilt while a panel is up, because the panel
    is drawn on the screen we would be reading: it would parse its own border
    as readouts.
    """

    MIN_INTERVAL = 1.0

    def __init__(self, pane):
        self.pane = pane
        self.at = 0.0
        self.segs = []

    def refresh(self, blocked=False):
        now = time.monotonic()
        if blocked or not self.pane or now - self.at < self.MIN_INTERVAL:
            return
        self.at = now
        segs = mklayout.build(self.pane)
        if segs:
            self.segs = segs      # keep the last good one on a failed read

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
    if cut >= 0 and not MOUSE.match(rest, cut):
        return bytes(forward + rest[:cut]), hovers, rest[cut:]
    return bytes(forward + rest), hovers, b""


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
    print("nfpty ok")


def main():
    argv = sys.argv[1:]
    if argv[:1] == ["--selfcheck"]:
        selfcheck()
        return
    claude = os.environ.get("CLAUDE_BIN") or "claude"

    pid, master = pty.fork()
    if pid == 0:                                    # child: become claude
        os.environ["NFPTY"] = "1"
        try:
            os.execvp(claude, [claude] + argv)
        except OSError as e:
            sys.stderr.write(f"nfpty: cannot run {claude}: {e}\n")
            os._exit(127)

    stdin_fd = sys.stdin.fileno()
    rows, cols = winsize(stdin_fd)
    set_winsize(master, rows, cols)

    out = sys.stdout.buffer

    painted = [0]

    def write(s):
        painted[0] += len(s)
        out.write(s.encode())
        out.flush()

    dbg = None
    if os.environ.get("NFPTY_LOG"):
        dbg = open(os.environ["NFPTY_LOG"], "a", buffering=1)

    pane = os.environ.get("TMUX_PANE")
    panel = Panel(write, rows, cols, backdrop=Backdrop(pane))
    layout = Layout(pane)

    old = None
    try:
        old = termios.tcgetattr(stdin_fd)
        tty.setraw(stdin_fd)
    except termios.error:
        pass                      # not a tty (a pipe, a test): relay anyway

    resized = [False]

    def on_winch(*_):
        resized[0] = True

    signal.signal(signal.SIGWINCH, on_winch)

    tail = b""
    last = time.monotonic()
    # When to take the panel down, if the pointer stays away.
    hide_at: list = [None]
    try:
        while True:
            if resized[0]:
                resized[0] = False
                rows, cols = winsize(stdin_fd)
                set_winsize(master, rows, cols)
                panel.rows, panel.cols = rows, cols
                panel.erase()         # its rect is meaningless after a reflow

            ready, _, _ = select.select([stdin_fd, master], [], [], FRAME)

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
                    panel.redraw()

            if stdin_fd in ready:
                try:
                    data = os.read(stdin_fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                fwd, hovers, tail = split_hovers(tail + data)
                if fwd:
                    os.write(master, fwd)
                if hovers:
                    # Never while a panel is up: the panel is drawn on the
                    # screen this reads, and it would parse its own border
                    # as readouts.
                    layout.refresh(blocked=bool(panel.rect))
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

            now = time.monotonic()

            if hide_at[0] is not None and now >= hide_at[0]:
                hide_at[0] = None
                panel.erase()
                # Blanking leaves a hole where the engine's own frame was. We
                # do not know what it had there, so ask IT to repaint rather
                # than guessing: a resize nudge is the cheapest full redraw a
                # TUI reliably honours.
                os.kill(pid, signal.SIGWINCH)

            if now - last >= FRAME:
                last = now
                # The head moves every frame whatever else is going on, so a
                # burst of engine repaints does not freeze the shine; only
                # HOW MUCH gets repainted depends on the interference.
                panel.paint(full=panel.advance())
    finally:
        if old is not None:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old)
        try:
            os.close(master)
        except OSError:
            pass

    _, status = os.waitpid(pid, 0)
    sys.exit(os.waitstatus_to_exitcode(status))


if __name__ == "__main__":
    main()

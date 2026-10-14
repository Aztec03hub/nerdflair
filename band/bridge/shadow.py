"""shadow.py - the engine's screen, as the engine drew it, without our cards.

WHY. The cards float over the real pane, so the real pane is part-ours: the
backdrop captured from it when a card opens can include a previous card's
leftovers, the rows a card covers cannot be read at all (mklayout had to skip
them and remember the old answer), and a status line that changes while a card
is up is restored to its OLD value until the engine next repaints.

WHAT. A second, private tmux server whose single pane runs `cat` on a fifo.
nfpty feeds it every byte the engine writes (and never one of ours), so tmux
parses the same stream into a screen that is the engine's alone. Backdrop and
the layout scan read that screen. This is the terminal emulator the design
declined to write, borrowed from the program that is already installed.

ORDER. A capture must see every byte fed so far. tmux and cat are
asynchronous, so before reading, a title sequence with a fresh number is
appended to the stream and the pane title is polled until it shows that
number: the title is set only after everything before it was parsed.

It never blocks the relay for long (0.5 s per tmux call, a bounded sync), and
any failure turns it off: callers then read the live pane exactly as before,
so the worst case is the old behaviour, never a stuck session.
"""
import os
import shlex
import subprocess
import tempfile
import time

import nflog

ESC = "\033"
MAX_BACKLOG = 4 * 1024 * 1024       # past this the shadow has fallen too far behind to trust


def _tmux(sock, *args, timeout=0.5):
    return subprocess.run(["tmux", "-S", sock, *args], capture_output=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


class Shadow:
    def __init__(self, rows, cols):
        self.ok = False
        self.why = ""           # why it is off, when it is: logged by the caller, never silent
        self.fd = -1
        self.dir = None
        self.pending = b""
        self.n = 0
        self.clean = True       # last fed bytes ended on a sequence boundary
        self.cool = 0.0         # no captures before this time after a failed sync
        try:
            base = os.environ.get("XDG_RUNTIME_DIR")
            if not (base and os.path.isdir(base)):
                nflog.note_once("shadow-tmpdir", "XDG_RUNTIME_DIR unset or not a directory: the shadow screen's "
                                                 "private directory goes under the default temp dir")
            # mkdtemp is private (0700) and ours alone; the socket and fifo live in it.
            self.dir = tempfile.mkdtemp(prefix="nf-shadow-",
                                        dir=base if base and os.path.isdir(base) else None)
            # mkdtemp's 0700 is masked by the umask: the tmux server runs with
            # 0117, which made this 0600 (no search bit) for every window it
            # starts, so tmux got "Permission denied" and the shadow never came
            # up inside tmux. chmod is not masked.
            os.chmod(self.dir, 0o700)
            self.sock = os.path.join(self.dir, "s")
            self.fifo = os.path.join(self.dir, "in")
            os.mkfifo(self.fifo, 0o600)
            # O_RDWR: opens at once without waiting for the reader, and cat never sees EOF
            self.fd = os.open(self.fifo, os.O_RDWR | os.O_NONBLOCK)
            r = _tmux(self.sock, "-f", "/dev/null", "new-session", "-d", "-s", "s",
                      "-x", str(cols), "-y", str(rows), f"stty raw -echo; exec cat < {shlex.quote(self.fifo)}",
                      timeout=3)
            self.ok = r.returncode == 0
            if not self.ok:
                self.why = " ".join((r.stderr or f"tmux exit {r.returncode}").split())   # one line, for the log
        except Exception as e:      # any failure here must not stop the session from starting
            self.ok = False
            self.why = f"{type(e).__name__}: {e}"
        if not self.ok:
            self.close()

    def _off(self, why):
        """The one way the shadow is turned off after startup. Always logged:
        from here on the session runs the OLD behaviour (stale restores, covered
        rows skipped) and that must be traceable."""
        if self.ok:
            self.ok = False
            self.why = why
            nflog.note_once("shadow-off", f"shadow screen disabled mid-session: {why}; reading the live pane from now on")

    # ── feeding ──────────────────────────────────────────────────────────────
    def feed(self, data, clean=True):
        """Pass the engine's bytes on. `clean` says they end on a sequence
        boundary. Never raises; too far behind turns it off."""
        if not self.ok:
            return
        self.clean = clean
        self.pending += data
        self._drain()
        if len(self.pending) > MAX_BACKLOG:
            self._off(f"fell more than {MAX_BACKLOG} bytes behind")
            self.pending = b""

    def _drain(self):
        while self.pending:
            try:
                n = os.write(self.fd, self.pending)
            except BlockingIOError:
                return
            except OSError as e:
                self._off(f"write to its fifo failed: {e}")
                self.pending = b""
                return
            self.pending = self.pending[n:]

    # ── reading ──────────────────────────────────────────────────────────────
    def sync(self, budget=0.05):
        """Wait until everything fed so far has been parsed. True if it has."""
        # A sync mark inside an unfinished sequence would abort it and corrupt
        # the screen, so wait for a boundary; the caller reads the live pane.
        if not self.ok or not self.clean or time.monotonic() < self.cool:
            return False
        self.n += 1
        mark = f"nfsync{self.n}"
        self.feed(f"{ESC}]2;{mark}\a".encode())
        end = time.monotonic() + budget
        while time.monotonic() < end:
            self._drain()
            try:
                r = _tmux(self.sock, "display-message", "-p", "-t", "s", "#{pane_title}")
            except (OSError, subprocess.SubprocessError) as e:
                self.cool = time.monotonic() + 2.0      # tmux hung: do not wait on it every time
                nflog.note_rate("shadow-sync-tmux", f"shadow sync: tmux did not answer ({type(e).__name__}: {e}); "
                                                    "reading the live pane for 2 s")
                return False
            if r.returncode != 0:
                self._off(f"its tmux server stopped answering (display-message exit {r.returncode}: "
                          f"{r.stderr.strip() or 'no output'})")      # the server is gone: stop paying for it
                return False
            if r.stdout.strip() == mark:
                return True
            time.sleep(0.005)
        self.cool = time.monotonic() + 2.0      # stalled: stop asking for a while
        nflog.note_rate("shadow-sync-stall", f"shadow sync stalled (the mark did not appear within "
                                             f"{budget * 1000:.0f} ms); reading the live pane for 2 s")
        return False

    def capture(self, *args, timeout=0.5):
        """`tmux capture-pane -p ARGS` of the engine's screen, or None if the
        shadow cannot answer (the caller reads the live pane instead)."""
        if not self.ok:
            return None
        if not self.sync():
            return None             # a screen that may lack the latest bytes is not the truth
        try:
            r = _tmux(self.sock, "capture-pane", "-p", *args, "-t", "s", timeout=timeout)
        except (OSError, subprocess.SubprocessError) as e:
            self.cool = time.monotonic() + 2.0
            nflog.note_rate("shadow-capture-tmux", f"shadow capture: tmux did not answer ({type(e).__name__}: {e}); "
                                                   "reading the live pane for 2 s")
            return None
        if r.returncode != 0:
            nflog.note_rate("shadow-capture-rc", f"shadow capture-pane exit {r.returncode}: "
                                                 f"{r.stderr.strip() or 'no output'}; reading the live pane")
            return None
        return r

    def resize(self, rows, cols):
        if not self.ok:
            return
        try:
            r = _tmux(self.sock, "resize-window", "-t", "s", "-x", str(cols), "-y", str(rows))
            if r.returncode != 0:
                self._off(f"resize to {cols}x{rows} failed (exit {r.returncode}: {r.stderr.strip() or 'no output'})")
        except (OSError, subprocess.SubprocessError) as e:
            self._off(f"resize to {cols}x{rows} failed ({type(e).__name__}: {e})")

    # ── teardown ─────────────────────────────────────────────────────────────
    def close(self):
        """Stop the server and remove what we made. Safe to call twice."""
        self.ok = False
        if getattr(self, "sock", None) and self.dir:
            try:
                r = _tmux(self.sock, "kill-server", timeout=2)
                # "no server running"/"error connecting" is the normal answer when
                # it never started or has already gone; anything else is not.
                if r.returncode != 0 and not any(s in r.stderr for s in ("no server running", "error connecting", "No such file")):
                    nflog.note_once("shadow-kill", f"shadow tmux kill-server exit {r.returncode}: {r.stderr.strip()}; "
                                                   f"a private tmux server may still be running at {self.sock}")
            except (OSError, subprocess.SubprocessError) as e:
                nflog.note_once("shadow-kill", f"shadow tmux kill-server failed ({type(e).__name__}: {e}); "
                                               f"a private tmux server may still be running at {self.sock}")
        if self.fd >= 0:
            try:
                os.close(self.fd)
            except OSError as e:
                nflog.note_once("shadow-close-fd", f"shadow fifo close failed: {e}")
            self.fd = -1
        # Only the three names we made, in the directory mkdtemp made.
        if self.dir:
            for name in ("in", "s"):
                try:
                    os.unlink(os.path.join(self.dir, name))
                except FileNotFoundError:
                    pass            # the socket goes with the server: expected
                except OSError as e:
                    nflog.note_once("shadow-cleanup", f"shadow cleanup: cannot remove {os.path.join(self.dir, name)}: {e}")
            try:
                os.rmdir(self.dir)
            except OSError as e:
                nflog.note_once("shadow-cleanup-dir", f"shadow cleanup: directory {self.dir} not removed: {e}")
            self.dir = None


def _umask_check():
    """Under the tmux server's umask (0117) the shadow must still come up. Falsifiable:
    without the chmod its directory is 0600 and tmux reports Permission denied."""
    nflog.ERRLOG = os.devnull           # a selfcheck must not write the real log
    old = os.umask(0o117)
    try:
        hostile = Shadow(5, 20)
        assert hostile.ok, f"shadow must start under umask 0117: {hostile.why}"
        hostile.close()
    finally:
        os.umask(old)


def selfcheck():
    _umask_check()
    """Against a real tmux: bytes fed appear on the shadow screen in order, a
    sequence split across two feeds is joined, a resize takes, and close
    leaves nothing behind. Falsifiable: a screen that never got the bytes is
    empty."""
    sh = Shadow(10, 40)
    assert sh.ok, "tmux is required for this check"
    d = sh.dir
    try:
        assert sh.sync(budget=3.0), "cat/tmux did not come up"      # warm-up: startup is slower than the 50 ms production budget
        sh.feed(f"{ESC}[2;3Hhello".encode())
        sh.feed(f"{ESC}[4;1H{ESC}[3".encode())          # a colour sequence split over two feeds
        sh.feed(b"1mred")
        r = sh.capture("-e")
        assert r is not None, "capture failed"
        lines = r.stdout.split("\n")
        assert lines[1].strip() == "hello" and lines[1].startswith("  hello"), lines[:3]
        assert "red" in lines[3] and "\x1b[31m" in lines[3], lines[3]
        # A read that ends inside a sequence is not synced into (the mark
        # would abort it); the caller falls back to the live pane.
        sh.feed(f"{ESC}[5;1H{ESC}[3".encode(), clean=False)
        assert sh.capture() is None, "no capture inside an unfinished sequence"
        sh.cool = 0.0
        sh.feed(b"2mgrn", clean=True)
        g = sh.capture("-e")
        assert g is not None and "\x1b[32m" in g.stdout and "grn" in g.stdout, g
        sh.resize(7, 30)
        small = sh.capture()
        assert small is not None and len(small.stdout.rstrip("\n").split("\n")) <= 7
        # Control: an unsynced, never-fed shadow shows nothing of the above.
        other = Shadow(10, 40)
        try:
            blank = other.capture()
            assert blank is not None and "hello" not in blank.stdout
        finally:
            other.close()
    finally:
        sh.close()
    assert d and not os.path.exists(d), "the shadow's directory must be gone"
    assert sh.capture() is None and not sh.ok
    # Falling too far behind turns it off instead of buffering for ever.
    big = Shadow(5, 20)
    real = big.fd
    try:
        big.fd = -2                           # writes now fail with EBADF
        big.feed(b"x")
        assert big.ok is False
    finally:
        big.fd = real
        big.close()
    print("shadow ok")


if __name__ == "__main__":
    selfcheck()

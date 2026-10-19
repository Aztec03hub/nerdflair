#!/usr/bin/env python3
"""logcheck.py - every failure the bridge absorbs must leave a log line.

The rule: hover/panel code never kills the user's claude session, so failures
are degraded around; but a degraded-around failure with no trace is a bug. This
drives each absorbing site with a forced failure and asserts that exactly the
expected line reached the log, and that the benign, frequent skips stay silent
(logging them would bury the real ones).

Runs against a temp log (nflog.ERRLOG is redirected), stubs subprocess and the
OS calls, and starts no tmux and no child.
"""
import errno
import io
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mklayout  # noqa: E402
import nflog  # noqa: E402
import nfpty  # noqa: E402
import panel as panel_mod  # noqa: E402
import shadow as shadow_mod  # noqa: E402

TMP = tempfile.mkdtemp(prefix="nf-logcheck-")
LOG = os.path.join(TMP, "err.log")
nflog.ERRLOG = LOG
fails = 0


def lines():
    try:
        with open(LOG) as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return []


def fresh():
    nflog.reset()
    try:
        os.unlink(LOG)
    except FileNotFoundError:
        pass


def check(name, cond, detail=""):
    global fails
    print(f"  {'PASS' if cond else 'FAIL'}  {name}{'' if cond else '  ' + detail}")
    fails += not cond


def expect_one(name, fn, needle):
    fresh()
    fn()
    got = [ln for ln in lines() if needle in ln]
    check(name, len(got) == 1, f"wanted exactly one line containing {needle!r}, log was {lines()}")


def expect_silent(name, fn):
    fresh()
    fn()
    check(name, lines() == [], f"must stay silent but logged {lines()}")


def stub(obj, name, value):
    old = getattr(obj, name)
    setattr(obj, name, value)
    return lambda: setattr(obj, name, old)


# ── nflog itself ───────────────────────────────────────────────────────────
def t_rate():
    fresh()
    for _ in range(50):
        nflog.note_rate("k", "something failed", every=3600)
    check("note_rate: 50 failures, one line", len(lines()) == 1, str(lines()))
    nflog.note_once("o", "x")
    nflog.note_once("o", "x")
    check("note_once: once", sum("x" in ln for ln in lines()) == 1)


def t_encoding():
    fresh()
    try:
        nflog.note_once("enc", "path with a lone surrogate: /tmp/\udcff/x")
        ok = True
    except Exception as e:      # a "never raises" logger must not
        ok = False
        print("   raised", e)
    check("nflog: a message that cannot be encoded does not raise, and is logged", ok and any("path with" in ln for ln in lines()), str(lines()))


def t_unwritable_log():
    fresh()
    saved, nflog.ERRLOG = nflog.ERRLOG, "/proc/nf-cannot-write/x.log"
    err, sys.stderr = sys.stderr, io.StringIO()
    try:
        nflog.note_once("u", "the message")
        text = sys.stderr.getvalue()
    finally:
        sys.stderr, nflog.ERRLOG = err, saved
    check("unwritable log: falls back to stderr (never nowhere)", "the message" in text, text)


# ── shadow ─────────────────────────────────────────────────────────────────
def mk_shadow():
    s = shadow_mod.Shadow.__new__(shadow_mod.Shadow)
    s.ok, s.why, s.fd, s.dir, s.pending, s.n, s.clean, s.cool = True, "", 5, None, b"", 0, True, 0.0
    s.sock = "/nonexistent/sock"
    return s


def t_shadow():
    def fifo_error():
        s = mk_shadow()
        undo = stub(os, "write", lambda fd, d: (_ for _ in ()).throw(OSError(errno.EPIPE, "broken pipe")))
        try:
            s.feed(b"x")
        finally:
            undo()
        check("shadow turned off by the fifo error", s.ok is False)
    expect_one("shadow fifo write error is logged", fifo_error, "shadow screen disabled mid-session")

    def backlog():
        s = mk_shadow()
        undo = stub(os, "write", lambda fd, d: (_ for _ in ()).throw(BlockingIOError()))
        try:
            s.feed(b"x" * (shadow_mod.MAX_BACKLOG + 1))
        finally:
            undo()
    expect_one("shadow backlog overflow is logged", backlog, "fell more than")

    def stall():
        s = mk_shadow()
        undo = stub(shadow_mod, "_tmux", lambda *a, **k: subprocess.CompletedProcess(a, 0, stdout="other", stderr=""))
        undo2 = stub(os, "write", lambda fd, d: len(d))
        try:
            s.sync(budget=0.02)
        finally:
            undo()
            undo2()
    expect_one("shadow sync stall is logged", stall, "shadow sync stalled")

    def tmux_hang():
        s = mk_shadow()
        undo = stub(shadow_mod, "_tmux", lambda *a, **k: (_ for _ in ()).throw(subprocess.TimeoutExpired("tmux", 1)))
        undo2 = stub(os, "write", lambda fd, d: len(d))
        try:
            s.sync(budget=0.05)
        finally:
            undo()
            undo2()
    expect_one("shadow tmux hang is logged", tmux_hang, "tmux did not answer")

    def server_gone():
        s = mk_shadow()
        undo = stub(shadow_mod, "_tmux", lambda *a, **k: subprocess.CompletedProcess(a, 1, stdout="", stderr="no server running"))
        undo2 = stub(os, "write", lambda fd, d: len(d))
        try:
            s.sync(budget=0.05)
        finally:
            undo()
            undo2()
        check("server gone turns the shadow off", s.ok is False)
    expect_one("shadow server gone is logged", server_gone, "stopped answering")

    def capture_rc():
        s = mk_shadow()
        calls = []

        def fake(*a, **k):
            calls.append(a)
            if "display-message" in a[1:]:
                return subprocess.CompletedProcess(a, 0, stdout=f"nfsync{s.n}", stderr="")
            return subprocess.CompletedProcess(a, 1, stdout="", stderr="can't find pane")
        undo = stub(shadow_mod, "_tmux", fake)
        undo2 = stub(os, "write", lambda fd, d: len(d))
        try:
            check("capture returns None on a tmux error", s.capture() is None)
        finally:
            undo()
            undo2()
    expect_one("shadow capture-pane error is logged", capture_rc, "capture-pane exit 1")

    def resize():
        s = mk_shadow()
        undo = stub(shadow_mod, "_tmux", lambda *a, **k: subprocess.CompletedProcess(a, 1, stdout="", stderr="bad size"))
        try:
            s.resize(10, 10)
        finally:
            undo()
    expect_one("shadow resize failure is logged", resize, "resize to 10x10 failed")

    def benign_unclean():
        s = mk_shadow()
        s.clean = False
        check("not-clean sync is declined", s.sync() is False)
    expect_silent("sync skipped on an unfinished sequence stays silent (benign, frequent)", benign_unclean)

    def startup_fail():
        undo = stub(shadow_mod, "_tmux", lambda *a, **k: subprocess.CompletedProcess(a, 1, stdout="", stderr="Permission denied"))
        try:
            s = shadow_mod.Shadow(5, 20)
        finally:
            undo()
        check("startup failure keeps the reason", not s.ok and "Permission denied" in s.why, s.why)
    startup_fail()


# ── layout / backdrop ──────────────────────────────────────────────────────
def t_layout_backdrop():
    def tmux_missing():
        undo = stub(subprocess, "run", lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError("tmux")))
        try:
            segs, truth = mklayout.build_ex("%0")
        finally:
            undo()
        check("layout: unreadable is None, not an empty list", segs is None and truth is False, repr(segs))
    expect_one("layout: tmux missing is logged", tmux_missing, "layout: tmux capture-pane failed")

    def tmux_rc():
        undo = stub(subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(a, 1, stdout="", stderr="can't find pane"))
        try:
            segs, _ = mklayout.build_ex("%0")
        finally:
            undo()
        check("layout: a tmux error is unreadable, not 'a dialog covers the status line'", segs is None)
    expect_one("layout: tmux error exit is logged", tmux_rc, "capture-pane exit 1")

    def keeps_last_layout():
        lay = nfpty.Layout("%0")
        lay.segs = [{"id": "a", "row": 3, "x": 1, "w": 5}]
        lay.MIN_INTERVAL = 0
        undo = stub(mklayout, "build_ex", lambda *a, **k: (None, False))
        try:
            lay.refresh()
        finally:
            undo()
        check("layout: unreadable keeps the previous regions", len(lay.segs) == 1)
    keeps_last_layout()

    def hung_backoff():
        lay = nfpty.Layout("%0")
        lay.MIN_INTERVAL = 0

        def slow(*a, **k):
            time.sleep(0.35)
            return (None, False)
        undo = stub(mklayout, "build_ex", slow)
        try:
            lay.refresh()
        finally:
            undo()
        check("layout: a hung tmux (slow AND unreadable) engages the 5 s backoff", lay.paused)
    hung_backoff()

    def backdrop_tmux():
        bd = nfpty.Backdrop("%0", shadow=None)
        undo = stub(subprocess, "run", lambda *a, **k: (_ for _ in ()).throw(subprocess.TimeoutExpired("tmux", 1)))
        try:
            bd.save(5, 3)
        finally:
            undo()
    expect_one("backdrop: tmux failure on save is logged", backdrop_tmux, "backdrop: tmux capture-pane failed")

    def backdrop_rc():
        bd = nfpty.Backdrop("%0", shadow=None)
        undo = stub(subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(a, 1, stdout="", stderr="gone"))
        try:
            bd.save(5, 3)
        finally:
            undo()
    expect_one("backdrop: tmux error exit on save is logged", backdrop_rc, "capture-pane exit 1")

    def live_fallback():
        class Dead:
            ok = True
            clean = True

            def capture(self, *a, **k):
                return None
        bd = nfpty.Backdrop("%0", shadow=Dead())
        undo = stub(subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(a, 0, stdout="r\nr\nr", stderr=""))
        try:
            bd.save(5, 3)
        finally:
            undo()
    expect_one("backdrop: shadow -> live pane fallback is logged", live_fallback, "shadow screen could not answer")

    def restore_stale():
        class Dead:
            ok = True

            def capture(self, *a, **k):
                return None
        bd = nfpty.Backdrop("%0", shadow=Dead())
        bd.rows, bd.span, bd.top = ["a", "b"], (3, 2), 3
        bd.restore()
    expect_one("backdrop: restore from stale saved rows is logged", restore_stale, "status line may show an old value")


# ── panel ──────────────────────────────────────────────────────────────────
def t_panel():
    def clipped():
        p = panel_mod.Panel(lambda t, keep=False: None, 20, 30)
        p.warn = nflog.note_once
        p.show("x", "Title", ["a body line that is far wider than the terminal can hold at all"], (1, 2, 3), 5, 10)
    expect_one("panel: clipped card is logged", clipped, "clipped to")

    def not_clipped():
        p = panel_mod.Panel(lambda t, keep=False: None, 50, 200)
        p.warn = nflog.note_once
        p.show("x", "T", ["short"], (1, 2, 3), 5, 10)
    expect_silent("panel: an unclipped card stays silent", not_clipped)

    def blank():
        p = panel_mod.Panel(lambda t, keep=False: None, 50, 200)
        p.warn = nflog.note_once
        p.show("x", "T", ["short"], (1, 2, 3), 5, 10)
        p.erase()
    expect_one("panel: erase with no snapshot (blank hole) is logged", blank, "blanked the card area")


# ── nfpty ──────────────────────────────────────────────────────────────────
def t_nfpty():
    def winsize_fail():
        nfpty.winsize(-1)
    expect_one("winsize failure is logged", winsize_fail, "TIOCGWINSZ failed")

    def set_winsize_fail():
        nfpty.set_winsize(-1, 10, 10)
    expect_one("set_winsize failure is logged", set_winsize_fail, "TIOCSWINSZ failed")

    def degrade_unwritable():
        saved, nflog.ERRLOG = nflog.ERRLOG, "/proc/nf-cannot-write/x.log"
        err, sys.stderr = sys.stderr, io.StringIO()
        try:
            try:
                1 / 0
            except ZeroDivisionError:
                nfpty.degrade("hover")
            text = sys.stderr.getvalue()
        finally:
            sys.stderr, nflog.ERRLOG = err, saved
        check("degrade with an unwritable log still reaches stderr", "ZeroDivisionError" in text, text)
    degrade_unwritable()

    def guard_cleanup_fails():
        g = nfpty.Guard(lambda: None, lambda: 1 / 0)
        g.run("hover", lambda: 1 / 0)
    fresh()
    guard_cleanup_fails()
    check("guard: a failing cleanup is logged too", any("cleanup" in ln for ln in lines()), str(lines()))

    def kill_esrch():
        undo = stub(os, "kill", lambda p, s: (_ for _ in ()).throw(ProcessLookupError()))
        try:
            nfpty.kill_child(1, 15)
        finally:
            undo()
    expect_silent("kill: ESRCH (already gone) stays silent", kill_esrch)

    def kill_eperm():
        undo = stub(os, "kill", lambda p, s: (_ for _ in ()).throw(PermissionError(errno.EPERM, "denied")))
        try:
            nfpty.kill_child(1, 15)
        finally:
            undo()
    expect_one("kill: EPERM is logged", kill_eperm, "could not send signal")

    def seq_cap():
        st = nfpty.Stream()
        st.feed(b"\x1b]0;" + b"a" * 5000)
    expect_one("a >4096-byte 'sequence' is logged", seq_cap, "over 4096 bytes")

    def highlight_degrade():
        class Dead:
            def capture(self, *a):
                return None
        wrote = []
        h = nfpty.Highlight(lambda s, keep=False: wrote.append(s), Dead())
        h.sync((2, 3, 4, (1, 2, 3)))
        h.sync((2, 3, 4, (1, 2, 3)))
        check("highlight: an unreadable shadow paints nothing", wrote == [] and h.cur is None, str(wrote))
    expect_one("highlight: shadow cannot answer is logged once", highlight_degrade, "the readout is not highlighted")

    def highlight_no_shadow():
        h = nfpty.Highlight(lambda s, keep=False: None, None)
        h.sync((2, 3, 4, (1, 2, 3)))
    expect_silent("highlight: NFPTY_SHADOW=0 (no shadow) adds no log line, startup already said so", highlight_no_shadow)

    def highlight_refresh_fails():
        class Flaky:
            ok = True

            def __init__(self):
                self.up = True

            def capture(self, *a):
                return type("R", (), {"stdout": "abc"}) if self.up else None
        sh = Flaky()
        h = nfpty.Highlight(lambda s, keep=False: None, sh)
        h.sync((2, 1, 2, (1, 2, 3)))
        sh.up = False
        h.last = 0.0
        h.refresh()
        h.last = 0.0
        h.refresh()
    expect_one("highlight: a failed refresh is logged once", highlight_refresh_fails, "was not repainted")


def main():
    t_rate()
    t_encoding()
    t_unwritable_log()
    t_shadow()
    t_layout_backdrop()
    t_panel()
    t_nfpty()
    print(f"\nlogcheck: {'FAIL' if fails else 'PASS'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    t0 = time.monotonic()
    main()

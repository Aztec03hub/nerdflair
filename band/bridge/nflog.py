"""nflog.py - the one place the bridge records a failure it absorbs.

The rule for this directory: hover and panel code must never kill the user's
claude session, so a failure is degraded around, never raised. But a failure
that is absorbed must leave a trace: silence is a bug. Everything goes through
here so there is one format, one file, and one place that limits the noise.

    note_once(kind, msg)          first occurrence of `kind` in this process
    note_rate(kind, msg, every)   first occurrence, then at most one line per
                                  `every` seconds saying how many were missed

Both never raise. If the log file cannot be written the line goes to stderr
instead (a last resort: mid-session it may mangle the TUI, which is better than
a failure with no record), once per kind.
"""
import os
import sys
import time

# NFPTY_ERRLOG lets tests (and a curious user) point the log somewhere else.
ERRLOG = os.environ.get("NFPTY_ERRLOG") or os.path.expanduser("~/.local/state/nerdflair/nfpty-error.log")
LOG_MAX = 1_000_000

_seen = {}      # kind -> [count, last_logged_monotonic]
_dbg = [None]   # optional extra sink (NFPTY_LOG), set by nfpty


def set_debug_sink(f):
    _dbg[0] = f


def _write(line):
    try:
        os.makedirs(os.path.dirname(ERRLOG), exist_ok=True)
        try:
            if os.path.getsize(ERRLOG) > LOG_MAX:
                os.replace(ERRLOG, ERRLOG + ".1")      # one generation: this is a diagnostic
        except OSError:
            pass
        with open(ERRLOG, "a", encoding="utf-8", errors="replace") as f:
            f.write(line)
    except (OSError, ValueError) as e:      # ValueError: an encoding problem must not escape a "never raises" logger
        try:
            sys.stderr.write(f"nfpty: cannot write {ERRLOG} ({e}); {line}")
        except (OSError, ValueError):
            pass            # no stderr either: nothing left to try, and this must not raise
    if _dbg[0]:
        try:
            _dbg[0].write(line)
        except (OSError, ValueError):
            pass


def _line(msg):
    return f"{time.strftime('%Y-%m-%d %H:%M:%S')} nfpty: {' '.join(str(msg).split())}\n"


def note_once(kind, msg):
    if kind in _seen:
        _seen[kind][0] += 1
        return
    _seen[kind] = [1, time.monotonic()]
    _write(_line(msg))


def note_rate(kind, msg, every=60.0):
    """First occurrence logs; later ones are counted and reported at most once
    per `every` seconds as 'N more since the last report'."""
    now = time.monotonic()
    st = _seen.get(kind)
    if st is None:
        _seen[kind] = [1, now]
        _write(_line(msg))
        return
    st[0] += 1
    if now - st[1] >= every:
        _write(_line(f"{msg} ({st[0] - 1} more since the last report)"))
        st[0] = 1
        st[1] = now


def count(kind):
    return _seen.get(kind, [0])[0]


def reset():
    """For tests."""
    _seen.clear()

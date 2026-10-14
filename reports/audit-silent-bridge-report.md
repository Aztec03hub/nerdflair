# Silent-failure audit: band/bridge (nfpty.py, shadow.py, panel.py, mklayout.py)

Read-only audit, static reading only. Standard: every absorbed, downgraded or worked-around failure must be logged once, with the reason, to a durable place (log file or stderr the user sees). Hover/panel code must never kill the session, so the answer is "degrade AND log", never "raise".

## Overall picture

There is exactly one real log sink today: `ERRLOG = ~/.local/state/nerdflair/nfpty-error.log`, written by `degrade()` (exceptions inside Guard) and once at startup when the shadow fails to start. The optional `NFPTY_LOG` (dbg) is debug-only and off by default, so it does not count as durable. Everything in `shadow.py`, `mklayout.py` and `Backdrop` after startup logs nothing. `Shadow.why` is set only at construction and read once. The shadow is turned off in four other places (backlog, drain error, sync "server gone", resize) with no message, and a dead shadow degrades every later `capture` to the live pane, which is exactly the stale/ghost-card behaviour the shadow was built to fix.

**Root cause of most findings:** there is no shared "log once per kind" helper. Suggested single fix, then call it from every site below:

```python
# nfpty.py (shadow.py/mklayout.py import it, or take a `warn` callback to avoid a cycle)
_SEEN = set()
def nflog(kind, msg, every=None):
    """Append to ERRLOG once per `kind` (or once per `every` seconds). Never raises;
    if the file is unwritable, fall back to stderr once."""
```

Put `nflog` in a tiny new module (e.g. `nflog.py`) so shadow.py and mklayout.py can import it without a circular import with nfpty.py. If the ERRLOG open fails, write to `sys.stderr` once (see finding 9).

## Ranked findings

### HIGH (user silently gets degraded hover)

**1. `Backdrop.save`: shadow -> live-pane fallback, tmux failure, and non-zero exit all silent** (nfpty.py)
```python
r = self.shadow.capture(*span) if self.shadow is not None else None
if r is None:
    try:
        r = subprocess.run(["tmux", "capture-pane", "-p", *span, "-t", self.pane], ... timeout=0.5)
    except (OSError, subprocess.SubprocessError):
        return
if r.returncode == 0:
    self.rows = r.stdout.split("\n")[:h]
    self.top = y
```
Absorbs: shadow unavailable (falls to live pane, which can contain earlier cards' leftovers), tmux missing/timeout (silent `return`, `rows` stays None), non-zero tmux exit (no else; `rows` stays None). Consequence: `Panel.erase` then blanks the area (a hole until the engine repaints). Logged today: nothing. Fix: `nflog("backdrop-live-fallback", "shadow capture unavailable, using live pane (cards may restore stale rows)")` once; `nflog("backdrop-save-tmux", f"{type(e).__name__}: {e}")` on the except; `nflog("backdrop-save-rc", f"tmux capture-pane exit {r.returncode}: {r.stderr.strip()}")` in an else. Once per kind, plus a count in dbg.

**2. `mklayout.build_ex`: tmux failure returns `[]`, and the exit code is never checked** (mklayout.py)
```python
try:
    r = subprocess.run(["tmux", "capture-pane", "-p", "-t", target], ... timeout=0.5)
except (OSError, subprocess.SubprocessError):
    return [], False
...
raw = r.stdout.split("\n")   # no r.returncode check
```
Absorbs: tmux missing/hung/timeout, and a non-zero exit (bad pane id, server gone) where stdout is empty. Both produce zero readouts, and `Layout.refresh` documents an empty read as "a dialog is covering the status line", so it clears every region. Result: hover is silently dead for the whole session, indistinguishable from "no readout under the pointer". Fix: log the exception with reason once; check `returncode` and log `stderr` once; distinguish "tmux failed" from "no readouts found" (return a third value or raise a private `LayoutUnavailable` that `Layout.refresh` catches and logs, keeping the previous segs instead of treating failure as an empty answer). Rate-limit to once per kind, re-arm after a success so a later recurrence is logged again.

**3. Shadow turns itself off in five places, only one logs** (shadow.py)
```python
if len(self.pending) > MAX_BACKLOG:
    self.ok = False          # callers fall back to the live pane
...
except OSError:
    self.ok = False; self.pending = b""; return          # _drain
...
if r.returncode != 0:
    self.ok = False         # the server is gone: stop paying for it   # sync
...
if _tmux(... "resize-window" ...).returncode != 0: self.ok = False     # resize
except (OSError, subprocess.SubprocessError): self.ok = False           # resize
```
Absorbs: backlog overflow, fifo write error (EPIPE/EBADF), private tmux server died, resize failed. Consequence: from that moment the session silently runs the OLD behaviour (stale restores, covered rows skipped, wrong-status-line restore). Logged today: nothing (the startup path logs via `shadow.why`, these do not). Fix: add `Shadow._off(self, why)` that sets `ok=False`, `self.why=why`, and calls `nflog("shadow-off", f"shadow screen disabled mid-session: {why}; reading the live pane")`; route all five sites through it. It fires once because `ok` is already False afterwards. Include the exception or tmux stderr text.

**4. `Shadow.capture`/`sync` return None for six different reasons, none logged** (shadow.py)
```python
if not self.ok or not self.clean or time.monotonic() < self.cool: return False
...
except (OSError, subprocess.SubprocessError):
    self.cool = time.monotonic() + 2.0 ; return False     # tmux hung
...
self.cool = time.monotonic() + 2.0   # stalled: stop asking for a while
return False
...
return r if r.returncode == 0 else None                  # capture
```
`not clean` is a normal, frequent, benign skip (do not log). The others are real degradations: sync stall (shadow not parsing, budget 50 ms exceeded), tmux hang/timeouts, capture-pane non-zero, each followed by a 2 s cool-down during which every capture silently uses the live pane. Fix: log once per kind with a counter ("shadow sync stalled; 2 s cool-down; reading live pane"), then rate-limit to once per 60 s with "N since last report". Do not log the `clean` and `cool` skips (consequences of an already-logged event). `r.returncode != 0` in capture: log `r.stderr`.

**5. `Backdrop.restore` falls back to stale saved rows silently** (nfpty.py)
```python
r = self.shadow.capture("-e", "-S", ...)
if self.note: self.note(f"restore shadow=...")     # dbg only
if r is not None:
    self.rows = ...
# else: keep the rows saved at open
```
When the shadow cannot answer at restore time the card is erased with the status line as it was when the card opened (the exact bug the shadow exists to fix). Only `NFPTY_LOG` records it. Fix: `nflog("restore-stale", "shadow unavailable at erase: restored rows saved at open, status line may be stale")`, rate-limited.

**6. `Panel.erase` blank fallback is silent** (panel.py)
```python
under = self.backdrop.restore() if self.backdrop else None
if under is None:
    # No snapshot: blanking is all that is left. ... it is the fallback, not the design.
    under = "".join(f"{ESC}[{r};{x}H{' ' * w}" ...
```
Visible damage (a hole in the status line) with no message. The code comment itself says it is a degraded path. panel.py has no log access. Fix: give `Panel` an optional `warn` callable (nfpty passes `nflog`), call `warn("erase-blank", "no backdrop snapshot: blanked the card area; hole until the engine repaints")` once. Cause is already logged by findings 1/5 if they are fixed, so one line suffices.

**7. Hover is silently disabled when not in tmux or no pane** (nfpty.py)
```python
pane0 = os.environ.get("TMUX_PANE")
shadow = Shadow(rows, cols) if pane0 and os.environ.get("NFPTY_SHADOW", "1") != "0" else None
...
if not self.pane or now - self.at < self.MIN_INTERVAL: return     # Layout.refresh
if not self.pane: return                                         # Backdrop.save
```
With `TMUX_PANE` unset (not in tmux, or env stripped) no layout is ever built and no backdrop saved: every hover finds no readout and nothing is ever shown, with no message. The startup warning only fires `if os.environ.get("TMUX") and not ok`. Fix: at startup, if `TMUX_PANE` is empty, `nflog("no-tmux-pane", "TMUX_PANE not set: hover panels disabled")` and also write one line to stderr before the TUI starts (same channel as the existing tmux-unreachable message). Also log `NFPTY_SHADOW=0` once as "shadow disabled by NFPTY_SHADOW=0" (explicit user choice, but the resulting behaviour change should be traceable).

**8. `degrade` and Guard cleanup swallow their own failures** (nfpty.py)
```python
try:
    os.makedirs(os.path.dirname(ERRLOG), exist_ok=True)
    with open(ERRLOG, "a") as f: f.write(text)
except OSError:
    pass
if dbg: dbg.write(text)
...
try:
    self.cleanup()
except Exception:
    pass
```
If ERRLOG is unwritable (read-only HOME, disk full) and `NFPTY_LOG` is unset, a hover crash is logged nowhere: the one "loud" path is silent. Hover is then off for the rest of the session with no trace. The `cleanup` exception (card erase failed, so a card may remain painted forever) is swallowed with no record. Fix: on `OSError` write the same text to `sys.stderr` (it will mangle the TUI, but it is a last resort and happens at most once because `Guard.ok` is then False); wrap `cleanup` failure in `degrade(f"{what} cleanup", ...)`. Also the user is never told on screen that hover turned off; acceptable under the standard (durable log) but consider a one-line stderr message on exit: "nfpty: hover was disabled this session, see <ERRLOG>".

### MEDIUM

**9. Startup shadow-failure log can itself fail silently** (nfpty.py ~588-598)
```python
try: ... open(ERRLOG, "a") ... write(...)
except OSError:
    pass
shadow = None
```
Same issue as 8: the message the code calls "not silent" is dropped if ERRLOG is unwritable. Fix: same stderr fallback; this runs before the TUI owns the screen so stderr is visible. Better: for a startup-time failure always also write one stderr line.

**10. `Shadow(...)` construction is unguarded against non-OSError exceptions** (nfpty.py main / shadow.py __init__)
`__init__` only catches `OSError, subprocess.SubprocessError`. `ValueError` (e.g. embedded NUL in an env path, `shlex`/`str` issues), `UnicodeError`, etc. propagate out of `main()` before the child is forked: the session never starts, with a traceback. Also on `TimeoutExpired` (3 s) a tmux server may be half-started; `close()` tries `kill-server` and its failures are swallowed (see 12). Fix: in `__init__` catch `Exception` (not BaseException), set `why`, then the existing logging path runs. Also log the `XDG_RUNTIME_DIR` fallback (`base` unset or not a dir -> default tempdir) once as info; the default tempdir may be /tmp, which is where long-lived things should not live and where a root-owned dir can break mkdtemp.

**11. Terminal geometry fallbacks are silent** (nfpty.py)
```python
except OSError:
    rows, cols = 50, 200                 # winsize
return (rows or 50), (cols or 200)
...
except OSError: pass                     # set_winsize (parent)
try: set_winsize(0, rows, cols) except OSError: pass     # child
```
A failed `TIOCGWINSZ` or a zero-size report makes panel placement and the shadow size use a made-up 50x200; a failed `TIOCSWINSZ` leaves claude on the wrong pty size (it could read 0x0, which the comment says "must never" happen). Note `set_winsize` itself catches `OSError`, so the child's `try/except OSError` around it is dead code. Fix: log once per kind: "TIOCGWINSZ failed (errno): assuming 50x200", "TIOCSWINSZ failed: pty size not applied", "terminal reports 0 rows/cols: assuming ...". Log at most once per session each; re-log only if the error message changes.

**12. `Shadow.close` swallows every teardown failure** (shadow.py)
```python
try: _tmux(self.sock, "kill-server", timeout=2)
except (OSError, subprocess.SubprocessError): pass
...
except OSError: pass     # close(fd), unlink x2, rmdir
```
A failed `kill-server` (timeout) leaves a private tmux server and a `cat` process alive after the session ends, and a failed `unlink`/`rmdir` leaks `nf-shadow-*` in `$XDG_RUNTIME_DIR`. Both are resource leaks on failure. Fix: log once each with the path/PID context ("shadow tmux kill-server failed: ...; server may still be running at <sock>", "shadow dir not removed: <dir>: <errno>"). Also check `kill-server` exit code (currently ignored: `_tmux(...)` result is discarded; "no server running" is benign, anything else is not).

**13. Child-exit and terminal-restore failures swallowed in `finally`** (nfpty.py)
```python
except (OSError, ValueError): pass                                   # mouse-mode reset write
except (termios.error, OSError): pass   # the terminal is gone; the reap below still must run
except OSError: pass                                                 # close(master)
```
If the reset write or `tcsetattr` fails, the user's terminal can be left in raw mode with mouse reporting on. The comment justifies "terminal is gone" but that is an assumption not a check. Fix: log once to ERRLOG with `errno`/exception text (do not write to the terminal). `close(master)` failure: log once.

**14. stdin read error treated as EOF** (nfpty.py)
```python
except OSError as e:
    if e.errno in (errno.EAGAIN, errno.EINTR): continue
    break
```
Any other `OSError` (EIO, EBADF) ends the session loop exactly like a clean EOF, then the child is SIGHUP/KILLed. A real I/O fault is indistinguishable from the user closing the terminal. Fix: `if e.errno not in (EIO, EBADF?)` is a judgement; minimum: log `f"stdin read failed: {e}"` before `break`. A genuine EOF (`not data`) needs no log.

**15. Escalation to SIGKILL, and failed signal delivery** (nfpty.py)
```python
try: os.kill(pid, sig) except OSError: pass          # on_term
if quit_sig[0] is not None and ... now - quit_at[0] > 2.0:
    try: os.kill(pid, signal.SIGKILL) except OSError: pass
...
if status is None:  os.kill(pid, SIGKILL)  # after 2 s grace
```
A child that ignored TERM/HUP for 2 s is force-killed with no record (user loses unsaved claude state). `ESRCH` is benign (already gone) so `except OSError: pass` is fine for that case, but other errnos (EPERM) are not. Fix: `nflog("sigkill", f"child {pid} ignored signal {sig} for 2s: sent SIGKILL")` once; log non-ESRCH `OSError` from `os.kill`.

**16. `CLAUDE_BIN` default** (nfpty.py)
`claude = os.environ.pop("CLAUDE_BIN", None) or "claude"` silently runs whatever `claude` is on PATH when the shim's variable is missing. If that resolves to the shim itself it re-enters nfpty (I could not verify whether the shim guards against this; the `NFPTY=1` env set in the child suggests it does). Fix: when it defaulted, write `nflog("claude-bin-default", "CLAUDE_BIN not set: running 'claude' from PATH (<resolved path>)")`.

**17. Dropped data without notice** (nfpty.py)
```python
if tail and now - tail_since[0] > 0.3:
    tail = b""                  # held fragment dropped
...
clean[0] = True ; unclean_since[0] = 0.0 ; flush_pending()   # unfinished sequence declared clean after 0.5 s
...
trim_pending(pending)           # frames silently dropped when > 64 queued
...
return n == 0 or n > 4096       # Stream.feed: >4096-byte "sequence" called clean
```
Each is a deliberate degradation (user keystrokes held and discarded; our paint written into a possibly unfinished engine sequence which can corrupt the screen; animation frames dropped). None is logged. Fix: count them and report once per kind per session with the count at exit (`"dropped N held input fragments"`, `"forced clean after 0.5 s stall N times"`, `"trimmed N frames"`), rather than per event. Severity medium-low: normal at low counts, but a sudden large count is the only diagnosable symptom of terminal corruption.

**18. `Layout.refresh` slow-tmux back-off is silent** (nfpty.py)
```python
if time.monotonic() - now > 0.3:
    self.at = time.monotonic() + 5.0
```
A 5 s hover blackout (stale layout, delayed cards) because tmux was slow, with no message. Fix: `nflog("layout-slow", f"tmux capture took {dt:.2f}s on the relay loop; layout paused 5s", every=60)`.

### LOW

**19. `Panel.show` clipping and clamping** (panel.py): `title = title[:max(1, w - 6)]`, `body = [b[:w - 4] ...]`, and `w = min(self.cols - 4, ...)`, plus the `y` clamps, silently truncate text on narrow terminals (a clipped card the user may take for a bug). Fix: `warn("card-clipped", f"card '{sid}' clipped to {w} cols (terminal {self.cols})")` once. Also `max(len(b) for b in body)` raises `ValueError` on an empty body; it is guarded by `Guard` (so logged via degrade, correct).

**20. `mklayout.cards_check`** (test tool, not runtime): `subprocess.run([binary], ...)` with no returncode check. A non-zero renderer exit would give empty output; `assert rows` catches the empty case with a message, so it is effectively covered. Add `check=True` for a clearer reason.

**21. `mklayout.build_ex` regex non-match paths** (`continue` on `row in skip`, `SEP not in clean or not NERD.search`): normal filtering, not failures. See "Correct" below.

**22. NFPTY_LOG handling** (nfpty.py): `dbg = open(os.environ["NFPTY_LOG"], "a", buffering=1)` is unguarded: a bad path raises and kills the session before it starts (not silent, but violates "never kill the session"). `note_modes(data, dbg)` in the main loop is also outside the Guard, so a failing debug write (disk full) would kill the relay. Fix: open in try/except, on failure `nflog`/stderr once and set `dbg=None`; wrap `note_modes` in `guarded`.

## Sites checked and CORRECT (no change needed)

- **Shadow startup failure message** (`nfpty.py`: "shadow screen unavailable ({shadow.why or 'unknown'}); reading the live pane"): logs reason to ERRLOG. Correct, except the unwritable-log gap in finding 9.
- **`Shadow.__init__` tmux failure**: sets `why` from stderr or exit code. Correct.
- **`degrade()` + `Guard.run`**: exception logged with traceback to ERRLOG, hover turned off once, `if not self.ok: return` is silent only after the logged event. Correct (modulo findings 8, 22).
- **Child exec failure**: `nfpty: cannot run {claude}: {e}` to stderr, exit 127. Correct.
- **Startup tmux probe**: `except -> ok=False` then a stderr warning when `TMUX` is set. Correct for that case; gap is `TMUX` unset (finding 7).
- **`EIO` on master read -> `break`**: the documented, normal child-exit signal. Correct. Other errors on the master read propagate (loud).
- **`EAGAIN/EINTR -> continue`** on stdin read: genuinely benign. Correct.
- **`termios.error` on `tcgetattr` -> pass** ("not a tty, a pipe, a test: relay anyway"): intended, no hover-relevant degradation; optional one-line dbg note only.
- **`status_box` / `on_term` already-reaped guard**, `waitpid` loop, exit-code mapping: logic, not absorption.
- **`Shadow.sync` `clean=False` early return**: expected and frequent; logging would be pure spam (see finding 4).
- **`Shadow._drain` `BlockingIOError: return`**: back-pressure, retried next call; the backlog cap handles the real failure (finding 3).
- **`mklayout.classify` GENERIC card** ("this readout has no card of its own yet"): visible to the user on hover, and `cards_check` fails the build for unmapped readouts. Not silent.
- **`mklayout.main` CLI**: prints "no status-line rows found" to stderr and exits 1. Correct.
- **`Layout.hit` returning None**, `split_hovers` pass-through of everything, `MOUSE` regex non-matches, `incomplete_tail`/`_escape_tail` helpers, `trim_pending` keeping erases: pure data logic, no failure absorbed (the drop count is finding 17).
- **`Panel.paint`/`advance`/`_border`/`redraw`** early returns on `not self.paths` / `not self.rect`: state checks, no failure.
- **`select.select`** is not wrapped; Python 3 retries EINTR; any other error is loud.
- **self-check functions** in all four files: tests, assertions fail loudly.

## What I could not verify

- Behaviour of the shim that sets `CLAUDE_BIN` and `NFPTY` (not in scope), so finding 16's recursion risk is unconfirmed.
- Whether `nf-tmux-heal` or any other component tails ERRLOG; I did not check that anything reads it, only that it is written. Also whether there is any rotation (the docstring says "never rotated away silently" but no rotation code is in these files).
- That stderr written mid-session is visible: once the TUI owns the screen, stderr output corrupts or is erased by the redraw. Startup-time stderr (findings 7, 9) is safe; mid-session events must go to ERRLOG only.
- Nothing was executed (per instructions). Failure modes such as the exact `TimeoutExpired` behaviour of tmux new-session, and whether `kill-server` leaves a child `cat`, are from reading the code only.
- panel.py lines 240-356 were not read (the `advance` tail and any later helpers); the grep showed no `except` clauses there. nfpty.py lines 397-500 are the self-check, only skimmed. The file is being edited by another engineer, so line numbers were deliberately omitted in favour of snippets.

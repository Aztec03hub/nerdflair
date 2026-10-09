# Hover bridge review, round 4 (commit 72b7494)

Static read only. Line numbers from `rg -n` at HEAD.

## Medium

### M1. Overflow trim reorders the queue, so an old paint frame lands after the erase that should cancel it
band/bridge/nfpty.py:611-612. `pending[:] = keep + [non-restore][-32:]` puts every restore write first and the surviving paint frames after it. `pending` is time ordered: panel.py:140 (redraw), :154 (erase) and :164 (paint) all append through `write`. Take queue `[redraw/paint (t0), erase (t1)]`. After the trim it is `[erase, paint]`: the terminal erases, then paints the panel back. `panel.rect` is already None, so nothing ever removes it: a ghost panel, the exact failure the commit says it prevents. The same happens for an old panel's border frames that precede an erase and a following `show()`.
Fix: keep order, drop only the oldest non-restore items in place:
```
drop = len(pending) - 64
if drop > 0:
    out = []
    for w in pending:
        if drop > 0 and RESTORE_MARK not in w: drop -= 1; continue
        out.append(w)
    pending[:] = out
```
Add a selfcheck that feeds 70 entries with an erase in the middle and asserts relative order.

### M2. The blank-fill erase fallback carries no RESTORE_MARK, so overflow still drops it
band/bridge/panel.py:148-154 versus nfpty.py:198-199 and :611. When `backdrop.restore()` returns None (no snapshot: tmux capture failed, nfpty.py:125-126, or `rows` empty, :133), `erase()` writes `ESC[r;xH` plus spaces, with no `ESC[2K`. The trim at :611 sees no mark and treats it as a droppable paint frame. The comment at :198 ("Backdrop.restore() output carries this") is true only for the snapshot path.
Fix: tag at the source instead of sniffing bytes. Make `Panel.erase` call `self.write(..., keep=True)` and have nfpty's `write(s, keep=False)` store `(s, keep)` pairs, or put a no-op marker such as `ESC[0m` guaranteed unique to erases at the front of both erase variants. Then delete the string-sniffing constant.

### M3. The "SIGKILL escalation on every exit path" claim is false when `tcsetattr` raises
band/bridge/nfpty.py:644-645. `termios.tcsetattr(stdin_fd, TCSADRAIN, old)` sits outside any try. The SIGHUP/closed-terminal case is where it can raise `termios.error` (EIO) or `OSError`. The exception then skips `os.close(master)` (:647) and the whole new reap/SIGKILL block (:651-667), leaving the child orphaned, which is the hang class this commit set out to remove. The cleanup in the `finally` was fixed for the write (:637-643) but not for this call.
Fix: wrap it, `try: termios.tcsetattr(...) except (termios.error, OSError): pass`. Better, put the reap/kill block in its own `finally` so an exception in the main loop (for example the `raise` at :526) also reaps.

## Low

### L1. install.sh refuses any rc file with a CR anywhere, and reports the wrong reason
band/hover/install.sh:49. `grep -q $'\r'` matches a stray CR in a string, a comment or a paste, not only CRLF markers. `install` and `uninstall` both then print "unmatched nerdflair marker" (:68, :79). A user with an incidental CR cannot even uninstall an existing block. A CRLF rc file with no marker is refused for a fresh install too.
Fix: refuse only when a marker line has a CR, `grep -qxF "$BEGIN"$'\r' "$1" || grep -qxF "$END"$'\r' "$1"`, and give it its own message ("has Windows line endings on a marker line"). No test covers this branch (`rg` finds none under tests/); add one with a CRLF fixture.

### L2. The last-words loop still cannot fail against the pre-fix ordering
tests/nfpty-exit.sh:49-61. The child prints and exits within microseconds of starting, while nfpty's `select` (nfpty.py:506) is blocked waiting for exactly that data, so `master` is already in `ready` when the reap at :511 sees the exit. The old order read it too. The race needs `select` to return for another reason and the data plus exit to land before `waitpid`. Sixty identical runs do not create that. Round 3 L2 was closed by repetition, not by a new interleaving.
Fix: mutation-check it (delete the re-select at nfpty.py:516 and see whether the test fails; if not, say in the comment it is a smoke test). To make it real, have the harness write a byte to nfpty's stdin at the same moment the child writes (child `sleep 0.2; printf LASTWORDS; exit 0`, harness writes stdin at t+0.2 s) so select wakes on stdin while the output and exit arrive together.

### L3. The 137 test is timing dependent and can fail for the wrong reason
tests/nfpty-exit.sh:69-72. The harness signals nfpty after a fixed 1.0 s. On a loaded machine bash may not have run `trap '' TERM` yet, so it dies of the forwarded SIGTERM (rc 143) and the test reports a SIGKILL failure that is not one. The `secs <= 4` bound uses `int()` truncation of a wall-clock difference that includes interpreter exit, so it is also load sensitive.
Fix: have the child announce readiness (`trap '' TERM; echo ready; sleep 6` with stdout piped) and wait for it before signalling; allow `secs <= 5`.

### L4. The signal handler stays live after the reap, so a late signal can hit a reused pid
band/bridge/nfpty.py:483-490 together with :657-659 (and :511-513). Once the child is reaped, `on_term` still calls `os.kill(pid, sig)`. A SIGTERM/SIGHUP landing between the reap and `sys.exit` signals whatever now owns that pid. The window is tiny; it existed before the commit but the new 2 s polling loop (:656-661) widens it slightly. The SIGKILL calls themselves (:617, :664) are safe: they run only while the child is unreaped, so the pid cannot be reused.
Fix: `status_box[0] = status` right after each reap and make `on_term` return early when `status_box[0] is not None`.

### L5. Two seconds may be too short for a child that handles SIGHUP slowly
band/bridge/nfpty.py:655-667. On terminal close the child gets SIGHUP from `os.close(master)`, and Claude Code may legitimately take longer than 2 s to flush a session. It is now SIGKILLed. Judgement call, not a defect; consider 5 s or an env override.

## Checked, no finding
- max of the two tails (nfpty.py:255): never undercounts, because an unfinished sequence's `len(data) - i` already contains any partial glyph at its end; never overcounts beyond the real unfinished span. A partial glyph after a finished sequence returns the glyph length only, and the carry is those bytes. The new selfcheck (nfpty.py:68-70 in the diff) fails against the old early-return code.
- RESTORE_MARK matching non-restore writes: nothing in panel.py's redraw/paint/border emits `ESC[2K` (`rg` for `2K` in panel.py finds only :139's caller path in nfpty.py). Captured tmux text could contain it, but that only keeps a restore write anyway. See M2 for the opposite miss.
- waitpid/SIGKILL versus a normal reap: the loop SIGKILL (:615-619) and the final one (:662-667) fire only while the child is unreaped, so a zombie absorbs the signal and no pid is reused. `waitpid(pid, 0)` after SIGKILL cannot hang. Exit code 137 results (`128 - (-9)`).
- First-signal clock (:484-485) is correct; a second signal no longer slides the deadline.
- Exit-reset write is now inside the try (:637-643); a dead terminal no longer skips the reap by that route (see M3 for the remaining route).

## Disposition 2026-10-09 (author)

Fixed: M1 (the overflow trim is now `trim_pending`, in place and in order; a selfcheck proves an erase still runs before a later write), M2 (erases are tagged by the panel with `keep=True` instead of sniffing bytes, so the blank-fill erase is protected too), M3 (`tcsetattr` is guarded so the reap and SIGKILL block always run), L1 (only a CR on a marker line is refused, with its own message), L3 (the test waits for the child's `ready` before signalling), L4 (the handler returns once the child is reaped).
Not changed: L2 (the last-words case cannot be made deterministic without controlling the select wakeup; kept as a regression smoke test and described as such), L5 (2 s before SIGKILL is a judgement call; kept).


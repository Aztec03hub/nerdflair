# Round 2 review of fb705a3 (hover bridge fixes)

Static reading only. Line numbers are from `Read` of the tree at fb705a3. Reviewed: nfpty.py, panel.py, mklayout.py, claude-shim, install.sh, nf-tmux-heal, register.tsx, tests/nfpty-exit.sh, tests/tmux-heal.sh.

## High

None.

## Medium

M1. The waitpid break can drop the child's final output (band/bridge/nfpty.py:442-451).
`select` returns, then `waitpid(WNOHANG)` runs, then the loop breaks if `master not in ready`. `ready` is stale by the time of the waitpid. If the child writes its last bytes and exits between the select return and the waitpid (or select returned only for stdin or on timeout), the bytes are in the master buffer, the child is reaped, `master` is not in `ready`, and the loop breaks without reading them. Claude prints its exit text ("Resume this session...") immediately before exiting, which is exactly this shape. The window is small, but it loses the one chunk that matters.
Fix: on reap, drain before breaking. Replace the break at 450-451 with a loop `while select.select([master],[],[],0)[0]: read, relay (note_modes, out.write), stop on EIO/empty`, then break. Also add this drain to tests/nfpty-exit.sh (child prints a marker then exits, assert the marker reaches stdout).

M2. `ends_clean` keeps no state across chunks (nfpty.py:244-273, called at 465).
It judges one chunk alone. A sequence split over three reads, or any split where the later chunk contains no ESC, is judged clean on the middle chunk. Example: chunk 1 `ESC[38;2` (unclean), chunk 2 `;1;2` (no ESC, so line 253 returns True), then the pending panel write is flushed inside the engine's CSI. The same applies to an OSC title split as `ESC]0;ti` then `tle`. Splitting twice in a row is rarer than once, but the 64 KB reads of a busy TUI make it reachable, and the failure is exactly the corruption the commit set out to prevent.
Fix: carry the unfinished tail. Keep `carry = data[i:]` (or the incomplete UTF-8 bytes) when unclean and call `ends_clean(carry + data)` on the next chunk, bounded to a few hundred bytes. Add a selfcheck case for a three-way split.

M3. Pending panel writes have no flush deadline (nfpty.py:380-392, 465-469).
`flush_pending` only runs from `write()` and after a master read. If the engine stops mid-sequence (stalled child, or a lone final ESC the engine is waiting to complete) the queue holds indefinitely, so a hide/erase is never painted and the panel stays on screen. `pending` also grows without bound across frames, since `panel.paint` queues a string every FRAME (line 543). When the stream finally ends clean, the backlog of all those frames is written at once.
Fix: cap the queue (keep only the latest paint plus any erase) and force-flush when `clean` has been False for more than about 0.25s (track `unclean_since`, check it beside the 0.3s tail check at 527), accepting the corruption risk over a stuck panel.

M4. The 0.3s tail flush is unguarded and can split a report (nfpty.py:527-529).
`os.write(master, tail)` is outside any try. If the child has just exited, EIO raises a traceback instead of the clean 128+signal exit path (the finally runs, but the exit code becomes 1). Separately, after a flush of `ESC[<35;1` the remainder `2;3M` arrives in a later read with `tail == b""`, so it is forwarded as plain text and typed into the prompt as `2;3M`. This needs a 0.3s stall mid-report, so it is rare.
Fix: wrap the write in `try/except OSError: break`; also remember a flushed-fragment flag so that a following read matching `^[\d;]*[Mm]` is dropped rather than forwarded.

M5. SIGTERM/SIGHUP forwarding can leave nfpty alive forever (nfpty.py:421-429).
Before this change a SIGHUP (terminal closed) killed nfpty and closing the master hung up the child. Now the handler only forwards. If the child ignores or defers the signal, nothing escalates and nfpty loops until stdin errors. `quit_sig` is written but never read, so the intended follow-up logic is missing.
Fix: in the loop, if `quit_sig[0]` is set and the child is still unreaped after about 2s, `os.kill(pid, SIGKILL)` and break. Remove `quit_sig` if not used.

## Low

L1. Cursor tracking regex sees one chunk only (nfpty.py:198, 466).
`ESC[?25l` split as `ESC[?2` / `5l` is missed, so `panel.cursor_visible` stays stale and the panel hands the cursor back wrong. Same stale-state issue as M2. Also, a paint queued before an engine `?25l` carries the old `_show_cursor()` result (composed in panel.py:89-90 at compose time) and is flushed after the engine's hide at 469, re-showing the cursor.
Fix: run CURSOR over `carry + data` with the same carry as M2, and have `Panel` store a callable or resolve `_show_cursor()` at flush time (queue closures, or a placeholder token replaced in `flush_pending`).

L2. `ends_clean` ignores several incomplete forms (nfpty.py:262-272).
`ESC (` / `ESC )` / `ESC #` / `ESC SP` (intermediate with no final), SS3 `ESC O`, and DCS/APC/PM/SOS strings (`ESC P`, `ESC _`) all fall to `return True` at 272. The OSC test `b"\x1b\\" in data[i:]` at 271 is dead code, because `i` is the last ESC and an ST would be a later ESC. The UTF-8 test returns True when an earlier invalid byte raises first (e.end < len), even if a truncated character sits at the end (nfpty.py:249-251).
Fix: treat `rest[:1]` in `()*+#` or space as needing one more byte, treat `P _ ^ X` like OSC (needs ESC-backslash), delete the dead clause, and test the tail with `data[-4:]` for truncated UTF-8 instead of decoding the whole chunk. Add selfcheck cases for `ESC(` and `ESC P...`.

L3. Pending writes are lost at exit and the reset can land mid-sequence (nfpty.py:544-551).
`finally` writes the mouse/cursor reset straight to `out`, bypassing `pending` (a queued panel erase is dropped) and ignoring `clean` (the reset can be written inside an unfinished engine sequence).
Fix: in `finally`, discard `pending` deliberately (add a comment) and prefix the reset with `ST`/`CAN` (`\x18`) so any half sequence is cancelled before the mode resets.

L4. Signal handler can signal a recycled pid (nfpty.py:421-426, 446-449).
After `waitpid` reaps the child at 447 the handler still does `os.kill(pid, sig)`. The window until exit is tiny, but fix is trivial.
Fix: `if status_box[0] is None:` guard in `on_term`.

L5. nf-tmux-heal parsing assumes no spaces in the socket path (band/hover/nf-tmux-heal:22).
`read -r _ _ _ _ path ...` splits on whitespace. A `TMUX_TMPDIR` containing a space truncates `path`, fails the `*/tmux-$uid/*` match at 23, and the script silently does nothing (safe, but a silent no-op is the failure mode the commit fixes). The pid is taken with a greedy sed (line 25), so with several users of the fd it picks the LAST pid; the comm check at 29 prevents a wrong signal, but it can produce a false skip.
Fix: take the path as `${line#*[0-9] }` from the fifth field using `awk '{print $5}'` only when no spaces, or parse with `ss -xlnpH -O` plus `sed 's/ \+[0-9]\+ \+\* .*//'`; take the pid from `grep -o 'pid=[0-9]*'` and test each in turn against the comm check.

L6. install.sh `paired` checks counts only, not order (band/hover/install.sh:44-49).
A file with END before BEGIN passes (1 and 1), and `strip` (awk) then skips from BEGIN to end of file, deleting everything after it, the original bug.
Fix: in `paired`, also require the BEGIN line number to be less than the END line number (`grep -nxF` first match for each).

L7. Shim import check does not cover nfpty.py itself (band/hover/claude-shim:35-36).
It imports `mklayout` and `panel` but not `nfpty`, so a syntax error or newer-Python-only construct in nfpty.py (the file that actually runs) is not caught, and claude would fail to start.
Fix: add `py_compile`-style check: `python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$HOVER/nfpty.py"` in the same guard, or run `nfpty.py --selfcheck`.

## What the tests do not prove

T1. tests/nfpty-exit.sh covers descendant-holds-pty exit, exit code 7, SIGTERM-of-child exit 143 and exit 0 (lines 36-45). It does not cover: final output surviving the reap (M1), SIGTERM/SIGHUP delivered to nfpty itself (the forwarding in M5; the test only has the child kill itself), the mouse reset sequence on exit, the pending queue, or the 0.3s tail flush. `secs < 6` uses integer truncation of the elapsed time. The leftover `setsid sleep 25` outlives the test.
Fix: add (a) a child that prints a marker and exits, assert the marker is in output, (b) `kill -TERM` of the nfpty pid and assert exit 143 with the child gone, (c) assert the output ends with the reset bytes.

T2. tests/tmux-heal.sh "healthy server: no-op" only asserts the server is still reachable (line 31), which a stray SIGUSR1 would also satisfy; it does not prove nothing was signalled or created. It also claims isolation from the real server, but `nf-tmux-heal` scans every tmux socket of the uid via `ss` (nf-tmux-heal:22), so the real server is in scope if its socket is ever missing during the run. `$ROOT` is never removed.
Fix: assert `$ROOT/tmux-uid` is not recreated after the no-op run, add a `trap 'rm -rf "$ROOT"' EXIT` guarded to the mktemp path, and note or avoid the real-server scope (for example by an `NF_HEAL_ROOT` filter honoured by the script).

T3. selfcheck (nfpty.py:306-312) tests single chunks only, so M2, L1 and L2 cannot fail it.

## Sound (no finding)

- Panel writes keep their relative order in `pending` and are flushed after the engine chunk that made them legal (nfpty.py:462-469).
- Exit code mapping `128 - code` for negative codes is correct (nfpty.py:563).
- SIGPIPE reset in the child (363) is correct.
- Tail cap at 24 bytes (243) is right: a real SGR mouse report is at most 16 bytes.
- tmux read timeouts (mklayout.py:223, nfpty.py:124) and the 5s backoff (nfpty.py:176-177) are sound; the backoff only delays hover.
- Heal's uid check on `/proc/$pid`, the `*/tmux-$uid/*` path filter and the exact-comm match prevent signalling the wrong process (nf-tmux-heal:23, 29-30).
- claude-shim loop guard via `readlink -f` (claude-shim:19-23) is correct.
- register.tsx `.map(plain)` (band/hooks/register.tsx:368) is fine, assuming `plain` is defined in scope (not verified here).

## Disposition 2026-10-09 (author)

Fixed: M1 (drain the master after the reap, test: output written just before exit survives), M2 and L2 (boundary tracking is now stateful across chunks and knows ESC-intermediate, SS3, DCS/APC/PM/SOS and OSC; selfcheck covers a three-read split), M3 (queued paints force-flush after 0.5 s and are capped at 64), M4 (the held fragment is dropped, never forwarded as text, and the write that could raise is gone), M5 (SIGKILL after 2 s, test: a child that ignores SIGTERM), L3 (the exit reset goes through the flush), L6 (the installer checks marker order), L7 (the shim imports nfpty itself).
Open: L1 (cursor-visibility tracking over a split sequence), L4 (a recycled pid, vanishingly rare), L5 (a socket path containing a space; tmux's own paths do not have one), and the test gaps noted for tmux-heal (it still reads every tmux socket of the uid, which is why it only ever signals a server whose socket path is missing).


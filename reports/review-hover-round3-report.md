# Hover bridge review, round 3 (commit ae61dcf)

Static read only. Line numbers from Read/rg -n at HEAD.

## Medium

### M1. `flush_pending()` in `finally` is outside any try, so a dead terminal skips the whole cleanup
band/bridge/nfpty.py:611-612 (the `try` that protects the write starts at 613).
`flush_pending()` calls `out.write`/`out.flush`. The SIGHUP path (terminal closed) is the one where stdout raises EIO or BrokenPipeError. The exception now escapes the `finally` before `termios.tcsetattr` (619) and `os.close(master)` (621) run. It also replaces the original exception and skips the reaping at 625-627. Before this commit the only writes in `finally` were guarded.
Fix: move `clean[0] = True; flush_pending()` inside the existing `try ... except (OSError, ValueError)` at 613-617, before the reset write.

### M2. Overflow cap can drop an erase that must run
band/bridge/nfpty.py:585-586. `del pending[:-64]` keeps the newest 64 items and drops the oldest, whatever they are. `pending` mixes paint frames and the `panel.erase()` restore-rows write (600) and the resize erase (481). If the erase is among the dropped items, the panel state says "erased" but the terminal never gets the restore, so a ghost panel stays on screen. The panel's saved-rows bookkeeping is also out of step. The cap is rarely reached (about 14 frames per 0.5s with no engine data), but an engine streaming unclean chunks gets a redraw per chunk.
Fix: on overflow, drop only paint/redraw frames, or collapse the queue to its last item plus any item that contains an erase. Simplest: have Panel tag erase writes (`write(s, keep=True)`) and filter `pending` by tag.

### M3. Stream.carry forgets the enclosing sequence when a partial UTF-8 character is the tail
band/bridge/nfpty.py:252-261 returns `k` (1-3) as soon as a partial character is found, so line 296 keeps only those k bytes. Inside an OSC that contains non-ASCII (Claude Code's title is `ESC ] 0 ; <3-byte glyph> ... BEL`):
- read 1: `ESC ] 0 ; \xe2\x9c` returns 2, carry = `\xe2\x9c`, OSC lost
- read 2: `\xb3 Cla` carry has no ESC, so `incomplete_tail` returns 0 and `feed` says clean
A paint can then land inside the OSC title string. It needs a 3-way split, so rare, but it is the exact class of bug Stream was added for.
Fix: do not return early from the UTF-8 check. Compute the UTF-8 partial count `u`, strip those bytes, run the ESC analysis on `data[:-u]`, and return `max(esc_tail_len, u)` where the ESC tail length is measured on the full `data` (`len(data) - i`). Add a selfcheck: `st.feed(b"\x1b]0;\xe2\x9c") is False; st.feed(b"\xb3x") is False; st.feed(b"\x07") is True`.

## Low

### L1. SIGTERM/SIGKILL test cannot fail
tests/nfpty-exit.sh:60-77 (new block). The child is `trap '' TERM; sleep 6` and the harness waits up to 8s. With the SIGKILL escalation deleted, bash still exits at about 6s, nfpty exits with 0, `rc != 124`, and the check passes. The measured seconds value is printed but never checked.
Fix: assert `rc == 137` and `secs <= 4` (kill at 2s plus slack), or raise the child to `sleep 30` and the timeout check accordingly. The 137 assertion alone proves the SIGKILL path.

### L2. Last-words test is nearly unfalsifiable against the old code
tests/nfpty-exit.sh:44-58. `printf LASTWORDS; exit 0` is written before nfpty's select wakes, so the old ordering (select, then waitpid, then read) also reads it. The race the fix closes needs data to arrive after select returns and before waitpid.
Fix: run the case in a loop (for example 200 spawns of `printf X; exit 0`) and require 200 hits, or accept it as a smoke test and say so in the comment.

### L3. quit_at is reset by every forwarded signal
band/bridge/nfpty.py:461-463. A second SIGHUP/SIGTERM (tmux and shells often send several) restarts the 2s SIGKILL timer, so the deadline can slide indefinitely.
Fix: `if quit_sig[0] is None: quit_at[0] = time.monotonic()`.

### L4. The stdin-EOF exit path has no SIGKILL escalation
band/bridge/nfpty.py:539-540 breaks with `status_box` still None, then 627 does a blocking `os.waitpid(pid, 0)`. A child that ignores the SIGHUP from `os.close(master)` hangs nfpty. The commit added escalation only for forwarded signals. The same applies to the `except OSError: break` at 537-538.
Fix: before 627, poll `waitpid(WNOHANG)` for 2s, then SIGKILL and block.

### L5. Streams over 4096 bytes in one sequence are treated as clean
band/bridge/nfpty.py:296-297. An OSC 52 or similar payload longer than 4096 bytes mid-flight reports clean and clears the carry, so a paint can land inside it. It was already the behaviour before (no limit) in spirit, and is a deliberate tradeoff, but it is undocumented as such.
Fix: leave as is but note it in the comment; the 0.5s deadline already bounds the other direction.

### L6. CRLF markers in an rc file defeat `paired` and duplicate the block
band/hover/install.sh:48. `grep -cxF` on `\r`-terminated lines counts 0 for both markers, so `paired` passes (0 == 0), `strip` removes nothing, and each install appends another block. Multiple markers are handled (count mismatch or `-le 1` fails). The new order check is correct for exactly one BEGIN and one END (line 52, single integers from `grep -nxF`).
Fix: normalise with `tr -d '\r' < "$1" | grep -cxF ...` in `paired` and compare against `$'\r'`-stripped input in `strip`, or refuse files containing `\r` with the "fix it by hand" message.

## No finding

- CSI with intermediates (`ESC [ 1 SP q`): the final-byte scan over `rest[1:]` (271) treats only 0x40-0x7e as final, so `ESC [ SP` is correctly incomplete.
- OSC whose ST `ESC \` is split across reads: bare trailing ESC returns 1 (268), carry is `ESC`, and the next chunk starting with `\` yields `ESC \`, which falls to `done = True` (279). Correct.
- Lone ESC: a trailing bare ESC holds paints until the next chunk or the 0.5s deadline (581-584). Acceptable; the engine does not emit a lone ESC as output.
- Stream.carry growth: bounded to 4096 (296) and cleared on a boundary.
- Post-reap re-select (493): level-triggered, nothing consumed before it, so no double read and no drop. The loop drains in 64 KiB reads until `master not in ready`, then breaks (494).
- SIGKILL when the child already exited: guarded by `status_box[0] is None` (589) and the reap precedes it in the same iteration (487-490), so no kill of a reused pid on this path.
- `pending` accounting at 585: `len > 64` check runs after growth each iteration; fine apart from M2.
- Shim `import nfpty` (claude-shim): module is `__main__`-guarded (632), so import has no side effects.
- Installer order check handles one BEGIN/END pair correctly and the `|| return 1` chaining is sound.

## Disposition 2026-10-09 (author)

All nine fixed: M1 (the exit reset sits inside the try), M2 (queue overflow keeps restore writes and drops old paint frames), M3 (a partial UTF-8 character no longer hides an enclosing OSC; the two tails are computed separately and the larger wins, with a selfcheck for a glyph split inside a title), L1 (the ignored-SIGTERM test now requires 137 within about 4 s), L2 (the last-words case runs 60 times), L3 (the first signal starts the kill clock), L4 (the stdin-EOF path escalates to SIGKILL after 2 s), L5 (the 4096-byte limit is documented), L6 (CRLF rc files are refused rather than re-appended to).


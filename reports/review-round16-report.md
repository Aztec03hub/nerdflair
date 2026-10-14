# Review round 16: hover linger, TERMINAL_NOISE, shadow chmod (HEAD 9af5090)

Static analysis only. Nothing run (no tests, tmux, nfpty, claude).

## Findings, ranked

### 1. MEDIUM - leaving the window off a readout keeps the card up 20 s (nfpty.py:716, 861)
The readout is on the status line, the bottom row of the window (e2e uses row 48 of a 48-row pane). The most common way to leave the window from it is straight down, so the last report is a readout hit, `on_card=True`, and the card stays for `WATCHDOG_ON_CARD` = 20 s. The comment at :716 and the const comment say leaving from the card is rarer. That is true of the card, but line 716 gives the readout the same 20 s, and the readout is the edge case. A resting pointer and a pointer that left downward send the same stream (nothing), so the two cannot be told apart by time alone.
Fix: use position. If the last report's row is the pane's last row, or its column is 1 or `cols` (an edge), use the short `WATCHDOG` for a readout hit. Keep 20 s only for hits on the card rect itself, which is interior. Otherwise, decide on one grace value for readouts. `hover-linger-e2e.py` `readout-rest` (EXPECT 8.0) currently locks the 20 s behaviour in, so it would need to change with the fix.

### 2. LOW-MEDIUM - the card vanishes while the pointer is truly still on it after 20 s (nfpty.py:861)
Reading a long card for more than 20 s without moving drops it (and a readout rest likewise). The card is then gone, the pointer is still on the readout, and nothing reopens it until the pointer moves. This follows from the design, but it is a "vanishes while on it" path.
Fix: accept it and document it, or refresh `last_motion` on any input read, including wheel and key bytes that are not typing.

### 3. LOW-MEDIUM - focus-out (ESC[O) is treated as noise, so it does not hide (nfpty.py:77 and 826)
A focus-out is a strong signal that the pointer left or the window lost focus (alt-tab with the card up). The card then waits 4 s or 20 s.
Fix: if `\033[O` appears in `fwd` and the card is shown, set `hide_at = now`. Keep ESC[I and the device replies as ignored.

### 4. LOW - TERMINAL_NOISE coverage and false matches (nfpty.py:72)
Verified by reading the regex:
- Not stripped, so they count as typing, as you wanted: Alt-i (ESC i), Alt-Shift-I (ESC I), Shift-Tab (ESC[Z), arrows ESC[A..D, ESC[1;5A, a plain `c`, Esc alone, bracketed-paste ESC[200~. `\033\[[IO]` needs the literal `[`, so ESC I and ESC O (SS3 keys) are safe.
- Wrongly stripped (real typing treated as noise, so the card is not hidden):
  - Shift-F3 / Ctrl-F3 arrive as ESC[1;2R / ESC[1;5R and match `\033\[[0-9;]*R`. The pattern also allows zero digits, so ESC[R matches.
  - Alt-[ followed by c (ESC[c), Alt-[ then I or O, all within one read, match as noise.
  - All of these are rare.
- Not stripped, so they count as typing (hide the card):
  - the kitty keyboard query reply ESC[?0u
  - OSC 10/11 colour replies (ESC]11;rgb:..ST)
  - DCS XTVERSION replies
  - ESC[8;r;ct size reports
  - DECXCPR ESC[?r;cR (the R branch has no `[?]?`)
  They arrive mostly at startup or on theme or focus change, so the effect is a spurious hide of a card that is up.
- A sequence split across two reads is not handled. `split_hovers` only holds ESC[<, so a read ending in `ESC[` forwards it, and that leftover is "typed" and hides the card.
Fix: add `\033\[\?[0-9;]*u`, `\033\][0-9;]*[^\a\033]*(?:\a|\033\\)`, `\033P[^\033]*\033\\`, `\033\[\d+;\d+;\d+t` and `[?]?` in the R branch. Require at least one digit in the R branch, or `;` for the modifier form. Hold a trailing `ESC[` plus partial noise in `tail` like the mouse tail.

### 5. LOW - last_motion is refreshed by any mouse match, but on_card is not (nfpty.py:823-824)
`MOUSE.search(fwd)` matches hovers (also handled in `on_hover`), clicks, releases, wheel and drag. Those refresh `last_motion` but never `on_card`, so a stale `on_card=True` keeps the 20 s grace alive for as long as non-hover reports arrive. Cases:
- Drag (button held, code 32..34): not `HOVER_BTN`, so `on_hover` never runs and no 0.25 s hide is scheduled. The card stays up for the whole drag even though the pointer is elsewhere. It clears when hover reports resume.
- A click or scroll at another position: normally preceded by hover reports, so benign.
Fix: only refresh `last_motion` there for codes that carry a position update, and also run the position test (or at least clear `on_card`) for drag and click reports. A simpler option: pass every mouse report's position to the same on-card/hit logic.

### 6. LOW - hover-linger-e2e.py gaps
- It can fail properly (a numeric result outside the window, "card never opened", "card closed while on it"). I found no unreachable expectation. `readout-rest` and `card-rest` pass only on ">8s", which the 8 s cap makes reachable.
- It cannot tell 20 s from, say, 9 s. It only proves that it is not 4 s.
- The pure watchdog path (reports just stop) is not tested for either value, since the 20 s watchdog is above the cap.
- Not tested: terminal noise (ESC[I, ESC[?1;2c) not hiding, focus-out, drag, and typing in the same read as a hover.
- The docstring lists three scenarios, but there are five.
- It hardcodes ROW 48 and cols 6..16 (the card sits on row 46 in `crossed` and `card-rest`). A window shorter than 48 rows gives "card never opened" rather than a real signal.
- `hover-stale-e2e.py` now always passes `NFPTY_LOG` (default /dev/null). That switches `dbg` on in nfpty, so it runs the debug-only code paths (including the restore note that splits `r.stdout`), which production does not.

### 7. LOW - shadow.py
- `_umask_check` as the first statement of `selfcheck()` (shadow.py:193) turns the docstring into a dead string expression. Cosmetic. Move the call below the docstring.
- chmod and the mkdtemp-to-chmod window (52-58): no security race. The dir is only ever more restrictive (0600) until chmod, and only the owner can touch it. The fifo (`mkfifo 0o600`, masked by 0117 to 0600) and `os.open(O_RDWR)` by the owner are fine. If chmod raises, the `except OSError` path sets `why` and `close()` still rmdirs (the dir is empty).
- The tmux socket in a 0700 dir: tmux creates it with its own umask handling, and the dir needs only owner rwx, which chmod provides. Looks right.
- The umask selfcheck is falsifiable in principle: without chmod, the dir is 0600, so the socket bind gets EACCES.
- The ERRLOG line interpolates `shadow.why`, which can be multi-line tmux stderr and so breaks the one-line log format. Collapse it with `" ".join(why.split())`. The log is append-only with no cap, one line per failing window start.
- nfpty.py:168 writes the captured pane rows into the debug log, so pane text ends up in `NFPTY_LOG`. That is acceptable for a debug sink, but worth knowing now that `hover-stale-e2e` enables it by default.

## Checked and found correct
- The ordering of `typed` after `on_hover` (nfpty.py:827-832) works. `hide_at=now` is applied in the same loop iteration, because `now` at :834 is later.
- `MOUSE.sub(b"", TERMINAL_NOISE.sub(b"", fwd))`: a mouse report that survives inside typing text is removed, and only the leftover bytes count as typing. The non-hover mouse reports in `fwd` are therefore not typing.
- The on-card branch does not clear a past-due typing hide.
- The off-card `min()` fixes the crossed-then-leave 3.99 s linger.
- `on_card` reused for a readout hit with the card not yet shown is harmless, since the watchdog requires `panel.shown`.
- The `last_motion[0]` truthiness guard at :861 means a card opened without any report is never watchdogged. That is only reachable if something other than `on_hover` calls `panel.show`; I did not trace that.

## Could not verify
- Whether the engine enables focus reporting (1004), which decides whether ESC[I/ESC[O ever arrive.
- That tmux gives EACCES for a 0600 dir (relied on the commit message and the code comment).
- Where the card rect actually sits relative to the `hover(c, 46)` coordinates in the e2e.
- Whether another caller of `panel.show` exists besides `on_hover`.
- Real terminals' encodings for Shift-F3 and the like.

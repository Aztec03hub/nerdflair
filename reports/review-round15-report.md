# Review round 15 - hover hide logic (read-only, analysis only, nothing executed)

Scope read: `git show HEAD` (0c38a90), band/bridge/nfpty.py (Layout 175-230, split_hovers 247-280, select_timeout 372, main 555-899), panel.py show/reset/erase, mklayout.build_ex skip/truth, hover-linger-e2e.py.

HEAD note: 0c38a90 is the Rust `state_file()` empty-HOME fix plus tests/empty-home.sh. It does not touch the hide logic. The fix itself is correct. Two weak spots in the test (low): rust/src/state.rs is fine, but tests/empty-home.sh:21-25 ignores the binary's exit status (a crash passes), and run as root the new code writes /.claude/nerdflair/state.json outside the checked dir, so the check cannot see it.

Verified clean (traced, no path found):
- on_card going stale across card close/reopen: a card is only ever opened from on_hover (nfpty.py:720-723), and on_hover sets on_card first (683). No stale-True reopen.
- last_motion == 0 with a card up: impossible, show() is only reached via on_hover which sets it (682).
- panel.shown vs panel.rect: set and cleared together in panel.py (127-128, 158-160, 182-184).
- Coordinates: hover cols/rows are 1-based, seg x is +1 (mklayout.py:280), panel rect is 1-based CSI coords; the rect test at 683-684 is consistent (variables named col0/row0 are misleading, nothing more).
- Shadow layout: with truth the skip is dropped (mklayout.py:262-263, nfpty.py:217), so covered readouts are hit-testable, but the on_card early return (685-693) runs before any hit(), so a pointer on the card never reopens/switches to a readout under it.
- Resize: reset() without erase, hide_at left over is harmless (erase no-ops, shown None so watchdog off).
- select_timeout: FRAME whenever shown/rect or hide_at set, so hide and watchdog resolve at frame rate.

## Findings, ranked

1. MEDIUM - typing-hide is cancelled by a hover report in the same read. nfpty.py:805-808 then 719.
   Scenario: one os.read returns a keystroke plus a motion report landing on a readout (fast typing with a jittering mouse, or a paste). 806 sets hide_at=now, then on_hover hit branch sets hide_at=None (719); same-id hit does not re-show, card stays. The comment at 686-690 handles this only for the on-card branch. Also, as 719 never checks due-ness, any later iteration's report on a readout also clears a typing-hide that was somehow still pending.
   Fix: in the hit branch, `if hide_at[0] is None or hide_at[0] > time.monotonic(): hide_at[0] = None` (same guard as 691), and if hit.id != panel.shown while a typing-hide is due, skip show(). Or run the typing-hide after the hovers block.

2. MEDIUM (design) - a pointer resting ON A READOUT loses the card after 4 s, contrary to "stays while the pointer is on the readout". nfpty.py:837 uses WATCHDOG whenever on_card is False, and a resting pointer sends no reports. After the hide, nothing reopens it until the pointer moves. Not distinguishable from leaving the window; the choice is yours. Option: use the long timeout when the last report was on a readout row that is not in the bottom/edge row, or when the pointer was last on card OR readout (`on_card` -> `on_ui`). The e2e does not pin this either way.

3. LOW-MEDIUM - stale layout can hit a readout the pointer is no longer on. nfpty.py:202 (MIN_INTERVAL 0.15 s) and 208-209 (`self.at = now + 5.0` after a slow tmux read) mean hit() at 698 can use segs up to 5 s old. After figures shift, a report on a non-readout cell can match an old seg, which cancels the pending hide (719) and may open the wrong card; it then stays until the 4 s watchdog. Fix: in on_hover, if layout is frozen (at > now) treat hit as None for cancelling purposes, or store the layout's build time and ignore hits older than ~0.5 s.

4. LOW - non-35 motion is invisible to both hover and watchdog. nfpty.py:66-69, 268: only button code 35 is a hover. Motion with a modifier (39/43/51), drags (32+), wheel (64/65) do not update last_motion/on_card. Pointer moved with Shift/Ctrl held away from the card: no hide armed, card stays up to 4 s (20 s if last report was on the card). Fix: accept `b & ~(4|8|16) == 35` as a hover, and treat any mouse report in MOUSE as proof of life (update last_motion) without running hit.

5. LOW - "typing" is any non-mouse forwarded byte. nfpty.py:805. Focus-in/out (\e[I/\e[O if the engine enabled 1004), terminal query replies (DA, CPR, OSC colour) and paste markers hide a card the pointer is truly on. Focus-out hiding is arguably wanted; the others are not. Fix: ignore bytes matching `\e[I`, `\e[O`, `\e[?...c`, `\e[...R`, `\e]...` before the test.

6. LOW (unverified) - erase followed by immediate reshow while pending is held. panel.py:178-184 marks the card gone at once but the write sits in `pending` until `clean` (up to 0.5 s, nfpty.py:819). If a hover report on the same readout arrives in that window, show() runs backdrop.save (panel.py:120) first. With the shadow that reads the engine-only screen so it is fine; with shadow None (nfpty.py:580-582) it would read the live pane that still has the card and save it as "what was under", leaving a permanent ghost. I could not run it to confirm.

7. LOW - on_card persists until the next hover (669). If the pointer leaves with a non-35 report (finding 4) or the last report was on the card and then the card is erased by typing, the 20 s watchdog applies to a state that no longer exists. Harmless because shown is None then, but if a modifier-move reopens nothing it stays benign. No action beyond 4.

## e2e: can it fail? (hover-linger-e2e.py)

- direct (76): bounds 0.0-1.0, PASS unless the card is still up after 1 s or never opens. Can fail. OK.
- crossed (55-58, 76): lower bound is 0.0, so a card that closes DURING the card crossing is reported as "0.00s" and passes. It does not prove the card survives the crossing. Also hover cols 8,12,16 at row 46 assume a card at least 13 cols wide from x=4 (w>=12 gives cols 4-15): col 16 may be off-card, so it may not even test on-card. Fix: after the crossing, assert card(target) is still True before the far hover.
- card-rest (59-60, 76): can fail (a card gone at 4 s gives 4.0, outside 8.0-8.0). It cannot detect a watchdog regression from 20 s to anything above 8 s, and it only exercises the pointer-on-card case, nothing for findings 1, 2, 3.
- Failures to set up (window not created, nfpty crash) return "card never opened" -> counts as FAIL in all three scenarios. Good.
- Missing: typing-hide, resting on readout, readout under the card (shadow), resize while a card is up.

## Could not verify
Nothing run (no tests, tmux, nfpty). Real terminal behaviour for pointer-leave (no report vs. a last edge report), whether the engine enables mode 1004, and finding 6's ghost are from reading code only. Serena was unavailable; used Read and rg.

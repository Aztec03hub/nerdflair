# Review round 8: nerdflair e392d9e (round 7 fixes) and 9f5cc46 (round 6 fixes)

Read-only static review of `git show HEAD`, `git show HEAD~1`, plus `band/bridge/shadow.py` and `band/bridge/nfpty.py` (Guard, main loop, on_hover, Backdrop, Layout, Stream), and `panel.py` show/erase/reset. Nothing was executed. Line numbers are from Read of the current files.

## Verdict

No Critical, High or Medium finding. All five round-7 fixes are correct as written. Findings below are Low or nits.

## Fix-by-fix verification

1. **Feed order (nfpty.py:742-746): correct.** `clean[0] = stream.feed(data)` now runs before `shadow.feed(data, clean[0])`, so the shadow gets the boundary flag of the bytes just read. `out.write` still comes first (737-741), so a shadow problem cannot delay the real terminal. `Shadow.feed` never raises (non-blocking write, `BlockingIOError` and `OSError` caught, shadow.py:80-90). `sync()` calls `self.feed(mark)` with the default `clean=True` (shadow.py:101), which resets `self.clean` to True, but only after the guard at line 97 has already seen `clean` True, so it is harmless.
2. **Stall override vs shadow (nfpty.py:798-801): consistent and safe.** The override sets only `clean[0]` and flushes our pending writes. `shadow.clean` is deliberately not touched, so during a real stall the shadow keeps refusing to sync (`capture` returns None, callers read the live pane, the old behaviour). It recovers on the next engine read, which reports its own flag. Our bytes never enter the shadow, so the override cannot corrupt it. There is no ordering hazard between the three.
3. **`_drop_card` / `flush_pending` (nfpty.py:611-615, 660-666): correct and safe from the Guard path.** `flush_pending` is defined at 611, long before `_drop_card` (660), and is a closure over `pending`, `clean` and `out`, so no ordering problem. It only writes when `clean[0]` is True; otherwise the queued erase (queued by `panel.erase`, keep=True) waits for line 753 or the stall override at 798. If `erase()` raises, `finally` still resets and flushes; any exception then goes to the `except Exception: pass` at 543-544. Order in `pending` is preserved, so queued card paints are followed by the erase.
4. **on_hover early return (nfpty.py:669-677): correct.** SGR mouse coordinates are 1-based, as are `panel.rect` x and y (`panel.py:108-127`), and `layout.hit` compares in the same space, so the containment test is right. Typing sets `hide_at = time.monotonic()` (785), which is `<= monotonic()` at the next call, so it is not cancelled in the same-chunk case (fwd is handled before hovers at 782-787). A timer-scheduled hide still in the future is cancelled. The due check at 814 runs in the same iteration, so a "stays due" hide is executed at once.
5. **Sync cooldown paths (shadow.py:93-114): correct.** Stalled sync and hung tmux both set `cool = now + 2 s` and return False. `capture` returns None, `Layout` treats this as `truth=False` and keeps covered rows (nfpty.py:209), and `Backdrop` falls back to the live pane or the saved rows. No path leaves the shadow trusted when unsynced.
6. **`stty raw -echo` (shadow.py:59): correct.** `stty` acts on the pane tty (the redirect applies only to `cat`). The engine's bytes already carry CR LF from the claude pty's ONLCR, so raw mode (no further translation) is more faithful, and the shadow's query replies are no longer echoed.

## Findings

### L1. Selfcheck can fail by timing, and a failed first sync blacks out the shadow for 2 s
`band/bridge/shadow.py:93,113` (budget 0.05, cooldown 2.0) and the check at 172-179.
Scenario: `Shadow(10, 40)` returns as soon as tmux has spawned the pane. The shell still has to run `stty` and `exec cat`, and only then is the queued fifo data read. The check feeds and calls `capture("-e")` at once. The first `sync` has 50 ms. If shell plus cat start takes longer (loaded WSL, cold tmux), the sync times out, `capture` returns None, `assert r is not None, "capture failed"` fires, and the 2 s cooldown makes every later assert in the check fail too. The old 0.15 s budget hid this. In production the same stall can happen under a heavy engine burst (a parse backlog over 50 ms), costing 2 s of live-pane fallback per stall, with stale restore rows (see L3).
Fix: in `selfcheck`, warm up with `assert sh.sync(budget=2.0)` before the first `capture`, and reset `sh.cool = 0.0` after the deliberate `clean=False` step. Optionally cut the production cooldown to about 0.5 s, or time-box the cooldown only when the stall repeats.

### L2. A card the pointer leaves from the card itself never hides if the pointer exits the terminal
`band/bridge/nfpty.py:673-677`.
Scenario: the user moves the pointer up onto the card, then out of the terminal window. No further hover reports arrive, `hide_at` is None, and nothing schedules a hide. The card stays until a key press or the pointer returns. Before round 6 the move onto the card gave `hit is None` and scheduled the hide. (The same trait already existed when leaving from a readout, but the card is the likelier place to rest the pointer.)
Fix: when on the card, set `hide_at[0] = time.monotonic() + HIDE_LONG` (for example 3 to 5 s) instead of None, refreshing it on every event, and still never replace a due value.

### L3. Fallback path can restore stale rows or capture card remnants
`band/bridge/nfpty.py:134-141, 153-157`.
Scenario: during the 2 s cooldown, or while the stream is unclean, `Backdrop.restore` keeps the rows saved at open, so a status line that changed meanwhile is restored to the old value until the engine repaints. `Backdrop.save` falls back to `tmux capture-pane` of the live pane, which can still show the previous card if our erase is queued in `pending` (unclean stream) or not yet parsed by the outer tmux (async). The card's cells then become the "backdrop" and a ghost comes back on the next restore. This is the pre-shadow behaviour, but round 6 made the fallback much more frequent (every unclean chunk, every stall).
Fix: when the shadow is wanted but momentarily cannot answer, skip opening a new card (return from `on_hover` without `show`) rather than saving from the live pane; for restore, prefer blanking the card rect over the stale saved rows only if the saved rows are older than the last known status change.

### L4. `Stream.feed` calls a stream "clean" after 4096 bytes of unfinished sequence, and the shadow inherits that
`band/bridge/nfpty.py:357-358` feeds the flag at 746.
Scenario: a very long OSC or DCS payload (OSC 52 clipboard, an image) whose read ends inside it with `n > 4096` reports clean=True. The sync mark's ESC then aborts the sequence in the shadow only (the real terminal is unaffected), and the shadow screen can show payload bytes as text. Very unlikely for Claude Code output.
Fix: keep a separate `Stream.strict` boundary flag (no 4096 cutoff) for the shadow; keep the cutoff only for our own paint gating.

### L5. A dead shadow tmux is never marked off; a hung `capture-pane` has no cooldown
`band/bridge/shadow.py:110-114, 123-126`.
Scenario: the private tmux server dies (killed, OOM). `display-message` returns non-zero every time, the loop spins until the 50 ms budget, and the cooldown re-arms every 2 s forever, so each hover costs a 50 ms stall about every 2 s and the shadow never reports `ok=False`. Separately, a `capture-pane` that times out (0.5 s) returns None with no cooldown, so each hover can block 0.5 s in the relay thread.
Fix: treat `returncode != 0` (or "no server") as `self.ok = False`; set `self.cool` in the `capture-pane` exception path too.

### Nits
- `nfpty.py:665`: `flush_pending()` in `_drop_card` is nearly redundant, since `write()` already flushes (620) and `reset()` writes nothing. It is harmless and does help if `erase()` returned early with unflushed leftovers.
- `nfpty.py:670` and 681 read `hovers[-1]` twice; use the first pair.
- `nfpty.py:675`: a hide that came due by timer within the same loop pass (up to one FRAME, about 36 ms) as a pointer move onto the card is still executed. Negligible.

## Test gaps

No check covers the feed ordering at 742-746 or the early return, both inline in `main()`. A regression of the round-7 ordering bug would pass `--nfpty-selfcheck` and `shadow.py` selfcheck. Fix: extract the per-chunk step into a small function `relay_chunk(data, stream, shadow, clean)` returning the flag, and assert against a fake shadow that the flag passed equals the stream's result for that chunk (split-sequence case).

## Could not verify

- Nothing was run: no tmux, no timing. L1's start-up race and L5's cost are reasoned from code, not measured.
- `mklayout.build_ex` and `Panel.paint/advance` internals were not re-read beyond what is cited.
- Whether `HIDE_AFTER` is long enough to make L2 matter in practice, and its value, were not checked.

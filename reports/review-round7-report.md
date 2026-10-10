# Review round 7: nerdflair 9f5cc46 (round-6 fixes)

Read-only static review. Nothing was run. Line numbers are from Read of the current files.
Severity: H = high, M = medium, L = low.

## Findings

### H1. The `clean` flag passed to the shadow is one chunk stale, so the round-6 M1 fix does not work in the real loop
`band/bridge/nfpty.py:740-741`:
```
shadow.feed(data, clean[0])
clean[0] = stream.feed(data)
```
`clean[0]` is read BEFORE `stream.feed(data)` updates it, so the shadow gets the cleanliness of the PREVIOUS chunk, not of the bytes it was just given. `shadow.py:73` stores that as `self.clean`, and `sync` (`shadow.py:97`) trusts it.
Failure scenario (the original M1 bug, unchanged): chunk N-1 ended clean, chunk N ends `ESC[3`. The shadow is told `clean=True` for chunk N. The same loop iteration then reads stdin, and a hover calls `on_hover` -> `Layout.refresh`/`Backdrop.save` -> `capture` -> `sync`. The sync mark `ESC ] 2 ; nfsyncN BEL` is injected inside the open CSI, tmux aborts it, and the next chunk's `1mred` is drawn as literal text on the shadow screen. That screen is then used as truth (`mklayout.py:262-263` drops `skip`) and written back by `Backdrop.restore`.
The reverse also happens: chunk N-1 unclean, chunk N completes it. The shadow is told `clean=False`, so `capture` returns None needlessly. That one is safe but wasteful.
The selfcheck (`shadow.py:185-189`) passes `clean` explicitly, so it never exercises this wiring and passes anyway.
Fix: compute the flag first, then feed.
```
c = stream.feed(data)
if shadow is not None:
    shadow.feed(data, c)
clean[0] = c
```
`stream.feed` does not depend on the shadow, so the reorder is safe. Add a check of the ordering (a `Stream`-plus-`Shadow` test that feeds `ESC[3` through the same two calls and asserts `capture() is None`).

### M1. The 0.5 s "stalled engine" override is not seen by the shadow
`nfpty.py:793-796` sets `clean[0] = True` after 0.5 s in an unfinished sequence. `shadow.clean` stays False until the next `feed`, so captures return None for as long as the engine is silent. This is the safe direction (live-pane fallback), but it means a stalled engine means no shadow reads, and the comment at 791 implies we resume. Fix: say so in a comment, or accept it. No code change needed once H1 is fixed.

### M2. `sync` has an unbounded-ish stall path with no cooldown
`shadow.py:106-108`: `_tmux(... display-message ...)` uses the default `timeout=0.5`. A hung tmux raises `TimeoutExpired`, `sync` returns False via the `except` and sets NO cooldown (the cooldown at line 112 is only set when the loop times out). Every `Backdrop.save`, `restore` and `Layout.refresh` (which can run every 0.15 s) then blocks the relay for another 0.5 s. `Layout` has a 0.3 s backoff (`nfpty.py:200-201`), but `Backdrop` does not.
Fix: set `self.cool = time.monotonic() + 2.0` in that `except` as well. Same for `capture-pane` failures at `shadow.py:124-125` (optional).

### L1. Budget cut to 0.05 s makes the 2 s cooldown likely on a loaded machine
`shadow.py:93,103-113`. Each poll spawns a tmux process (several ms, tens of ms on WSL under load) plus 5 ms sleep, so 0.05 s allows roughly 2 to 4 polls. The first poll comes right after the write, before cat and tmux have parsed it, so a slow spawn can end the budget on a sync that would have succeeded a few ms later. Result: a 2 s blackout where every read falls back to the live pane (with the card-leftover problem the shadow exists to fix). Not a correctness bug. I could not measure it. Fix: budget about 0.1 s, or make the cooldown 0.5 s and keep it for the timeout case only.

### L2. A pointer on the card also stops the typing-hide
`nfpty.py:779-780` sets `hide_at = now` when a chunk contains keystrokes, then `nfpty.py:781-782` runs `on_hover`, whose new early return (`nfpty.py:671-674`) sets `hide_at[0] = None`. If one read holds both a keystroke and a hover report that lands on the card, the hide is cancelled and the card stays after typing. Rare (needs both in one 64 KB read). Fix: in the early return, do not clear a hide that was scheduled by typing (for example set a `typed` flag, or process hovers before the keystroke check).

### L3. Early return: behaviour checked
- Rect order is `(x, y, w, h)` (`panel.py:127`), and `on_hover` uses `rect[0]/rect[2]` for columns and `rect[1]/rect[3]` for rows (`nfpty.py:671-672`). Correct, and 1-based like the SGR report.
- Cannot get stuck as long as the pointer ever leaves: any motion event off the card and off a readout schedules `hide_at` (`nfpty.py:691-693`); a motion event on a readout cancels it. A pointer that rests on the card and then leaves the window sends no event, so the card stays. That was already true for readouts, so not a regression.
- Cost: a card that sits over another readout's row (multi-row band, or the tiny-terminal clamp at `panel.py:114-116`) hides that readout while the pointer is on the card. Intended by the fix.
- `hide_at` is left correct: cleared on the card, set by the normal path elsewhere. The skipped `layout.refresh` only delays layout updates, which is fine.

### L4. Guard cleanup: checked, one note
`nfpty.py:660-666`: `erase()` then `reset()` in `finally`. `erase` queues the restore via `write` (`panel.py:178-182`, `keep=True`), which is sent at the next `flush_pending` (every master read, and in the `finally` at `nfpty.py:826-827`). If `erase` raises, `reset` still runs and the exception reaches `Guard.run`'s inner `except` (`nfpty.py:543`), so no loop break. If the failure was an `OSError` from `out.write` (terminal gone), `write()` leaves the text in `pending` and `erase` raises before `rect = None`; `reset` then clears it. Fine. Note: after a failure inside `show` before `rect` is assigned (`panel.py:117-127`) there is nothing to erase, which is correct because the old card was already erased at line 118.
Residual: when hover is disabled the erase text sits in `pending` until the engine next writes. If the engine is idle, the card stays visible until then. Fix (optional): call `flush_pending()` from `_drop_card` after `reset()`.

### L5. `stty raw -echo; exec cat < 'fifo'`: checked, no problem found
- Quoting: the command is one argv element passed to `new-session`, run by tmux as `$SHELL -c`. `shlex.quote` of a `mkdtemp` path is safe in sh, bash and fish. `stty` failing does not stop `exec cat` (`;`).
- Raw mode: cat reads the fifo, not the tty, so input flags only affect tmux's replies to queries (now not echoed, and unread input is simply buffered by the pty). The output side matters: raw clears OPOST/ONLCR, so the shadow no longer adds a CR to each LF. The real terminal is also raw (`tty.setraw`, `nfpty.py:633`), so the shadow is now MORE faithful than before. The engine's pty already applied its own translation before the bytes reach nfpty. No change to how tmux parses the bytes.
- A tiny window exists between pane start and `stty` where a reply could be echoed; negligible.
- Could not verify: the `$SHELL` fish path and `stty` availability on minimal images.

### L6. Resize rc handling: checked
`shadow.py:132-133` turns the shadow off on a nonzero rc. Correct and safe (fallback to live pane). Note it is permanent: a transient `TimeoutExpired` (line 134) or one failed call disables the shadow for the session. Fix (optional): retry once, or recreate the shadow. Could not verify `resize-window` behaviour on tmux older than 2.9 (it does not exist there, so the first resize would disable the shadow, which is acceptable).

### L7. Can anything else see the shadow server? No problem found
- Private socket `-S <mkdtemp 0700 dir>/s`; every `_tmux` call passes `-S` explicitly (`shadow.py:35`), and nfpty's own live-pane `tmux` calls (`nfpty.py:138`, `mklayout.py:258`) use no `-S`, so they hit the user's server via the inherited `$TMUX`. The two never cross.
- A user's default `tmux attach`/`ls` cannot see it (different socket). Only someone who runs `tmux -S <that path>` could attach, and the directory is 0700.
- `nf-tmux-heal` (`band/hover/nf-tmux-heal:29`) only signals sockets under `*/tmux-<uid>/*`, and the shadow lives in `nf-shadow-XXXX`, so it is never signalled.
- The fifo fd is close-on-exec, so the tmux server and claude do not inherit it (a SIGKILL of nfpty closes it, cat sees EOF, the server exits).
- Residue after SIGKILL: the `nf-shadow-*` directory (already noted in round 6, not fixed here).

### L8. Stale prose still present (carried over from round 6 L7)
`nfpty.py:99-115` (Backdrop docstring), `nfpty.py:811-812` ("saved from tmux"), `mklayout.py:250-252`, and `shadow.py:20-22` ("any failure turns it off": a failed sync does not, it cools off). The selfcheck at `shadow.py:204-213` still exercises the EBADF path, not `MAX_BACKLOG`.

## Checked and correct
- `capture` returning None on failed sync, and the three call sites handle None (`nfpty.py:134-141`, `nfpty.py:155-157`, `mklayout.py:254-263`). With None, `build_ex` falls back to the live pane with `truth=False`, so `skip` is honoured.
- `sync`'s own `self.feed(mark)` (`shadow.py:101`) sets `self.clean = True`, which is right because it only runs when clean was true.
- 2 s cooldown logic (`shadow.py:97,112`) is consistent: monotonic clock, only set on a budget timeout.

## Could not verify
Nothing was executed: no tmux behaviour, no timing for L1, no check of `$SHELL` variants, and no tmux version differences. `panel.cursor_visible` writers elsewhere were not searched.

## Verdict
One real defect (H1): the main fix of the round does not take effect in the relay loop because of argument ordering. Everything else is low severity. The H1 fix is a two-line reorder.

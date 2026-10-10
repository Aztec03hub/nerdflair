# Review round 6: nerdflair 838976c, 99e298f, dc0edf8

Read-only static review of `git diff 838976c~1 dc0edf8` plus the current files. Nothing was executed.
Severity: M = medium, L = low. No Critical or High found. Line numbers are from current files.

## Findings

### M1. Shadow desync: the sync mark is injected into an unfinished escape sequence
`band/bridge/shadow.py:614-631` (`sync`), fed from `band/bridge/nfpty.py:728-730`.
`shadow.feed(data)` runs on every 64 KB pty read, wherever the read ended. `sync()` then appends `ESC ] 2 ; nfsyncN BEL` straight after whatever the shadow has received, without asking whether the engine's stream is on a sequence boundary. The relay already computes that (`Stream.feed`, nfpty.py:343-358) but never tells the shadow.
Scenario: a read ends at `...ESC[3` or in the middle of a UTF-8 glyph. A hover fires, `capture()` calls `sync()`, and the mark's ESC aborts the CSI or UTF-8 character in tmux's parser. The next read's `1mred` then lands on the shadow screen as literal text, and the SGR is lost. Backdrop.save/restore and the layout scan then read that screen as truth and write the garbage back over the real status line.
Fix: have the relay pass `clean[0]` to the shadow and only sync when it is true. Otherwise `sync` returns False and `capture` returns None, so the caller reads the live pane. Alternatively, buffer the shadow's feed and flush only up to the last clean boundary.

### M2. `capture()` ignores whether `sync()` succeeded
`band/bridge/shadow.py:638` (`self.sync()` result dropped), then `mklayout.py` `build_ex` sets `truth = r is not None`.
Scenario: the fifo is full, or cat/tmux is behind. `sync` times out after 0.15 s and returns False. `capture` still returns a screen that lacks the latest bytes. `build_ex` marks it `truth=True` and drops `skip` (mklayout.py, the `if truth: skip = ()` line). Backdrop.restore then writes a stale or half-parsed row.
Fix: `if not self.sync(): return None`, so callers fall back to the live pane. That fallback is what the module docstring promises.

### M3. A teardown path leaves a visible ghost card
`band/bridge/nfpty.py:285-289` (`Guard.run` cleanup), calling `panel.reset()` (`band/bridge/panel.py:154-163`).
`reset()` explicitly does not paint. After any guarded exception the card stays on screen. Hover is now off for the session, so `erase` never runs, and the engine repaints only the rows that change.
Fix: make the cleanup `try: panel.erase() except Exception: pass` and then `panel.reset()`. `erase` has the backdrop fallback, so it is safe. If erase itself was the failing call, reset alone is acceptable, but then also write a clear-rows fallback.

### M4. Relay loop can block for tens to hundreds of ms per hover
`band/bridge/shadow.py:614-643`; callers are `Layout.refresh` (nfpty.py:194-210, up to every 0.15 s of pointer motion), `Backdrop.save` and `Backdrop.restore`.
Each capture now spawns 1 to ~30 `tmux display-message` processes (5 ms sleep plus spawn) and then `capture-pane`. Worst case is 0.15 s sync plus a 0.5 s capture timeout, all on the thread that reads the pty. While that thread is blocked the engine's pty fills, so typing and rendering lag. The 0.3 s backoff (nfpty.py:197-201) only reacts after the stall has happened.
Fix: cheaper sync (poll once or twice with a longer sleep, or check `pane_title` only after cat has drained). Cap total time per refresh. Count `sync` time toward the backoff. I could not measure this.

### M5. Possible echo of tmux's query replies into the shadow screen (not verified)
`band/bridge/shadow.py:581-583`. The pane runs `exec cat < fifo` on a default cooked pty, so ECHO is on.
If the engine emits terminal queries (DA1, DA2, CPR, XTVERSION, kitty keyboard query), the private tmux answers them by writing the reply into the pane's input. With ECHO on, that reply is echoed back as visible text (`^[[?1;2c`) at the shadow cursor. That corrupts captured rows and is written back by restore.
I could not run it, so this is a hypothesis.
Fix: `"stty raw -echo; exec cat < ..."`, or `-echo` plus `-onlcr`, in the new-session command. Add a selfcheck that feeds `ESC[c` and asserts the screen stays blank.

### L1. Shadow directory leaks on SIGKILL, SIGINT or early exceptions; orphan tmux server is bounded
`band/bridge/shadow.py:574` (mkdtemp), `nfpty.py:572` vs the `try:` at nfpty.py:690.
SIGKILL of nfpty: the O_RDWR fifo fd closes, cat sees EOF, the pane dies and the server exits. Good, no orphan server. But `nf-shadow-XXXX/` with the fifo stays in `$XDG_RUNTIME_DIR` or `/tmp` on every SIGKILL.
The same leak (and the server until process exit) happens when anything raises between `Shadow(...)` (nfpty.py:572) and the `try` at nfpty.py:690: `pty.fork`, `open(NFPTY_LOG)`, `Panel(...)`, non-termios errors from `setraw`. A KeyboardInterrupt in that window also leaks.
Fix: move the shadow into the try/finally (create before, close in the outer finally). Name the dir `nf-shadow-<pid>-` and sweep dirs whose pid is dead at startup.

### L2. Shadow.resize ignores a failing tmux and keeps trusting the shadow
`band/bridge/shadow.py:645-651`: only exceptions set `ok = False`. A non-zero return code leaves the shadow at the old geometry, and `capture` rows are then wrong but treated as truth.
Fix: check `r.returncode != 0` and set `ok = False` (or recreate the shadow).

### L3. With the shadow, hover regions under an open card become hoverable
`band/bridge/nfpty.py:204-210` (`keep = () if truth else covered`) and `on_hover` (nfpty.py:663-688).
Scenario: a multi-row status band where a card covers part of another readout's row. The old code skipped those rows. Now the segment under the card is live, so moving the pointer inside the card to read it can open a different readout's card.
Fix: in `on_hover`, if `panel.rect` contains `(col, row)`, treat it as "on the card": cancel `hide_at` and return.

### L4. SIGWINCH latency raised to 250 ms when idle
`band/bridge/nfpty.py:361` (`IDLE = 0.25`) and the select call at nfpty.py:701.
Python retries `select` after the handler (PEP 475) with the remaining timeout, so a resize sets `resized[0]` but is applied only after up to 0.25 s, where it was 36 ms. The claude child gets the new size late. Reaping and EIO still wake `select`, so only resize is affected.
Fix: `signal.set_wakeup_fd` on a self-pipe included in the select set (also removes the reason for polling), or accept the 250 ms and say so in the comment.

### L5. Tests that cannot fail, or do not test what they say
- `band/bridge/shadow.py:699-701`: the resize check is `len(small.stdout.rstrip("\n").split("\n")) <= 7`. Content is only on rows 2 and 4, so trailing-blank stripping gives at most 4 lines even if `resize-window` did nothing. Fix: draw on the last row of the 10-row screen, or assert `display-message -p '#{pane_height}'` is 7.
- `band/bridge/shadow.py:713-722`: the comment says "too far behind turns it off", but the test sets `fd = -2` and exercises the EBADF path. `MAX_BACKLOG` is never exercised. Fix: set `MAX_BACKLOG` small on the instance, point `fd` at a full non-blocking pipe, and assert `ok` is False.
- `band/bridge/hover-stale-e2e.py:30,56`: ROW=46 and the pointer position `48` assume a 48-row window. `tmux new-window -d` uses the session's size, so on other terminals it reports "NO CARD OPENED". It is also not listed in `tests/bridge-selfchecks.sh`, so nothing runs it. `FLAG` is a fixed `/tmp/nf-stale.flag` (a predictable-path symlink target, no concurrency safety), and `{HERE}` is unquoted in the command (spaces break it). Fix: size the window explicitly with `new-window` plus `resize-window`, use mkstemp for the flag, `shlex.quote` the paths.
- `tests/tmux-heal.sh` two-server case: "healthy server never signalled" is checked by socket inode equality. tmpfs and ext4 can reuse the just-freed inode, so a wrongly signalled server can still pass. Fix: compare `stat -c '%i %.9Z'` (ctime) or the server's SIGUSR1 count via `/proc/PID/status`.

### L6. install.sh PATH dedupe misses adjacent duplicates; backup overwritten on any later change
- `band/hover/install.sh:30-32`: `${_nf//:$HOME\/.nerdflair\/bin:/:}` does not overlap matches. `:S:S:a:` becomes `:S:a:`, so one extra shim entry survives. Fix: loop `while [[ $_nf == *":$HOME/.nerdflair/bin:"* ]]`. `tests/install-rc.sh` has no duplicate case.
- `band/hover/install.sh:88`: `cp -p "$f" "$f.nf-backup"` runs whenever the new block differs, so a second install after the user edited the rc replaces the pristine backup with a file that already holds the block. Uninstall then keeps it (correctly, via `cmp`), but the original is lost. Fix: create the backup only if it does not exist.
- `band/sync-local-plugin.sh:25`: `rm -rf` of `types` before `cp -rf` is not atomic. If `cp` fails, or Claude Code reads the directory meanwhile, the installed plugin has no types. Fix: copy to `types.new` and `mv`.

### L7. Stale prose
- `band/bridge/nfpty.py:99-115` (Backdrop docstring): "WHY NOT MODEL IT OURSELVES: that is a terminal emulator... recover information tmux has already parsed." Backdrop now reads a private tmux fed by the engine's bytes, and "runs twice per panel... what it reads is only ever written straight back" omits the shadow's per-restore re-read.
- `band/bridge/nfpty.py:800-802`: "erase() puts back the rows saved from tmux" is now "re-read from the shadow at hide time".
- `band/bridge/mklayout.py` `build_ex` docstring still opens with "Every readout on the status line of `target`, or [] ..." and "the caller keeps what it knew" for skipped rows. Both now hold only when `truth` is False.
- `band/bridge/shadow.py:22-26` says "any failure turns it off". It does not: M2 and L2 are failures that do not.

### L8. Smaller notes
- `band/bridge/nfpty.py:282-289`: `Guard.run` also absorbs `OSError` such as EPIPE or EIO from `out.write` inside panel code when the terminal has gone. The log gets a false "bug" entry. The main loop still ends on its own next write, so this is benign.
- `ERRLOG` (nfpty.py:249) is append-only with no cap.
- `band/hooks/register.tsx:302-376`: `inflight` is cleared only when the promise settles. `$.process.run` has `timeoutMs`, but `$.session.usage()/cwd()/id()/model()` do not. If one of those never resolves, every later render awaits the same promise and the band freezes. Before this change each render spawned its own. Fix: wrap the shared promise in `Promise.race` with a timeout (e.g. 8 s) that also clears `inflight`.
- `register.tsx:236-237`: `len` counts code points, not cells, so a wide CJK character is still counted as 1 (the comment says "cells"). Acceptable, but the wording overstates it.

## Checked and found correct
- `Stream` cursor tracking over `carry+data` (nfpty.py:343-358) is right. A match inside the carry could be seen twice, but ordering stays correct since the last one wins. The selfcheck exercises the split cases with a real control.
- Shadow partial-write handling: `_drain` keeps order, `BlockingIOError` is caught before `OSError`, and the 4 MB cap cannot deadlock because writes are non-blocking.
- `shlex.quote` on the fifo path is correct for `sh -c`. Temp dir is 0700 and fifo 0600. The fd is O_CLOEXEC by default, so claude and the tmux server do not inherit it.
- Resize ordering: `set_winsize(master)`, then `shadow.resize`, then the engine's redraw bytes are read afterwards. The WINCH-in-the-gap handling (nfpty.py:575-598) recovers via the second `resized[0] = True`.
- `nf-tmux-heal` regex matches the `ss -xlnp` column layout (path, inode, `*`, peer inode, process).
- `tests/install-rc.sh` uses a throwaway HOME, a systemctl stub, and an rmtree guarded by prefix and symlink checks. `rm -f`/`rmdir` in uninstall touch only names install created.

## Could not verify
- No code was run: no tmux behaviour (M5 echo, `resize-window` semantics, SIGUSR1 inode behaviour), no timing for M4.
- Whether `Panel` assigns `cursor_visible` anywhere other than nfpty.py:736. The rg guard blocked that search, so the unconditional per-chunk overwrite (`panel.cursor_visible = stream.cursor`) is unchecked for clobbering a Panel-set value.
- `Panel.show/paint/advance` internals and `mklayout.classify` were not reviewed beyond the diff.
- Whether Claude Code actually emits terminal queries (M5).

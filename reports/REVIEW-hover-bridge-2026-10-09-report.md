# Review: hover bridge (nfpty, panel, mklayout, shim, install, heal, sync, register.tsx)

2026-10-09. Static read only, nothing executed. Line cites come from Read output.
Paths are under /home/plafayette/nerdflair/band unless noted.

## High

### H1. Panel bytes are injected into the output stream at arbitrary chunk boundaries
bridge/nfpty.py:378-402 (redraw right after `out.write(data)`), :450-455 (paint on every FRAME tick).
`os.read(master, 65536)` returns whatever the pty delivered, and the kernel splits large engine frames (4 KB flip-buffer granularity). A chunk can end mid CSI sequence, mid OSC, or mid UTF-8 character. `panel.redraw()` (panel.py:113-134) and `panel.paint()` then write `ESC[s ...` straight after that fragment, so the terminal sees the engine's half-sequence swallowed by ours and the tail of the engine's sequence (`1m`, the second byte of a glyph) printed as literal text. The 28 fps `paint` in the timeout branch does the same between two partial reads.
Fix: keep a `pending_tail` for the relayed output. After each forwarded chunk compute whether it ends cleanly (no unterminated ESC/CSI/OSC, no incomplete UTF-8 lead byte; also skip while inside `?2026h` ... `?2026l`). Inject `redraw()` and `paint()` only when clean. Cheap extra guard: after `out.write`, do `select([master],[],[],0)` and defer the redraw if more is already queued.

### H2. nfpty never exits if anything else still holds the pty slave
bridge/nfpty.py:376-384 (only EIO or empty read ends the loop).
EIO arrives only when every slave fd is closed. Claude Code spawns MCP servers, background jobs and daemons that inherit the tty as stdio. After claude exits, a surviving descendant keeps the slave open, the master never reports EIO, and the user's pane hangs on a dead session. The `waitpid` at :464 is not reached.
Fix: also reap the child inside the loop. Use `os.waitpid(pid, os.WNOHANG)` each iteration (the select timeout is 36 ms), or a SIGCHLD handler that sets a flag. On exit, drain the master with a zero-timeout read loop, store the status, and break. Reuse the stored status for the exit code.

### H3. Synchronous tmux subprocesses in the relay loop freeze the whole session
bridge/nfpty.py:417 -> :168-179 -> mklayout.py:221-225 (`timeout=2`); bridge/nfpty.py:102 -> :121-124 (`timeout=1`).
While `capture-pane` runs, no engine output is relayed and no key is forwarded. When tmux is wedged (the exact socket-deleted case nf-tmux-heal exists for), each hover burst blocks 1-2 s, repeatedly (MIN_INTERVAL is only 0.15 s). Typing and rendering stall in a way that looks like a hung claude.
Fix: back off after a failure or timeout. After one timeout or non-zero return, set `layout.disabled_until = now + 30` and make `Backdrop.save` fail fast the same way. Better, run capture in a worker thread and have the loop poll its result. Also cut the timeouts to 0.3 s.

### H4. Held "possible mouse report" tail can swallow all keyboard input
bridge/nfpty.py:231-237 (`rfind(ESC[<)` then `not MOUSE.match`).
Any trailing `ESC [ <` that is not a complete report is held, with no length cap and no timeout. If it is not followed by a valid report, e.g. `ESC[<x` from a paste, a mangled sequence, or Alt-[ then `<`, every later chunk is prepended to it. `rfind` finds the same cut and the tail grows, so the engine gets nothing until a real mouse report happens to complete. Mouse reports save you only while the engine has a mouse mode on; in a dialog without mouse mode, typing is dead. selfcheck (:263-264) tests `ESC[A` only and so never exercises this.
Fix: hold only a true prefix: `re.compile(rb"\033(\[(<[0-9;]{0,12})?)?$")` on `rest`, cap the tail at about 24 bytes, and flush it when `time.monotonic() - tail_since > 0.05` (the select timeout already wakes the loop). Add a selfcheck case `ESC[<zz` then `a` and assert both are forwarded.

## Medium

### M1. Terminal is not restored on SIGTERM/SIGHUP or crash; no mouse-mode reset
bridge/nfpty.py:359 (only SIGWINCH handled), :456-462.
SIGTERM and SIGHUP take the default action (process dies, `finally` does not run), so the user's tty stays raw. SIGINT from outside raises KeyboardInterrupt and the traceback goes to a raw terminal. Even on the normal path, if claude was SIGKILLed or crashed it never emitted `?1000l ?1002l ?1003l ?1006l`, so the pane keeps reporting motion as garbage text. A panel that is up is also left on screen.
Fix: install handlers for SIGTERM/SIGHUP/SIGINT that raise `SystemExit(128+sig)` (and forward the signal to the child with `os.kill(pid, sig)`). In `finally`, write `ESC[?1000l ESC[?1002l ESC[?1003l ESC[?1006l ESC[?1015l ESC[?25h ESC[0m` and `panel.erase()` before `tcsetattr`.

### M2. Child inherits SIGPIPE=SIG_IGN from Python
bridge/nfpty.py:318-324 (`os.execvp` after `pty.fork`).
Python sets SIGPIPE to ignore at startup and ignored dispositions survive exec. Claude Code and everything it runs (the Bash tool, `yes | head`, `git log | head`) then see EPIPE errors instead of dying quietly, and some programs loop. This changes behaviour only under the wrapper, which is hard to diagnose.
Fix: in the child branch before exec: `signal.signal(signal.SIGPIPE, signal.SIG_DFL); signal.signal(signal.SIGXFSZ, signal.SIG_DFL)`. Preferably restore all signals Python touched.

### M3. Shim "never a failure" is false: an import error in nfpty locks the user out of `claude`
hover/claude-shim:38 (`exec -a claude python3 ...`) with bridge/nfpty.py:52-54 (top-level `import mklayout`, `from panel import ...`).
The shim checks only that the file exists. If `~/.nerdflair/hover` points into a checkout that is mid-edit or on another branch, or python is older than 3.9 (`os.waitstatus_to_exitcode` is 3.9+, used at nfpty.py:465 after claude has already run), the exec'd python dies and claude never starts, or a traceback follows a finished session.
Fix: in nfpty.py move the imports and everything before `pty.fork` inside `try/except Exception` that falls back to `os.execvp(claude, [claude]+argv)` (this is a startup fallback to the real binary, not a swallowed runtime error; print one line to stderr saying so). Also add a version gate in the shim: `python3 -c 'import sys; sys.exit(sys.version_info < (3,9))'`, or replace `waitstatus_to_exitcode` with a hand-rolled decode.

### M4. Shim can loop forever when PATH reaches its directory through a symlink
hover/claude-shim:10, :16.
`SELF_DIR` and each `$d` are compared as logical `pwd` strings. If `~/.nerdflair` is a symlink (dotfile managers, WSL path aliases) or PATH lists the dir by an alias, the shim finds itself as "the real claude" and `exec`s itself via the alias. Each pass takes the same route, so it is an exec loop, not a failure.
Fix: skip any candidate where `[[ "$d/claude" -ef "${BASH_SOURCE[0]}" ]]` (compares inodes). Add a recursion guard: `export NF_SHIM_DEPTH=$((${NF_SHIM_DEPTH:-0}+1))` and `exit 127` with a message above 3.

### M5. nf-tmux-heal can signal the wrong process, and probably never matches the real server
hover/nf-tmux-heal:15, :21.
On Linux tmux's kernel comm is `tmux: server`, so `ps -o comm=` gives two words and awk's `$3=="tmux"` never matches. On systems where comm is plain `tmux`, "tty is `?`" also matches tty-less clients (scripts, `tmux -C`, `wait-for`) and servers on other sockets (-L/-S, e.g. the e2e test server). SIGUSR1 to a tmux client or any other process has a default action of terminate. It also decides "healthy" by looking for `default` in three directories, ignoring `$TMUX` and custom socket names, so a healthy `-L work` server looks broken.
Fix: take the socket from `$TMUX` (`sock=${TMUX%%,*}`): if `[[ -S $sock ]]` exit 0. Otherwise find the server by identity: the pid in `$TMUX` is its third comma field (`${TMUX##*,}` is the session, the pid is the second field: `IFS=, read -r _ pid _ <<<"$TMUX"`). Verify `tr '\0' ' ' </proc/$pid/cmdline` starts with `tmux: server` before `kill -USR1`. Do the socket test before any `ps` call (it also saves a process spawn on every claude start).

### M6. Panel text is not clipped; narrow terminals break the border
bridge/panel.py:91-93, :74, :130-131.
`w = min(cols-4, ...)` but body lines are printed with `{line:<{w-4}}`, which pads and never truncates. A 55-char body line in a 40-column pane overflows past the right border, wraps to the next row and corrupts the engine's screen. The same for a title longer than `w-5` (top rule longer than `w`). With `cols <= 5`, `w-2` goes negative.
Fix: before building, `body = [l if len(l) <= w-4 else l[:w-5]+"…" for l in body]`, truncate the title the same way, and return without showing if `cols < 24`. Width should use wcwidth for non-ASCII.

### M7. Panel can be placed off-screen, and restore then overwrites the last row
bridge/panel.py:95-97, bridge/nfpty.py:139 (Backdrop.restore).
If `y < 1` the panel goes below the anchor (`anchor_row+1`) without checking `y+h-1 <= rows`. On short panes the rows past the bottom are clamped by the terminal onto the last row; `Backdrop.restore` then writes `ESC[top+i;1H` for rows beyond the screen and stamps stale lines onto the bottom row.
Fix: in `show`, clamp `y = max(1, min(y, rows - h + 1))` and return when `rows < h`. In `restore`, skip rows with `top+i > rows`.

### M8. Panel force-shows the cursor on every frame
bridge/panel.py:128, :133, :148, :159.
Every redraw/erase/paint ends with `ESC[?25h`, at 28 fps. If the engine had hidden the cursor (TUIs usually do while drawing), the real cursor flashes at the engine's cursor position whenever a panel is up.
Fix: track the last `?25h`/`?25l` the engine emitted (extend `note_modes` to do it, regardless of the log) and have `Panel` emit `?25h` only when the engine's last state was shown, otherwise nothing.

### M9. Restored rows can be stale (status line changed while the panel was up)
bridge/nfpty.py:92-141, panel.py:136-152.
`Backdrop` snapshots the rows at open time. While the panel is up the engine keeps repainting those rows (the burn counter ticks), then the panel is redrawn on top. On hide, the old snapshot is painted over the engine's newer content, and the engine's diff renderer believes the screen already shows the new text, so the wrong figures stay until the value next changes.
Fix: mark `dirty` when an output chunk arrives while a panel is up. On hide, if dirty, after restoring force a real repaint by changing the pty size by one column and back (`set_winsize(master, rows, cols-1)` then `cols`, 20 ms apart), since the docstring notes only a real size change redraws.

### M10. Race: backdrop captured before tmux has processed the previous erase
bridge/panel.py:99-102 (erase then `backdrop.save`), bridge/nfpty.py:121.
Our erase goes into the pane's pty and tmux parses it asynchronously. `save` spawns `capture-pane` immediately. If tmux has not read the erase yet, the capture contains the old panel's border and text, and that gets "restored" later as permanent debris. It bites on the readout-to-readout switch, the most common path.
Fix: on a switch, do not re-capture rows the old backdrop already holds. Keep `old.rows` and `old.top`; for rows of the new rect that fall inside the old rect take those saved lines, and only capture the rest. Alternatively poll `capture-pane` until its rows contain none of the box-drawing characters (limit 3 tries).

### M11. Exit status from a signalled child is wrong
bridge/nfpty.py:465.
`waitstatus_to_exitcode` returns `-N` for a signalled child, and `sys.exit(-15)` gives exit status 241, not 143. Callers (`claude` in scripts, `&&` chains) see an odd code.
Fix: `code = os.waitstatus_to_exitcode(status); sys.exit(code if code >= 0 else 128 - code)`.

### M12. Resize erase paints pre-resize rows into the new geometry
bridge/nfpty.py:367-372.
`panel.erase()` runs `Backdrop.restore()`, which writes saved rows at their old absolute positions after the terminal already reflowed. That corrupts the freshly reflowed screen until the engine repaints.
Fix: add `Panel.reset()` that clears `rect/paths/shown/body` and drops `backdrop.rows` without writing. Call that on SIGWINCH, since the engine repaints on a real size change.

### M13. rc block: unterminated marker deletes the rest of the user's rc file
hover/install.sh:44-46, :56, :65.
`strip` skips from BEGIN until END. If END is missing (hand edit, truncated file, merge conflict), everything after BEGIN is dropped on both install and uninstall. Only `.nf-backup` (install only) saves it. Uninstall keeps no backup.
Fix: only strip when both markers exist and BEGIN precedes END: `grep -qxF "$END" "$f" || { echo "malformed block in $f" >&2; continue; }`. Always make a backup before writing in uninstall as well.

### M14. rc block silently relocates tmux's socket directory
hover/install.sh:35-37.
The block exports `TMUX_TMPDIR=$XDG_RUNTIME_DIR` for interactive shells when no `/tmp/tmux-UID/default` socket exists. Non-interactive callers (cron, `wsl -e tmux attach`, scripts, hooks that call `tmux`) do not source the rc and look in `/tmp`, so they cannot see the server. If an old server is alive but its socket was deleted (the case nf-tmux-heal exists for), a new shell starts a second server. That is outside hover's stated purpose.
Fix: drop it from the hover block and offer it as a separate, opt-in `install.sh tmux-socket` action. If it stays, document it in install.sh's header and in `status`, and only set it when no tmux server process exists.

### M15. Band shows a fabricated model and fake timings
hooks/register.tsx:314-325.
The payload hardcodes `model: { display_name: 'Opus 5', id: 'claude-opus-5' }`, `total_api_duration_ms: 1`, `total_duration_ms: 1`, and a `/nonexistent/band.jsonl` transcript. The "Model" readout therefore says Opus 5 on Sonnet or Haiku, and throughput/API-time readouts are meaningless. The hover card then explains these numbers as "model.display_name".
Fix: read the model from the plugin API if there is one (`$.session` exposes usage/cwd/id; check `.claude-plugin/types`), otherwise omit the model segment and the two timing readouts from the band rather than invent values.

### M16. Shell-side quoting depends on the user's default shell
popup.sh (outside scope, called from register.tsx:469).
`printf '%q'` emits bash `$'...'` for strings with control characters. tmux runs the popup command with the user's `default-shell`, which may be dash/fish/csh where that form is not valid. Text is mangled, not injected, because `plain()` has already stripped control characters from segment text. `rcSeen.join(', ')` (register.tsx:411) and `rcCard` are NOT passed through `plain()`.
Fix: pass the text as an environment variable (`tmux display-popup -e NF_TITLE=... -e NF_BODY=...`) and have the popup command be the fixed string `printf '...%s' "$NF_TITLE" "$NF_BODY"`. Also run `plain()` over the whole `bodyText` and `title` inside `popup()` at register.tsx:468.

## Low

### L1. Ctrl-Z is inert under the wrapper
nfpty puts stdin raw (:350) so 0x1a goes to the child, but the child is a session leader in an orphaned process group (pty.fork calls setsid), where the kernel discards SIGTSTP. Fix: document it, or detect `\x1a` in the input stream and implement suspend in nfpty (restore termios, `os.kill(os.getpid(), SIGSTOP)`, re-raw and `os.kill(pid, SIGCONT)` on resume).

### L2. Child starts with a 0x0 window size
bridge/nfpty.py:317-328. The size is set after `pty.fork`. A child that reads the size at startup before the parent runs `set_winsize` sees 0x0 and relies on the SIGWINCH to fix it. Fix: call `winsize`/`set_winsize` on the child's fd 0 before `execvp` (compute rows/cols before `pty.fork`). Also install the SIGWINCH handler before reading the size (a resize in the gap at :327-359 is lost); set `resized[0] = True` once after installing it.

### L3. Partial `os.write` to the master is not retried
bridge/nfpty.py:413. A signal arriving mid-write of a large paste can return a short count; the rest is dropped. Fix: loop `while fwd: n = os.write(master, fwd); fwd = fwd[n:]`. Use `select` for writability to avoid a possible deadlock where nfpty blocks writing input while the child blocks writing output.

### L4. Stdin read error treated as end of session
bridge/nfpty.py:405-410. `except OSError: break` also catches EAGAIN (non-blocking tty shared with a parent), ending the session. Fix: `continue` on `EAGAIN/EINTR`, break only on EIO/EBADF. Also, after breaking out because stdin ended, `os.waitpid` at :464 can hang if the child traps SIGHUP; send `SIGHUP` then `SIGKILL` after a 2 s grace.

### L5. Idle wakeups 28 times a second in every session
bridge/nfpty.py:374, :450. `select(..., FRAME)` runs even with no panel or hide timer. Fix: use `timeout=None` when `panel.paths` is empty and `hide_at[0]` is None, otherwise FRAME.

### L6. Panel stays up when the pointer leaves the terminal window or the user types
No mouse report arrives when the pointer exits the window, so `hide_at` is never armed (nfpty.py:431-433); keystrokes do not hide it either. Fix: erase the panel on any non-mouse input byte and after about 3 s with no motion report.

### L7. Column math uses code points, not cell widths
mklayout.py:153, :241, nfpty.py:189, panel.py:91-93. CJK or emoji in a readout (a cwd or branch name) shifts every later column by one per wide char, so hover hits the wrong card. Fix: use `unicodedata.east_asian_width` ('W'/'F' count 2) in `pieces` and `Panel`.

### L8. `text=True` decode can raise
mklayout.py:222-223, nfpty.py:121-124. `subprocess.run(..., text=True)` raises `UnicodeDecodeError` (a ValueError, not caught by `except (OSError, SubprocessError)`) when the locale is not UTF-8 and the screen has non-ASCII. That kills the session. Fix: `encoding="utf-8", errors="replace"`.

### L9. Any exception in hover/panel code kills the user's claude session
bridge/nfpty.py:411-439. A bug in `panel.show` (empty body: `max()` of an empty sequence at panel.py:92) propagates through `finally`, closes the master and terminates claude. Fix: catch around the hover/paint block, log with traceback to NFPTY_LOG (or stderr once), set `hover_enabled = False`, and keep relaying. This is degrading a decoration, not hiding a failure, so log loudly.

### L10. Status band window is the last 8 capture rows
mklayout.py:231. A multi-line input box pushes the band above that window and hover silently stops. Fix: scan the whole pane (the NERD+SEP test already filters), or scan up to `len(raw)-30`.

### L11. Shim and installer details
- hover/claude-shim:28-31 scans every arg for `-p/-v/-h` even when it is a value (`--append-system-prompt -p`); the subcommand check looks at `$1` only, so `claude --model x mcp list` is wrapped. Fix: handle only args before the first non-option, or accept the rare miss.
- hover/claude-shim:38: `claude --selfcheck` runs nfpty's self-test instead of claude (nfpty.py:299). Fix: use `--nfpty-selfcheck`.
- hover/claude-shim:35 exports `CLAUDE_BIN` and nfpty.py:319 exports `NFPTY=1` into claude's whole process tree. Harmless to the shim (it checks NFPTY) but visible to every tool claude launches. Fix: pass `CLAUDE_BIN` as `--real` to nfpty instead of an env var, unset it in the child.
- stderr redirection (`claude 2>log`) is lost under the wrapper because the child's stderr is the pty. Fix: in the shim, `wrap=0` when `! -t 2`.
- hover/install.sh:65-68: uninstall leaves `*.nf-backup` copies of the rc files and `~/.nerdflair` itself; the dedupe line `${PATH//:$HOME\/.nerdflair\/bin:/:}` (install.sh:30) misses the first/last PATH element. Fix: also remove `$f.nf-backup` when its content equals the stripped original (or print their paths), `rmdir "$NF"`, and run the substitution on `":$PATH:"` then trim.
- hover/install.sh:52: the shim is copied, not linked, so a repo update to claude-shim does not propagate while `hover` is a link into the repo (version skew). Fix: re-run install on update, or make `status` compare `cmp` of the installed shim with the repo copy.
- band/sync-local-plugin.sh:23-25, :31: `cp -rf` of `types` leaves deleted files behind, and `claude plugin update ... || true` hides a failed update (the later check only prints status). Fix: `rm -rf "$DEST/.claude-plugin/types"` before the copy, and drop `|| true` or compare the installed version string afterwards.
- hooks/register.tsx:363-373: a failed refresh keeps the old `cache` forever, so figures freeze silently. Fix: if `now - cache.at > 30000`, set `cache = null` so the error band shows. Also dedupe concurrent refreshes with an in-flight promise.
- hooks/register.tsx:252, :254: `slice` on strings containing Nerd Font astral glyphs can split a surrogate pair and counts them as 2 wide. Fix: use `Array.from(t)`.

## Tests that cannot fail or are missing

- The self-checks (`nfpty.py --selfcheck`, `panel.py` demo, `mklayout.py --selfcheck`/`--cards-check`) are not invoked from tests/test-nerdflair.sh, the other tests/*.sh, or any workflow (searched .sh/.yml for `--selfcheck` and `cards-check`: no hits). They run only when a person remembers to. Fix: add a `tests/test-hover.sh` that runs all four and wire it into the main test script.
- nfpty selfcheck :240-294 are real tests (they can fail) but cover only the happy parse. Missing: the unterminated `ESC[<` tail (H4), tail cap/timeout, exit-status decode (M11), resize reset (M12), chunk-boundary injection (H1), narrow-terminal clipping (M6), panel at the bottom edge (M7). The panel demo uses `cols=200, rows=50` only.
- `assert note_modes(...) is None` (nfpty.py:268) is near vacuous; the log assertion on the next line is the real one.
- hover-e2e.py and hover-covered-e2e.py need a live tmux; they are not part of the unit gate and the review did not execute them.

## No finding

- Shim exec of the real claude for non-tty, `-p`, subcommands and `NFPTY` set: logic is right (claude-shim:24-31). Missing python3 falls to plain claude (:27). A missing tmux binary is caught in nfpty (:311, :125, mklayout :224).
- Input forwarding is byte-exact and ordered; SIGWINCH is handled with a flag (select is retried after the handler, PEP 475), and `set_winsize` on the master signals the child itself.
- Ctrl-C reaches the child through the pty line discipline because stdin is raw; no manual forwarding is needed for that.
- nfpty child exec failure prints through the pty and exits 127 (:321-324). A bare `claude` in `CLAUDE_BIN` unset resolves to the shim, which sees `NFPTY=1` and passes through, so no loop there.
- Security: no temp files anywhere in scope. popup.sh is called with an argv array (no shell), and the segment text is stripped of control bytes by `plain()` (register.tsx:173-176). The only escape-injection exposure is the unsanitised surface names in M16. Captured rows are tmux-sanitised SGR and are written back only to the same user's terminal. nf-tmux-heal creates its directory with `-m 700`. install.sh edits use a same-dir temp, `cat >` (preserves symlinked rc files) and a backup on install.
- install.sh idempotency on repeat install: the block is stripped and re-appended; a second run with the block already last yields an identical file, so no write and no new backup.

## Disposition 2026-10-09 (author)

Checked against the source and fixed where the claim held. Findings are named as the reviewer numbered them.

**Fixed, each with a test that fails on the code before the fix**
- **H1** panel writes into a half-written escape or UTF-8 character: panel writes now queue until the last relayed chunk ends on a sequence boundary (`ends_clean`, selfcheck cases).
- **H2** hang when a detached descendant (an MCP server) holds the pty after claude exits: the child is now reaped directly and its exit code comes through. `tests/nfpty-exit.sh` hangs on the old wrapper and passes now.
- **H3** tmux reads on the relay loop: the two reads are bounded at 0.5 s, and a slow answer backs the layout off for 5 s.
- **H4** an unfinished mouse-report fragment swallowing typing: a held fragment is capped at 24 bytes and flushed after 0.3 s.
- **M1** terminal state after SIGTERM, SIGHUP or a crash: signals are forwarded to the child and mouse modes and the cursor are reset on every exit path.
- **M2** SIGPIPE inherited as ignored: the child gets the default back.
- **M3** shim "never a failure": the wrapper's modules must import under this python3 before it is used.
- **M4** shim exec loop through a symlink: candidates that resolve to the shim are skipped.
- **M5** `nf-tmux-heal` never matched the server (name has a space, cmdline is the original argv): it now reads the kernel's listening-socket table. This was a real silent no-op; `tests/tmux-heal.sh` moves a scratch server's socket away and requires it to come back.
- **M8** forced `?25h`: the panel restores the cursor as the engine left it.
- **M11** a signalled child's exit code: 128 plus the signal.
- **M13** an rc block with a missing END marker deleting the rest of the file: markers must pair up or nothing is changed.
- **M16** surface names reaching a Text and a popup: passed through `plain()`.

**Not changed, with the reason**
- **M6 and M7** panel clipping and placement: width and x are already clamped to the screen (`panel.py` `show`); a narrower terminal than the text still needs a real clipping pass. OPEN.
- **M9 and M10** a restored row can be stale if the status line changed under a panel, and the capture can race tmux's parse of our previous erase: real but small, and the fix (re-capturing after the engine's next repaint) needs live measurement. OPEN.
- **M12** a resize erase paints pre-resize rows into the new geometry: OPEN.
- **M14** the rc block moves tmux's socket directory for interactive shells: kept on purpose, because a socket under `/tmp` is what stranded the server; it only applies when no `/tmp` socket exists. Say if you want it opt-in.
- **M15** the band's payload fakes the model name and API timings: it only affects what the renderer prints on the band row. OPEN, low.
- **Low findings:** not individually triaged here; they are in the report body above.
- **Tests that are not run:** the selfchecks are now exercised by the new e2e and exit tests, but there is still no single runner. OPEN.

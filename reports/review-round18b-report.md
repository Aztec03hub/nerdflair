# Review round 18b: round-17 fixes (HEAD ab6b4cf)

Analysis only. Nothing was run. No finding below can stop claude launching or kill a session; the worst is a false error in the band.

## Findings, ranked

### 1. (Medium) band/hooks/register.tsx:351-365 and :546 - the new HOME backoff makes a concurrent render report a false "plugin bug"
Scenario: the first render awaits `printenv HOME` (up to 2 s). `homeTriedAt` is now set BEFORE the await (line 352). A second render that arrives meanwhile (the code itself says renders arrive faster than the renderer returns, line 367) sees `!HOME` and `now - homeTriedAt` small, so it skips the lookup. It then skips the refresh (`HOME` empty), reaches `if (!cache)` at line 543 with `lastError === ''`, and calls `report($, 'band', 'no figures and no recorded reason (plugin bug)')` at line 546. That logs a false bug line and draws a red "nerdflair-band: band: no figures..." until the first good refresh. This happens even when the lookup then succeeds. Before the change every concurrent render ran its own lookup, so none reached line 546.
Fix: keep the in-flight state and return the engine's UI (or a neutral empty Box) while it is pending, e.g. `if (!HOME && !lastError) return <Box/>` (or `return next(e)`) before line 543. Alternative: store the lookup as a promise (`homeP ??= lookup()`) and have every render await it. Add a test: two renders started without awaiting the first, the first printenv held pending.

### 2. (Low-Medium) band/hover/install.sh:232 - the "never installed" match is too broad
`*"not found"*` and `*"No such file"*` also match real failures, e.g. "Failed to connect to bus: No such file or directory" or a "command not found". A watcher that is still running and could not be stopped is then reported as success, which is the case the warning exists for (comment at line 228). Only systemd's own wording is needed.
Fix: `*"does not exist"*|*"not loaded"*) ;;`, and if you want to keep the others, match them only together with "nf-tmux-watch".

### 3. (Low) band/hover/install.sh:58 - the once-per-shell flag does not survive a subshell
`out=$(claude -p x 2>&1)`, or any pipeline, runs `claude()` in a subshell. `_NF_SHIM_WARNED=1` is set there and lost, so every such call still prepends the warning to captured output. That is the case the comment says it protects.
Fix: also skip the echo when `[ ! -t 2 ]`, or accept and reword the comment. Exporting the variable does not help, because the subshell's change never reaches the parent.

### 4. (Low) band/bridge/nfpty.py:948 - EBADF is treated as a normal end
EIO is the terminal hanging up. EBADF on stdin means our own fd was closed, which is a bug worth the single log line. It is now silent.
Fix: suppress only EIO.

### 5. (Low, pre-existing but now reachable) band/hover/claude-shim:101-102 - the fallback exec inherits SIGPIPE ignored
Python sets SIGPIPE to SIG_IGN, and `os.execv` keeps ignored dispositions. Plain claude launched by the fallback therefore differs from one launched by bash. The normal child path resets it (nfpty.py:725); the fallback does not.
Fix: `signal.signal(signal.SIGPIPE, signal.SIG_DFL)` before the `execv` (add `signal` to the import on line 80).

### 6. (Low, pre-existing) band/bridge/nfpty.py:732-780 - code between the fork and the `try/finally` is unguarded
`set_winsize`, `Panel(...)`, `Layout(...)` and `tcgetattr` (only `termios.error` is caught) run after the fork and before the `try`. An exception there leaves claude running with no relay. `forked` is set, so the shim re-raises and the terminal is left as it was, but the child is orphaned and the session is dead. This is not new in round 17; it is noted because the round-17 text claims "a hover bug can never be a lockout" only up to the fork.

## Checked and found correct
- claude-shim quoting: the new `_marked_fork` lines contain no single quote, so the single-quoted bootstrap is still valid. Inner strings use double quotes only.
- `_marked_fork`: if `pty.fork` raises, nothing has forked, `forked` stays empty and the shim falls back. On success the append runs in the parent, and in the child just before its exec. A failure after a successful fork leaves `forked` set, so it re-raises: correct. nfpty calls `pty.fork` through the module attribute, so the patch applies.
- nfpty.py:716-721: a re-raise before the fork reaches the shim (`except BaseException`, `forked` empty), which then execs plain claude. The shadow is closed first. Nothing else is held at that point: the SIGWINCH handler is dropped on exec, and the raw tty is set only after the fork. If `shadow.close()` itself raised, the new exception would still be caught by the shim, so the fallback still happens.
- Layout.refresh: the backoff now runs before the `None` check, so a hung tmux pauses hover for 5 s. A slow but valid read still updates `segs`. The order is right.
- nf-log.sh:37: the `find` is anchored with `"$dir" -maxdepth 1 -name '.launcher-stamp-*'`, so it matches only hidden stamp files directly in the state dir. The fresh stamp was just touched, so it is never deleted. It runs only when a line is about to be logged (at most hourly per reason). It cannot hit launcher.log or other files.
- nflog: `errors="replace"` plus catching ValueError is enough. The stderr fallback and the debug sink also catch ValueError, since UnicodeEncodeError is a subclass.
- nf-tmux-watch: `encoding=` and `errors=` with `capture_output` is valid `subprocess.run` usage.
- tcgetattr ENOTTY check: `termios.error` args are `(errno, msg)`. The check is correct and a non-ENOTTY failure is logged once.
- scripts/nerdflair.sh: the `if ...; then bash ... || printf ...; fi` form is safe under `set -e`.
- tests/install-rc.sh: `set -uo pipefail` without `-e`, so `rc=$?` after the command substitution is fine, and the stub is restored afterwards.
- resetStateForTests resets `homeTriedAt`. After a failure the red band stays up during the 30 s gap, because `lastError` is set; the band is not blank. A later good lookup and refresh clears `lastError`.
- Toast catch: it covers a rejected promise. A synchronous throw from `$.ui.toast` is not covered, but that was already so.

## Could not verify
- Whether the engine really overlaps `ui.render` calls (finding 1 depends on it; the in-code comment says it does).
- The Python version in use. On Python before 3.12, `pty.fork` is a hand-written openpty/fork/setsid. An exception in its child half would skip the `forked.append`, so the child would exec plain claude on a half-set-up pty while the parent relays it. 3.12 and later use `os.forkpty`, which does not have this. Not checked here.
- Real systemctl wording across versions (finding 2). Only the stub's text was seen.
- Nothing was executed, including the new tests.

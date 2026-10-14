# Review round 17b: absorbed-failure logging (0c38a90..HEAD)

Read-only. Nothing was run (no tests, tmux, nfpty, install, sync, claude). Everything below comes from reading the code at the cited lines. Findings are ranked.

## 1. HIGH: `nerdflair uninstall` now aborts half-way, because install.sh uninstall exits non-zero

- `scripts/nerdflair.sh:2` is `set -euo pipefail`. Line 403 is a bare `[[ -f ... ]] && bash "$SCRIPT_DIR/../band/hover/install.sh" uninstall`. A non-zero exit aborts the whole script before it restores spinnerVerbs and removes the other traces.
- `band/hover/install.sh` uninstall now exits 1 whenever `problems=1`.
  - `install.sh:224` calls `systemctl --user disable --now nf-tmux-watch.service` and `warn`s on any failure. On a machine with a systemd user manager where the unit was never installed or is already gone (a second uninstall, an install that ran without systemd, or nerdflair.sh uninstall on a machine where the hover install was skipped), `disable` of a missing unit exits 1 ("Unit file ... does not exist"). I know this from systemd's behaviour, I did not run it. The old code ended with `|| true`.
  - Also an unreadable rc file, or an unmatched marker (`remove_block`).
- Scenario: user runs `nerdflair uninstall`. hover uninstall prints "WITH PROBLEMS", exits 1, and nerdflair.sh dies at 403 with the rest of the uninstall skipped.
- `nerdflair.sh:376` (install) uses `cmd && printf`, so a failure only loses the tick. It is not fatal.
- `tests/install-rc.sh` stubs `systemctl disable` to always succeed (except via SC_FAIL_DISABLE), so the missing-unit case is untested.
- Fix:
  - Treat "not loaded / does not exist" from `disable` as success. Test `systemctl --user cat nf-tmux-watch.service` first, or match `does not exist|not loaded`.
  - In nerdflair.sh make the call `bash ".../install.sh" uninstall || printf 'hover uninstall reported problems (see above)\n' >&2`, so it can never stop the main uninstall.
  - Add a test where the stub's `disable` says the unit does not exist.

## 2. HIGH: the launcher bootstrap does not fall back to plain claude when `pty.fork()` itself fails

- `band/hover/claude-shim:84` is `pty.fork = lambda: (forked.append(1), _fork())[1]`. `forked.append(1)` runs BEFORE `_fork()`.
- If `pty.fork` raises (the classic case: `OSError: out of pty devices` / EAGAIN, or fork failing), `forked` is already non-empty. The handler at lines 92-93 takes `if forked or not real: raise`. The user gets a traceback and no claude. That is exactly the lockout the bootstrap exists to prevent, and it happens in a realistic failure (pty exhaustion, process limit).
- The H7 test (`tests/launcher-logging.sh:111`) raises before `pty.fork`, so it cannot see this.
- Fix: record only after success, e.g. `def _pf(): r = _fork(); forked.append(1); return r`. The child also appends, which is harmless.
- Related leak, same path: `nfpty.main` creates the Shadow (a private tmux server plus a fifo) at about line 696, before the fork. Any pre-fork failure then goes to `os.execv(real, ...)` in the bootstrap, and exec skips cleanup. The private `tmux -S` server and its `cat` stay running forever, one per failed start.
  - Fix: wrap the pre-fork section of `main()` in `try/except BaseException: shadow.close(); raise`.

## 3. MEDIUM-HIGH: a hung tmux no longer triggers the slow-read backoff (typing lag regression)

- `band/bridge/nfpty.py:262-263`: `if fresh is None: return` comes BEFORE the `> 0.3 s` slow check at 266. A hung tmux makes `mklayout.build_ex` hit `timeout=0.5` and return `None`.
  - Before the change the timeout returned `[]`, and the 0.3 s check set `backoff_until`.
  - Now the backoff never engages. Every hover report (`on_hover` calls `refresh` and then `refresh(force=True)`, up to once per 0.15 s plus force) blocks the relay loop for 0.5 s. Typing and output stall for as long as tmux is unhealthy, and the only trace is `layout-tmux` at one line a minute.
- `logcheck.py` `keeps_last_layout` (about line 223) asserts the layout is kept, not that it backs off, so it cannot catch this.
- Fix: measure elapsed time first, then `if fresh is None:`, and set `backoff_until` in the None branch too, e.g. `took = time.monotonic() - now; if took > 0.3 or fresh is None: self.backoff_until = ...`. Add a logcheck case: a stub `build_ex` that sleeps 0.4 s and returns None must leave `lay.paused` true.

## 4. MEDIUM-LOW: nflog says "never raises", but it only catches OSError

- `band/bridge/nflog.py:34-46`: `open(ERRLOG, "a").write(line)` uses the locale encoding with strict errors. A `UnicodeEncodeError` is a ValueError and escapes `_write`.
  - Sources: lone surrogates from `os.fsdecode`'d paths in OSError text (XDG_RUNTIME_DIR, NFPTY_LOG, shadow paths), or non-ASCII in a non-UTF-8 locale.
  - It escapes `note_once`/`note_rate`. `degrade()` (`nfpty.py:622`) calls `_write` directly from inside `Guard`'s `except Exception`, so it propagates out of the guard and into the relay. That would kill the user's session, which is the one thing `degrade` exists to stop.
- Fix: `open(ERRLOG, "a", encoding="utf-8", errors="replace")`, and `except (OSError, ValueError)` for the whole body. The stderr fallback line already tolerates ValueError.
- Minor, same file: rotation is racy across sessions. Two processes that both saw the size over the limit each `os.replace`, and the second overwrites `.1` with a near-empty file, losing the old generation. The same pattern is in nf-tmux-watch `_append`. It is only a diagnostic log, so this is cosmetic.

## 5. LOW: watcher can still die on undecodable `ss` output

- `band/hover/nf-tmux-watch`, `socket_paths()`: `subprocess.run(..., text=True)` raises `UnicodeDecodeError` (a ValueError) on a socket path that is not valid UTF-8. The handler only catches `(OSError, SubprocessError)`, so the watcher exits (systemd restarts it 5 times, then stops). It is the same class as the "silent absorb" rule: a death with no `transition()` line.
- Fix: `errors="replace"` and catch ValueError into `transition("ss", ...)`.
- The same applies to `_append`'s `open(path, "a")` for non-ASCII reasons in a non-UTF-8 locale.

## 6. LOW: fallbacks still not durable, or noisy

- `nfpty.py:680-684`: with TMUX set and tmux unreachable (or missing), the only trace is a stderr line the TUI repaints over a moment later. It is not `note_once`'d, so it never reaches nfpty-error.log. The same holds for the `TMUX_PANE` and `shadow-start` messages at lines 689-702, which do go to the log. Only 684 is missing.
- `nfpty.py:937` logs `stdin read failed (EIO)` as an error. The comment at 1021 says EIO on the terminal is the NORMAL end of a session, so every window close now adds a line. Skip errno EIO there.
- `nfpty.py:767-768`: `except termios.error: pass` on `tcgetattr`/`setraw` is still silent. If it fails on a real tty, raw mode is never set and hover is silently wrong. Add `note_once`.
- `band/hover/nf-log.sh:33-35`: the stamp file is keyed on the whole reason text, and nothing prunes stamps. A reason that varies (a pid, an error with a path) creates a new stamp file per start and bypasses the hourly limit. The stamp is also written before the log line, so a failed write suppresses the report for an hour.
- `install.sh:55-56` (the rc-block `claude()` function): "shim missing, running plain claude" goes to stderr on every call with no rate limit. In an interactive shell, `claude -p ... 2>&1 | jq` gets that line in its data. Print it once per shell (a variable) or log it instead.
- `band/hooks/register.tsx` (the part runnable-in-engine I could not test):
  - HOME lookup (`register.tsx:349-362`): while `printenv HOME` keeps failing, every render spawns a new process. The log is deduped, the retry is not. Add a failure TTL.
  - A renderer that flaps (fail, success, fail) re-logs on each recurrence, because `seen.delete(lastError)` at line 518 forgets it. That is at most one debug line per 2 s TTL, so tolerable.
  - `popup()` (lines 671-686): `fail()` calls `note` plus `$.ui.toast`. If `toast` throws (both `ui.log` and `ui.toast` are sync `void` in the types, so this is plausible), the throw happens inside the `try` and the `catch` calls `fail` again. The second throw escapes the `void (async ...)()` as an unhandled rejection. Guard the toast with its own try/catch that falls back to `note` only.
  - Calling `$.ui.log` from the `ui.render` handler in `report`/`note` cannot loop within this code (`lastError`/`seen` are module variables, not state, and `note` dedupes). Whether the engine re-renders on a `ui.log` event I could not tell.

## 7. Tests that cannot fail, or that miss the main path

- `tests/launcher-logging.sh:116-119`: "nf_log never fails even if the state dir cannot be created" always passes. `nf_log` always returns 0, and under root (`chmod 555` is ignored) the log is simply written. It does not prove the log was skipped or that nothing hung.
- The shim tests use a fake `nfpty.py`. Nothing exercises the real wrapped path: the exit status of claude through the bootstrap, window name `claude` (`exec -a`), `python3` resolving with argv[0]=`claude`, or plain `claude -p`. `run_tty` prints `EXIT=` but no check reads it. At minimum assert `EXIT=` equals the stub claude's exit code for a wrapped run with a fake CLAUDE_BIN.
- `tests/launcher-logging.sh` (heal section): the watcher test only covers the NOT HEALED and "heal missing" cases. There is no success-path case, so a false NOT HEALED (or a false "healed" after a deliberate `kill-server`, where the log line says "socket restored" though the server is gone) would not be noticed.
- `tests/install-rc.sh`: the systemctl stub's `disable` never fails for a missing unit (see finding 1).
- `logcheck.py` keeps-last-layout only checks the layout is retained, not the backoff (finding 3).

## What I could not verify

- Whether `$.ui.log(..., {to: 'debug'})` lines are written to anywhere durable when the user has not run `claude --debug`. `index.d.ts:14485` says "The debug log is `claude --debug` or the `--debug-file`". If there is no default debug file, the plugin's "logged once" is only visible in the red band or the stale marker, not in a file.
- Whether a popup dismissed with Esc or Ctrl-C makes `tmux display-popup` exit non-zero. If it does, normal dismissal now toasts an error (`popup.sh:54-56` plus `register.tsx:681`).
- `exec -a claude python3`: Python derives its prefix from argv[0] by searching PATH for `claude`, which finds the shim. This works for a system python with a compiled-in prefix, but a relocatable python (uv, conda, pyenv-built) may fail at interpreter start, after exec, with no fallback. The `exec -a` predates this diff, and the import check runs without it, so it could not catch this. Not measured here.
- Whether the engine's module loader accepts every `$` use in register.tsx. I only confirmed the pattern: `$` is passed to the top-level `band`, `note` and `report`, and the closures (the refresh IIFE, `popup`, `onPress`) call `$.*` directly exactly as the base version already did. The new `$.ui.toast` is typed `void`-returning. I could not run a live engine.
- `register.test.ts`, the e2e scripts and the tmux-dependent selfchecks were not run.

## Checked and fine

- `claude-shim` no-wrap cases (non-tty, `-p`, not in tmux, subcommands) exec plain claude with the same exit status, and the symlink and readlink guard is correct.
- Exit status through nfpty: `sys.exit(128 - code if code < 0 else code)` is unchanged. The bootstrap re-raises `SystemExit`.
- `herr=$(heal 2>&1 >/dev/null)` cannot hang on the pipe, because `nf-tmux-heal` starts no background process.
- The watcher's heal verification (3 s `socket_paths` poll after heal, 30 s heal timeout) has no loop beyond the existing `self.heals` rate limit.
- `nfpty.ERRLOG` is gone and no other file references it. `NFPTY_ERRLOG` is read once at import in `nflog`, and the selfchecks redirect `nflog.ERRLOG` rather than the old name.
- `mklayout.build()` still returns a list. The other `build_ex` callers handle None.
- The `retry` path in `nfpty.py` (deferred card, retry once `pending` drains) is guarded and cannot spin: retry only fires when `pending` is empty, which is exactly when `settled()` is true.

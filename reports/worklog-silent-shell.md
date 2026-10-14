# Worklog: silent-failure fixes, shell/launcher layer

Branch `silent-shell` in /home/plafayette/nerdflair-wt-shell, based on main 6bd7c5d. Not pushed, not merged.
Commits: `3e843fb` (launcher: nf-log.sh, shim, heal, watcher, launcher-logging test), `258b21b` (install.sh, sync-local-plugin.sh, install-rc test), `dd79deb` (test-quality fixes).

## Design
- `band/hover/nf-log.sh`: `nf_log <component> <reason>` appends `ISO-time component: reason` to `$NF_STATE_DIR` (default `~/.local/state/nerdflair`) `/launcher.log`. Once per (component, reason) per process; a stamp file limits it to once an hour per reason (`NF_LOG_NOSTAMP=1` turns it off, install.sh uses that); 1 MB cap with one `.1` generation; every step guarded, returns 0, sets no shell options. install.sh copies it to `~/.nerdflair/bin`. shim, heal and install source it (a missing file degrades to a no-op, never stops claude).
- The python watcher writes the same format natively (`transition()`: logs when a failure starts and when it recovers, not every 30 s rescan) to launcher.log and to its own tmux-watch.log.
- Test-only hook: `NF_TEST_INOTIFY_FAIL=1` makes every `inotify_add_watch` fail with ENOSPC (documented in the watcher source).
- H7 (nfpty startup): nfpty.py is untouched. The shim now starts it with `exec -a claude python3 -c <bootstrap>`: the bootstrap runs nfpty.py via runpy with `pty.fork` wrapped. If nfpty raises BEFORE it has forked claude, the bootstrap logs the reason (through nf-log.sh), prints one stderr line, and `execv`s the real claude. After the fork the relay owns the session, so the exception is re-raised (no second claude). The window name is still `claude`.

## Per finding
- H1 import check: stderr captured, last line logged (`shim: hover import check failed (ImportError: ...)`), plain claude. H2: split into dangling-link and no-python3, each logged. H3: heal exits 3 whenever it found a missing socket (or could not tell) and could not act, reason on stderr and in the log; watcher polls up to 3 s for the socket and logs `NOT HEALED rc=N, still missing [...]: reason` or `healed rc=0 socket restored` (the old `healed rc=` wording is kept for the success case so tmux-watch.sh still matches). H4: inotify_add_watch failure logged once per directory with strerror, recovery logged. H5: ss failure (exec error, timeout, non-zero, unparsable format) logged on transition. H6: ss missing is logged, exit 3. H7: above. H8: `systemctl enable --now` output captured; failure prints a WARNING with the reason and install exits 1 (rc blocks are still installed first).
- M1: shim captures heal's output; heal logs its own reasons; a heal crash (rc not 0 or 3) is logged by the shim. M2: every `continue` after a missing socket is confirmed now says why; unparsable ss lines naming our tmux dir are reported (heal and watcher). M3: install exits 1 and prints `hover is NOT active` when no rc file was updated or any was skipped. M4: `watcher: skipped (no systemd user manager)` is printed. M5: `-r` guard, unreadable rc named, exit 1 (remove_block, install loop, uninstall `still` check). M6: uninstall prints and exits 1 if `systemctl disable --now` fails. M7: the rc function prints `shim missing, running plain claude` (once per call, only in the broken state). M8: `status` prints the tmux socket dir and `UNPROTECTED` when XDG_RUNTIME_DIR is unusable. M9: heal call has `timeout=30` and a handler. M10: `log()` never raises (stderr/journal fallback, once), rotation errors other than FileNotFoundError are reported. M11: IN_Q_OVERFLOW logged and treated as a hit. M12/M13 (popup.sh): out of scope (other implementer). M14: `claude plugin list --json` failure exits 1 with a message; python traceback vs "not found" distinguished. M15: ledger-concurrency exits 77 `PASS (1 SKIPPED)`. M16: validate-ledger exits 1 when a product figure is missing but the recount exists (2 when the recount itself fails); recount stderr (UNPRICED) is no longer dropped; product stderr shown on failure. M17: fixture git chain checked (set -e is off inside `if`, so it is an `&&` chain), failure counted; per-test stderr kept and shown on FAIL and on crash. M18: `_gitq` aborts the fixture build with git's message (exit 2); runs where both sides fail identically are listed as a note.
- L1 readlink guard: done. L2 `grep -v ... || [[ $? -eq 1 ]]`: done. L3: covered by the `-r` guard. L4: MISSING for absent copies and `watcher: <is-active>`: done. L5: surfaced by L4. L7 empty-home asserts rc 0 and output: done. L8: install-rc asserts statuses and covers enable/disable failure. L9 nfpty-exit stderr shown on FAIL: done. L10 price-recount counts and prints skipped files and bad lines: done. L11: `mktemp ... || exit 1` added; tests now set NF_STATE_DIR so they never write the real log; new cases added in launcher-logging.sh.
- Skipped: L6 and M12/M13 (popup.sh, other owner). test-nerdflair `|| true` mutation lines 689/729/739: not changed, I did not trace each following assertion (audit also could not verify); the runner now shows their stderr if a test crashes. Heal stderr in tmux-heal.sh/tmux-watch.sh is still discarded where assertions are by effect (the diagnostics are in launcher.log, which those tests now point at a temp dir). nf-tmux-watch.service unchanged (by design, surfaced via status).
- Kept silent on purpose, with comments: PATH probing in the shim (`cd "$d" 2>/dev/null`), deliberate no-wrap cases, `unalias ... || true`, `rmdir ... || true`, `/proc/$pid` probes, absent-file greps in `status`, the SKIP-77 convention.

## Notes for the lead
- Running tests/tmux-heal.sh BEFORE I set NF_STATE_DIR in it wrote 3 heal lines (a scratch tmux server path under /tmp/nf-heal-*) into the REAL `~/.local/state/nerdflair/launcher.log` (I created that file; nothing else was in it that I know of). Harmless, but you may want to delete that file. The tests no longer touch it.
- The worktree needed a gitignored symlink `rust/target -> /home/plafayette/nerdflair/rust/target` so bridge-selfchecks, empty-home, ledger and difftest can find the release binary. It is not tracked.
- validate-ledger now FAILS here with real data drift (live ledger vs transcript recount: -22.4% at 1h, -10.2% at 3h, bounds +2%/-10%). Not caused by this change; the old script had reported SKIP for a different reason in the old-tree run (below).
- Shell gotcha seen: the session umask is 0117, so every test run here used `umask 022` first.

## Output: tests/launcher-logging.sh, OLD code (HEAD 6bd7c5d `band/` and `tests/` extracted to a scratch dir, new test dropped in): 30 FAIL
```
  FAIL  python3 missing: the reason is logged (want 1, got 0)
  FAIL  python3 missing: the second start did not log it again (rate limited) (want 1, got 0)
  FAIL  hover link dangling: the reason is logged (want 1, got 0)
  FAIL  hover link dangling: the second start did not log it again (rate limited) (want 1, got 0)
  FAIL  nfpty import broken: the reason is logged (want 1, got 0)
  FAIL  nfpty import broken: the second start did not log it again (rate limited) (want 1, got 0)
  FAIL  nfpty fails at start: plain claude still starts (twice) (want 2, got 0)
  FAIL  nfpty fails at start: the reason is logged (want 1, got 0)
  FAIL  nfpty fails at start: the second start did not log it again (rate limited) (want 1, got 0)
  FAIL  nf_log never fails even if the state dir cannot be created (want 0, got 1)
  FAIL  ss missing: heal exits 3 (not a silent 0) (want 3, got 0)
  FAIL  ss missing: says why on stderr (want 1, got 0)
  FAIL  ss missing: logged, once across two runs (want 1, got 0)
  FAIL  ss format drift: heal exits 3 (want 3, got 0)
  FAIL  ss format drift: the unparsed line is named (want 1, got 0)
  FAIL  ss format drift: logged (want 1, got 0)
  FAIL  ss fails: heal exits 3 with the reason (want 3 1, got 0 0)
  FAIL  cannot recover: heal exits 3 (want 3, got 0)
  FAIL  cannot recover: the reason is logged (want 1, got 0)
  FAIL  inotify_add_watch fails: reported in launcher.log (want 0, got 1)
  FAIL  inotify_add_watch fails: with the errno text (want 1, got 0)
  FAIL  inotify_add_watch fails: once per directory, not per rescan (want 2, got 0)
  FAIL  ss fails: reported in launcher.log (want 0, got 1)
  FAIL  ss fails: once, not every rescan (want 1, got 0)
  FAIL  heal cannot recover: the watcher logs NOT HEALED (want 0, got 1)
  FAIL  heal cannot recover: with the reason from heal (want 1, got 0)
  FAIL  heal cannot recover: and never logs 'healed rc=' (want 0, got 1)
  FAIL  heal missing: reported (want 0, got 1)
  FAIL  heal missing: the watcher is still running (want 1, got 0)
launcher-logging: FAIL
```

## Output: tests/install-rc.sh, OLD code (new test file): FAIL lines
```
  FAIL  broken .profile: install finishes, and exits non-zero because it skipped a file (want 1, got 0)
  FAIL  systemctl enable fails: install exits non-zero (want 1, got 0)
  FAIL  systemctl enable fails: the reason is printed (want 1, got 0)
  FAIL  systemctl enable fails: it is in launcher.log too (want 1, got )
  FAIL  systemctl disable fails: uninstall exits non-zero (want 1, got 0)
  FAIL  systemctl disable fails: the reason is printed (want 1, got 0)
  FAIL  no systemd user manager: install says the watcher was skipped, exit 0 (want 0 1, got 0 0)
  FAIL  no rc file updated: install exits non-zero (want 1, got 0)
  FAIL  no rc file updated: says hover is NOT active (want 1, got 0)
  FAIL  unreadable rc on uninstall: named, exit non-zero (want 1 1, got 0 0)
  FAIL  shim missing: the function says it is running plain claude (want 1, got 0)
  FAIL  status: a missing installed copy is named MISSING (want 1, got 0)
  FAIL  status: says where tmux's socket will live (want 1, got 0)
install-rc: FAIL
```

## Output: tests/launcher-logging.sh, NEW code
```
shim
  PASS  python3 missing: plain claude still starts (twice)
  PASS  python3 missing: the reason is logged
  PASS  python3 missing: the second start did not log it again (rate limited)
  PASS  hover link dangling: plain claude still starts (twice)
  PASS  hover link dangling: the reason is logged
  PASS  hover link dangling: the second start did not log it again (rate limited)
  PASS  nfpty import broken: plain claude still starts (twice)
  PASS  nfpty import broken: the reason is logged
  PASS  nfpty import broken: the second start did not log it again (rate limited)
  PASS  nfpty fails at start: plain claude still starts (twice)
  PASS  nfpty fails at start: the reason is logged
  PASS  nfpty fails at start: the second start did not log it again (rate limited)
  PASS  nf_log never fails even if the state dir cannot be created
heal
  PASS  ss missing: heal exits 3 (not a silent 0)
  PASS  ss missing: says why on stderr
  PASS  ss missing: logged, once across two runs
  PASS  ss format drift: heal exits 3
  PASS  ss format drift: the unparsed line is named
  PASS  ss format drift: logged
  PASS  ss fails: heal exits 3 with the reason
  PASS  cannot recover: heal exits 3
  PASS  cannot recover: no 'socket recreated' success claimed
  PASS  cannot recover: the reason is logged
  PASS  cannot recover: and no success is in the log
watcher
  PASS  inotify_add_watch fails: reported in launcher.log
  PASS  inotify_add_watch fails: with the errno text
  PASS  inotify_add_watch fails: once per directory, not per rescan
  PASS  ss fails: reported in launcher.log
  PASS  ss fails: once, not every rescan
  PASS  heal cannot recover: the watcher logs NOT HEALED
  PASS  heal cannot recover: with the reason from heal
  PASS  heal cannot recover: and never logs 'healed rc='
  PASS  heal missing: reported
  PASS  heal missing: the watcher is still running

launcher-logging: PASS
rc-done
```

## Output: tests/install-rc.sh, NEW code
```
  PASS  login shell, before install: PATH lookup finds the real binary
  PASS  install: rc block present
  PASS  install: shim copied
  PASS  install: a backup of the old rc exists
/tmp/nf-install-IATDZU/home/.bashrc: line 22: id: command not found
  PASS  PATH: shim first, once, from nothing
/tmp/nf-install-IATDZU/home/.bashrc: line 22: id: command not found
  PASS  PATH: shim already first
/tmp/nf-install-IATDZU/home/.bashrc: line 22: id: command not found
  PASS  PATH: shim already last
/tmp/nf-install-IATDZU/home/.bashrc: line 22: id: command not found
  PASS  PATH: shim in the middle
  PASS  login shell, after install: PATH lookup finds the shim too
  PASS  bash -ic: claude is a function (the shim's)
  PASS  bash -lic: claude is a function (the shim's)
  PASS  reinstall: still exactly one block
  PASS  status: a stale copy is named
  PASS  status: clean after a reinstall
  PASS  uninstall: rc is back to the original
  PASS  uninstall: .profile is back to the original
  PASS  uninstall: the backup is gone
  PASS  uninstall: ~/.nerdflair is gone
  PASS  uninstall: a differing backup is kept
  PASS  uninstall: and its path is printed
  PASS  broken .profile: install finishes, and exits non-zero because it skipped a file
  PASS  broken .profile: and names the file
  PASS  broken .profile: the other files still got the block
  PASS  broken .profile: uninstall finishes and removes the shim
  PASS  alias claude: still the function
  PASS  legacy .zprofile block removed by install
  PASS  alias warning printed
  PASS  all skipped: the summary says so
  PASS  no login file at all: ~/.profile is created with the block
  PASS  a login shell with no prior files now gets the function
  PASS  three login files: only .bash_profile has the block
  PASS  backup holds the pristine original after repeat installs
  PASS  backup is not overwritten by a later changing install
  PASS  late .bash_profile: status says to re-run install
  PASS  late .bash_profile: install gives it the block
  PASS  function runs the shim
  PASS  no shim: the function falls back to the real claude
  PASS  dash sourcing the login file: no bad substitution / syntax error
  PASS  created-empty .profile is removed by uninstall
  PASS  uninstall with no login file: no marker complaint
  PASS  a user's own empty .profile survives uninstall
  PASS  stale entry: forgotten once the file is gone
  PASS  stale entry: the user's later empty .profile survives
  PASS  CRLF marker on uninstall is named
  PASS  spaced HOME: block installed in .bashrc and the login file
  PASS  spaced HOME: uninstall restores .bashrc
  PASS  systemctl enable fails: install exits non-zero
  PASS  systemctl enable fails: the reason is printed
  PASS  systemctl enable fails: it is in launcher.log too
  PASS  systemctl enable fails: the rc block was still installed
  PASS  systemctl ok: install exits 0 and says the watcher runs
  PASS  systemctl disable fails: uninstall exits non-zero
  PASS  systemctl disable fails: the reason is printed
  PASS  no systemd user manager: install says the watcher was skipped, exit 0
  PASS  no rc file updated: install exits non-zero
  PASS  no rc file updated: says hover is NOT active
  PASS  unreadable rc on uninstall: named, exit non-zero
  PASS  shim missing: the function says it is running plain claude
  PASS  status: a missing installed copy is named MISSING
  PASS  status: says where tmux's socket will live

install-rc: PASS
rc-done
```

## Output: tests/tmux-heal.sh, NEW code
```
  PASS  scratch server is reachable
  PASS  healthy server: heal is a no-op, still reachable
  PASS  socket directory gone: server unreachable
  PASS  after heal: reachable again
  PASS  after heal: socket exists
  PASS  after heal: the session survived
  PASS  a planted symlink is not followed or healed
  PASS  nothing was created behind the symlink
  PASS  two servers: the broken one is healed
  PASS  two servers: the healthy one kept its socket inode (never signalled)
  PASS  two servers: the healthy one kept its pid and session
  PASS  spaced path: server unreachable
  PASS  spaced path: healed

tmux-heal: PASS
rc=0
```

## Output: tests/tmux-watch.sh, NEW code
```
  PASS  control, no watcher: server stays unreachable
  PASS  scratch server is reachable
  PASS  with the watcher: reachable again within 10 s
  PASS  the session survived
  PASS  the log says what was deleted
  PASS  the log lists running processes
  PASS  the log records the heal
  PASS  a decoy named tmux-UID-x is ignored

tmux-watch: PASS
rc=0
```

## Output: tests/bridge-selfchecks.sh, NEW code
```
  PASS  nfpty ok
  PASS  panel ok
  PASS  shadow ok
  PASS  logcheck: PASS
  PASS  mklayout ok
  PASS  cards ok: 315 rows, 16 readouts, all with cards

bridge-selfchecks: PASS
rc-done
```

## Other changed tests, NEW code (tail)
### empty-home
```
  PASS  HOME unset: the renderer ran (exit 0, non-empty output)
  PASS  HOME unset: nothing written to the working directory
  PASS  HOME empty: the renderer ran (exit 0, non-empty output)
  PASS  HOME empty: nothing written to the working directory
empty-home: PASS
rc-done
```
### ledger-concurrency
```
  PASS  locked: no row lost under compaction         0
  PASS  locked: no malformed rows                    0
  PASS  control: unlocked arm DOES lose rows         33 rows lost, as it must
  PASS  lock inode survived every compaction         inode 74315736
  PASS  stale mkdir lock cleared, not wedged         row appended, lock is a file

ledger-concurrency: PASS
rc-done
```
### validate-ledger
```

  window       rust       bash    recount    delta
  1h          18.20      18.20      23.45   -22.4%  outside +2%/-10%
  3h          42.76      42.76      47.60   -10.2%  outside +2%/-10%
  4.8h        56.67      56.67      60.96    -7.0%  ok

validate-ledger: FAIL
rc-done
```
### nfpty-exit
```
  PASS  child killed by SIGTERM exits 143
  PASS  plain exit 0
  PASS  output written just before exit is not lost
  PASS  ignored SIGTERM: the child is killed (137)
  PASS  ignored SIGTERM: within about 2 s of the signal

nfpty-exit: PASS
rc-done
```
### test-nerdflair (tail), difftest (tail)
```
  test_renderer_zero_cost_not_shown                      ok

Results: 67 passed, 0 failed

[32m162/162 identical[0m
```

## shellcheck 0.x on changed scripts (warnings and above)
Only two remain, both pre-existing: SC2174 (mkdir -m with -p in heal) and SC2034 (unused var in ledger-concurrency.sh).

## Old-tree validate-ledger
Old script, no bash renderer in the extracted tree: `validate-ledger: SKIP: could not read a figure (rust='18.45' bash='' recount='23.63')` (exit 77). The new script reports a missing figure as FAIL.

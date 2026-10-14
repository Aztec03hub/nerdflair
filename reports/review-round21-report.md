# Review round 21 (independent, read-only) of defbf00

Scope: `git diff e472314..defbf00` (round 20 fixes), then the wider silent-failure work (`0c38a90..defbf00`). Round 18, 19, 20 reports and worklog-round19-fixes read first; their fixed items and the deferred /tmp git-cache symlink item are skipped. Source files were not edited. Ran nothing in the repo tree; the two renderers were run from a scratch dir under the session scratchpad (throwaway HOME, NERDFLAIR_ERR_STAMP_DIR) to reproduce findings 2 to 6. Not run: `bun test`/`claude plugin test band` (register.tsx findings are from reading).

Round 20 fixes confirmed in the diff: Rust `cwd_ok` + `cwd-cd` note (main.rs:517-523), literal memo key (lib.sh:114), `cache ||` gate dropped and `lastFailAt` stamped after the refresh (register.tsx:377, 548), `multi-cache-read` in both twins (main.rs:659-671, statusline.sh:549-554), cards-check seeding with O_NOFOLLOW and a throwaway repo (mklayout.py:332-364).

## 1. MEDIUM - bash `_nf_cmd` treats only rc 124 as a timeout; `timeout -k 1` returns 137 when it had to KILL
scripts/statusline.sh:32-34 (`timeout -k 1`), :56 (`elif (( _rc == 124 ))`).
Scenario: a git (or a child it spawned, an fsmonitor hook, a credential helper) that ignores SIGTERM. `timeout` waits 1 s, sends KILL and exits 137 (reproduced: `timeout -k 1 1 bash -c 'trap "" TERM; sleep 5'` returns 137). The code then logs `git:status:137 failed: (no stderr)`, does NOT set `_NF_GIT_TIMED_OUT`, does NOT touch `git-hung`, and the render carries on with empty output. Every later git call waits its own full 10 s + 1 s, and the empty result is written to /tmp/nerdflair-git-<cksum> as "clean, no branch" for the TTL. That is exactly the poisoned-cache and no-breaker case round 18/19 closed for rc 124. Rust kills with SIGKILL at the deadline, so the twins differ here.
Fix: `(( _rc == 124 || _rc == 137 ))` in the timeout branch (137 is also an external SIGKILL/OOM; for git that is still "not a statement about the repo"). Add a silent-failures fixture with a fake `git` that does `trap '' TERM; sleep 30` and expect one `timeout:` line and no cache write for both impls. Note for the record: a child in uninterruptible I/O cannot be reaped by `timeout` at all, so the `$(...)` still blocks; Rust bounds the reap (proc.rs:102-108), bash cannot without a background-and-poll wrapper.

## 2. MEDIUM - bash cannot repair a 0-byte state.json; it stays broken for every render
scripts/lib.sh:284-287, :292-316 (`_nf_write_state`), :337-345 (`_nf_state_heal`).
Reproduced: `: > ~/.claude/nerdflair/state.json`, then 4 bash renders. File still 0 bytes; log has `state-rebuilt ... unparseable ()` and `state-write ... jq: invalid JSON text passed to --argjson`.
Cause: `jq -c '.chime_recent_styles // []' emptyfile` exits 0 with EMPTY output, so line 284 does not take the failure branch and `recent_styles=""`; `--argjson recent ""` then fails. The heal path runs (jq -e . fails), copies the file to .corrupt, and the write that should rebuild it fails. Rust handles the same file (state.rs:185-197 resets history, writes defaults). Settings and last_session are never persisted by the bash renderer, and the state-write line is the only trace.
Fix: after line 287 add `[[ -n "$recent_styles" ]] || recent_styles="[]"` (cover the rc-0-empty case), and log it. Add a silent-failures case "empty state.json is rebuilt" for both impls, asserting the file parses afterwards.

## 3. MEDIUM - non-numeric `chime_volume`: Rust and bash print different status lines, bash also executes the value inside an awk program
rust/src/main.rs:1767, :1789 versus scripts/statusline.sh:2185, :2208.
Reproduced with a full state file (`chime_style":"random","chime_volume":"loud"`, no cost): Rust prints `random` (NaN becomes 100, so no percent), bash prints `random 0%` (awk reads `loud` as an unset variable = 0). Stdout md5 differs. Neither logs anything. The difftest corpus has no case with a bad volume.
Second problem, bash only: `awk "BEGIN {printf \"%g\", ${_SL_CHIME_VOLUME:-1} * 100}"` splices the state-file string into awk source. A value such as `1); system("...` runs a command on every render. The state file is user-owned, so this is hardening, not remote; but it is exactly the class the validated twin avoids.
Fix: in both twins validate `^[0-9]*\.?[0-9]+$` once where the volume is read; on failure `note`/`_nf_err chime-volume` ("chime_volume %q is not a number; shown as 100%") and use 1. Pass the value to awk with `-v v="$vol"` instead of splicing. Add a difftest payload with a bad volume.

## 4. LOW-MEDIUM - bash: non-integer usage in the transcript is an arithmetic error on stderr and no log line; Rust logs it
scripts/statusline.sh:881-887 versus rust/src/main.rs:870-881 (`ctx-usage-type`).
Reproduced with `"cache_read_input_tokens":12.5`: Rust logs `ctx-usage-type ... counted as 0`; bash prints `statusline.sh: line 885: 12.5: syntax error: invalid arithmetic operator` on stderr (the host can show it) and logs nothing. Stdout is identical (gauge reads 0%), so difftest and silent-failures cannot see it.
Fix: before the `$(( ))`, test each of `u_input u_cache_create u_cache_read u_output` against `^[0-9]+$`; if not, `_nf_err ctx-usage-type "usage.<field> = <v> is not an integer; counted as 0"` and set it to 0. Add a silent-failures case for both impls.

## 5. LOW-MEDIUM - bash: `cd "$project_dir"` with no redirect; Rust and bash diverge when the dir cannot be entered, and neither logs
scripts/statusline.sh:126 versus rust/src/main.rs:403-407.
Reproduced with a project/current dir that exists but has mode 000: bash prints `cd: ...: Permission denied` on stderr, `project_dir` becomes empty (so the per-repo cost chip is dropped: stdout differs, `$1.25` chip missing), Rust keeps the unresolved path (canonicalize failing is ignored, :404) and draws the chip. Rust additionally logs `spawn:git` and `cwd-read`, bash logs `cwd-cd` (different keys, same cause).
Fix: bash `project_dir=$(cd "$project_dir" 2>/dev/null && pwd -P) || { _nf_err project-dir-resolve "cannot resolve $project_dir"; }` keeping the raw path on failure; Rust `else` branch of :404 notes the same key. Align the cd test: Rust `Path::is_dir()` (:517) is true for a dir bash cannot `cd` into; use `std::env::set_current_dir`-style access check (`read_dir` or `metadata` plus execute bit) so both give the `cwd-cd` line.

## 6. LOW-MEDIUM - an unusable stamp directory is never reported, so every back-off silently stops working
rust/src/errlog.rs:49-55 (`None` returned with no note), scripts/lib.sh:55-61 (`_NF_SDIR` left empty); consumers: proc.rs:60 and statusline.sh:46-49 (`git-hung`), state.rs:253 and lib.sh:355 (`state-write-retry`).
Scenario: ~/.claude/.nerdflair-stamps is a symlink, a plain file, or owned by another uid (a sudo-run first render, restored backup). `stamp_dir()` returns None. `recent()` is then always false, so the 60 s git back-off never engages (10 s stall per render after a hang, the round 20 #6 note) and the state-write retry back-off never engages; every key logs once per process, so each render appends every failure line again. grep for stamp-dir logging finds nothing outside errlog.rs; round 20 #6 said the failure "is logged elsewhere", it is not. Calling `note()` from inside the OnceLock initialiser would deadlock, so this needs a direct write.
Fix: in the `None` branches call `emit("stamp-dir", ...)` directly (it does not use stamp_dir) and rate-limit it with a marker file directly under ~/.claude opened with O_NOFOLLOW; bash `_nf_log_line` with a `[[ -e ~/.claude/.nerdflair-stamp-dir-bad ]]` marker. Add a silent-failures case with the stamp dir pre-made as a symlink.

## 7. LOW - bash twin has no git timeout at all when `timeout` is not installed, and says nothing
scripts/statusline.sh:32-39 (`if command -v timeout ...`, no `else`).
Scenario: macOS without coreutils, or a minimal container. `_NF_TCMD` stays empty, every git runs unbounded, and the status line can hang until the host kills it with no trace. Rust has its own deadline, so the twins differ. (gtimeout is not tried.)
Fix: `else _nf_err no-timeout "timeout(1) not found; git runs without a deadline"`, and try `gtimeout` first.

## 8. LOW - git detection `cd` race: Rust runs git in the PARENT directory, bash logs and skips
rust/src/main.rs:2106-2109 versus scripts/statusline.sh:394-397.
`git_cache` only repoints `shell_cwd` when `git_dir` is currently a directory; otherwise it silently keeps the previous cwd (the wrapper folder or process cwd) and runs status/diff there. Bash logs `cwd-cd` and drops the git UI. Reachable when the adopted subrepo is removed or renamed between detection (:559) and the call, or when a worktree dir is deleted mid-session. Result: the branch and dirty count of another repo under the Rust renderer, no log.
Fix: `else { errlog::note("cwd-cd", ...); return GitCache::default(); }`, and add a case that removes the adopted repo between detection and cache (or unit-test `git_cache` with a missing dir).

## 9. LOW - register.tsx, test and comment gaps in the round 20 fix
band/hooks/register.tsx:548, band/hooks/register.test.ts (new test at the end of the stale-cache tests).
- The reason for the change (stamp the failure AFTER a 5 s timeout) is not tested: the fake `process.run` returns instantly, so `lastFailAt` equals `now` either way, and the new test would pass with the old line. Add a case where the fake run advances the clock by 5 s before returning an error and assert one spawn per back-off, not two.
- `lastFailAt = await $.clock.now()` is outside the refresh `try`; a rejecting clock throws out of `band()` (caught and reported at :345, so not silent), but it also leaves `cache` un-nulled for that render. Fine; noting only.
- A successful refresh still stores `cache = { at: now, segs }` with the PRE-refresh `now` (:536), so a renderer that takes 2 s or more produces a cache that is already past TTL_MS and is re-run on the next render with no back-off. Fix: `at: await $.clock.now()`.
- Module-level `lastFailAt` (:298) is shared across tests and sessions; tests only pass because a failed test is followed by a success that resets it. Reset it in the test `world()` helper.

## 10. LOW - cards-check is narrower than it looks, and its git setup fails with a bare traceback
band/bridge/mklayout.py:343-364, :371-372.
- Every `@@REPO:x@@` token is replaced by ONE dirty repo. The corpus fixtures for multi-repo wrappers, linked worktrees, detached HEAD and no-origin are all flattened into the same state, so readouts reachable only through them (multi-branch list, worktree marker) are no longer exercised by `want <= seen`. Today the check still passes; a card for one of those readouts could go unmatched without failing. Fix: build the same fixture set difftest.sh builds (`resolve_repo`, tests/difftest.sh:260-265), or assert the multi-repo readout separately.
- The token regex `[a-z0-9_-]+` (mklayout.py:371) differs from difftest's `[a-z0-9-]+` (difftest.sh:498); a future fixture name with an underscore would be replaced in one harness and not the other.
- `subprocess.run(["git", ...], check=True)` raises CalledProcessError (no message about which step) if git is absent, `commit.gpgsign=true` is set globally, or `GIT_DIR`/`GIT_INDEX_FILE` leak in from a hook. Run with `env` stripped of `GIT_*` and `-c commit.gpgsign=false`, and catch the error into the same one-line `sys.exit(...)` the seed step uses.
- Unused `seen, misses, rows = set(), {}, 0` and an inner `import glob` in `_cards_check_body` (:340-341).

## 11. LOW - small items found on the way
- rust/src/util.rs:312-315: `uid()` falls back to 0 when /proc is unreadable and `id -u` fails or prints garbage (`unwrap_or(0)`, `Err(_) => 0`) with no note. Uid 0 then mismatches the stamp dir owner (errlog.rs:53), so finding 6 triggers with no explanation, and tmux cache names (main.rs:1680) change. Fix: log once from the fallback.
- rust/src/errlog.rs:111-133 (`trim`): metadata/read/write/rename failures all return silently, so a log that can never be trimmed grows without limit. Fix: `eprintln!` once per failure kind (the logger's own stderr last resort).
- rust/src/main.rs:1695-1698: `tmux display-message` failure logs "failed; session name segment hidden" without the reason (`proc::out`, not `out_chk`); use `out_chk` with label `tmux`. The cache key is only the pane id (`%9`), so two tmux servers share a name for 60 s.
- rust/src/main.rs:1774-1781 and statusline.sh:2192: the chime label's second read of state.json swallows errors (`.ok()` / `|| true`); duplicate of a logged `state-corrupt` in the same render, as round 19 noted, still unlogged if only this read fails (permission change between reads).
- tests: no case for the second bash `cwd-cd` (statusline.sh:394-397), for `multi-cache-read` (acknowledged in the worklog), or for a payload cwd that exists but cannot be entered (finding 5).

## Checked and fine
- git_cache fresh/computed/timed-out handling (main.rs:2218-2246) and its bash twin (statusline.sh:468-479): a timeout keeps the last file, a failed write keeps the fresh value, `git-cache-read` only logs with no computation in hand.
- `cwd-cd-fails` now runs for both impls and difftest payload 163 gives identical stdout; stamps and `_nf_err` memo are literal for glob characters.
- mklayout.py seed file: O_NOFOLLOW|O_CREAT|O_TRUNC, OSError becomes a clear exit, removal in `finally`.
- payload-shape logging in `extract` (main.rs:80-150), `load_claude_json` (:195-238), `read_state`/`atomic_write` (state.rs:43-245), `read_ring` (main.rs:2590-2600), nf-tmux-watch `transition` and `_append`: every failure branch I read logs or is a documented normal answer.

## Not verified
register.tsx findings (9) were read, not run (`bun test` needs the engine). I did not run tests/difftest.sh, silent-failures.sh or any repo tests this round. Finding 1's 137 path was reproduced with `timeout` itself, not through statusline.sh.

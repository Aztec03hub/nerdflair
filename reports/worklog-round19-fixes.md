# Round 19 fixes (uncommitted, on 81170ba)

## Per finding
1. Bash git circuit breaker: `_nf_cmd` (scripts/statusline.sh) sets `_NF_GIT_TIMED_OUT` on rc 124 for git and returns 124 at once for later git calls; git cache and multi-repo cache writes are skipped after a timeout; the git-branch note is suppressed after a timeout, as in Rust. silent-failures: `git-partial-hang` and `git-fast-control` now run for both impls.
2. Cross-render back-off, both impls: a git timeout touches stamp `git-hung` (proc.rs `errlog::touch`, bash `_nf_touch`); a render within 60 s of it skips git (`errlog::recent` / `_nf_recent`). New case `git-hang-backoff` (both impls, expects 0 timeout lines).
3. Fresh computed value beats the cache file after a failed write: Rust `git_cache` (`computed.take()` unless timed out) and the multi-repo cache; bash `_gc_computed` / `_mb_have`. After a timeout the last file is preferred, as before.
4. statusline.sh mktemp failure: logs `buf-mktemp` (sources lib.sh early) and buffers under ~/.claude. New case `mktemp-fails` (bash, TMPDIR=/nonexistent/nf).
5. Bash `cd` failures log `cwd-cd` and skip the git UI (cwd and git_dir). New case `cwd-cd-fails` (bash only; Rust reports the bad dir as `spawn:git`).
6. NOT changed: git cache files still in /tmp (symlink hardening is a design change, left for a decision).
7. lib.sh `_nf_err` memo match now quotes the key.
8. Bash tmp-write keys are now `tmp-write:<file name>` at all four sites.
9. register.tsx: notes for missing ctx.window, cost.usd, percentUsed (5h/7d), resetsAt; toast in `popup.fail` wrapped in try/catch; 5 s back-off after a failed refresh when there is no cache (`lastFailAt`).
10. lib.sh `_nf_read_recent_styles` no longer merges jq stderr into the list (stderr re-run only on failure for the log line); proc.rs doc comment moved onto `fn run`; `tput cols` non-numeric now logs `columns-bad`.

## Old-code check
With scripts, rust/src, band, tests stashed (src only plus build), silent-failures failed: git-partial-hang cache written, git-partial-hang rust vs bash stdout differs, git-hang-backoff [rust] and [bash], cwd-cd-fails [bash], mktemp-fails [bash]. Stash popped, `git stash list` empty. (The old-code run used the old source with a rebuilt binary.)

## Final runs (rebuilt, cargo build --release OK)
- tests/silent-failures.sh: PASS
- tests/difftest.sh: 162/162 identical
- tests/bridge-selfchecks.sh: PASS (one earlier run failed `cards no real readout reaches: ['tmux']`; it did not reproduce in 4 later runs, including on the old code, so it looks flaky/environmental)
- tests/golden-mutation.sh: PASS, every mutation killed
- tests/empty-home.sh, install-rc.sh, launcher-logging.sh, popup-errors.sh: PASS
- claude plugin test band: 11 pass, 0 fail (the first try failed 1 test because the back-off hid a good refresh; back-off now applies only without a cache)

Not done: 6 (symlink-safe caches), the two other lows in 10 (chime label duplicate path, `.err` redirect wording).

# Round 20 fixes (uncommitted, on e472314)
1. Rust logs `cwd-cd` and skips git when the payload cwd is not a directory (main.rs, `cwd_ok`). `cwd-cd-fails` now runs for both impls (stdout byte-identical). New corpus payload 163 (nonexistent cwd; gen-payloads.sh updated). Old code: `cwd-cd-fails [rust]` FAILED. difftest runs from a neutral non-repo cwd, so it was 163/163 on old code too; the silent-failures case is the real guard.
2. lib.sh `_nf_err` memo is now `[[ "$_NF_MEM" == *" $_k "* ]]` (literal). New test with keys `spawn:abc`, `spawn:*`, `spawn:xyz` expects 3 lines; it FAILED on old code.
3. register.tsx: dropped the `cache ||` gate; `lastFailAt = await $.clock.now()` after the refresh settles. New test "spawned once per 5 s, even while a stale cache exists" FAILED on old code. The existing stale test advances 6 s instead of 3 s so the back-off has expired before the good refresh.
4. `multi-cache-read` logged in both renderers when the multi cache read fails with no computation in hand (quiet after a git timeout). No dedicated test added.
5. mklayout.py cards-check: O_NOFOLLOW seed, OSError gives a clear message and exit, file removed in `finally` (checked with a planted symlink: "Too many levels of symbolic links" message). Side fix: cards-check now feeds the corpus with `@@REPO:x@@` pointed at a throwaway dirty repo; before, the `dirty` readout was reached only by accident through Rust running git in the process cwd, which finding 1 removed (this also explains the earlier flaky `tmux` failure).

Final runs after rebuild: silent-failures PASS; difftest 163/163 identical; bridge-selfchecks PASS (run after difftest); golden-mutation PASS; empty-home PASS; install-rc PASS; launcher-logging PASS; popup-errors PASS; claude plugin test band 12 pass, 0 fail. `git stash list` empty.

# Round 21 fixes (uncommitted, on defbf00)
Skipped (as instructed): the /tmp git-cache symlink item. Not testable: the second bash `cwd-cd` (adopted repo vanishing between detection and the cache call) is a race; the Rust twin now returns None and clears `git_dir` like bash, covered by code only.
1. Bash `_nf_cmd` treats rc 137 (`timeout -k` had to KILL) as a timeout. New case `git-term-ignored` (both impls, git ignores TERM, expects one `timeout:git:status` and no cache file).
2. lib.sh `_nf_write_state`: an empty state.json (jq rc 0, no output) now resets history to `[]` and logs `state-empty`; the file is rebuilt. Case `state-empty-file`: bash rebuilds valid JSON with no `state-write` line, Rust logs `state-corrupt` (it never rewrites).
3. Non-numeric `chime_volume`: both twins validate `^[0-9]*\.?[0-9]+$`, log `chime-volume`, use 1 (100%); bash passes the value to awk with `-v` (no splicing). Case `chime-volume-bad` and difftest payload 164.
4. Bash non-integer usage fields log `ctx-usage-type` and count as 0 (case `usage-not-integer`).
5. Bash `cd "$project_dir"` is quiet and logs `project-dir-resolve`, keeping the raw path; Rust notes the same key and now uses `can_enter` (is_dir plus the execute bit) for both project_dir and cwd, so a mode-000 dir gives `cwd-cd` in both. Cases `cwd-not-enterable`, `project-dir-locked`.
6. Unusable stamp dir: Rust `stamp_dir_bad` (direct `emit` plus an O_NOFOLLOW marker `~/.claude/.nerdflair-stamp-dir-bad`, hourly) and the bash twin in `_nf_stamp_dir` log `stamp-dir`. Case `stamp-dir-symlink`.
7. Bash with no `timeout` tries `gtimeout`, else logs `no-timeout`.
8. Rust `git_cache` returns `Option`: a git_dir that cannot be entered logs `cwd-cd`, and `git_dir` is cleared (no git run in the parent dir).
9. register.tsx: successful refresh caches at the post-refresh clock; `lastFailAt` reset in `resetStateForTests` (used by the test `world()`). Tests: slow failing renderer backed off from its failure, and slow successful renderer leaves a fresh cache (the latter failed on old code; the former guards the round 20 stamp placement).
10. mklayout cards-check: fixtures now include a wrapper of two repos, a linked worktree, detached HEAD and a no-origin repo, with the difftest token regex `[a-z0-9-]+`; GIT_* stripped, signing off, git failures give a one-line `sys.exit`; dead code removed. This exposed a real gap: multi-branch list pieces (`bravo:bugfix/bravo`) had no card, so the branch card now also matches `name:branch`.
11. `uid()` is `libc::getuid()` (no silent 0 fallback); errlog `trim` writes each failure to stderr; `tmux display-message` uses `out_chk` label `tmux` (reason in the log); the chime-label state re-read logs `chime-label-read` in both twins. Case `multi-cache-unreadable` added (it already passed, since round 20 logs it).

Old-code check (scripts, rust/src, register.tsx, mklayout.py stashed; tests kept): silent-failures failed on git-term-ignored [bash], cwd-not-enterable [rust], project-dir-locked [both], chime-volume-bad [both], usage-not-integer [bash], state-empty-file [bash], stamp-dir-symlink [both]; difftest failed; band test "slow renderer that succeeds leaves a cache that is fresh" failed. Stash popped, list empty.

Final runs after rebuild: silent-failures PASS; difftest 164/164 identical; bridge-selfchecks PASS (after difftest); golden-mutation PASS; empty-home PASS; install-rc PASS; launcher-logging PASS; popup-errors PASS; claude plugin test band 14 pass, 0 fail.

# Round 22 fixes (uncommitted, on 11d4ea5)
1. Stamp-dir marker: a symlink marker (dangling or not) can never be written (O_NOFOLLOW), so both twins now stay quiet instead of logging every render (Rust `symlink_metadata`, bash `[[ -L ]]`). Case `stamp-marker-dangling` expects 0 lines after 4 renders (old code: 4 per impl).
2. chime_volume is validated once in lib.sh `_nf_read_state` (log `chime-volume`, default 1), so bell.sh and nerdflair.sh agree with the renderer; the duplicate in statusline.sh is gone (Rust keeps its own twin check). New standalone checks: bell.sh logs the line, and lib.sh yields 1 for "loud" (both failed on old code).
3. Bash `_nf_cmd`: 137 counts as a timeout (and arms `git-hung`) only when the command ran at least the deadline (`EPOCHREALTIME`, helper `_nf_ran_to_deadline`); otherwise it logs `killed:<label>` as an external kill, still marks the output untrusted, and arms no back-off. Case `git-killed-externally` (bash).
4. Low items: errlog `trim` stat warning is once per process; `can_enter` uses `faccessat(AT_EACCESS)` (effective ids, like cd); register.tsx falls back to the pre-refresh time with a `clock` note when `clock.now()` rejects after a good refresh (no dedicated test: mock.clock cannot reject).
Report item 4 (no-timeout ordering) needed no action.

Old-code check (scripts, rust/src, register.tsx stashed): silent-failures failed on stamp-marker-dangling [both], git-killed-externally [bash] (both checks), bell.sh volume, lib.sh volume. Stash popped, list empty.
Final runs: silent-failures PASS; difftest 164/164 identical (one run showed payload 145 UNSTABLE, differed once and matched on retry; two reruns were clean); bridge-selfchecks PASS (after difftest); golden-mutation PASS; empty-home PASS; install-rc PASS; launcher-logging PASS; popup-errors PASS; claude plugin test band 14 pass, 0 fail.

# Round 23 fixes (uncommitted, on 18f86a3)
1. Stamp-dir marker: a symlink marker now counts as "not recent" in both twins (errlog.rs `!is_symlink() && age < RATE`; lib.sh one `if [[ -L ]] || [[ ! -e ]] || age >= 3600`), so the line is logged once per render. `stamp-marker-dangling` now expects 4 (old code: 0 lines, failed in both twins).
2. `_nf_ran_to_deadline` and `_nf_cmd` strip `EPOCHREALTIME` with `//[.,]/` and treat a non-numeric result as "ran to the deadline" (no arithmetic error). Not testable here: only the C locale is installed.
3. register.tsx: `lastFailAt = await $.clock.now()` is guarded like the success path (note `clock`, falls back to the earlier time). No test (mock.clock cannot reject).
4. New Rust case `git-killed-externally-rs`: a SIGKILLed git logs `git:status:signal` (not `timeout:`) and arms no `git-hung` stamp.
Final runs: silent-failures PASS; difftest 164/164 identical; bridge-selfchecks PASS (after difftest); golden-mutation PASS; empty-home PASS; install-rc PASS; launcher-logging PASS; popup-errors PASS; claude plugin test band 14 pass, 0 fail. Stash list empty.

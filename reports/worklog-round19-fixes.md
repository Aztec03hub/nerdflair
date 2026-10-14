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

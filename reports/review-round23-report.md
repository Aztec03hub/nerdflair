# Review round 23 (read-only) of 18f86a3

Scope: `git diff 11d4ea5..18f86a3`, then the wider silent-failure work. Rounds 18 to 22 reports and worklog-round19-fixes read first; fixed items and the /tmp git-cache symlink item skipped. No source in the repo was edited. The proposed fix was built and tested in a scratch copy (`git ls-files` copy under the session scratchpad, `r23/`).

Ran in the repo: `tests/difftest.sh` = 164/164 identical. `bash tests/silent-failures.sh` = PASS (the file is not executable, so `tests/silent-failures.sh` directly gives "Permission denied"; invoke it with bash). Not run: band tests, bridge selfchecks.

## 1. MEDIUM (user rule) - round 22 stamp-dir change makes a dangling stamp dir plus marker log ZERO lines
rust/src/errlog.rs:83-86 (`stamp_dir_bad`), scripts/lib.sh:65-70 (`_nf_stamp_dir`).
Scenario: `~/.claude/.nerdflair-stamps` is a symlink (planted, or a broken dotfiles link) AND `~/.claude/.nerdflair-stamp-dir-bad` is a symlink. Every back-off and rate limit is then per render only, and the one line that says so is now suppressed forever: `stamp-marker-dangling` asserts 0 lines (silent-failures.sh:368). That is a silent fallback, which the user's rule forbids. It was introduced to stop a per-render repeat, but a per-render line is the honest outcome here, because the marker really cannot rate limit.
An in-memory flag adds nothing: `stamp_dir_bad` already runs once per process (the `OnceLock` initialiser at errlog.rs:44, `_NF_SDIR_DONE` at lib.sh:46). So the per-process limit exists; the symlink exception only removes the log.
Minimal fix (two lines, verified): treat a symlink marker as "not recent", so the line is logged once per process (once per render, since each render is a process):
- errlog.rs:84: `Ok(m) if !m.file_type().is_symlink() && file_age(&marker) < RATE_SECS => return,`
- lib.sh:65-66: replace the `if [[ -L "$_m" ]]; then :` / `elif` pair with one `if [[ -L "$_m" ]] || [[ ! -e "$_m" ]] || (( $(_nf_stamp_age "$_m") >= 3600 )); then`
- silent-failures.sh:368: `stamp-dir 4` (not 0) for `stamp-marker-dangling`, and fix the comment on :293 ("the line must not repeat" becomes "the marker cannot rate limit, so it logs once per render").
Verification in the scratch copy: `cargo build --release` OK; `bash tests/silent-failures.sh` PASS, with `stamp-marker-dangling [rust]` and `[bash]` both "exactly 4 'stamp-dir' line after 4 renders", `stamp-dir-symlink` still exactly 1 for both, stdout byte-identical rust vs bash. The cost is a log line per render in this broken-home case, which is the intended signal; the existing 256 KB trim bounds the file.
Same class, remaining hole: a marker that is a non-symlink but unwritable (read-only `~/.claude`) is already logged per render (age is read through `file_age`), so that case is fine.

## 2. LOW - `_nf_ran_to_deadline` assumes `EPOCHREALTIME` has a dot
scripts/statusline.sh:51-52 and :66.
bash uses the locale radix for `EPOCHREALTIME` (`1792009620,327445` under a comma locale). `${EPOCHREALTIME/./}` then leaves the comma, `(( ))` raises a syntax error (stderr noise into the status line's stderr) and returns non-zero, so a genuine `timeout -k` SIGKILL hang is logged as `killed:` "killed externally", no `git-hung` back-off, and git re-hangs every render. Not reproduced: only the C locale is installed here (a comma locale printed a dot), so this is by reading the bash manual only.
Fix: `local LC_NUMERIC=C` at the top of `_nf_cmd`/the helper does not affect an already-set variable reliably; strip with `${EPOCHREALTIME//[.,]/}` in both places, and treat a non-numeric result as "assume ran to deadline" (the helper's own bash<5 branch), logging nothing new.

## 3. LOW - band `lastFailAt = await $.clock.now()` is unguarded, unlike the post-success one fixed in round 22
band/hooks/register.tsx:555 (compare :540-543).
Scenario: refresh fails and `clock.now()` rejects: `band()` throws out before the stale-cache drop (:556) and `rcSeen` (:562), so the chip shows the render-level error instead of the intended stale/red state. Caught at the render level, so not silent, but it is the same defect class round 22 fixed on the success path.
Fix: `lastFailAt = await $.clock.now().catch((err: unknown) => { note($, 'clock', ...); return now })`; share one helper with :540.

## 4. LOW - the round 22 comment-only item and test gap
- register.tsx clock fallback (round 22 #4) has no test (mock clock cannot reject); acceptable, noted in the worklog. Items 2 and 3 share that gap.
- `git-killed-externally` runs bash only. Rust treats a signal exit separately from its own deadline, so there is no twin to diverge, but nothing asserts that Rust logs a distinct line for an external SIGKILL. Recommend one rust case (kill -9 stub) expecting a non-`timeout:` line and no `git-hung` stamp.

## Checked and fine
- Round 22 #2 chime_volume: lib.sh:280-285 validates once; the regex matches main.rs:376-380 (`^[0-9]*\.?[0-9]+$`); the removed statusline.sh copy leaves `_SL_CHIME_VOLUME` fed by the validated value.
- Round 22 #3 `_nf_cmd` 137 split: arms `git-hung` only past the deadline; both branches set `_NF_GIT_TIMED_OUT`, so the output is distrusted either way; `_t0` empty on bash < 5 falls to "ran to deadline" (old behaviour).
- `can_enter` with `faccessat(AT_FDCWD, ..., AT_EACCESS)`: correct on glibc (and musl emulates it).
- `trim` stat warning: `static WARNED` swap is per process, correct.
- Rust/bash twin divergence: none found besides item 1's pending test count; difftest 164/164 identical, silent-failures byte-identical stdout checks all PASS.

## Verdict
One finding against the user's rule (item 1, MEDIUM, fix verified in a scratch copy: apply it and flip the test count to 4). Items 2 and 3 are LOW; item 4 is a test gap. Nothing else found.

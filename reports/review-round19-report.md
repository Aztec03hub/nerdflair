# Review round 19 (independent, read-only) of 81170ba

Scope: diff 0c38a90..81170ba, with the round 18 and 18b items excluded. Method: read errlog.rs, proc.rs, state.rs, the git/MCP/cache paths of main.rs, lib.sh, statusline.sh (head, _nf_cmd, git block), register.tsx, nflog.py, the shim, install.sh, nf-log.sh, plus the new tests. Ran: tests/silent-failures.sh, launcher-logging.sh, popup-errors.sh, install-rc.sh (all PASS). Could NOT run band/hooks/register.test.ts (`bun test`: "Cannot find module 'claude-code/testing'"; it needs the engine), so the TS findings are read-only.

Round 18 items now fixed and confirmed: lax stamp dir tightened (errlog.rs:56-61, lib.sh:57-61), emit failure still stamps (errlog.rs:198-200, lib.sh:121-122), recovery window is 7 days (errlog.rs:216, lib.sh:135), kill before note (proc.rs:87-88), concurrent HOME lookup shared (register.tsx:358-374).

## 1. HIGH - the bash twin has none of the git-timeout fixes (poisoned cache, no circuit breaker)
scripts/statusline.sh:379-440 (git block), :38-54 (_nf_cmd); tests/silent-failures.sh:304 (`IMPLS=rust` for git-partial-hang).
Scenario: git hangs on a stalled filesystem (the scenario the 10 s timeout exists for). Rust stops after the first timeout (proc.rs:57) and skips the cache write (main.rs:2204). Bash runs every call with its own 10 s `timeout`: inside-work-tree, status, diff, ls-files, symbolic-ref, rev-parse x2-3, remote, rev-list. That is up to roughly 90 s of render, so the host kills the renderer and nothing is drawn. If it does finish, line 439 writes `0\x1f0\x1f0\x1f<empty>...` to /tmp/nerdflair-git-<cksum> unconditionally, so a "clean, no branch" verdict is served for the 3 s TTL. This is exactly the round 18 #1 bug, fixed only in Rust. The test deliberately restricts the case to Rust, so nothing would catch it.
Fix: in `_nf_cmd`, on rc 124 for a git command set `_NF_GIT_TIMED_OUT=1`; at the top of `_nf_cmd` return 124 at once for git when it is set; at line 439 skip the cache write when it is set; drop the `IMPLS=rust` restriction on git-partial-hang (and git-fast-control).

## 2. MEDIUM - no cross-render back-off after a git hang (both renderers)
rust/src/proc.rs:47-58 (process-wide flag only); main.rs:2163, 2204; statusline.sh:28-33.
Scenario: a hung NFS/SMB mount under the repo. Every status line refresh spends the full 10 s in its first git call, then logs nothing new (rate limited), so the user sees a 10 s stall on every refresh, forever. The flag lives for one process, and only one log line per hour exists to explain it.
Fix: on timeout also `errlog::touch("git-hung")`; at the start of a render, if `errlog::recent("git-hung", 60)`, skip git entirely (and serve the last cache file if any). The bash twin gets the same via `_nf_touch` / `_nf_recent`.

## 3. MEDIUM - git cache read prefers a STALE file over the fresh computation when the write failed
rust/src/main.rs:2211-2220 (git_cache); same shape in statusline.sh:439-442; multi-repo listing main.rs:654.
Scenario: the cache file exists, is older than the TTL, and cannot be overwritten (owned by another user in shared /tmp, or read-only). The write fails (logged once an hour as tmp-write), then `read_to_string` succeeds on the OLD file and `computed` is discarded. The branch and dirty count then stay frozen at the old values for as long as the file is unwritable, with only an hourly "git re-runs every render" line that is false (git does re-run, its answer is thrown away).
Same path after a git timeout: a stale file is read in preference to the empty `computed`. That one is arguably fine, but it is silent.
Fix: `computed.take()` first: use `computed` when `Some`, read the file only when it is `None`. In bash, `read` from the file only when no write was just attempted.

## 4. MEDIUM - statusline.sh cannot log its own startup failure (mktemp / exec)
scripts/statusline.sh:10-12.
Scenario: /tmp full, TMPDIR unwritable or missing. `_SL_BUF=$(mktemp ...)` fails, `_SL_BUF` is empty, `exec 3>&1 1>"$_SL_BUF"` fails ("No such file") and a non-interactive shell exits. Output: nothing, in the status line, and nothing in nerdflair-errors.log, because lib.sh is not sourced until line 17 and the EXIT trap is not set yet. This is the one path where the "every absorbed failure leaves a line" rule has no coverage, and it happens in the very condition (full disk) that other failures cluster in.
Fix: `_SL_BUF=$(mktemp ...) || { source lib.sh; _nf_err buf-mktemp "mktemp failed in ${TMPDIR:-/tmp}"; _SL_BUF=$HOME/.claude/.nerdflair-sl.$$; }` (or fall back to `exec 3>&1` with no buffering), and test with `TMPDIR=/nonexistent`.

## 5. MEDIUM-LOW - bash twin: `cd` failure silently runs git in the wrong directory
scripts/statusline.sh:338, :378 (`cd "$cwd" 2>/dev/null`, `cd "$git_dir" 2>/dev/null`).
Scenario: the payload cwd was deleted or is unreadable. `cd` fails quietly, the git commands then run in whatever directory the host launched the script from, which may be another repo. The status line shows THAT repo's branch and dirty count for this session, with no log line. Rust passes the dir to `Command::current_dir`, where a bad dir is a logged spawn error (`spawn:git`), so the twins also disagree.
Fix: `cd "$cwd" 2>/dev/null || { _nf_err cwd-cd "cannot cd to $cwd"; cwd=""; }`, same for git_dir (skip the git block).

## 6. LOW-MEDIUM - /tmp/nerdflair-git-<cksum> and the multi-repo cache still follow symlinks
rust/src/main.rs:645-650, 2204-2207 (`std::fs::write`), statusline.sh:372, 439 (`>`).
Scenario: the stamps were moved out of /tmp for this exact reason (errlog.rs:36-42), but the git caches are still predictable names in shared /tmp (the 32-bit cksum of the directory). Another local user pre-creates `/tmp/nerdflair-git-<n>` as a symlink to a file of the victim (or as their own file with forged content): the next render truncates and rewrites the victim's file with git output (the branch name is attacker-influenced), or serves forged fields. A failed write is logged, but the planted-file case is not an error at all.
Fix: put these caches in the private stamp dir (or `$XDG_RUNTIME_DIR`), or open with O_NOFOLLOW|O_CREAT, check owner == uid before trusting the content.

## 7. LOW - lib.sh `_nf_err` memo is a glob match
scripts/lib.sh:114 `case "$_NF_MEM" in *" ${_k} "*)`.
The unquoted `${_k}` is a pattern. A key holding `*`, `?` or `[` (any `spawn:`/`timeout:` label derived from an argument, env-bad names are safe) either never matches (duplicate lines) or, with `*`, matches every earlier key and silences all later ones for the process. Fix: `*" "${_k}" "*` (quote the key). Keys with spaces still false-positive, as noted in round 18.

## 8. LOW - statusline.sh git-cache failure key differs from Rust
statusline.sh:440 uses the fixed key `tmp-write`; Rust uses `tmp-write:<file name>` (errlog.rs:75). Two different failing files in one hour yield one line in bash, two in Rust. Fix: `_nf_err "tmp-write:${_git_cache_file##*/}" ...` (also the other bash tmp-write sites).

## 9. LOW - register.tsx details
- :466 and :386-405 payload: `ctx.window`, `u.cost.usd`, `five.percentUsed`/`seven.percentUsed` and a missing `resetsAt` are passed through undefined with no note, unlike the fields that were given notes. The renderer then draws a context gauge with an omitted size, or a limit with no reset, silently. Fix: note each, as the neighbours do.
- :687 `fail`: the toast guard covers a rejected promise only. A synchronous throw from `$.ui.toast` inside `fail`, called from the `try` at :694, lands in the `catch` at :695, which calls `fail` again and throws out of the detached async function: an unhandled rejection with no log of its own (the first `note` did log the popup reason). Fix: wrap the toast in `try { ... } catch (e) { note(...) }`.
- :536/:375: with no cache (renderer broken from the start) every render, which the code says arrive faster than the renderer returns, spawns a new renderer (one at a time via `inflight`, up to 5 s each). A permanently failing renderer is re-run back to back, with no back-off like the one added for HOME. Fix: remember `lastTryAt` and skip the spawn for ~5 s after a failure while showing the red band.
- register.test.ts could not be run here; confirm `bun test` in the engine harness.

## 10. LOW - small items still open
- scripts/lib.sh:177: `jq ... 2>&1` still merges jq's stderr into the styles list on success (round 18 #8, not changed).
- rust/src/proc.rs:35-47: the `run` doc comment still sits above `timed_out()` and the `TIMED_OUT` static, detached from `fn run`; the doc of `timed_out` is the second half of that block.
- rust/src/main.rs:970-975: `tput cols` succeeding with non-numeric output falls to 80 without a log (`bash_int(&o).unwrap_or(80)`); the COLUMNS branch logs. Fix: same note as `columns-bad`.
- rust/src/main.rs:1754-1761: a state file that cannot be read/parsed for the chime label silently gives "random"; `state-corrupt` is logged by read_state on the same render, so this is a duplicate path, not a silent one.
- statusline.sh:41-43: if the `$_SL_BUF.err` redirect itself fails, `_e=$(< ...)` errors to the hidden stderr and the log line says "failed: (no stderr)", misleading but not silent.

## Checked and fine
- errlog.rs note/ok/emit ordering; stamp dir verification (uid, symlink) with tighten-then-use; O_NOFOLLOW stamps; mem_seen exact set.
- proc.rs timeout ordering (kill, note, flag, bounded reap); drain threads detached on purpose; stdin/stdout errors in main (BrokenPipe not logged by design).
- mcp-probe shell block (main.rs:2490-2506): recovery rule now matches errlog::ok; an empty `recst` correctly suppresses the recovery line rather than repeating it.
- nf-log.sh:37 prune (anchored, GNU `find -delete` only inside the already-GNU stat path); claude-shim `_marked_fork` and SIGPIPE reset; install.sh uninstall wording and status message; nflog.py never raises.
- All four shell test scripts above pass; silent-failures.sh includes git-hangs, git-partial-hang and git-fast-control, but only for Rust.

## Not verified
register.test.ts and the TS runtime behaviour; the bash twin timeout (finding 1) is from code reading, not a run (the test fixture exists, so adding `bash` to IMPLS for git-partial-hang would prove or disprove it in one run).

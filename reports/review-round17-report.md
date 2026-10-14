# Review round 17: error log (errlog.rs, _nf_err, proc.rs guard, tests)

Scope: `git diff 0c38a90..HEAD -- rust scripts tests/silent-failures.sh`. Read-only, analysis only. Nothing was run.

## Findings, ranked

### 1. MEDIUM - shared-/tmp stamps: a planted file makes the logger spam, or silences it, or disables state writes
- `rust/src/errlog.rs:35-43` (stamp path, `/tmp/nerdflair-err-<uid>-<slug>`, predictable), `:126-134` (`write_stamp`, O_NOFOLLOW), `:137-147` (`note`), `:157-166` (`recent`/`touch`).
- Scenario A (spam): another local user plants a dangling symlink at the stamp name, or a regular file they own, mode 644, mtime 1970. Rust `note` sees `stamp.exists()` false (dangling) or age >= 3600. `write_stamp` then fails (ELOOP / EACCES), the result is ignored (`:145`), and `emit` runs. Every render logs that key, with no rate limit. At several renders per second the log hits 256 KB repeatedly and `trim` runs on almost every emit (see finding 6). The bash twin handles the dangling symlink correctly: `-L` is checked and `touch -h` works on the link. The two twins therefore behave differently (`lib.sh:51,61`). The regular-file-not-ours case spams in both.
- Scenario B (silence): a planted fresh-mtime file, kept fresh by the attacker, suppresses any key for good.
- Scenario C (functional DoS): the same plant on `state-write-retry` makes `errlog::recent("state-write-retry", 60)` true forever. `state.rs:253` and `lib.sh:98,~310` then return early, so `last_session` and settings are never written. A back-off marker in a world-writable dir is a functional input.
- Scenario D (symlink truncate): the MCP probe script in `main.rs:2469-2472` runs `: > "$_st"` with no noclobber and no `-h`. It follows a planted symlink and truncates whatever the victim can write. This is the exact attack the Rust and bash helpers were written to avoid.
- Fix: default the stamp dir to a per-user 0700 dir under `$HOME/.claude/` (for example `.claude/nerdflair-err/`), not `/tmp`. Keep `NERDFLAIR_ERR_STAMP_DIR` for tests. In the probe use `touch -h` / noclobber like `_nf_stamp_write`. Also, if `write_stamp` fails, do not fall back to "log anyway". Log at most once per process, or fall back to a stamp under `$HOME`.

### 2. MEDIUM - the 10 s guard cannot kill the hung-filesystem case it targets, and it blocks before logging
- `rust/src/proc.rs:70-80`: after the deadline it calls `child.kill()` and then `child.wait()` before `errlog::note`.
- A git stuck in uninterruptible I/O (hung NFS or 9p, the stated scenario) ignores SIGKILL, so `wait()` blocks forever. The renderer hangs and nothing is logged, which is the pre-guard behaviour.
- Fix: call `note` first, then `kill`. Skip the blocking `wait()`, or wait on a helper thread. The process is about to exit anyway. Bash has `timeout -k 1`, which is bounded, but the same D-state caveat applies.
- Related, not verified:
  - After the first timeout, each remaining git call waits another full 10 s. `status`, `diff`, `ls-files` and the `rev-parse` calls run in series, so a render can take 30-60 s.
  - A timed-out call returns empty and `false`. For `status` that yields `dirty=0`, which is then written to the git cache (`main.rs:2186`) for the TTL. A legitimately slow git, such as a big monorepo `ls-files --others`, would show a wrongly clean repo and log once an hour.
  - Fix: add a render-wide deadline, or skip the remaining git calls after a timeout (a "git is slow" marker).
  - I could not check the host's own kill timeout. If it is shorter than 10 s the guard never fires.

### 3. MEDIUM - one stamp per key, not per key and reason: later distinct failures are dropped for an hour
- Keys are shared across unrelated sites: `tmp-write` is used for roughly eight different files (`main.rs:641, 1666, 2187, 2741, 2963` and others), `state-write`, `state-corrupt`, `claude-json`, `mcp-json`, and `sample-read`. `slugify` also folds `:` and `-` into `_`, and `truncate(100)` can merge long `spawn:<prog>` keys.
- Scenario: the git-cache write fails (`tmp-write` is logged). The memo write fails 5 s later for a different reason, or a different path, and is silent for an hour. This is the "absorbed failure with no log line" the rule forbids.
- Fix: put the distinguishing part (basename or label) in the key, or fold a short hash of the reason into the stamp name.

### 4. MEDIUM - `ok()` clears the rate limit, so a flapping condition logs two lines per cycle
- `errlog.rs:150-155`, and the callers `ledger_tail` (`main.rs:3104`), `state.rs:88,232`, `main.rs:1631,2714,2722`.
- A condition that alternates fail, ok, fail (two concurrent sessions sharing `state-write`, intermittent ENOSPC, a ledger read racing compaction) deletes the stamp on each success. The next failure is therefore logged again, plus a `recovered:` line. That is about 2 lines per cycle with no hourly cap.
- Fix: make `ok()` log only if the stamp is older than a minimum (for example 60 s), or leave the stamp and let it expire normally.
- Also, bash `_nf_log_line "state-rebuilt"` (`lib.sh:290,292`) bypasses the rate limit. `_nf_update_recent_styles` (`lib.sh:382-387`) has no back-off like `_nf_update_field`. If the rebuild write fails, the file stays corrupt and every chime logs `state-rebuilt` and re-copies `.corrupt`. Use `_nf_err` for it.

### 5. LOW/MEDIUM - hot-path cost of `uid()` and an `id` fork on non-Linux
- `errlog.rs:42` calls `uid()` (`util.rs:292-309`) on every `note`, `ok`, `recent`, `touch` and `clear`. `uid()` reads and parses `/proc/self/status` each time, and has no cache.
- `ok()` runs on every healthy render, around 6-8 times (state, ledger, sample, probe). That is about 6-8 `/proc` reads per render, small but needless.
- Where `/proc` is absent (macOS, which the `stat -f` fallbacks and `brew install jq` suggest is supported), each call spawns `id -u`. That is a fork and exec per `ok()` per render.
- Fix: cache it in a `OnceLock<u32>`. In `ok()`, check `.exists()` before the work that is not needed.
- Bash on a persistent failure forks a subshell plus `stat` per `_nf_err` call (`lib.sh:86`, `_nf_stamp_age`) on every render. For example, a bad `NERDFLAIR_*` tunable (`statusline.sh` env-bad loop) costs 2 forks per render for as long as it stays bad. Bash also adds one `timeout` exec per git call (`_nf_cmd`). Cheap to avoid by using `[[ file -nt ]]` or `find -mmin` style checks, or by caching the verdict per process.

### 6. LOW - log trim can lose a concurrent line, and can never run in a read-only dir
- `errlog.rs:67-91`. Trim is read tail, write tmp, rename. An appender that opened the old inode before the rename writes into the orphaned inode and the line is lost. Two trimmers race each other the same way. With finding 1 active the window opens on almost every emit.
- Ordinary operation is fine: it keeps the newest 64 KB (correct half), and it only runs at roughly 190 KB between trims.
- Smaller points:
  - The first line is always dropped even if the cut falls exactly on a line start.
  - Rust keeps a newline-less tail whole. Bash `tail -n +2` drops it. This is a parity edge.
  - If the dir is unwritable but the file is writable, the log grows without bound and the failure is silent.
  - Fix: trim in place under `flock`, or truncate-and-rewrite through the same fd. If that is not wanted, document the tolerance.

### 7. LOW - bash stderr leaks on the last-resort and trim paths
- `lib.sh:80`: `printf ... >> "$NF_ERR_LOG" 2>/dev/null || printf ... >&2`. Bash applies redirections left to right, so when the `>>` open itself fails the shell's own "Permission denied" message goes to the real stderr before `2>/dev/null` takes effect. Put `2>/dev/null` first.
- Same ordering at `lib.sh:73` (`> "$_tmp" 2>/dev/null`).
- The deliberate stderr fallback (`errlog.rs:117-120`, `lib.sh:81`) fires once per key per hour whenever `~/.claude` is unwritable. That includes HOME unset (`/.claude/...` is not creatable for non-root; `main.rs:367` also logs `home-unset`).
- I could not verify whether the host shows stderr in the status line. If it can, drop the fallback, or emit it only once per process.

### 8. LOW - stamp is written before `emit`, so a failed log write still consumes the hour
- `errlog.rs:145-146`, `lib.sh:87-88`. If `emit` fails (disk full, `~/.claude` unwritable) the stamp already exists and the key is silent for an hour. Only the stderr fallback ever saw it. Write the stamp only after a successful append (the race window is already accepted, `errlog.rs:144`).

### 9. LOW - sites that still absorb silently (spot check against `audit-silent-rust-report.md`)
- `main.rs:536-538`: `read_dir(&cwd)` failure and `filter_map(|e| e.ok())` both silent.
- `main.rs:1653`: tmux name cache `read_to_string(...).unwrap_or_default()` silent.
- `main.rs:2744`: `metadata(&cost_file).map(len).unwrap_or(0)` silent, so a failed stat is read as an empty ledger. In the `1738-1745` chime-label chain, `.ok()` on the state read and parse is covered by `read_state`, so it is acceptable.
- `lib.sh`: `_nf_read_recent_styles` (line ~131) is still `2>/dev/null`.
- The rest of the audit's HIGH and MED sites that I spot-checked are now logged.

## Checked and found OK
- Recursion and panics: `uid()` and `epoch_secs()` use only std `fs` and `Command` and `unwrap_or(0)`. They do not call `errlog`, so there is no recursion. `note` and `emit` have no panicking path (`truncate` is boundary-safe, `civil` is integer-safe, `file_age` clamps negatives). A panic inside the hook would abort, but I found no such path.
- Stdout: no logger path writes to stdout. The `BrokenPipe` case is correctly silent (`main.rs:48`). The panic hook replaces the default stderr message and logs once per hour per key. A second distinct panic inside the hour is not logged.
- HOME unset or empty: Rust (`errlog.rs:30-32`) and bash (`lib.sh:41`) both resolve to `/.claude/nerdflair-errors.log`, same as `state.rs`.
- Log line format, ISO format, 400-char cap and control-char scrubbing: the same in both twins. Single `write_all` on an `O_APPEND` fd, so appends do not interleave.
- Noise cases: `not a git repository`, lock `EWOULDBLOCK`, ambiguous/bad `HEAD` and `NotFound` are all quiet in both.

## Tests (`tests/silent-failures.sh`)
- Stdout parity compares only `out.$RENDERS` (the last render, `:158`). Differences on renders 1-3, including the recovery render, are not checked.
- `err.$n` (stderr) is captured (`:101`) but never asserted empty. The stderr leaks in finding 7 pass.
- No case for: planted stamp or symlink (finding 1), log trim over 256 KB, concurrent renderers, `recovered:` lines or flapping (4), HOME unset, a long `timeout` on a legitimately slow command, or the `render-abort` trap.
- `NERDFLAIR_MCP_HEALTH=0` is forced in every case except the two probe cases, so `mcp-no-claude` and `mcp-cache-garbled` are never exercised.
- `compaction-corrupt-rows` and others count `" key: "` lines in the log, so a second line with a different reason under the same key would not be seen (finding 3 is invisible to the suite).
- `corrupt-state`: the Rust branch asserts the file is left corrupt, and the bash branch asserts it was healed. Intentional, but it bakes in a behaviour divergence. If the two twins ever share one `state.json`, bash rewrites to defaults and Rust keeps the corrupt file.
- Cases that need `chmod 555` or `444` pass trivially if the suite is run as root (the failure never triggers, so the "exactly one line" check fails rather than passes, but only loudly).

## Could not verify
- Anything that needs running: concurrent trim loss, bash redirect ordering behaviour (reasoned from bash semantics, not executed), and the real cost of `uid()`.
- Whether the host shows stderr, and the host's own render timeout.
- macOS support (assumed from `stat -f` fallbacks).
- Whether `statusline.sh` lines I only skimmed in the diff (ledger and MCP sections) have further unlogged branches. I read the diff, not every function body.

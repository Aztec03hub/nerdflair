# Silent-failure audit: nerdflair Rust renderer and bash twin

Scope read: rust/src/main.rs, state.rs, proc.rs, util.rs, jqx.rs (grep-level only for fmtx.rs, bar.rs, colors.rs), scripts/statusline.sh, lib.sh, nerdflair.sh.
Read-only. Nothing built, run or tested. Line numbers are from `rg -n` / Read at audit time (main.rs).

## Headline

There is NO error logging anywhere in the renderer today. `rg` for `eprintln`, `nerdflair-errors`, `ERRLOG` finds nothing in rust/src or scripts (only band/bridge/nfpty.py has a log). Every site below is silent. Bash is worse in form: `2>/dev/null` and `|| true` are on nearly every external call, so even a tool's own error text is discarded.

## Proposed single mechanism (one helper, both implementations)

`errlog::note(key, reason)` in Rust, `_nf_err key reason` in bash (put it in lib.sh and source it from statusline.sh, or inline it, since statusline.sh is hot-path).

- Target: `~/.claude/nerdflair-errors.log` (HOME-relative; if that fails, stderr as last resort). Line: `ISO-time pid session_id key: reason (errno/exit code/path)`.
- Rate limit: a stamp file `/tmp/nerdflair-err-<uid>-<slug(key)>`; log only if `file_age(stamp) >= 3600` (reuse `util::file_age`, which already handles clock steps), then `touch` the stamp. Key is the failure class plus path, NOT the session, so 14 sessions at several renders per second write at most one line per class per hour. The first occurrence logs immediately. Optionally append `(suppressed N)` is NOT worth it; ponytail: skip counters.
- Recovery line: when a class that has a stamp succeeds again, log "recovered" once and delete the stamp. Needed for the ledger/state sites so the log shows duration of an outage.
- Cap: if the log is over 256 KB, truncate to the last 64 KB at the same time the stamp expires (cheap, bounded, no loop). Open with O_APPEND and write one pre-built line (same lesson as the ledger splice incident).
- The logger itself must never panic, never block (no flock), and must swallow ITS OWN failure (the one place `let _ =` is correct). Cost on the happy path: zero syscalls (only runs in an error branch).
- Do not print anything into the status line for these. The twins must stay byte-identical on stdout, and garbage on stdout is the thing to avoid. One optional exception worth deciding: a 1-glyph "!" marker when the ledger append or state write has been failing, since a wrong dollar figure is read as fact. Needs an owner decision; I recommend log-only first.
- Also add a panic hook in `main()` (`std::panic::set_hook`) that writes the panic message to the same log. Today a Rust panic prints to stderr (hidden by host) and stdout is empty. A blank status line with no trace.

## Severity ranking (highest first)

Severity key: HIGH = wrong or missing money/context figure shown as fact, with no trace; MED = missing or stale segment, no trace; LOW = cosmetic or self-healing.

### HIGH

**H1. Ledger append failure (burn rate, billing block, repo total all silently wrong)** main.rs 2387-2411
```
let _shared = try_flock(&lock_file, false);
if _shared.is_some() { if let Ok(mut fh) = OpenOptions::new().create(true).append(true).open(&cost_file) {
    let _ = fh.write_all(line.as_bytes()); } }
let _ = std::fs::write(&stamp, "");
```
Absorbs: open failure (EACCES, ENOSPC, read-only fs, EISDIR), `write_all` failure (ENOSPC, short write, EIO), and `try_flock` returning None (lock held by compactor, or `try_flock` open failing). The stamp is written regardless, so the failed attempt is rate-limited AND invisible. The code comment says skipping a sample "loses nothing" because the column is cumulative. That is true for a lock miss lasting one interval, false for any persistent failure (full disk, bad permissions): the ledger stops growing, `stale_after` (180s) then suppresses the burn segment, the block figure freezes then reads "idle", and repo totals stop rising. All of it looks like a real "nothing spent".
Logged today: no. Severity: HIGH.
Fix: distinguish the three outcomes. (a) lock missed: not an error, do NOT log (expected during compaction); but count consecutive misses via the stamp name if you want to catch a wedged compactor (log if the compact stamp is older than 2x `every`). (b) `open` Err: `note("ledger-open:<path>", err)`. (c) `write_all` Err: `note("ledger-write:<path>", err)`. Do not stamp `stamp` on (b)/(c)? Keep the stamp (it protects the re-read cost) but the log line is the durable record.
Bash twin 1195-1199: `printf ... >> "$_REPO_COST_FILE" 2>/dev/null` inside `( flock -s -n 9 || exit 1 ... ) 9>>"$_RC_LOCK" 2>/dev/null`. Same absorption, plus the redirection error text is thrown away. Fix: capture with `_e=$(printf ... 2>&1 >>"$F")` or test `||` and call `_nf_err`, drop the blanket `2>/dev/null` on the subshell redirect (keep only for the `rmdir` probe).

**H2. Ledger tail read failure returns "empty ledger"** `ledger_tail` main.rs 2662-2687, caller 1212
`File::open` Err, `seek` Err, `read_to_end` Err all return `(String::new(), false)`, indistinguishable from "no ledger yet". Then burn/block segments are simply absent (`!ledger...is_empty()` gate, 1219 and 1276), falling back to the session-average burn (1238) which shows a different, plausible-looking number. NotFound is legitimately normal (first run); anything else is not.
Logged: no. Severity: HIGH (silent downgrade of the burn figure to a different formula).
Fix: match the io::ErrorKind: NotFound = silent (genuine, documented); every other error = `note("ledger-read:<kind>:<path>", err)`. Also log when `ledger_cut` and the window is not covered (1231, 1296): block segment is suppressed ("Suppress rather than undercount") with no trace. That is a documented degrade, so it needs a log line `note("ledger-uncovered", "tail cap N does not reach window start")` once per hour, since the cure (raise NERDFLAIR_LEDGER_TAIL_BYTES) is only discoverable from a log.
Bash twin 1544-1545: `_ledger=$(tail -c ... 2>/dev/null || true)`: same, plus `stat ... || echo 0`.

**H3. Ledger rows silently discarded as malformed** `usage_row_ok` 2211, used by `window_spend` 2746, repo total 2552, compaction 2462
Rows with wrong column count, epoch out of range, cost <= 0 or >= maxcost are skipped with `continue`. By design (splice defence), but the count is never surfaced. A cost above `NERDFLAIR_REPO_COST_MAX` (default 100000) or an epoch outside 1.6e9..4e9 (clock bug) makes a whole session vanish from burn/block/total. In compaction, dropped rows are permanently deleted (`kept_in` counts only valid rows, so rows lost to the filter are not even compared).
Severity: HIGH for compaction (irreversible data loss, no trace), MED for the readers.
Fix: in compaction (the only place that counts all lines), count `total_lines - kept_in` and `note("ledger-compact-dropped", "N malformed rows removed")` when N > 0. In readers, no logging (hot path, every render): rely on the compaction log.

**H4. Compaction failures swallowed, and the "refuse to wipe" branch is silent** main.rs 2438-2529
- `let _ = std::fs::write(&compacted_stamp, "")` (claim-first): fine functionally, but if it fails the cooldown never holds and the exclusive lock is taken every refresh (the treadmill the code warns about). Log on Err.
- `if let Ok(text) = read_lossy(&cost_file)` with no else: compaction silently skipped. Log Err.
- `if kept_in > 0 && kept_rows == 0 { // nothing survived: refuse }` is an EMPTY BRANCH. A deliberate safety refusal that does nothing visible. This is exactly the case (clock jumped past retention) where the owner needs to know the ledger is stuck above `maxb` and the time gate will retry hourly forever. Log `note("ledger-compact-refused", "...kept_in=N cutoff=...")`.
- `File::create(&tmp)` Err, `write_all`/`sync_all` Err, `rename` Err are all folded into "if ok { rename }" with no else and `let _ = rename`. Disk full during compaction leaves the old file (correct) and a stray `.tmp`, with no trace, retried hourly. Log each with the path and error; remove the tmp on failure.
- `try_flock(&lock_file, true)` None: another compactor or appender holds it. Expected, no log.
Bash twin 1278-1292: awk output to `.tmp` with `2>/dev/null`, count compare, `rm -f ... || true`, `sync ... || true`. Same. The awk-failed and count-mismatch branches (1287-1289) should log with the two counts.

**H5. state.json not written (atomic_write)** state.rs 189-194, 197-219, caller main.rs 761-763
```
fn atomic_write(..) { if std::fs::write(&tmp, contents).is_ok() { let _ = std::fs::rename(&tmp, path); } }
```
Absorbs: write to tmp fails (ENOSPC, perms, dir missing), rename fails. Nothing is reported, and the function returns `()` so callers cannot know. `update_field` also does `let _ = create_dir_all`, then `read_to_string` Err -> `return`, `from_str` Err -> `return` (comment: "jq fails ... mv never runs"), non-object -> `return`, all silent. Consequence: `last_session` is never persisted, so `f.session_id != last_session` is true on EVERY render and the write is retried (and silently fails) every render, several times a second per session. Plus a corrupt state.json is never reported: `read_state` (45-46) turns read Err and JSON parse Err into all-defaults (`vals` stays empty), so the user's mode, width, colour and chime settings silently revert to defaults on a corrupt file.
Severity: HIGH for the corrupt-state case (settings silently reset, no trace), MED for the write failure.
Fix: make `atomic_write` return `io::Result<()>`; at the two callers (`write_state`, `update_field`) `note("state-write:<path>", err)` on Err and remove the orphan tmp. In `read_state`: if `path.is_file()` and (read Err or parse Err or non-object) then `note("state-corrupt:<path>", err)` and keep defaults (degrade AND log). Missing file is genuinely normal, silent. Rate limit is essential here because of the per-render retry; the per-class hourly stamp covers it. Better: also avoid the per-render retry (cheap guard: do not retry `update_field` if the last attempt failed and the stamp is younger than 60s).
`write_state`'s `recent` merge (159-168) and `flair` parse (169-170, `unwrap_or(Value::Bool(true))`) silently drop `chime_recent_styles` history if the existing file is unreadable/corrupt, and silently turn a non-JSON `flair` into `true`. Log both (same `state-corrupt` key).
Bash twin lib.sh 141-181, 190-208, 256-265: `jq ... 2>/dev/null`, `|| echo "[]"`, `jq -e . >/dev/null 2>&1` then "recreate with defaults" (190-197, deliberately overwrites a corrupt file with defaults and tells nobody, which destroys the evidence), `printf > $_tmp && mv` with no else. lib.sh 47/59/69-84 reads `2>/dev/null`, so a corrupt file reads as defaults. Fix: `_nf_err` in each else branch; before overwriting a corrupt state file, copy it to `state.json.corrupt` (one copy) and log.

### MED

**M1. MCP health probe fails: nothing logged, stale or blank figures kept** `mcp_health` main.rs 2115-2205, bash 1328-1392
The probe runs in a detached `bash -c` with `stdout/stderr -> null`, `claude mcp list 2>/dev/null ... || true`, and `else touch {cache}` on zero results. Absorbed: `claude mcp list` failing, timing out (30s), emitting nothing, or all lines unparseable; `exec 9>>lock` failing (`|| exit 0`); `mv` failing; `c.spawn()` Err (`let _ = c.spawn();` at 2202, e.g. EAGAIN, bash missing). The `touch` is a deliberate documented degrade (keeps old values, gates retries), but after it the segment shows STALE counts forever and the user sees a green "8/8" for a probe that has been failing for days.
Fix, inside the spawned script (it is the only place that knows): capture rc of `timeout ... claude mcp list`; if rc != 0 or `_o+_b+_w == 0`, append one line to the errors log with the rc (124 = timeout) and a first line of output, only if the stamp `/tmp/nerdflair-err-<uid>-mcp` is older than 1h. Rust side: `if let Err(e) = c.spawn() { note("mcp-probe-spawn", e) }`. `try_flock(&lock,true)` returning None is the normal "probe already running" case, silent is correct. In the cache READ (2134-2140, 418-428) `read_to_string` Err on an existing cache is silent; log non-NotFound.
Also `proc::which("claude").is_none()` returns blank health silently (2124): log once ("claude not on PATH, MCP health disabled") since the segment simply vanishes. Same for NERDFLAIR_MCP_HEALTH=0: correct to stay silent (explicit opt-out).
`mcp_health` figures parsed with `bash_int(...).unwrap_or(0)` (1314-1316): a garbled cache shows "0/0" or hides the segment. Log if the cache is non-empty but unparseable.

**M2. Git failures degrade to "not a repo" or blank branch** proc.rs 7-39, main.rs 447-472, 1840-1960, multi-branch 528-546; bash 259, 292-330, 377-390
`proc::out` and `out_raw` map spawn Err to `(String::new(), false)` and send child stderr to null. This conflates three different things: git not installed (spawn NotFound), git ran and said "not a repo" (exit 128, normal and correct to stay silent), and git failed for a real reason (dubious ownership/safe.directory, index.lock, corrupt repo, timeout). Specific absorbers:
- `rev-parse --is-inside-work-tree` false: treated as "not a repo", which then runs the multi-repo glob. A repo that git refuses (safe.directory) silently loses the entire git UI.
- `git status ...` result and `ok` are ignored; failure gives `dirty = 0` (1864) which reads as a clean tree. A clean-looking tree that is really a git error is a wrong figure.
- `git diff --numstat HEAD` falling back to `git diff --numstat` (1868-1873): fallback is documented, silent. On a fresh repo with no HEAD that is right; otherwise log.
- `symbolic-ref` fail then `rev-parse --short HEAD` then empty branch: detached HEAD is normal; both failing is not. Log when both fail.
- `rev-list @{upstream}...HEAD` false means "no upstream", normal, silent.
- `git remote get-url origin` failing: normal when no origin.
- `std::fs::read(d.join(file))` Err in untracked-file line counting (1899): silently under-counts `+N`. Low value, log only non-NotFound.
- `let _ = std::fs::write(&cache_file, &payload)` (1942) and the multibranch cache write (546): cache write failure just means git is re-run every render (a performance cliff, not a wrong figure). Log once.
- `read_to_string(&cache_file).ok().or(computed).unwrap_or_default()` (1945-1948): an unreadable cache with no computed value yields an empty GitCache, which all of dirty/branch/ahead treat as zero.
Fix in proc.rs (central, one place): `out()` returns the error kind. On spawn Err with kind NotFound: `note("spawn:git", "git not found on PATH")`; other spawn Err: `note("spawn:<prog>:<kind>", err)`. For non-zero exit, capture stderr (currently `Stdio::null()`; use `Stdio::piped()` and keep the first line) and log ONLY for commands where failure is unexpected (`status`, `diff`, `rev-parse --git-dir`), not the probes where failure means "no". Suggest adding a `quiet: bool`/enum parameter: `Expect::Maybe` for rev-parse/symbolic-ref/upstream/remote, `Expect::Ok` for status/diff/ls-files. Rate limit key: `git:<subcommand>:<exitcode>`.
Also: no timeout on any git call. A hung git (network fs, huge repo) blocks the renderer and the host kills it, with nothing recorded. Add a wall-clock guard (spawn, poll `try_wait` for N ms, kill, `note("git-timeout:<sub>")`) or at least document it. Cannot confirm host kill timeout from the code.

**M3. Transcript tail / context usage ("usage tail seeking")** main.rs 664-736; bash 683-724
- `jqx::path(&root, &["transcript_path"]).map(tostring).unwrap_or_default()` then `Path::is_file()`: missing or non-file transcript silently yields 0%.
- `ledger_tail(transcript, tcap)` reuses the same helper: open/seek/read Err returns empty, so context shows `0/200k 0%` on a possibly full session (the same reason `pct` flicker was fixed). No log.
- `serde_json::from_str(l).ok()` in `filter_map`, bounded by `USAGE_SCAN=5`: if none of the last 5 usage lines parse, or none carry `message.usage`, total stays 0 and the gauge reads 0% silently. The wider re-read (688-693) is a documented retry; if it also finds no `"usage"`, nothing is logged.
- `u.get(k).and_then(as_i64).unwrap_or(0)` (720): a float or string token count becomes 0.
- `bash_int(&ctx_total_s).unwrap_or(200000)` (726): silently assumes a 200k window if the size is not an integer, producing a wrong percentage.
- `if pct > 100 { pct = 99 }` clamps silently (a >100% figure is hidden).
Severity: MED/HIGH (a 0% gauge on a full context is a wrong figure). Fix: `note("ctx-transcript-read:<kind>")` for non-NotFound I/O errors; `note("ctx-no-usage", "no parseable usage in last N bytes of <path>")` when a non-empty tail yields no usage; `note("ctx-size-nonint", value)` for the 200000 assumption. All once per hour, keyed without the session.

**M4. Payload parse failure silently renders a blank/default line** main.rs 31, 338, 64-157 and bash line 39
- `let _ = stdin.read_to_end(&mut buf)`: a failed stdin read gives an empty payload.
- `serde_json::from_str(input).unwrap_or(Value::Null)`: malformed payload from the host becomes Null, then every field is empty, so the status line renders with no model, cost, context or rate limits, as if the session had none. Bash line 39 `jq ... 2>/dev/null` same.
- `extract()`: a `jqx::path` Err (type error on an unexpected shape) sets `failed` and `parts.clear()`, blanking ALL 20 fields on one bad field. Documented as bash parity, silent.
- `parts.get(i).cloned().unwrap_or_default()`.
Severity: MED, but this is the exact "host changed its schema" detection point, and today it would look like a quiet degraded bar.
Fix: log `note("payload-parse", err + first 200 bytes of input)`, `note("payload-shape:<field>", err)`, and `note("payload-empty")` if stdin was empty. Output stays byte-identical (stdout untouched). Bash: `jq` stderr into `_nf_err` instead of `2>/dev/null` (capture to a variable, log when non-empty or rc != 0).

**M5. Arithmetic errors (`Ar::Fatal`, `Ar::Syntax`) coerce to 0 or abort** main.rs 651-661, 1125-1131, 1160-1164, 1239, 1379, 1413, 1475-1478, `bash_int` util.rs 210-213
Bash arithmetic failures are modelled: Fatal returns `Err(out)` and truncates the line (the render prints only what was buffered), Syntax silently becomes 0 or "not an int". These mirror bash, but a truncated status line caused by a non-numeric payload field is the worst visible failure and leaves no trace. `bash_int` collapses every parse failure to `None`, and 25+ call sites `.unwrap_or(0/80/200000)`.
Fix: in `arith`'s Fatal path call `note("arith-fatal:<expr>", ...)` before returning; the caller sites pass a field name. Syntax coercions: one `note("arith-syntax:<field>", value)` where the field matters (ctx_size, used_pct, total_api_ms, duration). Do not change the output (parity).

**M6. Session sample ring (`/tmp/nerdflair-sample-*`) write failure** main.rs 1412-1433; bash 1861
```
if std::fs::write(&tmp, body).is_ok() { let _ = std::fs::rename(&tmp, sp); }
```
Failure means the compaction ETA, throughput and Theil-Sen history never accumulate, so those segments never appear or fall to "Fallback 1/2" (session average) with a "~" fuzzy marker. `read_ring` (2240-2272) returns an empty ring for any read Err or malformed content. Wrong or missing ETA, no trace. /tmp full or perms are the realistic causes.
Fix: `note("sample-write:/tmp", err)` for write and rename Err; `read_ring`: log non-NotFound read Err and an unparseable first line (nonzero-length file, zero samples recovered).

**M7. `try_flock` fallbacks and the EISDIR migration** main.rs 2591-2621
`open()` Err then `remove_dir(path)` ignored then `open().ok()?`: a permanently unopenable lock file returns None, which every caller reads as "lock held, skip". Two consequences: appends skipped forever (H1) and compaction never runs. `libc::flock` returning -1 with an errno other than EWOULDBLOCK (ENOLCK, EBADF) is also treated as "held". Fix: distinguish `EWOULDBLOCK` (normal, silent) from every other errno and from open failure (`note("flock:<path>", err)`). Change the return type to `Result<Option<File>, io::Error>` or log inside.

### LOW

**L1. Cache and stamp files in /tmp** (`let _ = std::fs::write(&stamp, "")` 2411, `memo` 2571, tmux cache 1452, multibranch 546, `compacted_stamp` 2438): failures cause redundant work only. Log once as `tmp-write` since a full /tmp also breaks M6 and git cache. `file_age` (util.rs 233-246) maps a missing or unreadable mtime to 0, i.e. "infinitely old" (documented, fails toward doing work). Correct, but a stat Err other than NotFound is unreported.

**L2. tmux session name** main.rs 1437-1459, bash 1870-1882: `tmux display-message` failure gives empty name, segment hidden. Log spawn failure and non-zero exit once per hour (key `tmux`). `unwrap_or_default` on the cache read is harmless.

**L3. Session chime file** main.rs 746-760, bash 747: unreadable or corrupt `~/.claude/nerdflair/sessions/<id>` silently ignored, chime label falls back to style. Log parse Err (`session-file-corrupt`), not NotFound.

**L4. `~/.claude.json` and `.mcp.json` parse** main.rs 164-193, 374-401, 405-411; bash 107/126/136: read Err, JSON Err, or non-object `.projects` all become "no MCP servers" / empty names; the MCP name list falls back to the probe cache (416-429). `projects` not an object is encoded as a fake empty string (188) to emulate a jq error. A malformed ~/.claude.json (very plausible, the host rewrites it) shows "0 servers" with no trace. Log non-NotFound read and any parse Err, keyed by path. (I rate it LOW because the MCP health probe segment still shows; MED if names are the user's main readout.)

**L5. Terminal width** main.rs 792-810: `tput cols` failure, non-numeric `COLUMNS`, non-numeric configured width all fall to 80. Documented, bounded to 50..150, harmless. Log a bad `COLUMNS`/`width` value once; skip `tput` failure (tput not found is a plain environment fact, but it is still a silent downgrade: log once with the key `tput`).

**L6. `env_int` main.rs 2098-2104**: every `NERDFLAIR_*` tunable that is set but non-numeric is silently replaced by the default (e.g. a typo in NERDFLAIR_LEDGER_TAIL_BYTES). User-configuration error, so it should be logged: `note("env-bad:<NAME>", value)`. Cheap, once per hour.

**L7. `uid()` util.rs 292-309**: falls back to `id -u`, then to `0`. UID 0 silently misnames every /tmp cache path (`nerdflair-*-0-*`), which can collide across users. Log when the final fallback is taken (practically never).

**L8. `epoch_secs()` util.rs 216**: `unwrap_or(0)` on a pre-1970 clock gives now=0, which then zeroes every window (burn/block "idle"). Practically unreachable; log if hit.

**L9. `HOME` unset** state.rs 37, main.rs 318/2331: `unwrap_or_default` leads to root-relative paths (`/.claude/...`). Parity-by-design with bash; log once ("HOME unset, using /").

**L10. Final output** main.rs 31-36: `let _ = so.write_all(...)` / `flush`. stdout closed by the host is not a renderer error and cannot be reported usefully to stdout. If it fails, log (EPIPE is normal when the host kills the renderer: key `stdout-epipe`, skip logging for BrokenPipe, log others).

**L11. Formatting parsers in fmtx.rs / jqx.rs** (`unwrap_or(0)`, `unwrap_or_default`, `serde_json::to_string(...).unwrap_or_default()` jqx 12/179/190, hex digit `unwrap_or(0)`): pure number formatting of already-validated strings; the `to_string` of a `Value` cannot fail in practice. Not worth logging, but `fmtx::awk_num` (awk-style "parse prefix or 0") is the reason a garbled ledger cost becomes 0: this is parity with awk and is covered by H3's `usage_row_ok` guard.

## Bash-twin-only absorbers (not in the Rust code)

- statusline.sh line 12: `trap 'cat "$_SL_BUF" >&3; rm -f "$_SL_BUF"' EXIT` (output buffering). Good: always emits whatever was buffered. Add `_nf_err` on non-zero exit status so a killed/aborted render is recorded.
- Line 2: `set -uo pipefail` without `-e` so command failures never stop the script; every external failure is therefore tolerated, which is why the `2>/dev/null` sites above are the only place errors could be seen.
- lib.sh 30-35: missing `jq` prints to STDERR once per render (correct, visible, but not rate-limited and stderr is hidden by the host). Also route through `_nf_err`. This is the one site that already reports; it is a CORRECT report but not durable.
- nerdflair.sh (the CLI/hook script, not the render path): `jq ... > $_tmp && mv` chains at 189, 301, 308, 314, 371, 390, 410, 414, 423 with no else: a failed settings.json edit (spinner verbs, statusLine install) returns silently and the `&&` leaves a stale `$_tmp`. These are user-initiated commands, so the correct fix is to print an error to stderr AND return non-zero (stderr IS seen by the user here), not a rate-limited file log. Line 142-189 (`_cs_current`, session chime write) same. `AUDIO_DIR=""` fallbacks (126, 518) disable sound silently: print once when the user asks for sound.
- lib.sh 231-237 sound lock: `mkdir ... || return 0`, `rmdir` ignored. A mkdir lock with `sleep 6; rmdir` backgrounded. A killed holder leaves the dir, and the 30s age check recovers it. Fine and self-healing, but note this is the exact mkdir-lock pattern the owner's rules call out (a breaker (30s) vs a 6s job is longer than the job, so it is safe). No change needed beyond optional logging of a lock older than 30s.
- statusline.sh 1161-1207: `|| true` after `rmdir "$_RC_LOCK"` is a harmless migration shim; correct to keep.
- statusline.sh 1657, 1662, 1698: `awk ... 2>/dev/null` computing burn/block; awk failure leaves empty var and the segment disappears. Log when awk rc != 0.

## Sites that are CORRECT as they stand (no change needed)

- `try_flock(..) -> None` as "another holder", EWOULDBLOCK only (once split from other errnos per M7), in `mcp_health` idle probe (2162-2165) and the ledger shared/exclusive attempts. Expected contention, documented, must not log.
- `NERDFLAIR_MCP_HEALTH=0`, `NERDFLAIR_REPO_COST=0` early returns: explicit user opt-out.
- `read_state` when the file does not exist (first run): defaults are correct.
- `ledger_tail`/`read_ring`/session file/cache file when the error kind is NotFound: genuinely normal, silent is right. (Non-NotFound still needs logging.)
- `proc::which`, `is_exec`: query functions that return Option, absence is the answer.
- `git rev-parse --is-inside-work-tree` exit 128 / `remote get-url origin` / `rev-list @{upstream}` failing for "not a repo / no remote / no upstream": answers, not errors.
- `file_age` future-mtime to "very old": deliberate, documented, fails toward working.
- The ledger shared-lock miss (skip one sample) when it is a lock contention, per the long comment: correct once (a) is separated from (b)/(c) in H1.
- `read_lossy` using `from_utf8_lossy`: correct for a torn multibyte tail, but the replacement itself should be counted in the compaction log (H3) to be fully non-silent.
- `strtod`/`awk_num`/`bash_int` returning 0/None on garbage: output parity with bash/awk is a stated requirement, so the VALUE stays; only the log is missing (M5).
- `Err(partial)` in `render()` returning the buffered output: matches the bash EXIT trap, a correct degrade; only needs the log (M5).
- Final `let _ = so.write_all`/`flush` for BrokenPipe: correct to ignore EPIPE.

## Implementation order (suggested)

1. `errlog::note` + `_nf_err` + panic hook. One file each.
2. H1/H2/H4 (ledger), H5 (state), M1 (mcp probe): these are the ones where a figure or setting is wrong and looks right.
3. proc.rs central git change (M2), M3 transcript.
4. The rest.
Add a `tests/` case per class forcing the failure (read-only HOME, ENOSPC via /dev/full for the ledger path, corrupt state.json, missing git) and asserting exactly one log line after N renders, and that stdout is byte-identical to the bash twin. I did not write or run any of these.

## Could not verify

- Nothing was executed, so every "absorbs X" is by reading, not by observing the failure. In particular I did not confirm that a failed `last_session` write really retries every render (inferred from `f.session_id != last_session`, main.rs 761).
- I did not read fmtx.rs, bar.rs, colors.rs in full (only grepped them for absorbers); jqx.rs only at the sites that matched.
- statusline.sh (2626 lines) was audited by grep for absorbing constructs and the ledger/mcp/transcript/state regions, not line by line; there may be further `2>/dev/null` sites in the segment-building code that did not match the patterns.
- The host's status line timeout and whether it captures stderr (assumed hidden) are not knowable from this repo; the log-file recommendation does not depend on it.
- Whether `claude mcp list` writes useful reasons to stderr/stdout on failure: not checked, so the exact text to log in M1 is unconfirmed.
- `jqx::path` error semantics (what shapes yield Err) were not fully traced, so how often `extract()` blanks all fields in practice is unknown.
- `window_spend` / `usage_row_ok` edge behaviour was read but not tested against a real ledger.

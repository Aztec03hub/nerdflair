# Review: ledger concurrency, locking, durability (2026-10-08)

Reviewer: rev-concurrency. Read-only review of commits ac270a1, 7e58899, 5b64287, 200eb61. Nothing was executed; every claim is from reading the code.

## Verdict

With ~14 sessions appending every 60s plus compaction, the ledger cannot lose or corrupt a row on the append-versus-compaction path while every writer takes the lock. That path is sound. It CAN lose the whole history through compaction itself (F1: empty or truncated rename, forward clock jump, no fsync), and the 2026-10-08 failure mode is still reachable through the MCP probe lock (F6) and its retry loop (F7). Fix F1-F7 before relying on it.

## Safe paths (checked, no finding)

- Append vs compaction: the appender opens the ledger only after taking the shared lock (main.rs:2264-2270, statusline.sh:1207-1209). The compactor reads only after taking the exclusive lock (main.rs:2300, statusline.sh:1237). Rust releases the shared lock before requesting the exclusive one (main.rs:2283), so a process can't block itself. A row appended during a compaction is either skipped or fully visible to it.
- Kill at any point: killed between append and stamp gives a duplicate row, harmless because readers take the max per session. Killed mid-compaction leaves the old ledger intact because only a completed rename replaces it. A killed bash subshell keeps fd 9 only while awk runs and never reaches `mv`.
- The lock file is never unlinked or renamed by either implementation. Only the migration `rmdir` (main.rs:2446-2447, statusline.sh:1205) touches that path, and it fails on a regular file. The ledger rename (main.rs:2363, statusline.sh:1274) targets only the ledger.
- Torn last line: the next append yields a row with the wrong column count, which `usage_row_ok` (main.rs:2107) and `NF==4` (statusline.sh:1255) discard.
- Starvation: appenders never block. Shared holds last about a millisecond, so the compactor gets an instant with no shared holder.

## Findings

### F1. Medium. Compaction can replace the ledger with an empty or truncated file
- Where: main.rs:2362-2364; statusline.sh:1273-1274.
- Interleaving: the wall clock jumps forward more than 30 days (WSL resume, bad NTP). Session A passes the size and cooldown gate and takes the exclusive lock. `cutoff = now - 30d` now exceeds every row. Every row is filtered out, and A writes an empty tmp file and renames it over the ledger. The whole history is gone. Bash variant: if awk exits 0 after a short write (ENOSPC), `&&` still runs `mv -f` and a truncated file replaces the ledger. Neither implementation calls fsync, so a crash after rename can also leave a zero-length file.
- Fix: count valid input rows. Refuse the rename if valid_input_rows > 0 and kept_rows == 0. Require a non-empty tmp file (`[[ -s tmp ]]`) and compare `wc -l` in bash. fsync the tmp file, rename, then fsync the directory. A `.bak` copy is not needed.
- Residual risk: a forward jump of about 29 days drops most old rows without tripping the guard. The loss is bounded to repo totals older than the window, which are regenerable.

### F2. Medium. Bash stamps the cooldown when it did no work
- Where: statusline.sh:1278 (unconditional stamp) versus main.rs:2368 (inside `if let Some(_ex)`).
- Interleaving: session A holds a shared lock while appending. Session B reaches the compaction gate, its `flock -x -n 9` fails at line 1237, the subshell exits, and line 1278 stamps `.compacted` anyway. The shared stamp now blocks every session from compacting for 3600s. Repeats whenever a compaction attempt coincides with an append, with no diagnostic.
- Fix: stamp `.compacted` inside the exclusive section in both implementations, right after acquiring the lock and before the work (a claim). Never stamp on a lost lock. Rate-limit retries through the per-session stamp (see F3).

### F3. Medium. A skipped append leaves `due` true, so every render re-reads the whole ledger
- Where: main.rs:2265-2282 (stamp only after a successful write at 2279), main.rs:2379-2384; statusline.sh:1209-1210, 1286-1293.
- Interleaving: the compactor holds the exclusive lock for a multi-second rewrite of a ~30 MB ledger. Each of 14 sessions fails `flock -s -n`, writes no stamp, and so `due` stays true. Every refresh in every session then reads or awks the full file, which is the "per-refresh cost scales with a corpus that grew on its own" pattern from the incident.
- Fix: write the per-session stamp whether the append succeeded or the lock was missed, inside the cost-non-empty gate. The stamp rate-limits attempts and the cumulative column makes a skipped sample lossless. In bash change `&& : > "$_rc_stamp"` to `; : > "$_rc_stamp"`. In Rust move line 2279 out of the `is_ok()` branch. Keep it separate from `.compacted`. Checked against the memo logic: it reads only `due`, so there is no conflict. Cost is a 2-minute gap in burn/block samples.

### F4. Medium. A backwards clock or future-mtime stamp stops appends and compaction
- Where: rust/src/util.rs:233 (`epoch_secs() - mtime`, unclamped); statusline.sh:1187-1188, 1224-1225.
- Interleaving: the clock steps back 1h. Every stamp mtime is now in the future, so `age` is negative and less than `ttl`. `due=false` in all 14 sessions and no row is appended for up to an hour. The `.compacted` cooldown also never expires. If `now` is behind every row, `cutoff` and `full_from` fall below all rows, so everything counts as "recent" and compaction keeps every row.
- Fix: treat `age < 0` as expired in both implementations: `!(0 <= age && age < ttl)`. Clamp in `file_age` as well.

### F5. Medium. Compaction runs inline in the render and can restart on every refresh
- Where: main.rs:2296-2370; statusline.sh:1236-1278 (awk insertion sort at 1264-1270 is O(n^2), no timeout).
- Interleaving: session A starts a compaction that takes longer than Claude Code's status-line kill window. A is killed before the stamp is written (main.rs:2368, statusline.sh:1278 are last). Session B's next refresh sees the old stamp and starts the full rewrite again while holding the exclusive lock, so everyone's appends are skipped. A job that always outlives the kill window repeats forever.
- Fix: stamp `.compacted` immediately after taking the exclusive lock, before the work. Move compaction to a detached child under `timeout`; `flock -n` already makes it single-flight.

### F6. Medium. The MCP-probe mkdir lock can still pile up runners (2026-10-08 shape, slower)
- Where: statusline.sh:1325-1328 and main.rs:2072-2075 (`timeout 30 claude mcp list`, no `-k`); breaker at statusline.sh:1321-1323 and main.rs:2069-2071 (300s).
- Interleaving: runner R1 starts and `claude mcp list` hangs in uninterruptible I/O (WSL 9p) or ignores SIGTERM. `timeout` sends TERM at 30s and never sends KILL. R1 keeps the lock. At 300s session S removes the lock directory and creates its own, starting R2. R1 never dies. R2 hangs the same way, and so on: one more stuck runner every 300s, about 12 an hour while the cause persists.
- Not verified: whether `claude` actually ignores TERM. GNU timeout kills the process group on timeout, which mitigates the common case.
- ccusage is bounded: kill is 45+5s against a breaker of 180s (statusline.sh:1130-1131, main.rs:2084-2085), and it is off by default.
- Fix: use `timeout -k 5 30`. Better, replace the mkdir lock with `flock -n` on a file held by the job. A live holder then always blocks a new runner, and no breaker exists.

### F7. Medium. A failed probe writes no cache, so the probe re-runs continuously
- Where: statusline.sh:1351-1352 (cache written only if `_o+_b+_w > 0`), main.rs:2086-2087; ccusage cache only on success at statusline.sh:1151-1152.
- Interleaving: `claude mcp list` times out or fails. No cache is written, so `fresh` stays false. The lock is released at exit, and the next render in any session creates a new runner. The duty cycle is about 100% of `claude mcp list`, which spawns every MCP server, on an already stressed machine. It feeds itself: a slower machine produces more timeouts.
- Fix: touch the cache file (or write a `.attempt` stamp) whatever the result, so the TTL gates retries. Optionally write a "failed" verdict.

### F8. Medium. Tests do not exercise the shipped code
- Where: tests/ledger-concurrency.sh:43-70 (copy of the awk compactor), :93 (blocking `flock -s`, not the production `-n` skip), :166-182 (the only real-binary arm; missing build prints SKIP and passes); tests/loadtest.sh:94 (scratch ledger that never reaches 2 MB, so compaction never runs), :133 (census matches only `nerdflair-stat|ccusage|nvidia-smi`).
- Interleaving this hides: a bug in Rust `try_flock`, the Rust compactor, or the skip path is invisible, since no test runs the Rust binary concurrently. A stuck `claude`, `timeout` or `bash` helper from the MCP probe is invisible to the census. The load test also launches real `claude mcp list` against live servers because `NERDFLAIR_MCP_HEALTH` is not set.
- Fix: add an arm that runs the Rust binary with N parallel invocations and `NERDFLAIR_REPO_COST_TTL=0`, `NERDFLAIR_REPO_COST_MAXBYTES=1`, `NERDFLAIR_LEDGER_COMPACT_EVERY=0`, and checks that no recorded row is lost. Make a missing build a FAIL. Extend the census to `claude|timeout`, or put a stub `claude` that sleeps longer than the timeout on `PATH`. Set `NERDFLAIR_MCP_HEALTH` explicitly in the load test.
- Credit: the unlocked control arm means the test can fail correctly.

### F9. Medium. Rust uses strict UTF-8 on the compactor and the total reader
- Where: main.rs:2317 and main.rs:2384 (`read_to_string`), versus `ledger_tail` at main.rs:2486 (`from_utf8_lossy`).
- Interleaving: a process dies mid-write inside a multibyte character, or ENOSPC leaves a partial row. The next compaction attempt hits the invalid byte, `read_to_string` errors, and the rewrite is skipped (and stamped, by line 2368). The repo-cost total segment also vanishes, while bash's awk carries on. The bad byte stays because compaction is the only thing that could drop it. The two implementations diverge in that state, breaking the byte-identical guarantee.
- Fix: read bytes and convert with `String::from_utf8_lossy`.

### F10. Low. Compaction keeps the last row, not the max cost, and the two implementations tie-break differently
- Where: main.rs:2335-2340 (`*pt >= ti` keeps the first of equal epochs, epoch truncated to i64); statusline.sh:1259 (`>=` keeps the later row).
- Interleaving: a session appends two rows within one second with different costs. Rust keeps the first (lower cumulative), awk keeps the later (higher). The difftest compares stdout only, so it cannot see this. If a session id is reused and its cost restarts lower (my guess, unverified), keeping the last row also lowers the repo total.
- Fix: choose the survivor by (max cost, then latest epoch) in both implementations, with the same comparison and numeric type.

### F11. Low. Migration and lock-removal gaps
- Where: main.rs:2436-2451; statusline.sh:1205.
- Both implementations clear an empty leftover directory. The old scheme only did mkdir/rmdir (5b64287 diff), so it is always empty. A race between two processes clearing it is harmless.
- Gaps: the migration test covers Rust only (ledger-concurrency.sh:166-179), not bash. Bash runs the `-d` check on every render, even when no append is due. A pre-upgrade process holding a real mkdir lock has it removed, allowing one concurrent old+new compaction, once.
- Interleaving for the lock-file edge: an operator runs `rm ~/.claude/nerdflair-usage.tsv*` while sessions are live. Session A holds the exclusive lock on the unlinked inode. Session B recreates the lock file and takes a shared lock on a new inode, appends, and A's rename then replaces the ledger and drops B's row.
- Fix: add a bash arm to the migration test and move the `-d` check inside the `_rc_due` branch. Document that the `.lock` file must not be deleted while sessions run.

### F12. Low. Bash never records where `flock` is not installed
- Where: statusline.sh:1207, 1237.
- Interleaving: on macOS or a minimal container, `flock` is not found and the subshell exits 127. No append occurs and compaction never runs, silently. The Rust build uses `libc::flock` and works.
- Fix: `command -v flock`, and fall back to an unlocked `>>` append. A single O_APPEND write is atomic.

### F13. Low. The mkdir breakers are racy (ccusage and MCP locks)
- Where: statusline.sh:1141-1148, 1321-1325; main.rs:1096-1099, 2069-2072.
- Interleaving: P1 and P2 both observe the lock directory older than the breaker. P1 removes it and creates a fresh one. P2's `rmdir` succeeds on P1's fresh empty directory, and P2 creates its own. Both run. With 14 sessions up to 14 runners are possible, bounded by the job timeout (30s MCP, 50s ccusage). The EXIT trap `rmdir` can also delete a later runner's lock.
- Fix: the same `flock -n` conversion as F6.

### F14. nit. Ledger size and flock errors
- The live ledger is 2,528,367 bytes against the 2,000,000-byte trigger (main.rs:2285, statusline.sh:1227). It rewrites hourly without shrinking. That is cheap and bounded, but raise the threshold above the compacted steady state.
- main.rs:2453 treats any `flock` failure (EINTR, ENOLCK) as "busy". Harmless but silent. Fix: distinguish EWOULDBLOCK from other errors and log once.

## Accepted-risk note on F1 (backup)

A `.bak` was considered and judged not load-bearing. A stale `.bak` can be restored over good data, and the ledger is a derived cache for two readouts. The row-count guard, the non-empty check, and fsync of file and directory are sufficient. Residual risk: a roughly 29-day forward clock jump. Accept and document it.

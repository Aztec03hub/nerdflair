# Worklog: silent failures in the Rust renderer and its bash twin

Branch `silent-rust` in worktree `/home/plafayette/nerdflair-wt-rust`, base `6bd7c5d`. Nothing pushed or merged.

## Commits

| sha | what |
|---|---|
| `35b4933` | Rust: `errlog` module, panic hook, every Rust site (ledger, state, git, mcp probe, transcript, payload, tunables, flock) |
| `623ec07` | Rust: `NERDFLAIR_MCP_PROBE_TIMEOUT`, so the probe-timeout path is testable in seconds |
| `77c49d1` | bash twin: `_nf_err` family in `lib.sh`, every audited site in `statusline.sh` and `lib.sh` state functions |
| `3edbe14` | `tests/silent-failures.sh` |
| `167dc3e` | security-review fixes (symlink-safe stamps and probe stderr), bash payload parse vs shape |

No Co-Authored-By or Generated-with trailers. No em-dashes in prose or comments.

## Mechanism (followed the audit; deviations listed below)

* `rust/src/errlog.rs`: `note(key, reason)` appends ONE line `ISO-time pid key: reason` to `$HOME/.claude/nerdflair-errors.log`. HOME unset or empty means `/` (same rule as `state.rs`, never a relative path). Fallback when the log cannot be opened: stderr. Rate limit: stamp `$NERDFLAIR_ERR_STAMP_DIR` (default `/tmp`) `/nerdflair-err-<uid>-<slug(key)>`, checked with `util::file_age` (age < 3600 s means skip). `ok(key)` logs `recovered: key` once when a keyed stamp exists and the condition cleared. Cap: over 256 KB, trim to the last 64 KB at the next (rate limited) write. One pre-built buffer, one O_APPEND write, no lock, never panics; its own failures are the one correct `let _ =`. `note_io` adds the io error kind to the reason.
* `std::panic::set_hook` in `main`: logs `panic: <message> at <file>:<line>`. Stdout stays empty and the process still aborts (`panic = "abort"` in the release profile; the hook runs first).
* Bash: `_nf_err key reason`, `_nf_ok key`, `_nf_recent/_nf_touch/_nf_clear` in `scripts/lib.sh`. Same file, line format, stamp names and 3600 s limit. `_nf_ok` costs no fork on a healthy render (stamp path built with a global, builtins only). Nothing ever prints to stdout.
* Statusline-only helpers in `statusline.sh`: `_nf_cmd LABEL QUIET_ERE cmd...` (runs a command with a wall-clock guard, logs spawn failure `spawn:<cmd>`, timeout `timeout:<label>`, non-zero exit `<label>:<rc>` unless it matches a documented "no" answer or LABEL is `-` for a probe) and `_nf_jq KEY args...`.
* `proc.rs` rewritten around one `run()`: stderr is piped and drained on threads, `try_wait` polling with a deadline (`NERDFLAIR_PROC_TIMEOUT_MS`, default 10000), kill on timeout. `out`/`out_raw_chk` keep the old call shapes; `out_chk`/`out_raw_chk` take a label and a list of quiet stderr substrings.

## Per finding

HIGH
* **H1 ledger append.** Rust: lock miss (EWOULDBLOCK) silent, `open` Err -> `ledger-open`, `write_all` Err -> `ledger-write`, stamp write Err -> `tmp-write`; success clears via `ok`. Bash: the shared-lock subshell now exits 75 (contention, silent), 76 (append failed, classified open vs write by message), anything else is a lock-open failure `flock-open`. The blanket `2>/dev/null` on the append is gone (`2>&1` captured instead).
* **H2 ledger tail read.** `ledger_tail(path, cap, key)`: NotFound silent; open/stat/seek/read errors log under `ledger-read` (transcripts use `ctx-transcript-read`). A failed `stat` no longer degrades to `unwrap_or(0)` (which would have streamed the whole file). `ledger-uncovered` logged when the tail cap does not reach the burn or block window start (both twins). Bash `tail` failure logged.
* **H3 malformed rows.** Counted in compaction only (not on the hot path): `ledger-compact-dropped: N malformed ledger rows removed`. Invalid UTF-8 replacement logged as `ledger-invalid-utf8` (Rust). Bash counts non-empty lines minus valid rows.
* **H4 compaction.** Cooldown stamp write Err -> `ledger-compact-stamp`; read Err -> `ledger-compact-read`; the empty "refuse to wipe" branch now logs `ledger-compact-refused` with the counts; create/write/sync/rename Err -> `ledger-compact-write` and the orphan tmp is removed. Lock held stays silent. Bash: awk rc captured (stderr to the scratch file), refusal, mv failure and sync failure logged.
* **H5 state.** `atomic_write` returns bool and logs `state-write` + removes the orphan tmp; `update_field` logs create_dir/read/parse/non-object failures and now backs off 60 s after a failure (`state-write-retry`, the audit's "cheap guard"), so a broken disk is not hammered several times a second per session. `read_state` logs `state-corrupt` for read Err, parse Err and non-object (missing file stays silent); `write_state` logs history reset (`state-corrupt`) and a non-JSON `flair` (`state-flair`). Bash: `_nf_read_state` logs on a non-zero jq; `_nf_state_heal` (new, shared by `_nf_update_field` and `_nf_update_recent_styles`) copies a corrupt file to `state.json.corrupt` before rebuilding and logs `state-rebuilt`; `_nf_write_state` logs jq/mv failure and removes its tmp.

MED
* **M1 MCP probe.** The spawned script (Rust and bash twin) captures `claude mcp list` rc and stderr (to an unguessable `mktemp` file), logs `mcp-probe: claude mcp list exited N (timeout|failed); first output: ...` or `... printed no parseable server lines` (silent when the output says "No MCP servers"), logs `recovered: mcp-probe` on success, logs a failed cache `mv`. Rust: `spawn()` Err -> `mcp-probe-spawn`; `claude` not on PATH -> `mcp-no-claude`; cache read Err (non-NotFound) -> `mcp-cache-read`; non-empty cache without three integers -> `mcp-cache-garbled`. Probe lock held stays silent. `NERDFLAIR_MCP_HEALTH=0` stays silent.
* **M2 git.** Central in `proc.rs` (Rust) and `_nf_cmd` (bash). Quiet: `rev-parse --is-inside-work-tree` with "not a git repository", `diff --numstat HEAD` with no HEAD, `symbolic-ref` (detached HEAD), `remote get-url origin`, `rev-list @{upstream}`. Logged: `git:inside-work-tree:<rc>` (dubious ownership etc.), `git:status`, `git:diff`, `git:ls-files`, `git:common-dir`, `git:git-dir`, `git-branch` (both symbolic-ref and rev-parse failed), `spawn:git`, `timeout:<label>`, cache write/read failures (`tmp-write`, `git-cache-read`), unreadable untracked file (`git-untracked-read`). The git wall-clock guard is implemented (the audit left it optional).
* **M3 transcript/context.** `ctx-transcript-missing`, `ctx-transcript-read`, `ctx-no-usage` (tail has "usage" but nothing parses), `ctx-usage-type` (Rust: float/string token count counted as 0), `ctx-size-nonint` (Rust, the 200000 assumption), `ctx-pct-clamped` (both).
* **M4 payload.** `payload-empty`, `payload-parse` (message + first 200 chars), `payload-shape:<path>` (Rust, per field; bash logs the generic `payload-shape`), stdin read Err -> `stdin-read`. Output unchanged.
* **M5 arithmetic.** Rust `arith-fatal:<field>` / `arith-syntax:<field>` at every site; value handling unchanged (parity). Bash: EXIT trap logs `render-abort` when the render exits non-zero (that is how a fatal arithmetic error shows there), and still flushes the buffer first.
* **M6 sample ring.** Write and rename Err -> `sample-write` (tmp removed); `read_ring` non-NotFound Err and "content but no samples" -> `sample-read`. Bash: write/rename failure logged.
* **M7 try_flock.** EWOULDBLOCK silent; open failure (after the EISDIR migration attempt) -> `flock-open`; other flock errno -> `flock`. Bash MCP probe lock open failure -> `flock-open`.

LOW (done)
* L1 `/tmp` cache and stamp writes: `tmp-write` / `tmp-read` (all /tmp write sites in both twins that the audit named: stamp, memo, multibranch, tmux, git cache).
* L2 tmux: `tmux` key. L3 session chime file: `session-file`. L4 `~/.claude.json` / `.mcp.json`: `claude-json`, `mcp-json` (read Err non-NotFound, parse Err, `.projects` not an object).
* L5 width: `width-bad`, `columns-bad`, `tput`. L6 `env_int` and bash tunables: `env-bad:<NAME>`. L9 HOME unset: `home-unset` (Rust).
* L10 stdout write: logged unless BrokenPipe.
* Bash-only: jq missing now also goes through `_nf_err` (`jq-missing`) besides its stderr message; awk failures `burn-awk`; EXIT trap `render-abort`.

## Skipped, and why

* **L7 `uid()` fallback, L8 `epoch_secs()` pre-1970**: `errlog` itself calls both (stamp name, timestamp), so logging from inside them recurses. Practically unreachable. Left silent.
* **L1 `file_age` stat error other than NotFound**: logging it costs a syscall on the hot path or changes a documented fail-toward-work helper. Left.
* **L11 formatting parsers (fmtx/jqx)**: the audit itself says not worth logging; covered by H3 and the arith notes.
* **`nerdflair.sh` CLI `jq ... && mv` chains and the chime/sound lock**: user-initiated commands where the right fix is stderr + non-zero exit (the user sees it), a different mechanism from this log, and outside "the status-line renderer and its twin". Not touched. Also not touched: `_nf_read_field` / `_nf_read_recent_styles` in `lib.sh` (CLI and hook paths, not the render path).
* **Bash twin parity gaps, deliberately not logged**: `ctx-usage-type`, `ctx-size-nonint` (unreachable in bash: the size is the constant 200000 in that branch), the sample-ring READ side, per-field `payload-shape:<path>` (jq cannot say which field), `home-unset` (with `set -u` bash dies on an unset HOME before it could log). `render-abort` covers the fatal-arithmetic class.
* **Rust does not copy+rebuild a corrupt state file** (bash does, per the brief). Rust degrades to defaults and logs `state-corrupt`, leaving the file for inspection; output parity is unaffected. Cheap to add if the owner wants identical behaviour.

## Design notes and deviations

1. **Symlink-safe stamps (from the automated security review).** `/tmp` is shared and the stamp names are predictable. Rust writes stamps with `O_NOFOLLOW`; bash with `touch -h` / `noclobber`. The probe's stderr file is now an unguessable `mktemp` instead of `<cache>.err`. If a stamp cannot be written the line is logged anyway (a lost reason is worse than a repeat).
2. **Boundary race**: two renders in the same instant at the hour boundary may both log (no lock by design; commented as `ponytail`).
3. **Test-only switches** added to the product: `NERDFLAIR_TEST_PANIC` (Rust panics at start of `main`), `NERDFLAIR_ERR_STAMP_DIR` (stamp location), `NERDFLAIR_MCP_PROBE_TIMEOUT` (default 30), `NERDFLAIR_PROC_TIMEOUT_MS` (default 10000). Only the first is test-only in intent; the others are documented tunables.
4. **`/dev/full` is not usable as an unwritable ledger.** Both renderers also READ the ledger and reading `/dev/full` never ends: my first run hung in the awk repo-total over it. The test uses a ledger larger than `RLIMIT_FSIZE` with SIGXFSZ ignored instead (appends fail with EFBIG). Side finding, NOT fixed: `NERDFLAIR_REPO_COST_FILE` pointing at a character device or FIFO hangs the renderer (a user-config error, but it is the same class as the unbounded-read incidents).
5. **Keys differ slightly between twins** where jq or bash cannot give the detail (`payload-shape`, arithmetic). The tests assert the shared keys.
6. **Environment gotcha** while working: the shell's `umask 0117` made new directories unusable (the known tmux umask issue). Every command here ran with `umask 022`.

## Acceptance output (real, from `/home/plafayette/nf-acceptance.txt`, after the last commit)

```
### cargo build --release (touched, full recompile)
   Compiling nerdflair v0.1.0 (/home/plafayette/nerdflair-wt-rust/rust)
    Finished `release` profile [optimized] target(s) in 6.98s        <- no warnings

### bash tests/difftest.sh
│  corpus = 162 payloads   normalize-countdown = off
162/162 identical

### bash tests/burn-block-golden.sh
burn-block-golden (rust): PASS
### bash tests/burn-block-golden.sh --bash
burn-block-golden (bash): PASS
### bash tests/golden-mutation.sh
golden-mutation: PASS, every mutation was killed.
### bash tests/mcp-cap.sh
mcp-cap: PASS
### bash tests/empty-home.sh
  PASS  HOME unset: nothing written to the working directory
  PASS  HOME empty: nothing written to the working directory
empty-home: PASS
### bash tests/bridge-selfchecks.sh
bridge-selfchecks: PASS
### bash tests/validate-ledger.sh
  window       rust       bash    recount    delta
  1h          27.83      27.83      31.28   -11.0%  outside +2%/-10%
  3h          53.03      53.03      57.84    -8.3%  ok
  4.8h        62.57      62.57      67.22    -6.9%  ok
validate-ledger: FAIL
```

`difftest.sh` showed `UNSTABLE (differed once, matched on retry): 139` on one early run, then 162/162 identical on 5 further runs; it is timing noise in the harness (the harness reports it by design).

**`validate-ledger.sh` fails identically on the BASE commit `6bd7c5d`** (built in a throwaway worktree, since removed):
```
  window       rust       bash    recount    delta
  1h          20.47      20.47      25.67   -20.3%  outside +2%/-10%
  3h          45.32      45.32      50.08    -9.5%  ok
  4.8h        59.23      59.23      63.43    -6.6%  ok
validate-ledger: FAIL
```
It validates against the live machine ledger (the figures move as it grows); rust and bash agree to the cent in both runs, so this is not caused by this change.

### New test, on the new code (11.7 s; 63 PASS, 0 FAIL)

```
silent-failures: 4 renders per case, throwaway HOME, both renderers
FAILURE classes (each must log exactly one line):
  PASS  ledger-unwritable-file [rust]: exactly 1 'ledger-write' line after 4 renders
  PASS  ledger-unwritable-file [bash]: exactly 1 'ledger-write' line after 4 renders
  PASS  ledger-unwritable-file: stdout byte-identical (rust vs bash)
  PASS  ledger-readonly-file [rust]: exactly 1 'ledger-open' line after 4 renders
  PASS  ledger-readonly-file [bash]: exactly 1 'ledger-open' line after 4 renders
  PASS  ledger-readonly-file: stdout byte-identical (rust vs bash)
  PASS  ledger-dir-unwritable [rust]: exactly 1 'flock-open' line after 4 renders
  PASS  ledger-dir-unwritable [bash]: exactly 1 'flock-open' line after 4 renders
  PASS  ledger-dir-unwritable: stdout byte-identical (rust vs bash)
  PASS  corrupt-state [rust]: exactly 1 'state-corrupt' line after 4 renders
  PASS  state-corrupt [rust]: corrupt file left untouched
  PASS  corrupt-state [bash]: exactly 1 'state-corrupt' line after 4 renders
  PASS  state-corrupt [bash]: original kept as state.json.corrupt
  PASS  state-corrupt [bash]: state.json rebuilt as valid JSON
  PASS  state-corrupt [bash]: rebuild is logged too
  PASS  corrupt-state: stdout byte-identical (rust vs bash)
  PASS  state-dir-unwritable [rust]: exactly 1 'state-write' line after 4 renders
  PASS  state-dir-unwritable [bash]: exactly 1 'state-write' line after 4 renders
  PASS  state-dir-unwritable: stdout byte-identical (rust vs bash)
  PASS  compaction-corrupt-rows [rust]: exactly 1 'ledger-compact-dropped' line after 4 renders
  PASS  compaction-corrupt-rows [bash]: exactly 1 'ledger-compact-dropped' line after 4 renders
  PASS  compaction-corrupt-rows: stdout byte-identical (rust vs bash)
  PASS  compaction-refused [rust]: exactly 1 'ledger-compact-refused' line after 4 renders
  PASS  compaction-refused [bash]: exactly 1 'ledger-compact-refused' line after 4 renders
  PASS  compaction-refused: stdout byte-identical (rust vs bash)
  PASS  mcp-probe-exit1 [rust]: exactly 1 'mcp-probe' line after 4 renders
  PASS  mcp-probe-exit1 [bash]: exactly 1 'mcp-probe' line after 4 renders
  PASS  mcp-probe-exit1: stdout byte-identical (rust vs bash)
  PASS  mcp-probe-timeout [rust]: exactly 1 'mcp-probe' line after 4 renders
  PASS  mcp-probe-timeout [bash]: exactly 1 'mcp-probe' line after 4 renders
  PASS  mcp-probe-timeout: stdout byte-identical (rust vs bash)
  PASS  git-dubious-ownership [rust]: exactly 1 'git:inside-work-tree:128' line after 4 renders
  PASS  git-dubious-ownership [bash]: exactly 1 'git:inside-work-tree:128' line after 4 renders
  PASS  git-dubious-ownership: stdout byte-identical (rust vs bash)
  PASS  git-not-installed [rust]: exactly 1 'spawn:git' line after 4 renders
  PASS  git-not-installed [bash]: exactly 1 'spawn:git' line after 4 renders
  PASS  git-not-installed: stdout byte-identical (rust vs bash)
  PASS  git-hangs [rust]: exactly 1 'timeout:git:inside-work-tree' line after 4 renders
  PASS  git-hangs [bash]: exactly 1 'timeout:git:inside-work-tree' line after 4 renders
  PASS  git-hangs: stdout byte-identical (rust vs bash)
  PASS  missing-transcript [rust]: exactly 1 'ctx-transcript-missing' line after 4 renders
  PASS  missing-transcript [bash]: exactly 1 'ctx-transcript-missing' line after 4 renders
  PASS  missing-transcript: stdout byte-identical (rust vs bash)
  PASS  bad-payload-json [rust]: exactly 1 'payload-parse' line after 4 renders
  PASS  bad-payload-json [bash]: exactly 1 'payload-parse' line after 4 renders
  PASS  bad-payload-json: stdout byte-identical (rust vs bash)
  PASS  empty-payload [rust]: exactly 1 'payload-empty' line after 4 renders
  PASS  empty-payload [bash]: exactly 1 'payload-empty' line after 4 renders
  PASS  empty-payload: stdout byte-identical (rust vs bash)
  PASS  nonnumeric-tunable [rust]: exactly 1 'env-bad:NERDFLAIR_BURN_WINDOW' line after 4 renders
  PASS  nonnumeric-tunable [bash]: exactly 1 'env-bad:NERDFLAIR_BURN_WINDOW' line after 4 renders
  PASS  nonnumeric-tunable: stdout byte-identical (rust vs bash)
  PASS  panic [rust]: exactly 1 'panic' line after 4 renders
  PASS  panic [rust]: stdout stays empty
  PASS  panic [rust]: process still dies non-zero
  PASS  panic [rust]: message and location logged

NOISE (must stay completely silent):
  PASS  noise-lock-contention [rust]: log stays empty after 4 renders
  PASS  noise-lock-contention [bash]: log stays empty after 4 renders
  PASS  noise-lock-contention: stdout byte-identical (rust vs bash)
  PASS  noise-baseline-not-a-repo-missing-optional-files [rust]: log stays empty after 4 renders
  PASS  noise-baseline-not-a-repo-missing-optional-files [bash]: log stays empty after 4 renders
  PASS  noise-baseline-not-a-repo-missing-optional-files: stdout byte-identical (rust vs bash)

silent-failures: PASS
```

### The same test on the OLD code (`6bd7c5d` plus the test file copied in): 38 FAIL, 24 PASS

Every failure-class assertion fails (nothing is logged, the panic case does not even die), while the 24 passes are exactly the ones that must pass on old code too: the six NOISE assertions and the stdout byte-identity checks. (It took 5m55s there because each of the four MCP-probe cases waits its full 20 s for a line that never comes.)

```
  FAIL  ledger-unwritable-file [rust]: exactly 1 'ledger-write' line after 4 renders
  FAIL  ledger-unwritable-file [bash]: exactly 1 'ledger-write' line after 4 renders
  FAIL  ledger-readonly-file [rust|bash]: exactly 1 'ledger-open' ...
  FAIL  ledger-dir-unwritable [rust|bash]: exactly 1 'flock-open' ...
  FAIL  corrupt-state [rust|bash]: exactly 1 'state-corrupt' ...
  FAIL  state-corrupt [bash]: original kept as state.json.corrupt
  FAIL  state-dir-unwritable [rust|bash]: exactly 1 'state-write' ...
  FAIL  compaction-corrupt-rows [rust|bash]: exactly 1 'ledger-compact-dropped' ...
  FAIL  compaction-refused [rust|bash]: exactly 1 'ledger-compact-refused' ...
  FAIL  mcp-probe-exit1 [rust|bash]: exactly 1 'mcp-probe' ...
  FAIL  mcp-probe-timeout [rust|bash]: exactly 1 'mcp-probe' ...
  FAIL  git-dubious-ownership [rust|bash]: exactly 1 'git:inside-work-tree:128' ...
  FAIL  git-not-installed [rust|bash]: exactly 1 'spawn:git' ...
  FAIL  git-hangs [rust|bash]: exactly 1 'timeout:git:inside-work-tree' ...
  FAIL  missing-transcript [rust|bash]: exactly 1 'ctx-transcript-missing' ...
  FAIL  bad-payload-json [rust|bash]: exactly 1 'payload-parse' ...
  FAIL  empty-payload [rust|bash]: exactly 1 'payload-empty' ...
  FAIL  nonnumeric-tunable [rust|bash]: exactly 1 'env-bad:NERDFLAIR_BURN_WINDOW' ...
  FAIL  panic [rust]: exactly 1 'panic' line / stdout stays empty / process still dies non-zero / message logged
  PASS  noise-lock-contention [rust|bash]: log stays empty        (correct on old code too)
  PASS  noise-baseline-not-a-repo-missing-optional-files [rust|bash]: log stays empty
silent-failures: FAIL
```
(The `[rust|bash]` rows are two separate FAIL lines each in the real output, 38 FAIL lines in total; full file: `/home/plafayette/nf-sf-base.txt`.)

### Cost

150 warm renders of payload 104 in a git repo, temp HOME: base 2495 us, new 2664 us (about +7%, the git calls are served from the 3 s cache; the per-call cost is two drain threads and a polling `try_wait`). `loadtest.sh` was not run: it is a 10-minute process-count test and nothing here adds a background process.

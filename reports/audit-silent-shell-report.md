# Silent-failure audit: nerdflair hover shell, python, service and tests

Standard: every absorbed, downgraded or worked-around failure must leave an error in something durable (log file, or stderr a user will see), once, with the reason. Never raise where it could lock the user out of `claude`: degrade AND log.

Method: read every in-scope file in full; rg for absorbing patterns across tests/ and read the surrounding code of every hit plus each test's exit/summary path. Nothing was executed.

Proposed shared mechanism (used by the fixes below): one helper `nf_log <component> <reason>` that appends `date comp: reason` to `~/.local/state/nerdflair/hover.log` (the watcher already uses `~/.local/state/nerdflair/tmux-watch.log`; reuse that directory), dedupes by keeping a `last-<component>` marker holding the last reason so the same reason is written once until it changes or clears, caps the file like `log()` does in nf-tmux-watch, and itself ends in `|| true` (a logging failure must never block claude). A one-line stderr notice at the point the user acts (install.sh, popup click) is added only where a human is waiting; the shim and heal run on every claude start, so they log to file only.

## Ranked findings (absorbing sites that are NOT acceptable today)

### HIGH

**H1. claude-shim:36 import check silently drops hover**
`(( wrap )) && { python3 -c "import ... mklayout, panel, nfpty" "$HOVER" >/dev/null 2>&1 || wrap=0; }`
Absorbs: python too old, a SyntaxError or ImportError in mklayout/panel/nfpty, a broken install. Logged: nothing; the traceback is thrown away. Impact: user silently has plain claude, no hover, no hint why, indefinitely. This is the exact shape of the "silent no-op for a day" the heal test header describes.
Fix: capture stderr (`err=$(python3 -c ... 2>&1 >/dev/null)`), on failure `nf_log shim "import check failed: ${err##*$'\n'}"` (last line, once per distinct reason), then `wrap=0`. Still execs real claude.

**H2. claude-shim:33 missing nfpty.py or python3 silently drops hover**
`{ [[ -f "$HOVER/nfpty.py" ]] && command -v python3 >/dev/null; } || wrap=0`
Absorbs: dangling `~/.nerdflair/hover` link (repo moved or deleted), python3 not on PATH. Logged: nothing. Impact: silent loss of hover; the comment calls it "plain claude" as if intended.
Fix: split into two tests, log `nfpty.py not found at $HOVER (hover link dangling; run install.sh)` or `python3 not on PATH`, once.

**H3. nf-tmux-heal:48 and nf-tmux-watch:143 report success when nothing was healed**
heal always ends `exit 0`; the watcher logs `healed rc=0` regardless. Every "could not heal" path in heal (ss missing L20, ss failed L26, regex no match L27, no pid L32, wrong comm L35, wrong owner L36, mkdir failed L38) exits 0 with no output, and the watcher then writes `healed rc=0` with an empty stderr. The watcher's whole purpose is the repair; its log claims a repair that did not happen. tests/tmux-watch.sh asserts `healed rc=0` (it also asserts reachability, so the test is fine, but the production log is not).
Fix: (a) heal exits 0 only if it signalled a server or found nothing broken; exits 3 when it found a deleted socket and could not act, with the reason on stderr. (b) Watcher, after the heal, waits up to ~3 s for `os.path.exists(socket)` and logs either `socket restored` or `NOT RESTORED rc=N reason`. (c) Rename the log line from "healed" to the measured outcome.

**H4. nf-tmux-watch:117-119 inotify_add_watch failure ignored**
`wd = libc.inotify_add_watch(...); if wd >= 0: self.wd[wd] = d` with no else.
Absorbs: ENOSPC (watch limit), EACCES, ENOENT race. Retried every 30 s forever, never reported. Impact: the service is "running", the log says `watching [...]` at startup only, yet a directory is not watched and a deletion goes unnoticed and unhealed.
Fix: `else: errno = ctypes.get_errno(); if d not in self.failed: self.failed.add(d); log(f"cannot watch {d}: {os.strerror(errno)}")`, and `self.failed.discard(d)` plus a log line on later success.

**H5. nf-tmux-watch:73-74 `ss` failure returns []**
`except (OSError, subprocess.SubprocessError): return []`, and a nonzero return code or stderr from `ss` is ignored. Absorbs: ss missing, ss hanging 5 s, ss erroring. Impact: the watcher watches nothing, forever, and logs at most one `watching []` at start. Rescan every 30 s never says it still fails.
Fix: record the failure reason in `self.ss_err`; log on transition ok to failing and failing to ok only (not each 30 s). Check `r.returncode` too.

**H6. nf-tmux-heal:20 `command -v ss >/dev/null 2>&1 || exit 0`**
Heal is completely disabled where `ss` is absent (minimal containers, some BusyBox systems), silently, on every claude start. Fix: `nf_log heal "ss not found: tmux socket repair is disabled"` (deduped), exit 3 per H3.

**H7. claude-shim:47 exec python3 nfpty.py has no fallback after the import check**
Not a silent failure but the opposite violation of the standard's second half: once `exec -a claude python3 nfpty.py` runs, any startup failure inside nfpty (pty allocation, tmux query, env) kills the shim process and claude never starts. The import check only proves imports, not that nfpty can start. I did not read nfpty.py (out of scope), so I cannot say whether it itself falls back to exec'ing `CLAUDE_BIN` on its own errors. Verify that nfpty's top-level catches everything before the child is spawned and exec's `$CLAUDE_BIN` with a logged reason. If it does not, the shim should not `exec` but run nfpty as a child and fall through to `exec "$real"` on a startup-class exit code, logging it.

**H8. install.sh:149 `systemctl --user enable --now ... >/dev/null 2>&1 && echo "tmux socket watcher running"`**
If enable/start fails (bad unit, MemoryMax unsupported, no D-Bus session), nothing prints, install ends "hover installed". Under `set -e` the `&&` list does not abort. Fix: `if out=$(systemctl --user enable --now nf-tmux-watch.service 2>&1); then echo "  tmux socket watcher running"; else echo "install: WARNING watcher not started: $out" >&2; fi`.

### MEDIUM

**M1. claude-shim:43 `nf-tmux-heal 2>/dev/null || true`**
Discards every message heal prints, including the two diagnostics heal deliberately writes to stderr (L43 "not a private directory", L46 "socket recreated"). So heal's correct logging is defeated by its caller; nothing durable survives when it runs from the shim. Also ignores a nonzero rc. Fix: `nf-tmux-heal 2>>"$LOGDIR/heal.log" || nf_log shim "nf-tmux-heal rc=$?"`, and have heal prefix each stderr line with the date. Only emits when something happens, so no spam.

**M2. nf-tmux-heal:27, 32, 35, 36, 38: silent `continue` on a missing socket**
Lines 29/30 (path not ours, socket present) are correct filters. But once a tmux-UID socket path is confirmed MISSING, every later `continue` (regex mismatch, no `pid=` because `ss -p` lacked privileges, comm not "tmux: server", owner mismatch, mkdir failed) abandons a needed repair silently. L27 is the highest risk: any change to `ss` column layout makes heal and the watcher blind (the python regex at nf-tmux-watch:77 has the same exposure and also requires the literal `users:(("tmux: server"`). Fix: in heal, a line that contains `/tmux-$uid/` and fails the regex, or reaches a `continue` after the missing-socket test, writes one stderr line with the line text and the reason. In the watcher count lines containing `tmux` that fail the regex and log once if the count is nonzero and no paths were found.

**M3. install.sh:184 exits 0 when no rc file was updated**
Every rc file skipped (unmatched marker, CRLF) gives `0 rc file(s) updated, N skipped` and exit 0; the per-file reasons went to stderr, but a script or CI sees success, and the line "new shells start claude under the wrapper" is false. Fix: when `done == 0` or `skipped > 0`, print `install: hover is NOT active for new shells` and `exit 1` (install is not on the claude launch path, so raising is safe).

**M4. install.sh:145 systemd absent is skipped "quietly"**
By design per the comment, but it violates the standard: the user is never told the watcher is not installed. Fix: `else echo "  tmux socket watcher: skipped (no systemd user manager)"`.

**M5. install.sh:110, 166, 124 `grep ... 2>/dev/null` on a file that may be unreadable**
`! grep -qF "$BEGIN" "$f" 2>/dev/null` treats "cannot read" as "no marker". On uninstall that means the block stays in a root-owned or unreadable rc file while the run ends `hover removed`. The same grep on L166 hides the alias warning. Fix: test `[[ -r $f ]] || { echo "$f unreadable; skipped" >&2; return; }` before the grep. L124 (`$NF/created` missing) and L201/L209 (status) are fine, see Correct list.

**M6. install.sh:193 uninstall `systemctl --user disable --now ... >/dev/null 2>&1 || true`**
Then the unit file is removed. If disable/stop failed, the watcher keeps running with its file gone, and uninstall prints "hover removed". Fix: print `uninstall: could not stop nf-tmux-watch.service: $out` on failure.

**M7. install.sh rc block L43 function fallback `else command claude "$@"`**
If `~/.nerdflair/bin/claude` is not executable (partial uninstall, deleted dir) every claude start silently runs plain claude and the user loses hover. This is a deliberate no-lockout fallback (tests/install-rc.sh:140 pins it), but it is silent. Fix: `else echo "nerdflair: shim missing, running plain claude (run band/hover/install.sh)" >&2; command claude "$@"`. It fires only in the broken state, so it is not spam.

**M8. install.sh L48-50 TMUX_TMPDIR protection skipped silently**
When `XDG_RUNTIME_DIR` is unset or not a directory, the tmux socket stays in /tmp, which is the failure the watcher exists for. Nothing says so. Fix: `install.sh status` prints `tmux socket dir: <dir> | in /tmp (unprotected: XDG_RUNTIME_DIR unusable)`; do not print from the rc block.

**M9. nf-tmux-watch:142 `subprocess.run([HEAL], capture_output=True)` has no timeout and no except**
A missing heal binary raises FileNotFoundError and kills the watcher (traceback to the journal, then systemd restart; not silent, but the watcher is lost and after 5 starts in 10 minutes systemd stops trying). A hung heal (its `ss`) blocks the loop forever with no log. Fix: `timeout=30`, `try/except (OSError, subprocess.SubprocessError) as e: log(f"heal could not run: {e}")`.

**M10. nf-tmux-watch:58-65 `log()` can raise and kill the watcher; rotation failure absorbed**
`makedirs`/`open` errors (disk full, permissions) propagate out of `run()`; the loss of the logger takes the watcher down with it (journal only). `except OSError: pass` at L62 also swallows a failed `os.replace` rotation, so the log grows without bound. Fix: wrap the write in try/except that prints to stderr (journal) and continues; narrow L62 to `FileNotFoundError` and report other errors once to stderr.

**M11. nf-tmux-watch:159-165 IN_Q_OVERFLOW and unknown wd ignored**
On inotify queue overflow the kernel sends `wd=-1, mask=IN_Q_OVERFLOW (0x4000)`; the code resolves `d="?"` and drops it, so a deletion in the overflowed burst is lost. Low probability. Fix: `if mask & 0x4000: log("inotify queue overflowed; rescanning"); self.rescan()` and treat as a possible hit.

**M12. popup.sh:27-28 `exit 0` when tmux or $TMUX is absent**
The comment says "no popup, and no error either". The user pressed a readout and nothing happened with no trace. Fix: `nf_log popup "no tmux ($reason): detail popup not shown"` then `exit 0` (never an error status). Dedupe so repeated clicks write once.

**M13. popup.sh:43-46 `tmux display-popup ... 2>/dev/null`**
Absorbs: tmux older than 3.2 (no `display-popup`), no client, socket gone, bad geometry. Impact: every click is a silent no-op. Fix: `err=$(tmux display-popup ... 2>&1) || nf_log popup "display-popup failed rc=$?: $err"`. Cannot tell here whether the band's caller checks the exit status (hooks/register.tsx is out of scope).

**M14. sync-local-plugin.sh:30 `if claude plugin list --json | python3 -c ... ; then update else install`**
Within an `if` condition `set -e` and pipefail are suspended, so a failing `claude plugin list` (crash, not logged in, bad JSON, python traceback) is treated as "not installed" and the script runs `claude plugin install`. Not fully silent (the tool's stderr is visible), but the failure is converted into a different action with no message. Fix: `list=$(claude plugin list --json) || { echo "sync: claude plugin list failed" >&2; exit 1; }`, then test `$list`.

**M15. tests/ledger-concurrency.sh:181 SKIP exits 0**
`printf '  SKIP ... no release build'` and, with `fail=0`, the script ends `ledger-concurrency: PASS` and exit 0. The stale-lock migration check is skipped and the run is reported green. Every other test uses exit 2 or 77 for "could not run". Fix: set `skipped=1` and end `PASS (1 SKIPPED)` with exit 77 when anything was skipped, or fail.

**M16. tests/validate-ledger.sh:49, 68-71 a crashed product becomes SKIP 77**
`block_of` and the recount run with `2>/dev/null`; an empty figure from the Rust binary or bash renderer (crash, timeout 124, changed glyph) goes to `SKIP: could not read a figure` exit 77, which a runner may read as "could not run" rather than a regression. Also `price-recount.py` prints `UNPRICED {...}` on stderr (L153-154) and L68 discards it, so a model with no price silently lowers the recount. Fix: if bash and recount produced a figure and rust did not, FAIL; let recount's stderr through.

**M17. tests/test-nerdflair.sh:42 and 773**
`) >/dev/null 2>&1` around the fixture git setup: a failed `git init`/commit leaves a bad fixture and tests run against it with no message. `if "$t" 2>/dev/null` discards the stderr of each test, so `FAIL (crashed)` never says why. Because tests run inside `if`, `set -e` is off within them, so any unchecked command in a test is ignored. Mutation lines 689/729/739 (`|| true`) rely on later assertions I did not read to be sure they catch a failing hook. Fix: send each test's stderr to `$_results_dir/$t.err` and print it on FAIL; check the fixture subshell's exit code.

**M18. tests/difftest.sh:125 `_gitq` and identical-failure parity**
`git ... >/dev/null 2>&1` hides fixture build failures; both sides then read the same broken fixture and compare equal, a vacuous pass. Also two sides that both fail the same way (same rc, same empty stdout) count as "identical"; only stderr is reported (NOISY). Fix: make `_gitq` abort the fixture with the git error; flag any case where both sides exit nonzero unexpectedly.

### LOW

- **L1. claude-shim:18** `cd "$d" 2>/dev/null` fine as written, but `readlink -f` (L22) failing (BusyBox, odd mount) yields two empty strings that compare equal and `continue`s past EVERY candidate, ending in "no real claude" (logged, exit 127). Fail-safe wrong direction only on exotic systems; guard with `[[ -n ... ]]`.
- **L2. install.sh:126** `grep -vxF ... > created.tmp || true`: rc 1 (no lines left) is legitimate but rc 2 (error) is absorbed and the following `mv` replaces the record with a possibly truncated file. Use `|| [[ $? -eq 1 ]]`.
- **L3. install.sh:91** `grep -c ... || true` on an unreadable file gives an empty count that passes the pairing test. Covered by M5's `-r` guard.
- **L4. install.sh:216-220** `status` reports STALE only when the installed copy exists; a missing nf-tmux-heal or nf-tmux-watch is not reported. Add `else echo "MISSING: ..."`. Also print `systemctl --user is-active nf-tmux-watch` so a service stopped by the StartLimit (below) is visible.
- **L5. nf-tmux-watch.service**: `StartLimitBurst=5` then systemd stops trying. The journal records it, but nothing a user reads does; surface it via install.sh status (L4). `Restart=on-failure` also leaves a clean exit down. Both are by design and documented.
- **L6. popup.sh:23-24, 31** `shift || true`, `${1:-0}` defaults and `tmux display-message ... 2>/dev/null || echo 120`: a caller passing the wrong arguments gets a popup at column 0 with a default title; a tmux failure falls to width 120. Log in the same helper when `$#` < 3 or the width query fails.
- **L7. tests/empty-home.sh:21,23** runs the renderer with `>/dev/null 2>&1`, ignoring its exit code and output: a binary that crashes at start writes nothing to the cwd and passes. Assert rc 0 and non-empty stdout.
- **L8. tests/install-rc.sh** `bash "$INSTALL" install >/dev/null 2>&1` everywhere, exit status never asserted; `systemctl` is stubbed to always fail, so the enable-failure path (H8) and the success path are untested. Assert rc and capture stderr in the cases that expect a warning.
- **L9. tests/nfpty-exit.sh:23,51,70** nfpty's stderr goes to DEVNULL, so a traceback is invisible and only an rc/timing mismatch is reported. Capture it and print on FAIL.
- **L10. tests/price-recount.py:93-95, 105-106** unreadable transcripts and malformed JSON lines are skipped uncounted (and L99 `open` is unguarded, inconsistent with L92). A skipped file lowers the recount. Count skips and print them on stderr (and let validate-ledger show it, see M16).
- **L11. tests/tmux-heal.sh:20-24, tmux-watch.sh:13** `mktemp -d` result unchecked (the other tests use `|| exit 1`); `"$HEAL" 2>/dev/null` discards diagnostics though assertions are by effect. No test covers: ss missing, ss format drift, inotify watch failure, import-check failure logging, popup failure. Add them with the fixes.

## Correct sites (checked, no change needed)

claude-shim:
- L11 `set -u` without `-e`: intentional, the shim must never abort.
- L18 `cd "$d" 2>/dev/null` and L19 `-x` test: probing PATH entries that may not exist.
- L20-22 loop `continue`s: skipping self and symlink-to-self, required to avoid an exec loop.
- L25-27: no real claude is reported to stderr with exit 127; nothing to degrade to.
- L30-32, L38, L40: deliberate no-wrap cases (already wrapped, opt-out, not a tty, not in tmux, `-p`/subcommands). Intended and documented, not failures.
- L49: exec the real claude.

install.sh:
- L19 bash version check reports and exits 2.
- L41 `unalias claude 2>/dev/null || true` in the rc block: probing an optional alias.
- L88-89, L112, L167, L170: CRLF, unmatched marker and alias conditions all print to stderr with the reason.
- L110 (missing-file case), L124, L201, L209: `grep ... 2>/dev/null` on an optional file; absence is the normal answer.
- L137-141: `mkdir`/`ln`/`install` under `set -e` abort loudly.
- L148, L195 `daemon-reload || true`: stderr is not redirected so the error shows; acceptable.
- L203 `rmdir ... 2>/dev/null || true`: non-empty directory is expected.
- L130, L218: messages for kept backup and stale copies.

nf-tmux-heal:
- L26 `ss 2>/dev/null` stderr is only noise when it works (failure path is M2).
- L29-30: filters for foreign and healthy sockets.
- L35-36 `cat`/`stat 2>/dev/null` while probing a pid that may have just exited.
- L42-45: refuses an unsafe directory and says so on stderr (the caller discarding it is M1).
- L18 `set -u` without `-e`: intentional.

nf-tmux-watch:
- L90-91: `ps` failure is logged into the record as `(ps failed)`.
- L96, L99: skipping malformed ps lines and itself.
- L107-109: inotify_init failure raises (journal).
- L130-136: rate limit logs once an hour, with the reason.
- L153-155: BlockingIOError on a non-blocking fd.
- L160 `errors="replace"`; L171-172 dropping a dead watch.
- nf-tmux-watch.service: bounded restart, documented.

sync-local-plugin.sh: `set -euo pipefail`; `cp`, `mkdir`, `rm` all abort on failure; L25 `[[ ]] && rm -rf` is a conditional, not an absorber; the final check (L38-44) exits nonzero on plugin errors or a missing plugin.

popup.sh: `set -uo pipefail` without `-e` is a no-lockout design choice; `shift || true` is argument-count tolerance (L6 above notes the missing log).

tests: bridge-selfchecks.sh (prints output and fails on any nonzero), golden-mutation.sh (an unapplied mutation is an ERROR, not a kill), loadtest.sh (aborts if workers died; `read -t ... || true` is a sleep idiom; `kill ... 2>/dev/null` cleanup), difftest.sh cleanup `rm 2>/dev/null` and `ls 2>/dev/null` (empty corpus exits 2), ledger-concurrency.sh L105 sleep idiom and L119 `stat || echo 0` (the later test rejects `0`) and its unlocked-arm control, mcp-cap.sh and transcript-tail.sh (stderr dropped but outputs are compared with expected values, an empty result fails), gen-payloads.sh L18 cleanup, install-rc.sh `grep -c || true` helpers, exit 2 or 77 for "not built / missing tool" in tmux-heal.sh, tmux-watch.sh, validate-ledger.sh (a skip never returns 0), the positive controls in tmux-heal.sh and tmux-watch.sh, and the python scratch-dir cleanup guards.

## Could not verify

- Behaviour of `band/bridge/nfpty.py`, `mklayout.py`, `panel.py` after the shim's `exec` (out of scope), so H7 is open.
- Whether the band's TypeScript (`band/hooks/register.tsx`) checks `popup.sh`'s exit status or surfaces its absence.
- Output format of `ss -xlnp` on other distributions or versions (the regex dependence in M2) and tmux version thresholds for `display-popup` (3.2+, from memory).
- test-nerdflair.sh (811 lines): I read the runner and the pattern hits, not every assertion, so I cannot say whether the `|| true` hook invocations at 689/729/739 are always followed by an assertion that would catch a failure.
- difftest.sh, burn-block-golden.sh and loadtest.sh: read the summary/exit paths and the grep hits, not every line; a Headroom-compressed grep showed only part of the FAIL/exit list for those files.
- Nothing was run, so no claim here is empirically reproduced.

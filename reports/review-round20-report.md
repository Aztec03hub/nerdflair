# Review round 20 (independent, read-only) of e472314

Scope: `git diff 81170ba..e472314` (round 19 fixes), then the wider silent-failure work. Read round 18, round 19 and the round 19 worklog first; finding 6 (git caches in /tmp following symlinks) skipped as a known deferred item.

Ran: `tests/difftest.sh` = 162/162 identical (corpus has no failed-cwd payload, see finding 1). `tests/silent-failures.sh` = PASS. Both pass, yet finding 1 is a live divergence, so the suite has a coverage hole there.

Round 19 items confirmed fixed: bash git circuit breaker and 60 s back-off (statusline.sh:46-49, :57), fresh git result survives a failed write (main.rs:2220-2235, statusline.sh:468-475), mktemp failure logged (statusline.sh:10-15), cards-check seeds its own tmux cache (mklayout.py:328-334), band notes for missing fields.

## 1. HIGH - Rust/bash twin divergence AND a silent fallback when the payload cwd does not exist
rust/src/main.rs:515-520 versus scripts/statusline.sh:348-354.
Round 19 made bash log `cwd-cd` and skip the whole git UI when `cd "$cwd"` fails. Rust still keeps `shell_cwd` = the process cwd and runs git there, with no log at all.
Reproduced (script run from /home/plafayette/nerdflair, payload `current_dir=/nonexistent/zz`, throwaway HOME):
- Rust stdout: `󰉋 zz · 󰘬 main ·  Opus 5 ... 1 [+48] ↑24` and an EMPTY error log.
- Bash stdout: `󰉋 zz ·  Opus 5` and `cwd-cd: cannot cd to /nonexistent/zz; git UI skipped`.
So a deleted worktree or renamed project dir shows another repo's branch and dirty count under the Rust renderer (the one that is actually installed), with nothing logged. The new tests/silent-failures.sh case `cwd-cd-fails` is pinned `IMPLS=bash` (line ~311), which hid it, and the difftest corpus has no such payload.
Fix: in Rust, when `!cwd.is_empty()` and `!Path::new(&cwd).is_dir()`, `errlog::note("cwd-cd", ...)` and skip git detection (leave `git_dir` empty), the same as bash. Run `cwd-cd-fails` for both impls (drop `IMPLS=bash`) and add a failed-cwd payload to the difftest corpus. Same for the second bash site (statusline.sh:395) if Rust has a cd for `git_dir` (it uses current_dir per call; check it logs a failure to spawn in a missing dir).

## 2. MEDIUM - the "literal key" memo in lib.sh is still a glob
scripts/lib.sh:114: `case "$_NF_MEM" in *" "${_k}" "*) return 0 ;; esac`
`${_k}` sits between two quoted spaces and is itself unquoted, so `*`, `?`, `[` in a key are pattern characters. Reproduced: `_NF_MEM=" spawn:abc "; _k='spawn:*'` prints MATCH. Keys are built from labels and file names (`tmp-write:${f##*/}`, `spawn:$1`, `timeout:${_l...}`), so a key with `*`, `?` or `[` would be swallowed because an earlier different key matched its pattern, and then never logged in that process. The round 19 fix removed the spaces-in-pattern problem but not this one.
Fix: quote the key so it is literal: `[[ "$_NF_MEM" == *" $_k "* ]] && return 0` (quoted parts of the pattern are literal in `[[ == ]]`; the unquoted `*` at each end stay globs). Keep the `" "` seed at line 43 and `+="${_k} "` at line 115. Add a lib test with `_k='a*'`.

## 3. MEDIUM - band back-off never engages while a stale cache exists, and is measured from the wrong clock
band/hooks/register.tsx:377 and :546.
(a) Gate `(cache || now - lastFailAt > FAIL_BACKOFF_MS)`: with a cache present the back-off is skipped, so a renderer that fails after one good render is re-run on every render past TTL_MS (2 s) for the whole 30 s stale window. That is exactly the "not re-run on every render" case the comment at :546 claims to prevent. The back-off only applies once the cache has been dropped.
(b) `lastFailAt = now` uses `now` from line 354, taken BEFORE the awaited refresh. The renderer call has `timeoutMs: 5000` (:471), so for a timeout the failure is recorded 5 s in the past and the 5 s back-off has already expired when the failed run returns: back-off of zero for the timeout class, the case that matters.
Scenario: renderer binary hangs; each render (2 s apart) spawns another 5 s run, three overlapping up to the inflight guard, band stalls.
Fix: remove `cache ||` from the gate (the stale-marking logic already serves the old figures during back-off), and set `lastFailAt = await $.clock.now()` after the refresh settles. Add a test: failing renderer with a cache, assert one spawn per 5 s.

## 4. LOW - multi-branch cache read failures are silent in both renderers
scripts/statusline.sh:549-550 (`read ... 2>/dev/null`, `sed ... 2>/dev/null`) and rust/src/main.rs:659 (`read_to_string(&cache_file).unwrap_or_default()`).
Round 19 turned this read into a fallback for the timeout case, but it also absorbs a plain unreadable or vanished cache file (fresh by `-f`/`is_file` at check time, then removed by a tmp cleaner, or EACCES): the multi-repo list silently disappears and nothing is logged. The git cache has `git-cache-read`; this twin does not.
Fix: log `multi-cache-read` (label per cache) when the file read fails and no computation is in hand, in both renderers; keep the timeout path quiet.

## 5. LOW - mklayout cards_check writes a predictable /tmp file with symlink following, no cleanup, no error handling
band/bridge/mklayout.py:331-333.
`open(tcache, "w")` on `/tmp/nerdflair-tmux-<uid>-_nfcards` follows a pre-planted symlink (same class as the deferred finding 6, but this one is new code and a write of a fixed string), is never removed, and an OSError is an unhandled traceback in a dev check.
Fix: put the seed in a `tempfile.mkdtemp()` only if the renderer takes a cache dir; otherwise `os.open(tcache, O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW, 0o600)` in try/except that prints the cause and exits non-zero, and `os.remove` it in a `finally`.

## 6. INFO - git back-off window is silent by design, one gap worth a line
rust/src/proc.rs:60-62, statusline.sh:46-49.
For 60 s after a hang every render drops the git UI (inside-work-tree returns 124 at once) with no log; the hang itself was logged once. That matches the stated design and is tested (`git-hang-backoff`, expects 0 new lines). If the stamp dir is unwritable the back-off silently never engages (`errlog::touch` ignores the error, proc.rs errlog.rs:241); acceptable since the stamp-dir failure is logged elsewhere, but note the 10 s cost per render returns in that case.

No other bugs found in the new code: the timeout-after-write ordering, `computed.take()` handling in `git_cache`, `computed_multi`, the `_cd_ok` expansion and the `tmp-write:<name>` key split all behave as intended.

# Review round 22 (read-only) of 11d4ea5

Scope: `git diff defbf00..11d4ea5`, then the wider silent-failure work. Rounds 18 to 21 reports and worklog-round19-fixes read first; fixed items and the /tmp git-cache symlink item skipped. No source edited. Scratch HOME under the session scratchpad.

Ran: `tests/difftest.sh` = 164/164 identical. `tests/silent-failures.sh` = PASS. Not run: bun/band tests (register.tsx and mklayout.py read only).

Round 21 fixes confirmed in the diff: `_nf_cmd` rc 137 (statusline.sh:63), empty state.json (lib.sh:295-298), chime_volume validation in both twins (main.rs:376-380, statusline.sh:105-108; `is_plain_number` matches `^[0-9]*\.?[0-9]+$` on the cases I traced: "", "5", ".5", "1.", "1.2.3"), usage-type guard, `can_enter`, `git_cache` returning `Option`, uid via getuid, `no-timeout`, cards fixtures.

## 1. LOW-MEDIUM - the stamp-dir "once an hour" limit does not hold when the marker cannot be written, so the line is logged on every render
rust/src/errlog.rs:75-86 (`stamp_dir_bad`), scripts/lib.sh:61-69.
Reproduced in both twins (HOME with `.claude/.nerdflair-stamps` and `.claude/.nerdflair-stamp-dir-bad` both dangling symlinks, 3 renders each): 3 `stamp-dir` lines per implementation. Cause: the marker test uses `exists()` / `-e`, which follow the link and say "absent"; the write is `O_NOFOLLOW` / `[[ -L ]]` guarded and fails, with the failure discarded (`let _ =`, `2>/dev/null`). The same happens whenever `~/.claude` is not writable for the marker (the log itself would then fall to stderr, once per render). Round 21 #6 was meant to stop exactly this per-render repetition. The marker is only as good as its write.
Fix: treat a marker that exists as a symlink (`symlink_metadata().is_ok()` / `-e || -L`) as "recent" and do not log, or, if the write fails, fall back to a per-process memo only (already so) and add the marker failure into the one logged reason. Add a silent-failures case with a dangling marker symlink asserting 1 line after 3 renders.

## 2. LOW-MEDIUM - a non-numeric `chime_volume` shows 100% on the status line, but the chime is silently muted by bell.sh and nerdflair.sh
hooks/bell.sh:172, :216 (and :221), scripts/nerdflair.sh:108, :196, :481, scripts/lib.sh:436 versus the new validation at statusline.sh:105-108 and main.rs:376-380.
Scenario: state.json has `"chime_volume":"loud"`. The status line now logs `chime-volume` and displays "100%" (volume 1). bell.sh runs `awk -v v=loud 'BEGIN {print (v+0 <= 0) ? 1 : 0}'` = 1, so `_chime_muted=1` and no audio plays; `_nf_play_audio` would also compute `v * 65536` = 0. The status line says audible at 100%, the hook is silent, and bell.sh/nerdflair.sh log nothing. The validation only lives in the renderer.
Fix: put the check once in lib.sh where `NF_CUR_CHIME_VOLUME` is loaded (lib.sh:277 area): non-numeric gives `_nf_err chime-volume ...` and `NF_CUR_CHIME_VOLUME=$NF_DEFAULT_CHIME_VOLUME`; then drop the duplicate in statusline.sh. Add a case that runs bell.sh with a bad volume and expects the log line and an audible (not muted) decision.

## 3. LOW - rc 137 is reported as "still running after Ns, killed" for any SIGKILL, and arms the 60 s git back-off
scripts/statusline.sh:63-65.
137 also arises from an external SIGKILL/OOM kill of git shortly after start, not only `timeout -k`. The log line then claims a timeout that did not happen (wrong diagnosis in the one place the owner reads), `git-hung` is touched and git is skipped for 60 s. Rust distinguishes its own deadline from a signal exit.
Fix: split the branch: 124 = timeout (as now); 137 = log `git:... killed (rc=137: SIGKILL after ignoring TERM, or killed externally)` and still set `_NF_GIT_TIMED_OUT` (the output is not trustworthy either way), but touch `git-hung` only when elapsed time is at least the deadline (compare `$SECONDS` before and after, or `EPOCHREALTIME`).

## 4. LOW - bash `no-timeout` and the `timeout` probe happen before the stamp dir / log are usable on a first render in a home with no `~/.claude`
scripts/statusline.sh:44-45.
`_nf_err no-timeout` is called at top level; the `_nf_log_line` path does `mkdir -p` of the log dir, so it works, and the empty-HOME suite passes. Noting only that `_nf_err` here runs before `_nf_require_jq`'s failure path matters not. No action unless the `timeout` probe is moved. Not a defect; listed so the next round can skip it.

## 5. LOW - small items
- rust/src/errlog.rs:131-141 (`trim` stat error branch): on a stat failure other than NotFound it writes to stderr on EVERY emit that passes the size check path; no rate limit, so a log on an unreadable path prints one stderr line per absorbed failure per render. stderr is the last resort, but the host may show it. Fix: gate it with the same per-process once-flag used for `mem_seen`.
- rust/src/main.rs:2274-2285 `can_enter`: uses `access(X_OK)`, which honours the real uid; bash `cd` uses effective permissions. Equal for a normal run, differs only under setuid or root-with-dropped-caps. No action, comment only.
- band/hooks/register.tsx:537: `await $.clock.now()` inside `if (segs)` is outside the refresh `try`; a rejecting clock throws out of `band()` after a successful refresh and the good `segs` are discarded. Caught and reported at the render level, so not silent; fix is to fall back to `now` with a logged note.

## Checked and fine
- `git_cache` None path (main.rs:2110-2122): `git_dir.clear()` at the call site is the only user of `gc`; fresh-cache path never needs `can_enter` (same as bash, statusline.sh:468-479).
- `stamp_dir_bad` inside the OnceLock initialiser: `emit` and `write_stamp` do not call `stamp_dir()`, so no deadlock.
- `uid_uncached` getuid: no fallback left, `libc` already a dependency.
- mklayout.py fixtures: GIT_* stripped, errors become a one-line `sys.exit`, token regex equals difftest's.
- awk `-v` use in statusline.sh:2228, :2872: safe against injection (the value is validated and not spliced). `-v` does process backslash escapes in the value, but a validated number has none.

## Verdict
No HIGH or MEDIUM defects. Two LOW-MEDIUM items (1 and 2) are real, one reproduced (1), one by reading plus the exact awk expression (2). Everything else is LOW.

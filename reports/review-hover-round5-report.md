# Hover review, round 5 (commit f455567)

Scope: git show HEAD (nfpty.py, panel.py, install.sh, nfpty-exit.sh). Static reading only.

## Findings

### Medium

M1. tests/nfpty-exit.sh:74-75 - the new readiness wait can spin forever. `readline()` returns b"" at EOF, and `b"ready" not in b""` is true, so if nfpty (or the bash child) dies before printing `ready` the loop busy-spins with no timeout and the whole test run hangs instead of failing.
Fix: stop on EOF and fail, e.g.
```
while True:
    line = p.stdout.readline()
    if not line: print(1, 99); sys.exit(0)   # nfpty died before ready: fails both checks
    if b"ready" in line: break
```
(or `select` with a 5 s deadline). The `read -r rc secs` consumer then gets a non-137 rc and secs > 4, so both checks fail loudly.

### Low

L1. band/bridge/nfpty.py:500-502 vs 672-688 - "signal handler ignores a reaped pid" is only true for the in-loop reap (:530-532). The final reap loop (:678-681) and the post-SIGKILL `waitpid` (:688) never set `status_box`, so a SIGTERM/SIGHUP landing after those reaps still `os.kill`s a reaped (reusable) pid. The window is tiny (process exits right after) and the in-loop reap has the same non-atomic gap between `waitpid` returning (:530) and `status_box[0] = st` (:532).
Fix: set `status_box[0] = status` right after each reap at :680 and :688, and restore the default handlers (`signal.signal(sg, signal.SIG_DFL)` for TERM/HUP) once the loop exits, before the final reap.

L2. band/bridge/panel.py:178-181 and nfpty.py:373-376 - the keep wiring has no automated check. `Panel.demo()` (panel.py:258+) only builds `Panel` with `keeps` False, so nothing asserts that `erase()` passes `keep=True` when `keeps=True`, and `nfpty.py --selfcheck` (the only home of the new `trim_pending` assert, nfpty.py:417) is not invoked by any script in tests/. Dropping the `if self.keeps` branch, or never running selfcheck, would go unnoticed.
Fix: add to `demo()` a case `calls=[]; Panel(lambda s, keep=False: calls.append((s, keep)), 50, 200, keeps=True)`, show then erase, and assert the last call has `keep` True and that a `keeps=False` panel with a one-arg writer still works; add `python3 band/bridge/nfpty.py --selfcheck` and `python3 band/bridge/panel.py` (whatever invokes demo) to a test script.

L3. band/hover/install.sh:49-50 and :70/:81 - a CRLF marker now prints two messages: the specific CRLF one, then the caller's generic "has an unmatched nerdflair marker; fix it by hand". Not wrong, slightly misleading.
Fix: have `paired` return distinct codes (2 for CRLF) and let callers skip their own message when it is 2, or drop the callers' wording to "is not safe to edit (see above)".

L4. band/hover/install.sh:49 - the CRLF probe only matches a CR immediately after the marker text. A marker line with trailing spaces then CR is not detected, and `grep -cxF` also counts 0 for it, so the original "append another block every install" bug remains for that shape. Rare.
Fix: use `"^(${BEGIN}|${END})[[:space:]]*"$'\r'`... or simply test `grep -qE "^(${BEGIN}|${END})[[:space:]]+$"` (any trailing whitespace on a marker is refused).

## Checked, no defect

- Quoting of `"^(${BEGIN}|${END})"$'\r'`: concatenation of a double-quoted string and an ANSI-C string is one argument ending in a literal CR. Neither marker contains an ERE metacharacter (`#`, `>`, `<`, space are literal in ERE without a backslash), so the pattern matches only a marker line ending in CR. `grep -q` inside `if` is safe under `set -e`.
- Panel write callers: only panel.py:152, 181, 191 call `self.write`; 152 and 191 pass one arg (fine for the keep-aware `write(s, keep=False)`), 179 passes `keep=True` only when `keeps`. `demo()` (panel.py:262-330) and every other Panel construction use `keeps` default False with `list.append`, so none break. hoverdemo.py does not construct Panel. No other importer found.
- Queue types: the only producer is `write` (nfpty.py:466-469), appending `(s, keep)`; `flush_pending` (:462) joins `w` from tuples; `trim_pending` indexes `[1]`. No str/tuple mix. `painted[0] += len(s)` still counts the str.
- `trim_pending` (nfpty.py:295-305): `i` advances on keep, an entry is deleted otherwise, so each pass makes progress and terminates; if every entry is a keep it exits with len > limit (erases are few and bounded by hides, so no growth concern). Limit is 64 now (was keep-all + last 32 frames); the call site `len(pending) > 64` (:627) is consistent. Order is preserved. The selfcheck arithmetic holds (73 entries, limit 5: 3 frames + erase + late remain).
- `on_term` early return (:501-502): it only fires when `status_box` is set, and the SIGKILL clock (:633) is gated on `status_box[0] is None`, so leaving `quit_sig` unset cannot suppress an escalation that is still needed. Exit code uses `status`, not `quit_sig`.
- `tcsetattr` guard (:662-666): `termios.error`/`OSError` swallowed narrowly, reap and SIGKILL block (:672-688) always run.
- Test SIGTERM timing: `ready` is echoed after `trap '' TERM`, so the signal can no longer arrive before the trap; 137 and the <=4 s check can still fail.

## Disposition 2026-10-09 (author)

All five fixed. M1 (the readiness wait now fails instead of hanging when the child dies first), L1 (the final reap and the post-SIGKILL reap set the reaped flag, and the TERM/HUP handlers go back to default once the loop is over), L2 (the panel selfcheck asserts the `keeps` wiring, and `tests/bridge-selfchecks.sh` now runs every selfcheck), L3 and L4 (the installer returns a distinct code for CRLF markers, prints one message, and tolerates trailing spaces before the CR).

Five rounds in all. Nothing Critical or High in any of them; the Medium count went 4 High, then 5, 3, 3, 1, and the last Medium was in a test, not in the bridge. A sixth round was not run: the findings had narrowed to the test harness and installer edges, and each round was producing fixes of its own. Say if you want one anyway.


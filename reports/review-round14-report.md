# Review round 14: band/hover/install.sh, tests/install-rc.sh, HEAD (39af46e)

Read-only analysis. Nothing was run (no install, tests, tmux, claude); no dotfile touched.

## Verdict

No defect found that deletes or corrupts a user's dotfile, locks the user out of `claude`, or aborts install/uninstall under `set -euo pipefail` on a normal system. Only low-severity items below, none blocking.

## Paths checked and found sound (with line refs)

- install.sh:126-127: `grep -vxF ... > created.tmp || true` always creates the tmp file (redirect), so `mv` cannot hit a missing source. The branch is only entered after `grep -qxF` at :124 proved `$NF/created` exists. An emptied created file is harmless.
- install.sh:201: `grep -qF ... && still=1` as the last statement of a `for` body. A failing `grep` is not the last command of the `&&` list, so errexit is not triggered, and a compound command whose status came from an ignored failure does not exit. `(( still )) || rm` at :202 is safe.
- install.sh:64, 70, 78: `[[ ]] && ...` in loops are each followed by an `echo`/`return 0`, so a false last iteration cannot leak status 1 out of the function.
- install.sh:91: `grep -c ... || true` correct (prints 0, exit 1, swallowed). :95 runs under `||` context, no errexit.
- install.sh:111, 169: `paired ... || rc=$?` is errexit-safe, and rc 0/1/2 are each handled.
- install.sh:114: `strip` (awk) exits 0 even when the output is empty, so a created file that ends up empty goes `cat tmp > f` (empty) and then through cleanup_backup. No `grep -v` is involved in that path.
- install.sh:124: the `&&` is in an `if` condition, so safe.
- Trailing newline: awk always terminates the last record, so `{ strip; block; }` never glues the BEGIN marker onto an unterminated last line.
- Lockout: the block's function falls back to `command claude` when the shim is missing (:43). The shim (claude-shim:15-26) skips its own dir and any symlink to itself, and falls back to exec of the real claude on any wrap failure. Uninstall removes the shim last-ish but an already-sourced shell keeps working through the fallback. Shim install (:139) happens before any rc file is touched, so a mid-install abort never leaves a block pointing at a missing shim.
- Created-record logic: deletion needs all of: file is in `created`, backup byte-equal to file, file empty. Entry is pruned when the file is removed (:126) and kept while a block remains (:200-202). I could not construct a realistic sequence that deletes a file the user made or filled. (Remaining marginal case is item 4.)

## Findings (all LOW), ranked

### 1. install.sh:148 and :195 (and :139-141, :179): a failing step aborts midway under set -e

- Scenario: `systemctl --user show-environment` succeeds but `daemon-reload` fails (D-Bus hiccup, session ending). Install aborts at :148 before any rc block is written (nothing broken, the user just gets no hover). Uninstall aborts at :195 after the rc blocks are stripped but before the shim, hover link and `created` are removed, and "hover removed" is never printed. The leftover shim is harmless (nothing references it) and a rerun finishes. Likewise `cat "$tmp" > "$f"` at :179 / :114 on an unwritable rc file stops the loop partway and leaves `$f.nf.$$` behind (no trap).
- Fix: `systemctl --user daemon-reload || true` at both sites; in the rc loops use `cat "$tmp" > "$f" || { echo ... >&2; rm -f "$tmp"; skipped=$((skipped+1)); continue; }` (and a `trap 'rm -f "$f.nf.$$"' ...` is optional).

### 2. install.sh:120 and :114/:174: original without a trailing newline leaves the backup behind forever

- Scenario: the user's `.bashrc` last line lacks `\n`. Install writes through awk (adds the newline), so after uninstall the file is the original plus one `\n`, `cmp` with the backup fails, and uninstall prints "kept .nf-backup" on every uninstall. No data is lost; the backup is simply never auto-removed and the file gained a byte.
- Fix: optional. Compare with the trailing newline normalized, or note it in the message.

### 3. install.sh:92: two complete blocks reported as "unmatched"

- Scenario: the user pasted the block twice (b=e=2). `paired` returns 1, the message says "unmatched nerdflair marker", install skips, and uninstall cannot strip it. Safe (the function still falls back), only a misleading message.
- Fix: message text "duplicate or unmatched".

### 4. install.sh:124 plus a stale `created` entry (very marginal)

- Scenario: a nonempty created `~/.profile` stays recorded while a block elsewhere is unfixable (`still=1`). The user later empties that `.profile` themselves and retries uninstall; the file (empty, equal to the empty backup, still recorded) is removed as ours. Requires an earlier failed uninstall plus the user emptying the file; low risk and arguably correct.
- Fix: none needed; or drop the entry when the file is found nonempty at cleanup time.

## Tests (tests/install-rc.sh)

Isolated correctly: HOME is a mktemp dir, `systemctl` is stubbed, the final rm is guarded by an assert on the `nf-install-` prefix and not-a-symlink. Round-13 cases (:163-176) match the new behaviour. No case covers findings 1-3; none of them justifies a test.

## Not verified

- Nothing was executed, so all errexit conclusions come from reading plus bash semantics (ignored-failure rules for `&&`/`||`/`if`), not observation.
- zsh behaviour of the block (pattern substitution at block lines 35, function definition after `unalias`) was reasoned, not run; the test itself notes zsh is not exercised.
- nfpty.py, nf-tmux-heal and nf-tmux-watch were not read; the lockout analysis rests on claude-shim only.

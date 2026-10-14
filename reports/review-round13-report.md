# Review round 13: band/hover/install.sh and tests/install-rc.sh (HEAD 892a22f)

Method: static reading only (Read, rg). Nothing was run. All line numbers are from Read of band/hover/install.sh and tests/install-rc.sh.

Verdict: no data-loss path found in the new code. The created-list mechanics are safe where it counts: nothing the user wrote is ever deleted, because every delete requires an empty file that is cmp-equal to the backup. There are 2 real (low/medium) defects and 3 minor ones.

## Checks you asked about

- mkdir order: OK. `mkdir -p "$NF/bin"` is line 130; the first write to `$NF/created` is line 154. `$NF` always exists first.
- Created list already contains the path (earlier run): OK. The append happens only when the file is absent (line 150), so duplicates are rare and harmless: `grep -qxF` matches any copy.
- Uninstall with `$NF` gone or `created` absent: OK. `grep ... 2>/dev/null` sits in an `if` condition (line 121), so `set -e` and `pipefail` cannot trip it. The result is "not created", so the file is kept (fail-safe). Line 190 `rm -f` tolerates a missing file, and `rmdir ... || true` tolerates a missing dir.
- Guard line 19: `BASH_VERSINFO` is always set in bash, so `set -u` is fine. The `(( ))` runs inside an `||` list, so a false result does not trip `set -e`. Placement is after line 17 and before any state change (HERE/BRIDGE are only computed, nothing is written), so it exits 2 before anything is modified. Bash parses command by command, so bash 3.2 reaches the guard before parsing the `mapfile` lines. Under dash, `set -o pipefail` already aborts on old dash before anything runs.
- Legacy strip of an empty file we created that is no longer the chosen login file: see finding 1. It does delete the empty file (safe), but leaves a stale list entry.

## Findings, ranked

### 1. Medium-low: stale created entry can later delete a user's own empty file
install.sh:121 and 150-154. Scenario: install creates `~/.profile` and records it. The user then makes `~/.bash_profile`. Re-install: `.profile` becomes legacy, `remove_block` empties it, `cleanup_backup` removes it (line 121), but the entry stays in `$NF/created`. Later the user (or another tool) creates an empty `~/.profile`, and the user deletes `.bash_profile`. Install runs again: `.profile` exists, so it is not re-recorded, yet it is still listed. The block goes in, an empty backup is made, and uninstall deletes the user's own empty `.profile`. Only an empty file is lost, but it breaks the "only a file WE created" promise.
Fix: when line 121 removes a file, drop its line from `created` (`grep -vxF "$f" "$NF/created" > t; cat t > "$NF/created"`, guarded for a missing file). Alternatively, reset the list at the start of install and re-add only what this run creates.

### 2. Low: the `-x` change suppresses the CRLF warning and orphans CRLF blocks on uninstall
install.sh:107 vs 88. A marker line ending in `\r` or with trailing whitespace no longer matches `grep -qxF`, so `remove_block` returns 0 before `paired` can print its CRLF diagnostic. Before the change, `-qF` matched, `paired` returned 2, and the message printed. Now uninstall (and legacy cleanup on install) silently leaves the block, prints "hover removed", and the shim is gone while the block remains (the block degrades safely to `command claude`).
Fix: do the pre-check with the same regex `paired` uses (`grep -qE "^(${BEGIN}|${END})[[:space:]]*\r?$"`), or call `paired` first and return on rc 0 with b == 0.

### 3. Low: uninstall no longer cleans a backup when the marker is absent
install.sh:107 (previously `cleanup_backup` ran on uninstall even with no marker). If the user hand-removed the block, a stale `.nf-backup` is now never cleaned. If the file we created is now empty, it is left behind as a 0-byte file. This is fail-safe but a regression from the old behavior. Fix: on uninstall, with no BEGIN present, call `cleanup_backup` only (it is already guarded by cmp and created).

### 4. Low: `created` is deleted even when some files were skipped
install.sh:190. If `remove_block` skipped a file (unmatched marker, CRLF), uninstall still removes `$NF/created`, so a later retry can no longer tell that an empty login file was ours. Fix: keep `created` when any `remove_block` returned nonzero, or when any block remains.

### 5. Info: status uses non-exact marker match
install.sh:197 still uses `grep -qF`, so a comment mentioning the marker text reports "rc block: yes". It is inconsistent with the `-x` change. Fix: use `-qxF`.

### Upgrade note
A login file created by a version without the created list is never removed (kept as 0 bytes). This is fail-safe; mention it in the changelog.

## Tests (tests/install-rc.sh)

- New test at lines 157-161 can fail: before the fix an empty user `.profile` was deleted. It is a valid regression test. Caveat: the test relies on `created` having been removed by the earlier uninstall at line 150, so it cannot detect finding 1 (a stale entry) because no test builds one.
- Not covered: the bash 4.4 guard (no test invokes it, for example with a fake `BASH_VERSINFO`), the cmp-differs and created-present combination, the stale-entry case (finding 1), CRLF on uninstall (finding 2), and `created` absent with an install-created file. The check at line 156 ("no marker complaint") cannot fail meaningfully, because no login file exists, so the loop `continue`s and nothing could print "unmatched".
- Line 148 `check ... "$(... | grep -c unmatched)"` and the other `grep -c` checks are fine under `set -uo pipefail` (no `-e`).

## Could not verify (nothing was executed)

- Behavior on real bash 3.2 or 4.3 (guard reached before parse errors).
- zsh behavior of the block.
- Whether tests pass at HEAD.
- Any systemd-path interaction on uninstall.

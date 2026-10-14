# Review round 12: commit f2ee80c (band/hover/install.sh, tests/install-rc.sh)

Static analysis only. Nothing was run. Line numbers are from `sed -n` / `rg -n` of the working tree.

## Findings, ranked

### 1. MEDIUM - uninstall deletes a user's genuinely empty pre-existing rc file
`band/hover/install.sh:~99-104` (cleanup_backup: `[[ -s "$f" ]] || rm -f "$f"`).
A user file that was empty before install is indistinguishable from one install created: both get an empty
`.nf-backup`, both are empty after strip. Scenario: `touch ~/.zshrc` (a common way to silence zsh-newuser-install),
or an empty `~/.bash_profile`/`~/.bash_login` (its mere existence hides `~/.profile` from bash). Install, uninstall.
The file is gone: zsh's first-run wizard returns, and bash falls back to `~/.profile`. No content is lost, but
behaviour changes. A non-empty file is never removed: removal requires cmp-equal to the backup AND `-s` false, so
backup empty and file now non-empty means the backup is kept. The data-loss path for non-empty content does not exist.
Fix: record creation. At install, where `: > "$(loginfile)"` runs (~line 146), `touch "$NF/created-login"` (or
write the path into a list file). Only delete if the file is on that list. Drop the delete for `.bashrc`/`.zshrc`
(install never creates them; rcfiles lists only existing ones).

### 2. LOW - same deletion on the legacy path and on stale backups
`remove_block "$f"` at install (~line 143) also reaches cleanup_backup. An empty user-owned legacy file
(e.g. empty `.profile` while `.bash_profile` is chosen) that an old version blocked is deleted after strip.
In uninstall with no block (`install.sh:~30`) a stale empty `.nf-backup` next to an empty user file deletes the file.
Fix: same creation-record gate as finding 1; run cleanup_backup only when a block was actually removed, except to drop an equal backup (never the file).

### 3. LOW - bash 3.2 (macOS /bin/bash) breaks
`mapfile` does not exist before bash 4.0 (macOS ships 3.2), so `install`/`uninstall`/`status` die under `set -e`.
Also, under `set -u` on bash < 4.4 an empty array expansion (`"${old[@]}"`, legacy often empty) is an unbound-variable error.
README advertises macOS, but the hover installer uses systemd/tmux; I could not tell whether macOS is in scope for hover.
Fix: if macOS matters, use `while IFS= read -r f; do arr+=("$f"); done < <(legacy)` and `${old[@]+"${old[@]}"}`;
otherwise add a `(( BASH_VERSINFO[0] >= 4 )) || { echo ...; exit 1; }` guard at the top.

### 4. INFO - mapfile edge cases are fine
Trailing newline: no empty element. Empty output: empty array (fine on bash 5.2). No function emits an empty line.
A filename or HOME containing a newline splits into bogus entries: uninstall skips them via `[[ -f ]]`; install's
targets loop would run `strip`/`cp` on a nonexistent path and abort under `set -e`. Not worth fixing.

### 5. INFO - set -e interactions are safe
`grep -qF ... || { [[ -n ]] && cleanup_backup; return 0; }` (line ~30): the false `[[ -n ]]` sits in an `&&` list, and `return 0` follows.
`paired "$f" || rc=$?`, `(( rc == 0 )) || return 0` are guarded. cleanup_backup ends in an `if`, which returns 0 when its test is false.
Only an awk failure on `strip "$f" > "$tmp"` would abort and leave `$f.nf.$$` (pre-existing behaviour).

### 6. INFO - minor
- `grep -qF "$BEGIN"` matches substrings, so a comment mentioning the marker enters paired (0/0, ok) and then cleanup_backup runs on a file with no real block. Use `-x`.
- `rm -f "$f"` on a symlinked dotfile removes only the link (target stays).
- Uninstall list is computed once, before any deletion, so deleting `.profile` mid-loop cannot change which files are visited.

## Tests (tests/install-rc.sh)
- HOME is exported to a mktemp dir before anything else, and `|| exit 1` guards a failed mktemp, so real dotfiles are not touched. Cleanup uses a checked python rmtree. If a check fails midway the temp dir is kept; `fail=1` is set so it can fail.
- Gaps: nothing asserts finding 1 (user's empty pre-existing file survives), stale-backup-with-no-block, legacy-file removal, or that the spaced-HOME run removes the created `.profile`. A test for finding 1 would currently fail, which is the point.
- `blocks()` and the `grep -c unmatched` check are correct (`grep -c` exit 1 sits inside `$()`).

## Not verified
Nothing was executed (per the brief). macOS scope, bash 4.0-4.3 behaviour, and zsh behaviour with a removed `.zshrc` are from reasoning only.

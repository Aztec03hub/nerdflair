# Review round 11: band/hover/install.sh and tests/install-rc.sh (HEAD, HEAD~1)

Read-only analysis. Nothing was run (no install, tests, tmux or claude). Every behaviour below is derived from reading the code, not executed.

Verdict: no data-loss bug. The strip/pair logic, the once-only backup and the cmp-guarded removal all fail safe. There are two real defects (1, 2), one real gap (3), and several lows.

## Ranked findings

### 1. (Medium) Uninstall leaves the installer-created, now-empty ~/.profile behind
- `install.sh:120` creates it with `: >`. At `:135` the backup `.profile.nf-backup` is cp'd from that empty file. At `:148` uninstall strips the block, leaving a 0-byte file. At `:152` the cmp matches (both empty), so the backup is removed and the empty `~/.profile` stays.
- The same happens when the chosen login file changes later. A user with only `.bashrc` gets `.profile` created. They later create `~/.bash_profile` and re-run install. `legacy()` (`:72`) strips `.profile` at `:118`, leaving an empty file plus an empty `.profile.nf-backup`. A later uninstall removes only the backup.
- Impact: harmless to bash. It does leave a file the user never made, and an empty `~/.profile` can confuse tools that test "does .profile exist".
- `tests/install-rc.sh:106-117` creates exactly this state and never asserts on it.
- Fix: in the uninstall loop after `:148`, add `[[ -f "$f.nf-backup" && ! -s "$f.nf-backup" && ! -s "$f" ]] && rm -f "$f" "$f.nf-backup"`. That is the empty-backup and empty-file signature of "we created it". Do the same in the install legacy branch at `:118`. Cleaner alternative: write a `$NF/created-profile` marker at `:120` and remove the file only if it is still empty.
- Add a test: bashrc only, install, uninstall, then assert `~/.profile` is absent.

### 2. (Medium) Spaces in $HOME make install/uninstall silently do nothing, with a false "unmatched marker" error
- `install.sh:116, 121, 144, 165` iterate `$(legacy)` and `$(rcfiles)` unquoted. With `HOME="/home/a b"` the paths split into `/home/a` and `b/.bashrc`, and glob characters would expand too.
- `paired` on those words runs grep on a directory or a missing file. Both greps fail and `|| true` hides it, so `b` and `e` are empty. The `[[ "" -le 1 ]]` passes as 0, then the `== 0` test fails and the `-lt` on empty values is false. `paired` returns 1, which is the "unmatched" status.
- Result: install prints "unmatched nerdflair marker" for non-files, ends with "0 rc file(s) updated, N skipped", and still copies the shim. The user gets a shim with no PATH block and a misleading message. There is no data loss, because the strip and redirect lines are never reached.
- The tests use a space-free HOME (`mktemp`), so this is not covered.
- Fix: have `legacy`/`rcfiles` print one path per line and loop with `while IFS= read -r f; do ...; done < <(rcfiles)`, or use `mapfile -t files < <(rcfiles)` and `for f in "${files[@]}"`. Add a test with `HOME="$ROOT/ho me"`.

### 3. (Low-Medium) `paired` returns 1 for a nonexistent file, so uninstall misreports
- `install.sh:82-93` and `:143-147`. `rcfiles` always emits the login file, even when it does not exist. Scenario: the user deleted `~/.profile`, or never installed, and runs uninstall.
- grep errors go to stderr and `paired` returns 1. The user sees "uninstall: ~/.profile has an unmatched nerdflair marker; fix it by hand" plus grep "No such file" noise.
- Fix: put `[[ -f "$f" ]] || continue` at the top of the uninstall loop at `:145`. Alternatively make `paired` return 0 when `[[ ! -f $1 ]]`. Status already hides grep errors with 2>/dev/null.

### 4. (Low) Legacy files and block-free files are rewritten unconditionally
- `install.sh:118` strips and `cat`s back every legacy file that pairs. A file with no block is still rewritten. awk adds a trailing newline if the last line lacked one, and the mtime changes. This is also an unbacked-up edit of a file the user owns.
- `:148` does the same for any file uninstall visits.
- Fix: guard with `grep -qxF "$BEGIN" "$f" &&` before rewriting, or `cmp -s "$tmp" "$f" ||` as `:132` does.

### 5. (Low) Backup caveats; they are safe but worth knowing
- If uninstall keeps a differing backup (`:152`), a later install never refreshes it (`:135` is guarded by `-e`). It stays stale forever, and a later uninstall keeps it again with the same message.
- A backup left by an earlier installer version holds the old block. It is never equal to the stripped file, so it is always kept.
- Legacy strips (`:118`) make no backup.
- A file with no final newline never round-trips byte-exactly, because awk appends one. The backup is therefore kept even though nothing was lost.
- All of this fails safe. The only cost is stray `.nf-backup` files. No fix is needed beyond maybe a one-line note in the uninstall message.

### 6. (Low) Stale header comment
- `install.sh:9` still says the block goes into `~/.profile, ~/.bash_profile and ~/.bash_login (if present)`. It now goes into exactly one of them. Reword it to match `:56-58`.

### 7. (Low, tests) The suite can leak a temp dir and, in one corner, write outside the temp HOME
- `tests/install-rc.sh:13-15`. There is no `trap` and no `-e`, so a Ctrl-C or crash leaves `$ROOT` (the real HOME is never touched, because HOME is exported only inside the script).
- If `mktemp -d` fails, `ROOT` is empty and `HOME` becomes `/home`. The script would then write and `rm -f` dotfiles in `/home`.
- Fix: `ROOT=$(mktemp -d ...) || exit 1` right after the assignment, then `[[ -n $ROOT ]]`.
- The cleanup at `:148-153` is safe, since it asserts the `nf-install-` prefix and the directory type. It is skipped on early exit.
- Tests can fail: `check` sets `fail=1` and the script exits 1.
- Gaps in coverage:
  - spaces in HOME
  - the empty `.profile` after uninstall (finding 1)
  - uninstall with no login file at all (finding 3)
  - a login-file change leaves a stripped file (the `1 0 0` assert at `:117` does cover the strip itself)
  - `.bash_profile` that does not source `.bashrc`
  - zsh, which is noted as not exercised

## Questions answered

- **Ordering/word-splitting.** The order is correct: legacy is stripped, then the login file is ensured, then `rcfiles` run. The only splitting problem is finding 2. `[[ -f ]] && echo` returning 1 inside the functions is safe under `set -e`: each function ends in an unconditional echo or `return 0`, and the callers use `$(...)` in a `for` list, where -e does not apply.
- **Login file changes between installs.** The previously chosen file is in `legacy()`, since `legacy` excludes only the currently chosen file. Install strips it (`:116-119`), and the test at `:117` asserts `1 0 0`. The only residue is the empty-file case in finding 1.
- **Uninstall on every combination.** `rcfiles` plus `legacy` covers `.bashrc`, `.zshrc`, all three login files and `.zprofile` exactly once each, with no duplicates. Issues: finding 1 (empty leftover), finding 3 (nonexistent chosen login file), finding 5 (backup kept).
- **Once-only backup vs cmp.** It is consistent and non-destructive. The removal happens only when the stripped file equals the backup byte for byte, otherwise it is kept with a message.
- **`set -e`.** Every `paired` call is guarded with `|| rc=$?`. `grep -c` inside `paired` uses `|| true`. The redirect at `:131` into `$tmp` would abort the script if the directory were unwritable, which is acceptable. There is one window: if install dies after `:118` but before the new block is written, the old file is stripped and the new one has no block, so rerunning install fixes it.
- **A `.bash_profile` that does not source `.bashrc`.** This is fine, because both files carry the block. If it does source `.bashrc`, the block runs twice. The PATH dedupe and the function redefinition are idempotent.
- **Does creating `~/.profile` hide anything?** No. It is created only when none of `.bash_profile`, `.bash_login` and `.profile` exist, so there is nothing for it to hide. Side effects:
  - It is now read by every login shell, including `sh` and `dash` login shells, display managers and some systemd user environments. The block is POSIX-guarded and was tested under dash.
  - It does not source `~/.bashrc`, but the block is in `.bashrc` too.
  - The reverse hazard, a later `~/.bash_profile` hiding `.profile`, is what `status` flags (`:165-170`) and what install fixes.

## Could not verify
- Nothing was executed, so all runtime behaviour is by reading.
- ugrep/GNU grep differences on a nonexistent file or directory (the exit code and whether `-c` prints). The stated result for findings 2 and 3 assumes a nonzero exit with empty stdout.
- The zsh block, and macOS or BSD tools.
- A dangling symlink as a dotfile, and a dotfiles-managed symlinked `~/.profile`. `cat > "$f"` writes through a symlink, which is probably desirable.

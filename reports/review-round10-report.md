# Review round 10: HEAD 8498bed (round 9 fixes) over 4cad8b0

Read-only, by reading only. I did not run install.sh, tests, tmux or claude, and touched no dotfile. Line numbers are from Read of /home/plafayette/nerdflair/band/hover/install.sh (IS) and tests/install-rc.sh (T).

Verdict: all four round-9 fixes are correct as far as they go. Two follow-on defects, both caused by the fixes, and some weak tests. Ranked.

## Confirmed correct
- `rc=0; paired "$f" || rc=$?` (IS:94, IS:107): correct under `set -e`. The `||` list makes the failure non-fatal and records the status. Side effect: errexit is also off inside `paired`, harmless because every risky command in it already has `|| true` or is a tested condition, and the last line's status is the return value. rc 1 and rc 2 both skip the file (IS:96, IS:109). Messages are reachable now.
- unalias (IS:38): `2>/dev/null || true` is safe in bash and zsh when no alias exists (non-zero status is absorbed), and under `set -e` and `set -u` in the sourcing shell (no unset variable used, and `||` shields errexit). A user .bashrc with `set -e` is fine for the whole block: the only conditionals are inside `if`/`case`/`||`. It is on its own line, so bash and zsh run it before parsing `claude() {`.
- Guard (IS:30-34): when false (dash, sh), the PATH is still set, because `export PATH=...` (IS:35) is outside the guard. Only the dedupe is skipped, so repeated sourcing under sh grows PATH with duplicate shim entries, harmless since first wins. `${BASH_VERSION:-}${ZSH_VERSION:-}` is safe under `set -u`.
- rcfiles (IS:56) is used by install, uninstall and status alike, so .bash_profile and .bash_login are handled everywhere consistently.

## 1. MEDIUM: unalias silently deletes the user's alias and its flags
IS:38. Scenario: `alias claude='claude --dangerously-skip-permissions'` (very common) in .bashrc or .zshrc above the block. The unalias drops it for the session and the function calls the shim with no flags, so the user's flags vanish with no message, and stay gone after uninstall only if they re-source. Before round 9 the alias would at least beat the function, keeping the flags but bypassing the shim.
Fix: capture it first, and forward the flags. For example, before the unalias: `_nf_a=$(alias claude 2>/dev/null)`, and if non-empty, evaluate its value into the function. Simpler and honest: do not unalias; if `alias claude` exists, skip defining the function and print one line at install time naming the file (scan for `^[[:space:]]*alias[[:space:]]+claude=` in rcfiles and warn). At minimum, document it in the block comment.

## 2. MEDIUM: .zprofile blocks written by HEAD~1 are orphaned
IS:56. HEAD~1 installed a block into ~/.zprofile; round 9 removed .zprofile from rcfiles. Anyone who ran install at 4cad8b0 keeps that block forever: uninstall (IS:106) and status (IS:127) never look at it, and the block says "Remove with: install.sh uninstall". Once uninstall deletes the shim the leftover function falls back to `command claude`, so it is benign but permanent clutter, and re-running install does not clean it.
Fix: add a legacy list, for example `legacy() { [[ -f "$HOME/.zprofile" ]] && echo "$HOME/.zprofile"; }`, and iterate `rcfiles; legacy` in uninstall only (strip only, never add). Add a test that seeds a .zprofile block and checks uninstall removes it.

## 3. LOW: backup logic overwrites a previous backup and leaves stray old-block backups
IS:99. `cp -p "$f" "$f.nf-backup"` runs whenever the new content differs, even if a backup already exists. (a) A user-edited kept backup (T:73-76) is overwritten by the next install; T:80-82 does exactly this sequence (the EDITED backup is silently replaced) and nothing notices. (b) Upgrading from a block-containing install makes the "backup" a copy that still has the old block; at uninstall `cmp` (IS:114) differs, so it is kept as a stray. Fix: create the backup only if `$f.nf-backup` does not exist (it then always holds the true original); on uninstall keep the cmp rule.

## 4. LOW: install says success when a file was skipped
IS:103 prints "hover installed" and exits 0 even if every file was skipped for a broken marker. The test asserts exit 0 (T:83), so it is deliberate, but the final line is misleading. Fix: count skipped files and print "hover installed, N file(s) skipped (see above)".

## 5. LOW: empty-PATH edge
IS:32-35. If PATH is exactly the shim directory, the strip leaves PATH empty and the export yields `shim:` with a trailing empty entry (current directory). Only reachable with a one-entry PATH. Fix: `PATH="$HOME/.nerdflair/bin${PATH:+:$PATH}"`.

## 6. INFO: late-created or multiple login files
If ~/.bash_profile, ~/.bash_login and ~/.profile all exist, all three get a block but bash reads only the first. Harmless. A login file created after install gets no block until install is re-run, and status shows nothing for a missing file. A .bash_profile that does not source .bashrc depends on its own block.

## Tests (T) can they fail, and do they restore state
State: HOME is a temp dir and cleanup is a checked rmtree (T:93-99), systemctl is stubbed, so nothing real is touched. The script has no `set -e`, so an early failure still reaches cleanup. Fine.
- Broken .profile (T:81-86): can fail on the old bug (non-zero exit, no message, shim not removed). Weak spot: the broken file is third in order and .bashrc comes first, so T:85 would have passed under the old abort too. Break .bashrc, or place the broken file first, and assert .profile or .bash_profile still got the block. It also never asserts the broken .profile is left byte-identical, or the uninstall exit code.
- Alias (T:89-91): can fail (without unalias, bash gives a syntax error and `type -t` would report alias or nothing). It does not check the alias value is preserved (finding 1), and stderr is hidden.
- Nothing tests the BASH_VERSION guard: no `sh -c '. ~/.profile'` (dash) case, so deleting the guard passes. Nothing seeds .bash_profile or .bash_login, so the rcfiles change is untested. Nothing tests zsh, a `set -e` rc, or a stale .zprofile (finding 2). Nothing runs `claude` through the function or the missing-shim fallback.

## Not verified
Everything is from reading. Not reproduced: errexit behaviour, zsh unalias/definition behaviour, dash handling of the block. I did not check that zsh or dash exist here, did not confirm the `${_nf//...}` pattern in zsh (only bash is tested), and did not read claude-shim, nf-tmux-heal or nf-tmux-watch. Whether the user actually has a .zprofile block from 4cad8b0 or a claude alias is unknown.

# Review round 9: HEAD 4cad8b0 (claude() function, .profile/.zprofile blocks)

Read-only, by reading only. I did not run install.sh, the tests, tmux or claude. Line numbers are from Read of /home/plafayette/nerdflair/band/hover/install.sh (IS) and claude-shim (SH).

Verdict: the core idea is sound. The function falls back to `command claude` when the shim is missing, and the shim falls back to the real binary. Neither can loop or lock you out, and `exec claude` and `command claude` still resolve through PATH to the shim. Findings below, ranked.

## 1. HIGH (pre-existing, now more exposed): `paired` failing under `set -e` aborts the whole install/uninstall silently
IS:16 (`set -euo pipefail`), IS:89 and IS:102 (`paired "$f"; rc=$?`).
`paired` returns 1 or 2 for a missing END, an END above its BEGIN, or CRLF markers. As a plain simple command it triggers errexit before `rc=$?` runs. So the `rc == 1` message (IS:90, IS:103) is unreachable. The script exits non-zero partway.
Scenario: ~/.profile has a BEGIN with no END (the fourth file is now in the loop). Install exits after .bashrc and .zshrc with no message, never prints "hover installed", and does not process .zprofile. Uninstall exits before removing the shim and systemd unit, leaving a half-uninstalled state.
Fix: `rc=0; paired "$f" || rc=$?` at both sites. Add a test with an END-less .profile that checks the message and the exit code.

## 2. MEDIUM: an existing `alias claude=...` breaks the new function definition
IS:36.
Bash expands aliases when it parses `claude() {`, so `alias claude='claude --dangerously-skip-permissions'` earlier in the rc file gives "syntax error near unexpected token `('". zsh errors with "defining function based on alias". The rest of the sourced file is affected, since bash abandons it at the error. Even if no error occurs, an alias beats the function and silently bypasses the shim.
Fix: put `unalias claude 2>/dev/null || true` on its own line before the function (it must be a separate line, because aliases are expanded per line read). Alternatively use `function claude {` plus the unalias. Add a test with the alias in .bashrc.

## 3. MEDIUM: ~/.bash_profile or ~/.bash_login shadows ~/.profile
IS:51.
Bash login shells read only the first of .bash_profile, .bash_login, .profile. If the user has a .bash_profile (it usually sources .bashrc and then edits PATH), .profile is never read. The function defined in .bashrc still wins for bash, but the PATH half of the block does not. The comment at IS:49 and the commit claim more than they deliver there. The function carries the fix, so the effect is limited to PATH order for non-function lookups. Fix: add .bash_profile and .bash_login to `rcfiles`, or say in the comment that the function is the real fix.

## 4. LOW: bash-isms run under a POSIX sh that reads ~/.profile
IS:31.
`${_nf//.../...}` is bash/zsh only. dash (a login `sh -l`, display managers, anything that sources ~/.profile with /bin/sh) fails with "Bad substitution" and aborts the file. It only fires when the shim is already on PATH (an inherited PATH from a parent shell), since the case branch is skipped on first run. Fix: a POSIX strip, or guard the whole block with `[ -n "${BASH_VERSION:-}${ZSH_VERSION:-}" ]`. zsh syntax of the rest of the block is fine, as far as I can see by reading.

## 5. LOW: the .zprofile block does nothing useful for zsh login order
IS:49-50.
zsh login shells read .zprofile BEFORE .zshrc, so the claim that login shells run it "last, after .zshrc" is false for zsh. The .zshrc block already lands last, so .zprofile only adds another backup file and another file to keep consistent. Fix: drop .zprofile, or correct the comment. If it stays, it is a harmless duplicate.

## 6. LOW: backups and symlinked dotfiles
IS:94, IS:108-110.
- A reinstall that changes the block overwrites .nf-backup with the previous block-containing file. Uninstall then finds the backup differs and prints "kept ... .nf-backup", so there are now up to four stray backups (.profile.nf-backup and .zprofile.nf-backup are new).
- A symlinked dotfile (stow or a dotfiles repo) is written through the link (`cat > "$f"`), which is fine. But the managed repo is modified, and the backup is a regular file next to the link. A dangling symlink is skipped by `-f`. A file created after install (a new .profile) gets no block until install is rerun. `status` shows "NO" for existing files only.
Fix: write the backup only when none exists (the original), and document the symlink and late-file behaviour.

## 7. INFO: `command -v claude` and `type claude` in interactive shells now return the bare name `claude` (a function), not a path
Scripts or tools run from an interactive shell that locate the binary this way get a non-path. Non-interactive shells and subprocesses are unaffected, because functions are not exported. `exec claude`, `env claude`, `sudo claude` and `xargs claude` bypass the function and use PATH, which the block keeps shim-first.

## 8. Double run of the block
When a .profile sources .bashrc, or .bashrc sources .profile, the block runs twice per shell. It is idempotent: the PATH strip-then-prepend dedupes, the function is redefined identically, and TMUX_TMPDIR is guarded. No issue. No lockout path found: a missing shim falls to `command claude`, and an uninstall with a skipped file leaves a block whose function falls back.

## Test weaknesses (tests/install-rc.sh, diff lines)
- `type -t claude` only proves a function exists. Nothing runs `claude` through it and checks it prints REAL (no tty, so the shim should exec the real binary).
- No test of the fallback when ~/.nerdflair/bin/claude is absent.
- No test for an alias claude (finding 2), an END-less .profile (finding 1), or zsh at all (.zprofile, zsh syntax). zsh is not exercised, and I could not tell whether zsh is installed.
- No test with ~/.bash_profile present (finding 3), a symlinked .profile, CRLF in .profile, or a .profile created after install.
- Test .bashrc has no `case $- in *i*) ;; *) return;; esac` guard, unlike a stock Ubuntu .bashrc, so the non-interactive path is untested.
- The `grep -a '^NF:' | tail -1` filter with `2>/dev/null` hides shell startup errors; a syntax error in the block would show as a wrong value but not as its cause.

## Not verified
Everything above is from reading. In particular, finding 1 (errexit on `paired`), finding 2 (alias parse error) and finding 4 (dash) rest on documented shell semantics and were not reproduced. I did not check whether zsh or dash exist on the machine, and I did not read the rest of the test file or the other scripts in band/hover beyond claude-shim.

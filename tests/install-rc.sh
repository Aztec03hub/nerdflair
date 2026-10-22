#!/usr/bin/env bash
# install-rc.sh - band/hover/install.sh in a throwaway HOME: the rc block goes in,
# the PATH it writes dedupes the shim wherever it sits, status notices a stale
# copy, and uninstall puts everything back (backup and ~/.nerdflair included).
#
# Never touches the real HOME or the real user service manager: HOME is a temp
# dir and `systemctl` is a stub that reports "no user manager".
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO/band/hover/install.sh"

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nf-install-XXXXXX") || exit 1
[[ -d "$ROOT" ]] || exit 1
export HOME="$ROOT/home"
mkdir -p "$HOME" "$ROOT/stub"
printf '#!/bin/sh\nexit 1\n' > "$ROOT/stub/systemctl"
chmod +x "$ROOT/stub/systemctl"
export PATH="$ROOT/stub:$PATH"

fail=0
blocks() { if [[ -f "$1" ]]; then grep -cxF '# >>> nerdflair hover >>>' "$1" || true; else echo 0; fi; }   # 0 for a missing file
check() { if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }

printf 'export FOO=1\n' > "$HOME/.bashrc"
# The real failure: a login shell runs .profile AFTER .bashrc, and .profile prepends ~/.local/bin.
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho REAL\n' > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
printf '. "$HOME/.bashrc"\nPATH="$HOME/.local/bin:$PATH"\n' > "$HOME/.profile"
cp "$HOME/.bashrc" "$ROOT/original"
cp "$HOME/.profile" "$ROOT/original-profile"

# Control, BEFORE installing: in a login shell the PATH lookup alone finds the
# real binary. That is the bug this installer must beat.
ctl=$(env -i HOME="$HOME" PATH="/usr/bin:/bin" "$BASH" -lic 'echo "NF:$(type -P claude)"' 2>/dev/null | grep -a '^NF:' | tail -1)
check "login shell, before install: PATH lookup finds the real binary" "NF:$HOME/.local/bin/claude" "$ctl"

bash "$INSTALL" install >/dev/null 2>&1
check "install: rc block present" 1 "$(grep -cxF '# >>> nerdflair hover >>>' "$HOME/.bashrc")"
check "install: shim copied" yes "$([[ -x "$HOME/.nerdflair/bin/claude" ]] && echo yes || echo no)"
check "install: a backup of the old rc exists" yes "$([[ -f "$HOME/.bashrc.nf-backup" ]] && echo yes || echo no)"

# What the block does to PATH, whichever end the shim was already at.
runpath() { # initial PATH -> resulting PATH from sourcing the rc
  env -i HOME="$HOME" PATH="$1" "$BASH" -c '. "$HOME/.bashrc"; printf %s "$PATH"'
}
S="$HOME/.nerdflair/bin"
check "PATH: shim first, once, from nothing" "$S:/a:/b" "$(runpath /a:/b)"
check "PATH: shim already first" "$S:/a:/b" "$(runpath "$S:/a:/b")"
check "PATH: shim already last" "$S:/a:/b" "$(runpath "/a:/b:$S")"
check "PATH: shim in the middle" "$S:/a:/b" "$(runpath "/a:$S:/b")"

shellq() { env -i HOME="$HOME" PATH="/usr/bin:/bin" "$BASH" "$1" "$2" 2>/dev/null | grep -a "^NF:" | tail -1; }
check "login shell, after install: PATH lookup finds the shim too" "NF:$HOME/.nerdflair/bin/claude" "$(shellq -lic 'echo "NF:$(type -P claude)"')"
for mode in "-ic" "-lic"; do
  check "bash $mode: claude is a function (the shim's)" "NF:function" "$(shellq "$mode" 'echo "NF:$(type -t claude)"')"
done

bash "$INSTALL" install >/dev/null 2>&1
check "reinstall: still exactly one block" 1 "$(grep -cxF '# >>> nerdflair hover >>>' "$HOME/.bashrc")"

echo "# changed in the repo" >> "$HOME/.nerdflair/bin/claude"
check "status: a stale copy is named" 1 "$(bash "$INSTALL" status 2>&1 | grep -c STALE)"
bash "$INSTALL" install >/dev/null 2>&1
check "status: clean after a reinstall" 0 "$(bash "$INSTALL" status 2>&1 | grep -c STALE)"

bash "$INSTALL" uninstall >/dev/null 2>&1
check "uninstall: rc is back to the original" "$(cat "$ROOT/original")" "$(cat "$HOME/.bashrc")"
check "uninstall: .profile is back to the original" "$(cat "$ROOT/original-profile")" "$(cat "$HOME/.profile")"
check "uninstall: the backup is gone" no "$([[ -e "$HOME/.bashrc.nf-backup" ]] && echo yes || echo no)"
check "uninstall: ~/.nerdflair is gone" no "$([[ -e "$HOME/.nerdflair" ]] && echo yes || echo no)"

# A backup the user has since changed is theirs: kept, and named.
bash "$INSTALL" install >/dev/null 2>&1
echo "export EDITED=1" >> "$HOME/.bashrc.nf-backup"
out=$(bash "$INSTALL" uninstall 2>&1)
check "uninstall: a differing backup is kept" yes "$([[ -e "$HOME/.bashrc.nf-backup" ]] && echo yes || echo no)"
check "uninstall: and its path is printed" 1 "$(grep -c 'kept .*nf-backup' <<<"$out")"

# A broken block in ONE file must not stop the install or uninstall of the rest
# (it used to exit silently under set -e), and must be named.
bash "$INSTALL" uninstall >/dev/null 2>&1
printf 'export B=1\n# >>> nerdflair hover >>>\nno end marker\n' > "$HOME/.profile"
out=$(bash "$INSTALL" install 2>&1); rc=$?
check "broken .profile: install finishes, and exits non-zero because it skipped a file" 1 "$rc"
check "broken .profile: and names the file" 1 "$(grep -c 'profile has an unmatched' <<<"$out")"
check "broken .profile: the other files still got the block" 1 "$(grep -cxF '# >>> nerdflair hover >>>' "$HOME/.bashrc")"
bash "$INSTALL" uninstall >/dev/null 2>&1; check "broken .profile: uninstall finishes and removes the shim" no "$([[ -e "$HOME/.nerdflair/bin/claude" ]] && echo yes || echo no)"

# An alias of the same name must not break the function or the file.
printf 'alias claude="echo ALIAS"\n' > "$HOME/.bashrc"
bash "$INSTALL" install >/dev/null 2>&1
check "alias claude: still the function" "NF:function" "$(env -i HOME="$HOME" PATH="/usr/bin:/bin" "$BASH" -ic 'echo "NF:$(type -t claude)"' 2>/dev/null | grep -a '^NF:' | tail -1)"

# A block an earlier version put in ~/.zprofile is cleaned up by install and uninstall.
printf 'export Z=1\n' > "$HOME/.zprofile"; cp "$HOME/.zprofile" "$ROOT/zp"
{ cat "$ROOT/zp"; printf '# >>> nerdflair hover >>>\nold\n# <<< nerdflair hover <<<\n'; } > "$HOME/.zprofile"
bash "$INSTALL" install >/dev/null 2>&1
check "legacy .zprofile block removed by install" "$(cat "$ROOT/zp")" "$(cat "$HOME/.zprofile")"
# The alias warning names the file.
printf 'alias claude="claude --foo"\n' > "$HOME/.bashrc"
check "alias warning printed" 1 "$(bash "$INSTALL" install 2>&1 >/dev/null | grep -c 'defines alias claude')"
# Every file broken: say so, do not claim success silently.
rm -f "$HOME/.profile" "$HOME/.zshrc" "$HOME/.zprofile"; printf '# >>> nerdflair hover >>>\n' > "$HOME/.bashrc"
check "all skipped: the summary says so" 1 "$(bash "$INSTALL" install 2>&1 | grep -c '1 rc file(s) updated, 1 skipped')"

# ── login file selection, backups, late files, the function, dash ───────────
bash "$INSTALL" uninstall >/dev/null 2>&1
rm -f "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zprofile"
rm -f "$HOME/.bashrc.nf-backup"       # left by the earlier cases
printf 'export BR=1\n' > "$HOME/.bashrc"; cp "$HOME/.bashrc" "$ROOT/br0"
bash "$INSTALL" install >/dev/null 2>&1
check "no login file at all: ~/.profile is created with the block" 1 "$(grep -cxF '# >>> nerdflair hover >>>' "$HOME/.profile" 2>/dev/null)"
check "a login shell with no prior files now gets the function" "NF:function" "$(env -i HOME="$HOME" PATH="/usr/bin:/bin" "$BASH" -lic 'echo "NF:$(type -t claude)"' 2>/dev/null | grep -a '^NF:' | tail -1)"

# bash reads only the first of .bash_profile/.bash_login/.profile: one block, in that one.
printf 'export BP=1\n' > "$HOME/.bash_profile"; printf 'export BL=1\n' > "$HOME/.bash_login"
bash "$INSTALL" install >/dev/null 2>&1
check "three login files: only .bash_profile has the block" "1 0 0" "$(blocks "$HOME/.bash_profile") $(blocks "$HOME/.bash_login") $(blocks "$HOME/.profile")"

# The backup is the file as the user left it, and survives later installs.
bash "$INSTALL" install >/dev/null 2>&1
check "backup holds the pristine original after repeat installs" "$(cat "$ROOT/br0")" "$(cat "$HOME/.bashrc.nf-backup")"
printf '\n# my edit\n' >> "$HOME/.bashrc"
bash "$INSTALL" install >/dev/null 2>&1
check "backup is not overwritten by a later changing install" "$(cat "$ROOT/br0")" "$(cat "$HOME/.bashrc.nf-backup")"

# A login file created AFTER install is noticed by status, and fixed by install.
rm -f "$HOME/.bash_profile"; bash "$INSTALL" install >/dev/null 2>&1
printf 'export LATE=1\n' > "$HOME/.bash_profile"
check "late .bash_profile: status says to re-run install" 1 "$(bash "$INSTALL" status 2>&1 | grep -c 'rc block: NO .*bash_profile')"
bash "$INSTALL" install >/dev/null 2>&1
check "late .bash_profile: install gives it the block" 1 "$(grep -cxF '# >>> nerdflair hover >>>' "$HOME/.bash_profile")"

# Run claude THROUGH the function: with the shim present it runs the shim...
printf '#!/bin/sh\necho SHIM\n' > "$HOME/.nerdflair/bin/claude"
check "function runs the shim" "NF:SHIM" "NF:$(env -i HOME="$HOME" PATH="/usr/bin:/bin" "$BASH" -ic 'claude' 2>/dev/null | grep -a SHIM | tail -1)"
# ...and with the shim gone it falls back to the real binary instead of failing.
rm -f "$HOME/.nerdflair/bin/claude"
check "no shim: the function falls back to the real claude" "REAL" "$(env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/bin:/bin" "$BASH" -ic 'claude' 2>/dev/null | grep -a '^REAL$' | tail -1)"

# dash (a POSIX sh reading .profile) must survive the block: no syntax error.
if command -v dash >/dev/null; then
  err=$(env -i HOME="$HOME" PATH="/usr/bin:/bin" dash -c '. "$HOME/.bash_profile"' 2>&1 >/dev/null | grep -ci 'bad substitution\|syntax error')
  check "dash sourcing the login file: no bad substitution / syntax error" 0 "${err:-0}"
fi
command -v zsh >/dev/null && printf '  note: zsh present but its block is not exercised here\n'

# The ~/.profile install created empty is gone after uninstall, not left as 0 bytes.
bash "$INSTALL" uninstall >/dev/null 2>&1
rm -f "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.bashrc.nf-backup"; printf 'x=1\n' > "$HOME/.bashrc"
bash "$INSTALL" install >/dev/null 2>&1; bash "$INSTALL" uninstall >/dev/null 2>&1
check "created-empty .profile is removed by uninstall" no "$([[ -e "$HOME/.profile" ]] && echo yes || echo no)"
# Uninstall with no login file at all must not complain about a marker.
check "uninstall with no login file: no marker complaint" 0 "$(bash "$INSTALL" uninstall 2>&1 | grep -c unmatched)"

# An EMPTY file the user already had is theirs: uninstall must not delete it.
printf '' > "$HOME/.profile"
bash "$INSTALL" install >/dev/null 2>&1; bash "$INSTALL" uninstall >/dev/null 2>&1
check "a user's own empty .profile survives uninstall" yes "$([[ -e "$HOME/.profile" ]] && echo yes || echo no)"
rm -f "$HOME/.profile"

# A stale "created" entry must not let uninstall delete a file the user made later.
bash "$INSTALL" uninstall >/dev/null 2>&1; rm -f "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.bashrc.nf-backup"
printf 'x=1\n' > "$HOME/.bashrc"
bash "$INSTALL" install >/dev/null 2>&1                       # creates .profile, records it
printf 'export A=1\n' > "$HOME/.bash_profile"                  # login file changes: the empty .profile is stripped and forgotten
bash "$INSTALL" install >/dev/null 2>&1
check "stale entry: forgotten once the file is gone" 0 "$(grep -cxF "$HOME/.profile" "$HOME/.nerdflair/created" || true)"
rm -f "$HOME/.bash_profile"; printf '' > "$HOME/.profile"       # the user makes their own empty .profile
bash "$INSTALL" uninstall >/dev/null 2>&1
check "stale entry: the user's later empty .profile survives" yes "$([[ -e "$HOME/.profile" ]] && echo yes || echo no)"
rm -f "$HOME/.profile"
# CRLF marker: uninstall says so instead of reporting success silently.
printf '# >>> nerdflair hover >>>\r\nx\r\n# <<< nerdflair hover <<<\r\n' > "$HOME/.bashrc"
check "CRLF marker on uninstall is named" 1 "$(bash "$INSTALL" uninstall 2>&1 | grep -c CRLF)"

# A $HOME with a space in it: install and uninstall still work.
SP="$ROOT/my home"; mkdir -p "$SP"; printf 'y=1\n' > "$SP/.bashrc"
HOME="$SP" bash "$INSTALL" install >/dev/null 2>&1
check "spaced HOME: block installed in .bashrc and the login file" 2 "$(cat "$SP/.bashrc" "$SP/.profile" | grep -cxF '# >>> nerdflair hover >>>')"
HOME="$SP" bash "$INSTALL" uninstall >/dev/null 2>&1
check "spaced HOME: uninstall restores .bashrc" "y=1" "$(cat "$SP/.bashrc")"

# ── no silent failures: the exit status and the message say what happened ────
# A systemctl stub with a working user manager whose enable/disable can be made to fail.
mkdir -p "$ROOT/stub2"
cat > "$ROOT/stub2/systemctl" <<'SH'
#!/bin/sh
case "$*" in
  *show-environment*) exit 0 ;;
  *enable*)  [ -n "${SC_FAIL_ENABLE:-}" ]  && { echo "Failed to enable unit: boom" >&2; exit 1; }; exit 0 ;;
  *disable*) [ -n "${SC_FAIL_DISABLE:-}" ] && { echo "Failed to disable unit: bang" >&2; exit 1; }; exit 0 ;;
  *is-active*) echo active; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$ROOT/stub2/systemctl"
HOME="$ROOT/h2"; export HOME; mkdir -p "$HOME"; printf 'z=1\n' > "$HOME/.bashrc"
OLDPATH=$PATH; PATH="$ROOT/stub2:$PATH"

out=$(SC_FAIL_ENABLE=1 bash "$INSTALL" install 2>&1); rc=$?
check "systemctl enable fails: install exits non-zero" 1 "$rc"
check "systemctl enable fails: the reason is printed" 1 "$(grep -c 'watcher not started: Failed to enable unit: boom' <<<"$out")"
check "systemctl enable fails: it is in launcher.log too" 1 "$(grep -c 'install: .*boom' "$HOME/.local/state/nerdflair/launcher.log")"
check "systemctl enable fails: the rc block was still installed" 1 "$(grep -cxF '# >>> nerdflair hover >>>' "$HOME/.bashrc")"
bash "$INSTALL" uninstall >/dev/null 2>&1

out=$(bash "$INSTALL" install 2>&1); rc=$?
check "systemctl ok: install exits 0 and says the watcher runs" "0 1" "$rc $(grep -c 'watcher running' <<<"$out")"
out=$(SC_FAIL_DISABLE=1 bash "$INSTALL" uninstall 2>&1); rc=$?
check "systemctl disable fails: uninstall exits non-zero" 1 "$rc"
check "systemctl disable fails: the reason is printed" 1 "$(grep -c 'could not stop nf-tmux-watch.service: Failed to disable unit: bang' <<<"$out")"

PATH="$ROOT/stub:$OLDPATH"
out=$(bash "$INSTALL" install 2>&1); rc=$?
check "no systemd user manager: install says the watcher was skipped, exit 0" "0 1" "$rc $(grep -c 'watcher: skipped (no systemd' <<<"$out")"
bash "$INSTALL" uninstall >/dev/null 2>&1

# No rc file can be updated (the only one has a broken marker): not a success.
rm -f "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bashrc.nf-backup"
printf '# >>> nerdflair hover >>>\nno end\n' > "$HOME/.profile"
out=$(bash "$INSTALL" install 2>&1); rc=$?
check "no rc file updated: install exits non-zero" 1 "$rc"
check "no rc file updated: says hover is NOT active" 1 "$(grep -c 'hover is NOT active' <<<"$out")"
rm -f "$HOME/.profile"; bash "$INSTALL" uninstall >/dev/null 2>&1

# An unreadable rc file is named, not treated as "no marker".
if [[ $(id -u) != 0 ]]; then
  printf 'k=1\n' > "$HOME/.bashrc"; printf 'p=1\n' > "$HOME/.profile"
  bash "$INSTALL" install >/dev/null 2>&1
  chmod 000 "$HOME/.bashrc"
  out=$(bash "$INSTALL" uninstall 2>&1); rc=$?
  check "unreadable rc on uninstall: named, exit non-zero" "1 1" "$(grep -c 'bashrc is not readable' <<<"$out") $rc"
  chmod 644 "$HOME/.bashrc"; bash "$INSTALL" uninstall >/dev/null 2>&1
fi

# The function falls back to plain claude when the shim is gone, and now says so.
printf 'q=1\n' > "$HOME/.bashrc"; bash "$INSTALL" install >/dev/null 2>&1
rm -f "$HOME/.nerdflair/bin/claude"
mkdir -p "$HOME/.local/bin"; printf '#!/bin/sh\necho REAL\n' > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
fb=$(env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/bin:/bin" "$BASH" -ic 'claude' 2>&1 >/dev/null)
check "shim missing: the function says it is running plain claude" 1 "$(grep -c 'shim missing, running plain claude' <<<"$fb")"
check "status: a missing installed copy is named MISSING" 1 "$(bash "$INSTALL" status 2>&1 | grep -c 'MISSING')"
check "status: says where tmux's socket will live" 1 "$(env -u XDG_RUNTIME_DIR bash "$INSTALL" status 2>&1 | grep -c 'tmux socket dir: /tmp (UNPROTECTED')"
bash "$INSTALL" uninstall >/dev/null 2>&1
HOME="$ROOT/home"

# A watcher unit that was never installed is already disabled: uninstall must not fail on it
# (nerdflair.sh runs the hover uninstall under set -e).
cat > "$ROOT/stub/systemctl" <<'STUB'
#!/bin/sh
case "$*" in
  *show-environment*) exit 0 ;;
  *disable*) echo "Failed to disable unit: Unit file nf-tmux-watch.service does not exist." >&2; exit 1 ;;
  *) exit 0 ;;
esac
STUB
printf 'x=1\n' > "$HOME/.bashrc"; rm -f "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login"
bash "$INSTALL" install >/dev/null 2>&1 || true
out=$(bash "$INSTALL" uninstall 2>&1); rc=$?
check "uninstall: a never-installed watcher unit is not a failure (exit 0)" 0 "$rc"
check "uninstall: and it prints no warning for it" 0 "$(grep -c 'could not stop' <<<"$out")"
# enable --now never restarts a running service: install restarts it only when it was running and the installed watcher or
# unit changed. The stub answers is-active from $SC_ACTIVE, so "was it running" is under the test's control.
export SC_LOG="$ROOT/systemctl.log" SC_ACTIVE="$ROOT/unit-active"
printf '#!/bin/sh\ncase "$*" in *is-active*) [ -f "$SC_ACTIVE" ]; exit $? ;; esac\necho "$*" >> "$SC_LOG"\nexit 0\n' > "$ROOT/stub/systemctl"
restarts() { grep -c 'try-restart nf-tmux-watch' "$SC_LOG" 2>/dev/null || true; }
: > "$SC_LOG"; rm -f "$SC_ACTIVE"; bash "$INSTALL" uninstall >/dev/null 2>&1; : > "$SC_LOG"
bash "$INSTALL" install >/dev/null 2>&1
check "install: new files, unit was not running (enable --now started it): no restart" 0 "$(restarts)"
: > "$SC_ACTIVE"
W="$HOME/.nerdflair/bin/nf-tmux-watch"; U="$HOME/.config/systemd/user/nf-tmux-watch.service"
touch -d @1000000000 "$W" "$U"
bash "$INSTALL" install >/dev/null 2>&1
check "reinstall: nothing changed, no restart" 0 "$(restarts)"
check "reinstall: nothing changed, the watcher's mtime is untouched (doctor compares it with the service start)" 1000000000 "$(stat -c %Y "$W")"
check "reinstall: nothing changed, the unit's mtime is untouched" 1000000000 "$(stat -c %Y "$U")"
echo '# edited' >> "$W"; bash "$INSTALL" install >/dev/null 2>&1
check "reinstall: installed watcher differed, running unit restarted" 1 "$(restarts)"
check "reinstall: ...and the watcher is back to the source" 0 "$(cmp -s "$W" "$REPO/band/hover/nf-tmux-watch"; echo $?)"
echo '# edited' >> "$U"; bash "$INSTALL" install >/dev/null 2>&1
check "reinstall: installed unit differed, running unit restarted" 2 "$(restarts)"
rm -f "$SC_ACTIVE"; echo '# edited' >> "$W"; bash "$INSTALL" install >/dev/null 2>&1
check "reinstall: changed watcher but the unit was not running: no restart" 2 "$(restarts)"
bash "$INSTALL" uninstall >/dev/null 2>&1
printf '#!/bin/sh\nexit 1\n' > "$ROOT/stub/systemctl"

# Remove only what mktemp made, checked first: no glob, no guess.
python3 - "$ROOT" <<'PY'
import os, shutil, sys
d = sys.argv[1]
assert os.path.isdir(d) and not os.path.islink(d) and os.path.basename(d).startswith("nf-install-"), d
shutil.rmtree(d)
PY
printf '\n'
(( fail )) && { echo "install-rc: FAIL"; exit 1; }
echo "install-rc: PASS"

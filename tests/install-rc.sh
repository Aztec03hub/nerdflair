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

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nf-install-XXXXXX")
export HOME="$ROOT/home"
mkdir -p "$HOME" "$ROOT/stub"
printf '#!/bin/sh\nexit 1\n' > "$ROOT/stub/systemctl"
chmod +x "$ROOT/stub/systemctl"
export PATH="$ROOT/stub:$PATH"

fail=0
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
check "broken .profile: install still finishes" 0 "$rc"
check "broken .profile: and names the file" 1 "$(grep -c 'profile has an unmatched' <<<"$out")"
check "broken .profile: the other files still got the block" 1 "$(grep -cxF '# >>> nerdflair hover >>>' "$HOME/.bashrc")"
bash "$INSTALL" uninstall >/dev/null 2>&1; check "broken .profile: uninstall finishes and removes the shim" no "$([[ -e "$HOME/.nerdflair/bin/claude" ]] && echo yes || echo no)"

# An alias of the same name must not break the function or the file.
printf 'alias claude="echo ALIAS"\n' > "$HOME/.bashrc"
bash "$INSTALL" install >/dev/null 2>&1
check "alias claude: still the function" "NF:function" "$(env -i HOME="$HOME" PATH="/usr/bin:/bin" "$BASH" -ic 'echo "NF:$(type -t claude)"' 2>/dev/null | grep -a '^NF:' | tail -1)"

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

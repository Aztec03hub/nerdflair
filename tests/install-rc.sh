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
cp "$HOME/.bashrc" "$ROOT/original"

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

bash "$INSTALL" install >/dev/null 2>&1
check "reinstall: still exactly one block" 1 "$(grep -cxF '# >>> nerdflair hover >>>' "$HOME/.bashrc")"

echo "# changed in the repo" >> "$HOME/.nerdflair/bin/claude"
check "status: a stale copy is named" 1 "$(bash "$INSTALL" status 2>&1 | grep -c STALE)"
bash "$INSTALL" install >/dev/null 2>&1
check "status: clean after a reinstall" 0 "$(bash "$INSTALL" status 2>&1 | grep -c STALE)"

bash "$INSTALL" uninstall >/dev/null 2>&1
check "uninstall: rc is back to the original" "$(cat "$ROOT/original")" "$(cat "$HOME/.bashrc")"
check "uninstall: the backup is gone" no "$([[ -e "$HOME/.bashrc.nf-backup" ]] && echo yes || echo no)"
check "uninstall: ~/.nerdflair is gone" no "$([[ -e "$HOME/.nerdflair" ]] && echo yes || echo no)"

# A backup the user has since changed is theirs: kept, and named.
bash "$INSTALL" install >/dev/null 2>&1
echo "export EDITED=1" >> "$HOME/.bashrc.nf-backup"
out=$(bash "$INSTALL" uninstall 2>&1)
check "uninstall: a differing backup is kept" yes "$([[ -e "$HOME/.bashrc.nf-backup" ]] && echo yes || echo no)"
check "uninstall: and its path is printed" 1 "$(grep -c 'kept .*nf-backup' <<<"$out")"

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

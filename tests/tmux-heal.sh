#!/usr/bin/env bash
# tmux-heal.sh - nf-tmux-heal must bring back a tmux server whose socket
# directory was deleted, and must leave a healthy one alone.
#
# Runs against a SCRATCH tmux server in its own TMUX_TMPDIR, never the real
# one, so a bug here cannot touch a live session. The first version of the
# script matched the wrong process name ("tmux: server" has a space) and was a
# silent no-op for a day, which is why this exists: the check is the positive
# control, a socket that really is gone and really comes back.
set -uo pipefail

HEAL="${NF_TMUX_HEAL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/band/hover/nf-tmux-heal}"
[[ -x "$HEAL" ]] || { echo "tmux-heal: missing $HEAL" >&2; exit 2; }
command -v tmux >/dev/null && command -v ss >/dev/null || { echo "tmux-heal: needs tmux and ss" >&2; exit 77; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nf-heal-XXXXXX")
export TMUX_TMPDIR="$ROOT"
unset TMUX
fail=0
check() { if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }

# SIGUSR1 makes the server recreate its socket asynchronously, so "reachable
# after heal" is polled (up to 5 s) rather than read once; a single read raced.
reach() { local i; for i in $(seq 1 50); do "$@" ls >/dev/null 2>&1 && { echo 0; return; }; sleep 0.1; done; echo 1; }
tmux new-session -d -s heal-test 'sleep 120'
sock="$ROOT/tmux-$(id -u)/default"
check "scratch server is reachable" 0 "$(tmux ls >/dev/null 2>&1; echo $?)"

"$HEAL" 2>/dev/null
check "healthy server: heal is a no-op, still reachable" 0 "$(tmux ls >/dev/null 2>&1; echo $?)"

mv "$ROOT/tmux-$(id -u)" "$ROOT/removed"
check "socket directory gone: server unreachable" 1 "$(tmux ls >/dev/null 2>&1; echo $?)"

"$HEAL" 2>/dev/null
check "after heal: reachable again" 0 "$(reach tmux)"
check "after heal: socket exists" yes "$([[ -S "$sock" ]] && echo yes || echo no)"
check "after heal: the session survived" heal-test "$(tmux list-sessions -F '#{session_name}' 2>/dev/null | head -1)"

# A symlink planted where the socket directory belongs must be left alone, not
# followed: heal may only act on a private directory of ours.
mv "$ROOT/tmux-$(id -u)" "$ROOT/removed2"
mkdir "$ROOT/elsewhere"
ln -s "$ROOT/elsewhere" "$ROOT/tmux-$(id -u)"
"$HEAL" 2>/dev/null
check "a planted symlink is not followed or healed" 1 "$(tmux ls >/dev/null 2>&1; echo $?)"
check "nothing was created behind the symlink" 0 "$(find "$ROOT/elsewhere" -mindepth 1 | wc -l)"
rm "$ROOT/tmux-$(id -u)"
mv "$ROOT/removed2" "$ROOT/tmux-$(id -u)"
"$HEAL" 2>/dev/null

# kill-server needs a reachable socket, so a failed run would leave the
# scratch server behind; take it down by the pid the kernel reports for it.
stop_under() { # dir: kill the tmux servers whose socket lives under it
  local p
  for p in $(ss -xlnp 2>/dev/null | grep -F "$1" | grep -o 'pid=[0-9]*' | cut -d= -f2); do
    [[ "$(cat "/proc/$p/comm" 2>/dev/null)" == "tmux: server" ]] && kill "$p"
  done
}

# Two servers, only one with its socket gone. Heal must signal ONLY that one:
# SIGUSR1 makes a server recreate its socket, so a signalled healthy server
# shows a new socket inode. The healthy one must keep pid, inode and session.
ROOT2=$(mktemp -d "${TMPDIR:-/tmp}/nf-heal2-XXXXXX")
TMUX_TMPDIR="$ROOT2" tmux new-session -d -s healthy 'sleep 120'
sock2="$ROOT2/tmux-$(id -u)/default"
pid2=$(TMUX_TMPDIR="$ROOT2" tmux display -p -t healthy '#{pid}')
ino2=$(stat -c %i "$sock2")
mv "$ROOT/tmux-$(id -u)" "$ROOT/removed3"
"$HEAL" 2>/dev/null
check "two servers: the broken one is healed" 0 "$(reach tmux)"
check "two servers: the healthy one kept its socket inode (never signalled)" "$ino2" "$(stat -c %i "$sock2")"
check "two servers: the healthy one kept its pid and session" "$pid2 healthy" "$(TMUX_TMPDIR="$ROOT2" tmux list-sessions -F '#{pid} #{session_name}' 2>/dev/null | head -1)"

# A socket path with a space in it must be found and healed too.
ROOT3=$(mktemp -d "${TMPDIR:-/tmp}/nf heal3-XXXXXX")
TMUX_TMPDIR="$ROOT3" tmux new-session -d -s spaced 'sleep 120'
mv "$ROOT3/tmux-$(id -u)" "$ROOT3/removed"
check "spaced path: server unreachable" 1 "$(TMUX_TMPDIR="$ROOT3" tmux ls >/dev/null 2>&1; echo $?)"
"$HEAL" 2>/dev/null
check "spaced path: healed" 0 "$(TMUX_TMPDIR="$ROOT3" reach tmux)"

tmux kill-server 2>/dev/null
stop_under "$ROOT"; stop_under "$ROOT2"; stop_under "$ROOT3"
sleep 0.3
# Remove only the three directories mktemp made, each checked to be a real
# directory (not a symlink) with the expected prefix: no glob, no guesswork.
python3 - "$ROOT" "$ROOT2" "$ROOT3" <<'PY'
import os, shutil, sys, tempfile
for d in sys.argv[1:]:
    assert os.path.isdir(d) and not os.path.islink(d), d
    assert os.path.basename(d).startswith(("nf-heal-", "nf-heal2-", "nf heal3-")), d
    assert os.path.dirname(d) == os.path.realpath(os.environ.get("TMPDIR") or "/tmp") or os.path.dirname(d) == (os.environ.get("TMPDIR") or "/tmp"), d
    shutil.rmtree(d)
PY
printf '\n'
(( fail )) && { echo "tmux-heal: FAIL"; exit 1; }
echo "tmux-heal: PASS"

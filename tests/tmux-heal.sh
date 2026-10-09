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

HEAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/band/hover/nf-tmux-heal"
[[ -x "$HEAL" ]] || { echo "tmux-heal: missing $HEAL" >&2; exit 2; }
command -v tmux >/dev/null && command -v ss >/dev/null || { echo "tmux-heal: needs tmux and ss" >&2; exit 77; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nf-heal-XXXXXX")
export TMUX_TMPDIR="$ROOT"
unset TMUX
fail=0
check() { if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }

tmux new-session -d -s heal-test 'sleep 120'
sock="$ROOT/tmux-$(id -u)/default"
check "scratch server is reachable" 0 "$(tmux ls >/dev/null 2>&1; echo $?)"

"$HEAL" 2>/dev/null
check "healthy server: heal is a no-op, still reachable" 0 "$(tmux ls >/dev/null 2>&1; echo $?)"

mv "$ROOT/tmux-$(id -u)" "$ROOT/removed"
check "socket directory gone: server unreachable" 1 "$(tmux ls >/dev/null 2>&1; echo $?)"

"$HEAL" 2>/dev/null
check "after heal: reachable again" 0 "$(tmux ls >/dev/null 2>&1; echo $?)"
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
tmux kill-server 2>/dev/null
for p in $(ss -xlnp 2>/dev/null | grep -F "$ROOT" | grep -o 'pid=[0-9]*' | cut -d= -f2); do
  [[ "$(cat "/proc/$p/comm" 2>/dev/null)" == "tmux: server" ]] && kill "$p"
done
printf '\n'
(( fail )) && { echo "tmux-heal: FAIL"; exit 1; }
echo "tmux-heal: PASS"

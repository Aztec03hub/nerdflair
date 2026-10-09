#!/usr/bin/env bash
# tmux-watch.sh - nf-tmux-watch must notice a socket directory vanishing, name
# the processes that were running, and bring the socket back, within seconds.
#
# Runs against a SCRATCH tmux server in its own TMUX_TMPDIR with its own log,
# so it cannot touch a real session. The watcher is also pointed at the
# repository's nf-tmux-heal. Positive control: the same sequence with the
# watcher NOT running must leave the server unreachable.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$REPO/band/hover/nf-tmux-watch"
command -v tmux >/dev/null && command -v ss >/dev/null || { echo "tmux-watch: needs tmux and ss" >&2; exit 77; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nf-watch-XXXXXX")
export TMUX_TMPDIR="$ROOT" NF_TMUX_WATCH_LOG="$ROOT/log" NF_TMUX_HEAL="$REPO/band/hover/nf-tmux-heal" NF_TMUX_WATCH_RESCAN=1
unset TMUX
fail=0
check() { if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }
reachable() { tmux ls >/dev/null 2>&1; echo $?; }
uid=$(id -u)

stop_scratch() {
  for p in $(ss -xlnp 2>/dev/null | grep -F "$ROOT" | grep -o 'pid=[0-9]*' | cut -d= -f2); do
    [[ "$(cat "/proc/$p/comm" 2>/dev/null)" == "tmux: server" ]] && kill "$p"
  done
}

# ── positive control: no watcher, the socket stays gone ──────────────────────
tmux new-session -d -s ctl 'sleep 120'
mv "$ROOT/tmux-$uid" "$ROOT/gone1"
sleep 2
check "control, no watcher: server stays unreachable" 1 "$(reachable)"
"$REPO/band/hover/nf-tmux-heal" 2>/dev/null          # put it back so we can reuse the root
stop_scratch
sleep 0.5

# ── the watcher ──────────────────────────────────────────────────────────────
tmux new-session -d -s watched 'sleep 120'
check "scratch server is reachable" 0 "$(reachable)"
python3 "$WATCH" &
wpid=$!
sleep 2.5
mv "$ROOT/tmux-$uid" "$ROOT/gone2"
for _ in $(seq 1 40); do
  [[ "$(reachable)" == 0 ]] && break
  sleep 0.25
done
check "with the watcher: reachable again within 10 s" 0 "$(reachable)"
check "the session survived" watched "$(tmux list-sessions -F '#{session_name}' 2>/dev/null | head -1)"
check "the log says what was deleted" yes "$(grep -q "DELETED:.*tmux-$uid" "$ROOT/log" && echo yes || echo no)"
check "the log lists running processes" yes "$(grep -q 'pid=' "$ROOT/log" && echo yes || echo no)"
check "the log records the heal" yes "$(grep -q 'healed rc=0' "$ROOT/log" && echo yes || echo no)"

# Names that merely START with the socket directory's name are not it: another
# user could otherwise create and delete one in a loop and make the service
# log and heal for ever.
before=$(grep -c 'DELETED:' "$ROOT/log")
mkdir "$ROOT/tmux-$uid-decoy" && rmdir "$ROOT/tmux-$uid-decoy"
sleep 1.5
check "a decoy named tmux-UID-x is ignored" "$before" "$(grep -c 'DELETED:' "$ROOT/log")"

kill "$wpid" 2>/dev/null
stop_scratch
printf '\n'
if (( fail )); then echo "tmux-watch: FAIL"; exit 1; fi
echo "tmux-watch: PASS"

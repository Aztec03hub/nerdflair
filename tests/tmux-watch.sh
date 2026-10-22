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

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nf-watch-XXXXXX") || exit 1
export TMUX_TMPDIR="$ROOT" NF_TMUX_WATCH_LOG="$ROOT/log" NF_TMUX_HEAL="$REPO/band/hover/nf-tmux-heal" NF_TMUX_WATCH_RESCAN=1
unset TMUX
export NF_STATE_DIR="$ROOT/state"   # heal/watch failure logs go here, never the real ~/.local/state
fail=0
cleanup() {   # every exit path: kill our scratch server and watcher, remove ONLY the dir mktemp made
  trap - EXIT
  [[ -n "${wpid:-}" ]] && kill "$wpid" 2>/dev/null
  stop_scratch
  sleep 0.3
  if [[ -d "$ROOT" && ! -L "$ROOT" && "$ROOT" == "${TMPDIR:-/tmp}"/nf-watch-* ]]; then rm -rf -- "$ROOT"; fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
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
# The socket is reachable the moment heal signals the server; the watcher writes its "healed" line a
# beat later (a race that made this check flaky, also before the log sanitizing): wait for the line.
for _ in $(seq 1 40); do grep -q 'healed rc=0' "$ROOT/log" && break; sleep 0.25; done
check "the log records the heal" yes "$(grep -q 'healed rc=0' "$ROOT/log" && echo yes || echo no)"

# Names that merely START with the socket directory's name are not it: another
# user could otherwise create and delete one in a loop and make the service
# log and heal for ever.
before=$(grep -c 'DELETED:' "$ROOT/log")
mkdir "$ROOT/tmux-$uid-decoy" && rmdir "$ROOT/tmux-$uid-decoy"
# Events are handled in order: delete the real directory once more and wait (bounded) for its log line.
# If the decoy had logged, it would have done so before that line, so the count would be before+2.
[[ -d "$ROOT/tmux-$uid" ]] || sleep 0.5
mv "$ROOT/tmux-$uid" "$ROOT/gone3"
deadline=$((SECONDS + 15))
until (( $(grep -c 'DELETED:' "$ROOT/log") > before )) || (( SECONDS >= deadline )); do sleep 0.1; done
check "a decoy named tmux-UID-x is ignored (exactly one new DELETED line)" "$((before + 1))" "$(grep -c 'DELETED:' "$ROOT/log")"

kill "$wpid" 2>/dev/null
stop_scratch

# ── no terminal control reaches tmux-watch.log or the launcher.log copy (argument lists are attacker-influenced) ──
python3 -I - "$WATCH" "$ROOT" <<'PY'
import importlib.machinery, importlib.util, os, sys
watch, root = sys.argv[1], sys.argv[2]
os.environ["NF_TMUX_WATCH_LOG"] = os.path.join(root, "ctl-watch.log")
os.environ["NF_STATE_DIR"] = os.path.join(root, "ctl-state")
loader = importlib.machinery.SourceFileLoader("nfw", watch)
spec = importlib.util.spec_from_loader("nfw", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
m.LAUNCHER_LOG = os.path.join(root, "ctl-launcher.log")
m.log("ps: evil \x1b]0;pwn\x07\x1b[2J \u009b[2J \r\nforged")
m.transition("ctl", "arg \x1b[2J \u009b[2J \x9d")
bad = []
for n in ("ctl-watch.log", "ctl-launcher.log"):
    raw = open(os.path.join(root, n), "rb").read()
    for c in (b"\x1b", b"\xc2\x9b", b"\xc2\x9d", b"\r", b"\x07"):
        if c in raw: bad.append((n, c))
    if n == "ctl-watch.log" and raw.count(b"\n") != 2: bad.append((n, "extra newline"))
try:    # a lone surrogate (os.fsdecode of a non-UTF-8 path) must neither raise nor lose the line
    m._append(os.path.join(root, "sur.log"), "pid 1 path /tmp/\udcff/x")
    sur = b"path /tmp/" in open(os.path.join(root, "sur.log"), "rb").read()
except Exception as e:
    sur = False
    bad.append(("surrogate", repr(e)))
if not sur: bad.append(("surrogate", "line lost"))
open(os.path.join(root, "ctl-result"), "w").write("yes" if not bad else f"no {bad}")
PY
check "watch logs: ESC, C1, CR, BEL never reach tmux-watch.log or launcher.log" yes "$(cat "$ROOT/ctl-result" 2>/dev/null)"
printf '\n'
if (( fail )); then echo "tmux-watch: FAIL"; exit 1; fi
echo "tmux-watch: PASS"

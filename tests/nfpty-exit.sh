#!/usr/bin/env bash
# nfpty-exit.sh - how nfpty ends must match how the child ended.
#
#  1. A child that exits while a descendant keeps the pty open (an MCP server
#     outliving claude is the real case) must not leave nfpty hanging, and its
#     exit code must come through.
#  2. A child killed by a signal exits 128+signal, not a wrapped negative.
#
# Both would hang or lie before the review of 2026-10-09 (findings H2, M11).
# Needs no tmux and no terminal. stdin is an OPEN pipe, as a terminal is: with
# stdin at EOF nfpty correctly treats it as a hangup and takes the child down.
set -uo pipefail

NFPTY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/band/bridge/nfpty.py"
fail=0
check() { if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }

run() { # script -> prints "<exit code> <seconds>"
  python3 - "$NFPTY" "$1" <<'PY'
import os, subprocess, sys, time
t = time.time()
p = subprocess.Popen([sys.executable, sys.argv[1], "-c", sys.argv[2]], stdin=subprocess.PIPE,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     env=dict(os.environ, CLAUDE_BIN="/bin/bash"))
try:
    rc = p.wait(timeout=10)
except subprocess.TimeoutExpired:
    p.kill()
    rc = 124
print(rc, int(time.time() - t))
PY
}

# setsid: a plain background job is killed by the hangup when its session
# leader exits; a daemon that detached itself is not, and keeps the pty open.
read -r rc secs < <(run 'setsid sleep 8 < /dev/tty > /dev/tty 2>&1 & sleep 0.3; exit 7')
check "descendant holds the pty: exit code 7 comes through" 7 "$rc"
if (( secs < 6 )); then r=prompt; else r=slow; fi
check "descendant holds the pty: nfpty does not wait for it" prompt "$r"
read -r rc _ < <(run 'kill -TERM $$'); check "child killed by SIGTERM exits 143" 143 "$rc"
read -r rc _ < <(run 'exit 0'); check "plain exit 0" 0 "$rc"

# The child's last words must survive its exit (finding M1 of round 2).
out=$(python3 - "$NFPTY" <<'PY'
import os, subprocess, sys, threading
# The race is a window of microseconds, so one run proves little: every one of
# 60 runs must keep the output.
lost = 0
for _ in range(60):
    p = subprocess.Popen([sys.executable, sys.argv[1], "-c", "printf LASTWORDS; exit 0"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         env=dict(os.environ, CLAUDE_BIN="/bin/bash"))
    timer = threading.Timer(10, p.kill)
    timer.start()
    # Read stdout directly: communicate() would close stdin, which nfpty
    # rightly takes for a terminal hangup.
    data = p.stdout.read()
    p.wait()
    timer.cancel()
    lost += b"LASTWORDS" not in data
print("yes" if lost == 0 else f"lost {lost} of 60")
PY
)
check "output written just before exit is not lost" yes "$out"

# SIGTERM to nfpty is forwarded, and a child that ignores it is killed.
read -r rc secs < <(python3 - "$NFPTY" <<'PY'
import os, signal, subprocess, sys, time
p = subprocess.Popen([sys.executable, sys.argv[1], "-c", "trap '' TERM; echo ready; sleep 6"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env=dict(os.environ, CLAUDE_BIN="/bin/bash"))
# Signal only once the child has installed its trap: under load a signal sent
# earlier kills bash normally and the test would blame the SIGKILL path.
line = p.stdout.readline()
while b"ready" not in line:
    if not line:                       # EOF: nfpty or the child died first
        p.kill()
        print(1, 99)                   # fails both checks instead of hanging
        sys.exit(0)
    line = p.stdout.readline()
t = time.time()
p.send_signal(signal.SIGTERM)
try:
    rc = p.wait(timeout=8)
except subprocess.TimeoutExpired:
    p.kill(); rc = 124
print(rc, int(time.time() - t))
PY
)
# The child is `sleep 6` and the harness waits 8 s, so exiting at all proves
# nothing: it must be the SIGKILL escalation (137) and within about 4 s.
check "ignored SIGTERM: the child is killed (137)" 137 "$rc"
if (( secs <= 4 )); then r=quick; else r=slow; fi
check "ignored SIGTERM: within about 2 s of the signal" quick "$r"

printf '\n'
if (( fail )); then echo "nfpty-exit: FAIL"; exit 1; fi
echo "nfpty-exit: PASS"

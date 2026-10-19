#!/usr/bin/env bash
# shellcheck disable=SC2086
# launcher-logging.sh - no silent failures in the shell/launcher layer.
#
# The rule: a fallback is fine, but every absorbed failure is logged (or
# visibly surfaced), once, with the reason. Each case below breaks ONE thing
# in a throwaway HOME, with stubs on PATH, and asserts three things: the
# fallback still happens (claude still starts; heal does not crash), the reason
# is in launcher.log, and it is there ONCE (a second start is rate limited).
#
# Never touches the real HOME, state dir, tmux servers or systemd: HOME and
# NF_STATE_DIR are temp, ss/systemctl/claude are stubs, and the only process
# this starts that it kills is the python watcher, by its exact pid.
# (install/uninstall cases live in install-rc.sh, which owns the rc fixtures.)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOVER_SRC="$REPO/band/hover"

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nf-launcher-XXXXXX") || exit 1
[[ -d "$ROOT" ]] || exit 1
chmod 755 "$ROOT"
export HOME="$ROOT/home" NF_STATE_DIR="$ROOT/state"
LOG="$NF_STATE_DIR/launcher.log"
mkdir -p "$HOME" "$ROOT/real" "$ROOT/stub"
unset TMUX NFPTY NERDFLAIR_HOVER

fail=0
check() { if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }
count() { # pattern: lines of the launcher log matching it
  if [[ -f "$LOG" ]]; then grep -c -- "$1" "$LOG" || true; else echo 0; fi
}
resetlog() { rm -f "$LOG" "$NF_STATE_DIR"/.launcher-stamp-*; }

# A PATH holding symlinks to just the named tools, so "python3 missing" or "ss
# missing" is true for real, not simulated.
mkbin() { # dir tool...
  local d=$1 t p; shift; mkdir -p "$d"
  for t in "$@"; do p=$(command -v "$t") && ln -sf "$p" "$d/$t"; done
}
# shellcheck disable=SC2086  # TOOLS is a word list on purpose
TOOLS="bash env id sed cat stat kill mkdir cksum cut find date mv rm dirname readlink tr head tail sleep ps grep awk"
mkbin "$ROOT/bin-nopy" $TOOLS
mkbin "$ROOT/bin-noss" $TOOLS python3
mkbin "$ROOT/bin-full" $TOOLS python3

printf '#!/bin/sh\necho "REAL-CLAUDE $*"\n' > "$ROOT/real/claude"; chmod +x "$ROOT/real/claude"

# A fake ~/.nerdflair as install.sh would lay it out, with a stubbed heal so the
# shim tests never signal a real tmux server.
NFB="$HOME/.nerdflair/bin"
mkdir -p "$NFB"
cp "$HOVER_SRC/claude-shim" "$NFB/claude"; cp "$HOVER_SRC/nf-log.sh" "$NFB/nf-log.sh"
printf '#!/bin/sh\nexit 0\n' > "$NFB/nf-tmux-heal"; chmod +x "$NFB/claude" "$NFB/nf-tmux-heal"

# Run the shim on a pty (it only wraps when stdin, stdout and stderr are ttys).
run_tty() { # PATH -> output of one `claude` start
  python3 - "$1" "$NFB/claude" <<'PY'
import os, pty, sys
path, shim = sys.argv[1], sys.argv[2]
env = dict(os.environ, PATH=path, TMUX="/nonexistent/sock,1,0", TERM="xterm")
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("bash", ["bash", shim, "--flag"], env)
out = b""
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
_, st = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
sys.stdout.write("EXIT=%d\n" % (os.WEXITSTATUS(st) if os.WIFEXITED(st) else 255))
PY
}

shim_case() { # label, log pattern, PATH
  resetlog
  local o1 o2
  o1=$(run_tty "$3"); o2=$(run_tty "$3")
  check "$1: plain claude still starts (twice)" "2" "$(grep -c 'REAL-CLAUDE --flag' <<<"$o1
$o2")"
  check "$1: the reason is logged" 1 "$(count "$2")"
  check "$1: the second start did not log it again (rate limited)" 1 "$(count "$2")"
}

echo "shim"
# H2: python3 missing
rm -rf "$HOME/.nerdflair/hover"; mkdir -p "$ROOT/hover-ok"
printf '' > "$ROOT/hover-ok/mklayout.py"; printf '' > "$ROOT/hover-ok/panel.py"; printf 'pass\n' > "$ROOT/hover-ok/nfpty.py"
ln -sfn "$ROOT/hover-ok" "$HOME/.nerdflair/hover"
shim_case "python3 missing" "shim: python3 not on PATH" "$NFB:$ROOT/real:$ROOT/bin-nopy"

# H2: dangling hover link
rm -f "$HOME/.nerdflair/hover"; ln -sfn "$ROOT/gone" "$HOME/.nerdflair/hover"
shim_case "hover link dangling" "shim: nfpty.py not found" "$NFB:$ROOT/real:$ROOT/bin-full"

# H1: an import in the wrapper is broken
mkdir -p "$ROOT/hover-badimport"
printf '' > "$ROOT/hover-badimport/mklayout.py"; printf '' > "$ROOT/hover-badimport/panel.py"
printf 'raise ImportError("boom import")\n' > "$ROOT/hover-badimport/nfpty.py"
ln -sfn "$ROOT/hover-badimport" "$HOME/.nerdflair/hover"
shim_case "nfpty import broken" "shim: hover import check failed (ImportError: boom import)" "$NFB:$ROOT/real:$ROOT/bin-full"

# H7: imports fine, nfpty dies at START (before it forks claude)
mkdir -p "$ROOT/hover-badstart"
printf '' > "$ROOT/hover-badstart/mklayout.py"; printf '' > "$ROOT/hover-badstart/panel.py"
printf 'if __name__ == "__main__":\n    raise RuntimeError("startup boom")\n' > "$ROOT/hover-badstart/nfpty.py"
ln -sfn "$ROOT/hover-badstart" "$HOME/.nerdflair/hover"
shim_case "nfpty fails at start" "shim: hover failed to start (RuntimeError: startup boom)" "$NFB:$ROOT/real:$ROOT/bin-full"

# A failing logger must never stop claude: unwritable state dir.
resetlog; chmod 555 "$ROOT"; : > /dev/null
NF_STATE_DIR="$ROOT/state-unwritable/x" bash -c '. "$1"; nf_log shim "reason"; echo "rc=$?"' _ "$NFB/nf-log.sh" | grep -q 'rc=0' && r=0 || r=1
chmod 755 "$ROOT"
check "nf_log never fails even if the state dir cannot be created" 0 "$r"

echo "heal"
HEAL="$HOVER_SRC/nf-tmux-heal"
cp "$HOVER_SRC/nf-log.sh" "$ROOT/stub/nf-log.sh"
healrun() { # PATH-dir -> prints "<rc>|<stderr>"
  local err rc
  err=$(env -i HOME="$HOME" NF_STATE_DIR="$NF_STATE_DIR" PATH="$1" bash "$HEAL" 2>&1 >/dev/null); rc=$?
  printf '%s|%s' "$rc" "$err"
}
uid=$(id -u)

resetlog
r=$(healrun "$ROOT/bin-noss")
check "ss missing: heal exits 3 (not a silent 0)" 3 "${r%%|*}"
check "ss missing: says why on stderr" 1 "$(grep -c 'ss not found' <<<"${r#*|}")"
healrun "$ROOT/bin-noss" >/dev/null
check "ss missing: logged, once across two runs" 1 "$(count 'heal: ss not found')"

# ss output whose format drifted: our socket path is there but the columns are not
cat > "$ROOT/stub/ss" <<SH
#!/bin/sh
echo "State Recv-Q"
echo "garbage-without-columns /tmp/tmux-$uid/default"
SH
chmod +x "$ROOT/stub/ss"; mkbin "$ROOT/bin-stubss" $TOOLS; ln -sf "$ROOT/stub/ss" "$ROOT/bin-stubss/ss"
resetlog
r=$(healrun "$ROOT/bin-stubss")
check "ss format drift: heal exits 3" 3 "${r%%|*}"
check "ss format drift: the unparsed line is named" 1 "$(grep -c 'cannot parse ss line' <<<"${r#*|}")"
check "ss format drift: logged" 1 "$(count 'heal: cannot parse ss line')"

# ss itself failing
printf '#!/bin/sh\necho "ss: boom" >&2\nexit 1\n' > "$ROOT/stub/ss"
resetlog; r=$(healrun "$ROOT/bin-stubss")
check "ss fails: heal exits 3 with the reason" "3 1" "${r%%|*} $(grep -c 'ss -xlnp failed rc=1: ss: boom' <<<"${r#*|}")"

# A missing socket that heal cannot act on (the listener is not a tmux server):
# no success line, exit 3, reason logged.
sleep 30 & SLP=$!
cat > "$ROOT/stub/ss" <<SH
#!/bin/sh
echo "u_str LISTEN 0 10 $ROOT/tmux-$uid/default 111 * 0 users:((\"sleep\",pid=$SLP,fd=3))"
SH
resetlog; r=$(healrun "$ROOT/bin-stubss")
kill "$SLP" 2>/dev/null; wait "$SLP" 2>/dev/null
check "cannot recover: heal exits 3" 3 "${r%%|*}"
check "cannot recover: no 'socket recreated' success claimed" 0 "$(grep -c 'socket recreated' <<<"${r#*|}")"
check "cannot recover: the reason is logged" 1 "$(count "not 'tmux: server'")"
check "cannot recover: and no success is in the log" 0 "$(count 'SIGUSR1')"

echo "watcher"
WATCH="$HOVER_SRC/nf-tmux-watch"
mkdir -p "$ROOT/tmux-$uid"
cat > "$ROOT/stub/ss-ok" <<SH
#!/bin/sh
echo "u_str LISTEN 0 10 $ROOT/tmux-$uid/default 111 * 0 users:((\"tmux: server\",pid=1,fd=3))"
SH
chmod +x "$ROOT/stub/ss-ok"
WL="$ROOT/watch.log"

start_watcher() { # ss-stub-file [extra env...] -> sets WPID; PATH has that ss first
  local ssfile=$1; shift
  rm -f "$ROOT/wbin/ss"; mkdir -p "$ROOT/wbin"; ln -sf "$ssfile" "$ROOT/wbin/ss"
  : > "$WL"; resetlog
  env "$@" PATH="$ROOT/wbin:$ROOT/bin-full" NF_TMUX_WATCH_LOG="$WL" NF_TMUX_WATCH_RESCAN=1 \
    NF_TMUX_HEAL="$ROOT/stub/heal-stub" python3 "$WATCH" >/dev/null 2>"$ROOT/watch.err" &
  WPID=$!
}
stop_watcher() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
waitfor() { # file pattern seconds: block until the pattern appears (bounded)
  local i; for ((i = 0; i < $3 * 10; i++)); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1
}

# inotify_add_watch failing (test hook NF_TEST_INOTIFY_FAIL=1: every add fails with ENOSPC)
start_watcher "$ROOT/stub/ss-ok" NF_TEST_INOTIFY_FAIL=1
waitfor "$LOG" 'inotify_add_watch failed' 8; found=$?
sleep 3     # several 1 s rescans must not repeat the line
check "inotify_add_watch fails: reported in launcher.log" 0 "$found"
check "inotify_add_watch fails: with the errno text" 1 "$([[ $(count 'No space left on device') -ge 1 ]] && echo 1 || echo 0)"
check "inotify_add_watch fails: once per directory, not per rescan" 2 "$(count 'inotify_add_watch failed')"
stop_watcher

# ss failing
printf '#!/bin/sh\necho "ss: boom" >&2\nexit 1\n' > "$ROOT/stub/ss-bad"; chmod +x "$ROOT/stub/ss-bad"
start_watcher "$ROOT/stub/ss-bad"
waitfor "$LOG" 'ss: ss exited 1: ss: boom' 8; found=$?
sleep 3
check "ss fails: reported in launcher.log" 0 "$found"
check "ss fails: once, not every rescan" 1 "$(count 'ss exited 1')"
stop_watcher

# A heal that cannot recover the socket must NOT be logged as a success.
printf '#!/bin/sh\necho "nf-tmux-heal: cannot do it" >&2\nexit 3\n' > "$ROOT/stub/heal-stub"; chmod +x "$ROOT/stub/heal-stub"
start_watcher "$ROOT/stub/ss-ok"
waitfor "$WL" 'watching' 8
: > "$ROOT/tmux-$uid/default"; sleep 0.3; rm -f "$ROOT/tmux-$uid/default"     # a real IN_DELETE of the socket name
waitfor "$WL" 'NOT HEALED' 10; found=$?
check "heal cannot recover: the watcher logs NOT HEALED" 0 "$found"
check "heal cannot recover: with the reason from heal" 1 "$(grep -c 'NOT HEALED rc=3.*cannot do it' "$WL")"
check "heal cannot recover: and never logs 'healed rc='" 0 "$(grep -c 'healed rc=' "$WL" || true)"
stop_watcher

# heal binary missing: reported, watcher keeps running
rm -f "$ROOT/stub/heal-stub"
start_watcher "$ROOT/stub/ss-ok"
waitfor "$WL" 'watching' 8
: > "$ROOT/tmux-$uid/default"; sleep 0.3; rm -f "$ROOT/tmux-$uid/default"
waitfor "$WL" 'could not run' 10; found=$?
alive=$(kill -0 "$WPID" 2>/dev/null && echo 1 || echo 0)
check "heal missing: reported" 0 "$found"
check "heal missing: the watcher is still running" 1 "$alive"
stop_watcher

# ── no terminal control ever reaches launcher.log (reasons carry paths and python errors) ──
resetlog
( . "$HOVER_SRC/nf-log.sh"; NF_LOG_NOSTAMP=1
  nf_log hostile $'path \x1b]0;pwn\x07\x1b[2J \xc2\x9b[2J \xff\x9b \r\nforged: line ' ; nf_log utf8 '日本 “x” Д' )
_raw=$(LC_ALL=C cat "$LOG" 2>/dev/null)
check "launcher.log: ESC, BEL, CR, U+009B and a raw 0x9b never reach the file" yes \
  "$( ( LC_ALL=C; [[ "$_raw" != *$'\x1b'* && "$_raw" != *$'\x07'* && "$_raw" != *$'\r'* && "$_raw" != *$'\x9b'* ]] ) && echo yes || echo no)"
check "launcher.log: a newline in a reason cannot forge a second line" 2 "$(wc -l < "$LOG" | tr -d ' ')"
check "launcher.log: valid UTF-8 (CJK, smart quotes, Cyrillic) is kept byte for byte" yes \
  "$( ( LC_ALL=C; [[ "$_raw" == *'日本 “x” Д'* ]] ) && echo yes || echo no)"

# Remove only what mktemp made, checked first: no glob, no guess.
python3 - "$ROOT" <<'PY'
import os, shutil, sys
d = sys.argv[1]
assert os.path.isdir(d) and not os.path.islink(d) and os.path.basename(d).startswith("nf-launcher-"), d
shutil.rmtree(d)
PY
printf '\n'
(( fail )) && { echo "launcher-logging: FAIL"; exit 1; }
echo "launcher-logging: PASS"

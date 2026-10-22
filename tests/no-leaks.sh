#!/usr/bin/env bash
# no-leaks.sh - the tmux e2e scripts must leave nothing behind: no nf-* temp dir, no tmux socket, no live server.
#
# Runs logcheck.py, cells-table.py and one short hover-highlight scenario (resized, about 5 s) with TMPDIR and TMUX_TMPDIR pointed at
# ONE scratch dir, so "what is left" is exactly what those runs created (the shared /tmp has other sessions'
# files in it). Afterwards that dir must hold no nf-* entry and no socket. Whatever a leaky script left is killed
# (by socket path) and removed before this script exits, so a FAIL does not itself leak.
# Never touches the ambient tmux: TMUX is unset and every run has its own TMUX_TMPDIR.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$HERE/band/bridge"
D=$(mktemp -d "${TMPDIR:-/tmp}/nf-noleaks-XXXXXX") || exit 1
fail=0

cleanup() {   # only the dir mktemp made; live servers found under it are killed by their exact socket path first
  trap - EXIT
  if [[ -d "$D" && ! -L "$D" && "$D" == */nf-noleaks-* ]]; then
    find "$D" -type s -print0 2>/dev/null | while IFS= read -r -d '' s; do tmux -S "$s" kill-server 2>/dev/null; done
    sleep 0.3
    rm -rf -- "$D"
    rm -f -- "$D.out"
  fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

run() {   # label, command...: run with a private TMPDIR/TMUX_TMPDIR, no ambient tmux, 15 s cap
  local label="$1"; shift
  local R; R=$(mktemp -d "$D/run-XXXXXX") || exit 1    # a fresh scratch per run, so a leak is blamed on one script
  if env -u TMUX TMPDIR="$R" TMUX_TMPDIR="$R" nice -n 19 ionice -c3 timeout 15 "$@" >"$D.out" 2>&1; then
    printf '  PASS  %s ran\n' "$label"
  else
    printf '  FAIL  %s exited non-zero (%s)\n' "$label" "$?"; tail -5 "$D.out" | sed 's/^/      /'; fail=1
  fi
  local left
  left=$(find "$R" -mindepth 1 \( -name 'nf-*' -o -name 'nf heal*' -o -type s \) 2>/dev/null | sed "s|^$R/||" | head -5 | tr '\n' ' ')
  if [[ -z "$left" ]]; then printf '  PASS  %s left no nf-* dir and no tmux socket\n' "$label"
  else printf '  FAIL  %s LEAKED: %s\n' "$label" "$left"; fail=1
    find "$R" -type s -print0 2>/dev/null | while IFS= read -r -d '' s; do tmux -S "$s" kill-server 2>/dev/null; done
  fi
}

command -v tmux >/dev/null || { echo "no-leaks: needs tmux" >&2; exit 77; }
run logcheck.py python3 "$B/logcheck.py"
run cells-table.py python3 "$B/cells-table.py"
run "hover-highlight-e2e resized" python3 "$B/hover-highlight-e2e.py" resized
run tmux-heal.sh bash "$HERE/tests/tmux-heal.sh"
if (( fail )); then echo "no-leaks: FAIL"; exit 1; fi
echo "no-leaks: PASS"

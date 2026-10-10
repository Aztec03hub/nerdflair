#!/usr/bin/env bash
# bridge-selfchecks.sh - the in-file selfchecks of the hover bridge, in one
# runnable place. They are the only tests of the stream transforms, the
# boundary tracking, the queue trim and the panel geometry, and until now no
# script ran them.
set -uo pipefail
B="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/band/bridge"
fail=0
run() {
  if out=$("$@" 2>&1); then
    printf '  PASS  %s\n' "$(tail -1 <<<"$out")"
  else
    printf '  FAIL  %s\n%s\n' "$*" "$out"
    fail=1
  fi
}
run python3 "$B/nfpty.py" --nfpty-selfcheck
run python3 "$B/panel.py"
run python3 "$B/mklayout.py" --selfcheck
run python3 "$B/mklayout.py" --cards-check
printf '\n'
if (( fail )); then echo "bridge-selfchecks: FAIL"; exit 1; fi
echo "bridge-selfchecks: PASS"

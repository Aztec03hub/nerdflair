#!/usr/bin/env bash
# full.sh - the slow checks in tests/heavy.list, one after another, with no per-check time limit.
# Goes through the machine-wide 3-slot gate (lantern's `heavy`) when it exists, plain otherwise.
# The hover-e2e scripts are skipped unless you pass --e2e (they use the ambient tmux).
# Exit 1 on any failure. Usage: tests/full.sh [--e2e]
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/.." || exit 2
e2e=0; [[ "${1:-}" == --e2e ]] && e2e=1
gate=(/home/plafayette/claude_projects/lantern/tools/heavy)
[[ -x ${gate[0]} ]] || gate=()
bad=0
while IFS= read -r line; do
  cmd="${line%%   #*}"
  [[ -z "${cmd//[[:space:]]/}" || "$cmd" == \#* ]] && continue
  if [[ $cmd == *e2e.py* ]] && (( ! e2e )); then printf 'SKIP  %s (pass --e2e)\n' "$cmd"; continue; fi
  start=$EPOCHREALTIME
  # shellcheck disable=SC2086
  "${gate[@]}" $cmd; rc=$?
  secs=$(awk -v a="$start" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.1f", b-a}')
  if (( rc == 0 )); then printf 'PASS  %s (%ss)\n' "$cmd" "$secs"
  elif (( rc == 77 )); then printf 'SKIP  %s (%ss)\n' "$cmd" "$secs"
  else printf 'FAIL  %s rc=%s (%ss)\n' "$cmd" "$rc" "$secs"; bad=1; fi
done < "$here/heavy.list"
if (( bad )); then echo "full: FAIL"; exit 1; fi
echo "full: PASS"

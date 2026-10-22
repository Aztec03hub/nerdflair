#!/usr/bin/env bash
# Run difftest N times (default 20) and print the UNSTABLE / mismatch count of each run.
# usage: difftest-repeat.sh [N] [difftest args...]   exit 1 if any run was not clean.
N=${1:-20}; shift || true
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bad=0
for ((i = 1; i <= N; i++)); do
  out=$("$here/difftest.sh" "$@" 2>&1); rc=$?
  uns=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | rg -o 'UNSTABLE[^:]*: (.*)' -r '$1' | head -1)
  fails=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | rg -c '^╔═ FAIL')
  printf 'run %02d rc=%s mismatch=%s unstable=[%s]\n' "$i" "$rc" "${fails:-0}" "$uns"
  [[ $rc -ne 0 || -n "$uns" ]] && bad=$((bad + 1))
done
printf 'runs not clean: %d/%d\n' "$bad" "$N"
exit $((bad > 0))

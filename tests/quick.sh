#!/usr/bin/env bash
# quick.sh - every check that finishes under 15 s, one after another, with a table.
# Each line of tests/quick.list runs from the repo root at nice 19 / ionice idle under `timeout 15`,
# with a temp HOME and NERDFLAIR_CACHE_DIR and no TMUX. Exit 1 on any FAIL or TIMEOUT (exit 77 = SKIP).
# Usage: tests/quick.sh [list-file]
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/.." || exit 2
list="${1:-$here/quick.list}"
real_home="$HOME"
# One fresh temp dir per check: a shared HOME / cache let one check's leftovers fail the next (transcript-tail).
R=$(mktemp -d) || exit 2
trap 'rm -rf "$R"' EXIT
printf '%-52s %-8s %s\n' CHECK RESULT SECONDS
bad=0; n=0
while IFS= read -r line; do
  cmd="${line%%   #*}"
  [[ -z "${cmd//[[:space:]]/}" || "$cmd" == \#* ]] && continue
  T="$R/$((++n))"; mkdir -p "$T"
  start=$EPOCHREALTIME
  # word splitting of $cmd is intended: one plain command per line
  # shellcheck disable=SC2086
  env -u TMUX HOME="$T" NERDFLAIR_CACHE_DIR="$T/cache" \
    RUSTUP_HOME="${RUSTUP_HOME:-$real_home/.rustup}" CARGO_HOME="${CARGO_HOME:-$real_home/.cargo}" \
    timeout 15 nice -n 19 ionice -c3 $cmd >"$T/out" 2>&1
  rc=$?
  secs=$(awk -v a="$start" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.1f", b-a}')
  case $rc in
    0) r=PASS ;;
    77) r=SKIP ;;
    124) r=TIMEOUT; bad=1 ;;
    *) r=FAIL; bad=1 ;;
  esac
  printf '%-52s %-8s %s\n' "${cmd:0:52}" "$r" "$secs"
  if [[ $r == FAIL || $r == TIMEOUT ]]; then tail -n 8 "$T/out" | sed 's/^/    | /'; fi
done < "$list"
if (( bad )); then echo "quick: FAIL"; exit 1; fi
echo "quick: PASS"

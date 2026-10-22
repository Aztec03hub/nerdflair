#!/usr/bin/env bash
# full.sh - the slow checks in tests/heavy.list, one after another, with no per-check time limit.
# Goes through the machine-wide 3-slot gate (lantern's `heavy`) when it exists, plain otherwise.
# Each check gets a fresh temp HOME (with a git identity) and no TMUX, like quick.sh.
# Every *e2e.py script is excluded outright: they need Phil's ambient tmux, so run them by hand.
# --e2e is accepted but changes nothing. Exit 1 on any failure. Usage: tests/full.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/.." || exit 2
real_home="$HOME"
R=$(mktemp -d) || exit 2
trap 'rm -rf "$R"' EXIT
n=0
gate=(/home/plafayette/claude_projects/lantern/tools/heavy)
[[ -x ${gate[0]} ]] || gate=()
bad=0
while IFS= read -r line; do
  cmd="${line%%   #*}"
  [[ -z "${cmd//[[:space:]]/}" || "$cmd" == \#* ]] && continue
  if [[ $cmd == *e2e.py* ]]; then printf 'SKIP  %s (needs the ambient tmux; never run by full.sh)\n' "$cmd"; continue; fi
  T="$R/$((++n))"; mkdir -p "$T"; printf '[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n' > "$T/.gitconfig"
  start=$EPOCHREALTIME
  # shellcheck disable=SC2086
  env -u TMUX HOME="$T" NERDFLAIR_CACHE_DIR="$T/cache" \
    RUSTUP_HOME="${RUSTUP_HOME:-$real_home/.rustup}" CARGO_HOME="${CARGO_HOME:-$real_home/.cargo}" \
    "${gate[@]}" $cmd; rc=$?
  secs=$(awk -v a="$start" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.1f", b-a}')
  if (( rc == 0 )); then printf 'PASS  %s (%ss)\n' "$cmd" "$secs"
  elif (( rc == 77 )); then printf 'SKIP  %s (%ss)\n' "$cmd" "$secs"
  else printf 'FAIL  %s rc=%s (%ss)\n' "$cmd" "$rc" "$secs"; bad=1; fi
done < "$here/heavy.list"
if (( bad )); then echo "full: FAIL"; exit 1; fi
echo "full: PASS"

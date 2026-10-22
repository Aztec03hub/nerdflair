#!/usr/bin/env bash
# quick.sh - every check that finishes under 15 s, one after another, with a table.
# Each line of tests/quick.list runs from the repo root at nice 19 / ionice idle under `timeout 15`,
# with a temp HOME and NERDFLAIR_CACHE_DIR and no TMUX. Exit 1 on any FAIL or TIMEOUT (exit 77 = SKIP).
# Before the checks: (1) every test file in tests/ must be in quick.list or heavy.list (names that are not tests are
# in NOT_TESTS below), (2) `cargo build --release` and `cargo test --release --no-run` run, outside the per-check timeout, through $NF_HEAVY (or `heavy`
# on PATH) when there is one; a failed build is exit 2, so no check runs against a stale binary.
# Usage: tests/quick.sh [list-file]   (NF_HEAVY_LIST=<file> overrides heavy.list for the coverage check)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/.." || exit 2
list="${1:-$here/quick.list}"
real_home="$HOME"
# explicit exclusion list: files in tests/ that are runners, helpers or lists, not tests
NOT_TESTS=(quick.sh full.sh real-home-guard.sh gen-payloads.sh quick.list heavy.list)
# Coverage check only for the default list (a custom list is a subset by design). Only the command part of each
# list line counts (what the runners run: comments and "   #" tails are cut), and only `bash|python3 tests/<name>`.
if [[ $list == "$here/quick.list" ]]; then
  listed=$(cat "$list" "${NF_HEAVY_LIST:-$here/heavy.list}" | sed -e 's/^[[:space:]]*#.*//' -e 's/   #.*//' \
    | rg -o '(bash|python3) tests/[A-Za-z0-9_.-]+' | sed 's|.* tests/||' | sort -u)
  missing=0
  for f in "$here"/*; do
    [[ -f $f ]] || continue
    b=$(basename "$f")
    [[ " ${NOT_TESTS[*]} " == *" $b "* ]] && continue
    rg -qx -F -- "$b" <<<"$listed" || { echo "quick: $b is in neither quick.list nor heavy.list (add it, or add it to NOT_TESTS in quick.sh)"; missing=1; }
  done
  (( missing )) && exit 1
fi
HEAVY="${NF_HEAVY:-$(command -v heavy || true)}"
[[ -z $HEAVY || -x $HEAVY ]] || { echo "quick: NF_HEAVY is not executable: $HEAVY"; exit 2; }
# One fresh temp dir per check: a shared HOME / cache let one check's leftovers fail the next (transcript-tail).
# The build log lives in it too: a fixed /tmp name could be a planted symlink.
R=$(mktemp -d) || exit 2
trap 'rm -rf "$R"' EXIT
# shellcheck disable=SC2086
# the test profile is built too, so quick.list's `cargo test --release` doesn't compile under its 15 s cap
for sub in "build --release" "test --release --no-run"; do
  ${HEAVY:+$HEAVY} cargo $sub --manifest-path rust/Cargo.toml >/dev/null 2>"$R/build.log" \
    || { echo "quick: cargo $sub FAILED"; tail -n 20 "$R/build.log"; exit 2; }
done
printf '%-52s %-8s %s\n' CHECK RESULT SECONDS
bad=0; n=0
while IFS= read -r line; do
  cmd="${line%%   #*}"
  [[ -z "${cmd//[[:space:]]/}" || "$cmd" == \#* ]] && continue
  T="$R/$((++n))"; mkdir -p "$T"
  start=$EPOCHREALTIME
  # word splitting of $cmd is intended: one plain command per line
  # shellcheck disable=SC2086
  env -u TMUX NF_REAL_HOME="$real_home" HOME="$T" NERDFLAIR_CACHE_DIR="$T/cache" \
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

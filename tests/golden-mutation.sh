#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# golden-mutation.sh — prove that burn-block-golden.sh can FAIL.
#
# A passing test suite is worth nothing on its own: a suite that cannot fail
# passes for the same reason a broken one does. The adversarial review of
# 2026-10-08 made this its keystone objection, and it was right. Four of the
# golden cases had already "passed" by finding nothing at all (a cost of 0 in
# the payload suppressed the entire right-hand group under test).
#
# So: take the bash reference, break ONE rule in it, and require the golden
# suite to fail. A mutation the suite still passes is a rule nothing checks,
# which is reported as a GAP rather than quietly tolerated.
#
# The bash reference is the mutation target because it is the readable one and
# is held byte-identical to the Rust build by tests/difftest.sh. A rule broken
# in bash and caught here is a rule the goldens would catch in either.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="$ROOT/scripts/statusline.sh"
GOLDEN="$ROOT/tests/burn-block-golden.sh"
[[ -r "$REF" && -x "$GOLDEN" ]] || { printf 'mutation: missing %s or %s\n' "$REF" "$GOLDEN" >&2; exit 2; }

RUN=$(mktemp -d "${TMPDIR:-/tmp}/nerdflair-mutation-XXXXXX")
trap 'rm -rf "$RUN"' EXIT

# Each mutation is a python replacement against the reference text: a NAME, the
# exact source fragment to replace, and what to replace it with. Exact
# fragments, never regexes: a mutation that silently fails to apply would make
# this script report a pass as a kill, which is the failure mode it exists to
# prevent. A fragment that no longer matches is a hard error below.
run_mutation() { # $1=name $2=find $3=replace $4=what-rule-it-breaks
  local name=$1 find=$2 repl=$3 rule=$4
  local mut="$RUN/$name.sh"
  FIND="$find" REPL="$repl" python3 -I - "$REF" "$mut" <<'PY' || return 2
import os, sys
src = open(sys.argv[1]).read()
find, repl = os.environ["FIND"], os.environ["REPL"]
n = src.count(find)
if n != 1:
    sys.stderr.write(f"  fragment matched {n} times, expected exactly 1\n")
    sys.exit(3)
open(sys.argv[2], "w").write(src.replace(find, repl))
PY
  chmod +x "$mut"
  local out rc
  out=$(NERDFLAIR_GOLDEN_IMPL="$mut" NERDFLAIR_GOLDEN_LABEL="$name" "$GOLDEN" 2>&1)
  rc=$?
  if (( rc != 0 )); then
    printf '  KILLED  %-22s %s\n' "$name" "$rule"
    return 0
  fi
  printf '  SURVIVED %-21s %s\n' "$name" "$rule"
  printf '%s\n' "$out" | sed 's/^/           | /'
  return 1
}

printf 'golden-mutation: breaking one rule at a time, each must make the goldens fail\n\n'
gaps=0
errs=0

# 1. Count a FALLING cumulative cost as negative spend, i.e. the old
#    last-minus-first behaviour. Case 1 (session D falls) and case 5 (a
#    mid-window reset) both exist to catch exactly this.
run_mutation monotonic \
  'if (v > pv[s]) gain[s] += v - pv[s]' \
  'gain[s] += v - pv[s]' \
  'counter falls must not subtract'
case $? in 1) ((gaps++));; 2|3) ((errs++));; esac

# 2. Accept a row that goes backwards in time within one session. Case 8.
run_mutation ordering \
  'if (t < lt[s]) next' \
  'if (0) next' \
  'backwards row must be skipped'
case $? in 1) ((gaps++));; 2|3) ((errs++));; esac

# 3. Total a billing window that has already lapsed. Case 6.
run_mutation lapsed_block \
  'if (( EPOCHSECONDS >= rl_5h_reset )); then' \
  'if (( 0 )); then' \
  'lapsed resets_at must not total two blocks'
case $? in 1) ((gaps++));; 2|3) ((errs++));; esac

# 4. Divide by a span too short to mean anything. Case 2.
run_mutation min_span \
  '_bspan >= _bmin' \
  '_bspan >= 0' \
  'a rate needs a minimum span'
case $? in 1) ((gaps++));; 2|3) ((errs++));; esac

printf '\n'
if (( errs )); then
  printf 'golden-mutation: ERROR, %d mutation(s) could not be applied.\n' "$errs"
  printf '  The source fragment moved or changed. Fix the fragment, do not delete\n'
  printf '  the mutation: an unapplied mutation reports a pass as a kill.\n'
  exit 2
fi
if (( gaps )); then
  printf 'golden-mutation: %d SURVIVOR(S). The goldens do not check those rules.\n' "$gaps"
  exit 1
fi
printf 'golden-mutation: PASS, every mutation was killed.\n'

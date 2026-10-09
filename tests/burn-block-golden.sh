#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# burn-block-golden.sh — prove the burn-rate and billing-block ARITHMETIC
# against hand-computed answers, with no second estimate involved.
#
# tests/validate-burn-block.sh cross-checks us against ccusage, but agreement
# between two estimates is corroboration, not proof: both could be wrong the
# same way, and the tolerance there is wide enough to hide a real defect. This
# file is the other half. It feeds a ledger whose correct answer is known by
# construction and demands that exact answer, so it fails on an error far too
# small for the cross-check to see.
#
# Every expected value below is computed BY HAND in the comment above its case,
# never by re-running the implementation's own logic. A golden that recomputes
# the thing it is checking proves nothing.
#
# Runs against the shipped Rust binary by default; --bash checks the reference.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMPL="$ROOT/rust/target/release/nerdflair-statusline"
LABEL=rust
[[ "${1:-}" == "--bash" ]] && { IMPL="$ROOT/scripts/statusline.sh"; LABEL=bash; }
# golden-mutation.sh points this at a deliberately broken copy and requires
# this suite to FAIL. A suite that has never been shown to fail is not evidence.
if [[ -n "${NERDFLAIR_GOLDEN_IMPL:-}" ]]; then
  IMPL="$NERDFLAIR_GOLDEN_IMPL"; LABEL="${NERDFLAIR_GOLDEN_LABEL:-mutant}"
fi
[[ -x "$IMPL" ]] || { printf 'golden: not executable: %s\n' "$IMPL" >&2; exit 2; }

RUN=$(mktemp -d "${TMPDIR:-/tmp}/nerdflair-golden-XXXXXX")
trap 'rm -rf "$RUN"' EXIT
NOW=$(date +%s)
fail=0

# NERDFLAIR_REPO_COST=0 stops the renderer appending a row of its own, which
# would contaminate a ledger whose contents must be exactly what we wrote.
# Burn and block read the ledger independently of that flag.
#
# total_cost_usd must be NON-ZERO: the whole right-hand group of row 3, burn
# and block included, is suppressed when the session cost is 0.00, so a zero
# here silently hides the very segments under test and every case "passes" by
# finding nothing. total_duration_ms stays at 1 so the session-average burn
# FALLBACK (which needs > 120000 ms) can never fire and mask a ledger result.
render() { # $1=ledger $2=resets_at  -> plain-text last row
  printf '%s' "$(python3 -c "
import json,sys
print(json.dumps({'session_id':'golden',
 'transcript_path':'/nonexistent/t.jsonl',
 'workspace':{'current_dir':'$RUN','project_dir':'$RUN'},
 'model':{'display_name':'Opus 5','id':'claude-opus-5'},
 'context_window':{'context_window_size':200000,'total_input_tokens':1,'total_output_tokens':1,'used_percentage':5},
 'cost':{'total_cost_usd':7.77,'total_duration_ms':1,'total_api_duration_ms':1},
 'rate_limits':{'five_hour':{'used_percentage':5,'resets_at':$2}}}))")" \
  | NERDFLAIR_REPO_COST_FILE="$1" NERDFLAIR_REPO_COST=0 COLUMNS=400 \
    "$IMPL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tail -1
}

check() { # $1=name $2=expected-regex $3=actual $4=what
  if [[ "$3" =~ $2 ]]; then
    printf '  PASS  %-34s %s\n' "$1" "$4"
  else
    printf '  FAIL  %-34s expected /%s/ in: %s\n' "$1" "$2" "$3"; fail=1
  fi
}

# ── Case 1: the arithmetic, including the traps ──────────────────────────────
#
#   A  T-2760 $10.00 -> T-60   $40.00   delta  30.00
#   B  T-2400  $5.00 -> T-1200 $11.00   delta   6.00
#   C  T-1800 $100.00 (one sample only) delta   0.00   (nothing to subtract)
#   D  T-900  $50.00 -> T-300  $48.00   delta   0.00   (cumulative FELL; a
#                                        negative here would invent a refund)
#
#   spent = 30.00 + 6.00 = $36.00
#   span  = latest - earliest = (T-60) - (T-2760) = 2700s = 0.75h
#   burn  = 36.00 / 0.75 = $48.00/h        (span 2700 >= the 600s minimum)
#
#   resets_at = T+9000, so the 5h block began at T+9000-18000 = T-9000 and
#   every row above sits inside it: block spend = $36.00
L1="$RUN/c1.tsv"
{
  printf '%s\tA\trepo\t10.00\n'  $((NOW-2760))
  printf '%s\tB\trepo\t5.00\n'   $((NOW-2400))
  printf '%s\tC\trepo\t100.00\n' $((NOW-1800))
  printf '%s\tB\trepo\t11.00\n'  $((NOW-1200))
  printf '%s\tD\trepo\t50.00\n'  $((NOW-900))
  printf '%s\tD\trepo\t48.00\n'  $((NOW-300))
  printf '%s\tA\trepo\t40.00\n'  $((NOW-60))
} > "$L1"
out1=$(render "$L1" $((NOW+9000)))
printf '\n[%s] case 1: mixed sessions, a single-sample session, a falling counter\n' "$LABEL"
check "burn = \$48.00/h"  '\$48\.00/h'  "$out1" "hand-computed 36.00 / 0.75h"
check "block = \$36.00"   '\$36\.00'    "$out1" "hand-computed spend in the 5h block"

# ── Case 2: too little signal to divide ──────────────────────────────────────
#   One session, two samples 300s apart. span = 300s, under the 600s minimum,
#   so no rate may be printed: 3 minutes of data extrapolated to an hour is
#   noise. The payload carries cost 0, so the session-average fallback cannot
#   fire either, and the burn segment must be ABSENT.
L2="$RUN/c2.tsv"
{
  printf '%s\tA\trepo\t1.00\n' $((NOW-400))
  printf '%s\tA\trepo\t9.00\n' $((NOW-100))
} > "$L2"
out2=$(render "$L2" $((NOW+9000)))
printf '\n[%s] case 2: span below the minimum must print no rate\n' "$LABEL"
if [[ "$out2" =~ /h ]]; then
  printf '  FAIL  %-34s got a rate from 300s of data: %s\n' "no burn rate" "$out2"; fail=1
else
  printf '  PASS  %-34s %s\n' "no burn rate" "suppressed, as it must be"
fi
check "block still = \$8.00" '\$8\.00' "$out2" "block has no minimum span"

# ── Case 3: no block without a window ────────────────────────────────────────
#   An absent rate_limits.five_hour.resets_at arrives as "", which integer
#   arithmetic reads as 0. Treating that as an epoch would put the block start
#   in 1969 and total the entire ledger. No field means no block.
L3="$RUN/c3.tsv"
{
  printf '%s\tA\trepo\t1.00\n'  $((NOW-2460))
  printf '%s\tA\trepo\t31.00\n' $((NOW-60))
} > "$L3"
out3=$(printf '%s' "$(python3 -c "
import json
print(json.dumps({'session_id':'golden','transcript_path':'/nonexistent/t.jsonl',
 'workspace':{'current_dir':'$RUN','project_dir':'$RUN'},
 'model':{'display_name':'Opus 5','id':'claude-opus-5'},
 'context_window':{'context_window_size':200000,'total_input_tokens':1,'total_output_tokens':1,'used_percentage':5},
 'cost':{'total_cost_usd':7.77,'total_duration_ms':1,'total_api_duration_ms':1}}))")" \
  | NERDFLAIR_REPO_COST_FILE="$L3" NERDFLAIR_REPO_COST=0 COLUMNS=400 \
    "$IMPL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tail -1)
printf '\n[%s] case 3: no resets_at means no block, not a block since 1969\n' "$LABEL"
#   burn is still well defined: 30.00 over (T-60)-(T-2460) = 2400s = 0.6667h
#   30.00 / 0.666... = $45.00/h
check "burn = \$45.00/h" '\$45\.00/h' "$out3" "hand-computed 30.00 / 0.6667h"
if [[ "$out3" =~ (\$[0-9]+\.[0-9]{2})[^/] ]] && [[ ! "$out3" =~ /h ]]; then
  printf '  FAIL  %-34s a block appeared without a window: %s\n' "no block segment" "$out3"; fail=1
else
  printf '  PASS  %-34s %s\n' "no block segment" "absent, as it must be"
fi

# ── Case 5: a counter RESET mid-window must not erase the session ────────────
#
# The cumulative cost is not monotonic. A resumed, compacted or restarted
# session reports a lower total than before; measured on the real ledger on
# 2026-10-08, 11 sessions had 12 such drops, one of them an hour old. The
# earlier (last - first) rule turned that into a negative, discarded it, and
# silently lost everything that session spent in the window.
#
#   A  T-2460 $10.00 -> T-1860 $25.00    +15.00
#      T-1260  $2.00 (RESET, counter restarts)   contributes nothing
#      T-660   $9.00 -> T-60   $14.00     +7.00  +5.00
#
#   Summing positive increments: 15.00 + 7.00 + 5.00 = $27.00
#   Under the old last-minus-first rule: 14.00 - 10.00 = $4.00, a 6.75x
#   undercount, and had the session ended below its start it would have been
#   discarded entirely.
#
#   span = (T-60) - (T-2460) = 2400s = 0.6667h
#   burn = 27.00 / 0.6667 = $40.50/h
L5="$RUN/c5.tsv"
{
  printf '%s\tA\trepo\t10.00\n' $((NOW-2460))
  printf '%s\tA\trepo\t25.00\n' $((NOW-1860))
  printf '%s\tA\trepo\t2.00\n'  $((NOW-1260))
  printf '%s\tA\trepo\t9.00\n'  $((NOW-660))
  printf '%s\tA\trepo\t14.00\n' $((NOW-60))
} > "$L5"
out5=$(render "$L5" $((NOW+9000)))
printf '\n[%s] case 5: a mid-window counter reset\n' "$LABEL"
check "block = \$27.00"  '\$27\.00'    "$out5" "sum of positive increments, not 14-10"
check "burn = \$40.50/h" '\$40\.50/h' "$out5" "hand-computed 27.00 / 0.6667h"
if [[ "$out5" =~ \$4\.00 ]]; then
  printf '  FAIL  %-34s the old last-minus-first rule is back\n' "regression guard"; fail=1
else
  printf '  PASS  %-34s %s\n' "regression guard" "no \$4.00 anywhere"
fi

# ── Case 6: a LAPSED block must not total two blocks ─────────────────────────
#
# resets_at in the PAST means the payload's window has already rolled over and
# the host has not refreshed it, which is the normal state on the first render
# after a session wakes. block_start = reset - 5h, and summing to now then
# spans the whole lapsed block plus everything since. Measured against the
# real ledger with resets_at one hour stale: $282.99 reported where the true
# current-block figure was about $163.
L6="$RUN/c6.tsv"
{
  printf '%s\tA\trepo\t1.00\n'   $((NOW-20000))
  printf '%s\tA\trepo\t500.00\n' $((NOW-600))
} > "$L6"
out6=$(render "$L6" $((NOW-3600)))   # reset one hour in the PAST
printf '\n[%s] case 6: a lapsed resets_at\n' "$LABEL"
if [[ "$out6" =~ \$499\.00 ]] || [[ "$out6" =~ \$500\.00 ]]; then
  printf '  FAIL  %-34s totalled a lapsed block: %s\n' "lapsed block" "$out6"; fail=1
else
  printf '  PASS  %-34s %s\n' "lapsed block shows no amount" "idle, not a six-hour total"
fi

# ── Case 7: a cut tail that misses the window start must suppress the block ──
#
# The tail read has a hard byte cap. If the block began before the oldest row
# the cap let us see, the sum is missing its earliest spend. An absolute
# dollar figure that is quietly low is read as fact, so it must not be shown.
# Forced here with a tiny cap against a ledger far larger than it.
L7="$RUN/c7.tsv"
for i in $(seq 1 4000); do
  printf '%s\tS%s\trepo\t%s.00\n' $((NOW-18000+i*4)) $((i % 7)) $((i))
done > "$L7"
out7=$(NERDFLAIR_LEDGER_TAIL_BYTES=4096 render "$L7" $((NOW+9000)))
printf '\n[%s] case 7: tail cap shorter than the block window\n' "$LABEL"
if [[ "$out7" =~ \$[0-9]+\.[0-9]{2}([^/]|$) ]] && [[ ! "$out7" =~ idle ]]; then
  # the session cost 7.77 is always present, so look for a SECOND amount
  n=$(grep -o '\$[0-9]*\.[0-9][0-9]' <<<"$out7" | grep -cv '7\.77' || true)
  if (( n > 0 )); then
    printf '  FAIL  %-34s showed an undercounted block: %s\n' "cut tail" "$out7"; fail=1
  else
    printf '  PASS  %-34s %s\n' "cut tail suppresses the block" "no amount shown"
  fi
else
  printf '  PASS  %-34s %s\n' "cut tail suppresses the block" "no amount shown"
fi

# ── Case 4: an empty ledger must not divide by zero or print junk ────────────
L4="$RUN/c4.tsv"; : > "$L4"
out4=$(render "$L4" $((NOW+9000)))
printf '\n[%s] case 4: empty ledger\n' "$LABEL"
if [[ -n "$out4" ]] && [[ ! "$out4" =~ (nan|inf|/h) ]]; then
  printf '  PASS  %-34s %s\n' "renders, no rate, no nan/inf" "clean"
else
  printf '  FAIL  %-34s %s\n' "empty ledger produced" "$out4"; fail=1
fi

# ── Case 8: a row that goes BACKWARDS in time within one session ─────────────
#
# Two renders of one session can both find the sample stamp expired, both take
# the shared lock (which does not exclude them from each other), and append in
# the order they finish rather than the order they read the clock. The ledger
# then holds a row older than the one before it, for the SAME session.
#
# Session A, in file order:
#   T-2000  $10.00   first sample, baseline, contributes nothing
#   T-1000  $30.00   rise of 20.00
#   T-1400  $20.00   OLDER than T-1000: out of order, must be SKIPPED whole
#   T-60    $35.00   rise from 30.00 of 5.00
#
#   spent = 20.00 + 5.00 = $25.00
#   span  = (T-60) - (T-2000) = 1940s   (>= the 600s minimum)
#   burn  = 25.00 * 3600 / 1940 = $46.39/h
#
# Accepting the stale row instead makes $20.00 the new baseline, so the rise to
# $35.00 is charged as 15.00 against a figure that already contained it:
# 20.00 + 15.00 = $35.00, and burn 35.00 * 3600 / 1940 = $64.95/h. Both wrong
# numbers are asserted ABSENT, so this case fails loudly if the skip is removed.
L8="$RUN/c8.tsv"
{
  printf '%s\tA\trepo\t10.00\n' $((NOW-2000))
  printf '%s\tA\trepo\t30.00\n' $((NOW-1000))
  printf '%s\tA\trepo\t20.00\n' $((NOW-1400))
  printf '%s\tA\trepo\t35.00\n' $((NOW-60))
} > "$L8"
out8=$(render "$L8" $((NOW+9000)))
printf '\n[%s] case 8: a backwards row within one session\n' "$LABEL"
check "block = \$25.00"   '\$25\.00'   "$out8" "hand-computed, stale row skipped"
check "burn = \$46.39/h"  '\$46\.39/h' "$out8" "hand-computed 25.00 / 0.53889h"
if [[ "$out8" =~ \$35\.00 ]] || [[ "$out8" =~ \$64\.95/h ]]; then
  printf '  FAIL  %-34s took the backwards row as a sample: %s\n' "regression guard" "$out8"; fail=1
else
  printf '  PASS  %-34s %s\n' "regression guard" "no \$35.00 and no \$64.95/h"
fi

# ── Case 9: a total too small to round to a cent is nothing ──────────────────
#   0.004 of spend prints as $0.00, which reads as money. The test is on the
#   ROUNDED figure, so the block says idle.
L9="$RUN/c9.tsv"
{
  printf '%s\tA\trepo\t1.000\n' $((NOW-2000))
  printf '%s\tA\trepo\t1.004\n' $((NOW-60))
} > "$L9"
out9=$(render "$L9" $((NOW+9000)))
printf '\n[%s] case 9: spend under half a cent\n' "$LABEL"
check "block says idle" 'idle' "$out9" "0.004 of spend is not \$0.00"
if [[ "$out9" =~ \$0\.00 ]]; then
  printf '  FAIL  %-34s printed a zero-dollar figure: %s\n' "no \$0.00" "$out9"; fail=1
else
  printf '  PASS  %-34s %s\n' "no \$0.00" "absent"
fi

printf '\n'
(( fail )) && { printf 'burn-block-golden (%s): FAIL\n' "$LABEL"; exit 1; }
printf 'burn-block-golden (%s): PASS\n' "$LABEL"

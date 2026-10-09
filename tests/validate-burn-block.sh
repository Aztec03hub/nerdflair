#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-burn-block.sh — shadow-compare our burn rate and block spend against
# ccusage, the implementation they replaced.
#
# This is the strangler-fig check. nerdflair stopped calling ccusage on
# 2026-10-08 and now derives both figures from ~/.claude/nerdflair-usage.tsv.
# The two methods differ in AGGREGATION and in PRICING, and that is all they
# differ in. Both start from the token counts the API reports, so a flaw that
# lives upstream of both (cache-tier pricing, long-context or fast-mode
# premiums, subagent usage) is invisible here, and so is whether the ledger
# faithfully records Claude Code's figure. This catches window and arithmetic
# bugs. Correctness is pinned by tests/burn-block-golden.sh, not by this.
#
#   ours     Claude Code's own `cost.total_cost_usd` per session, sampled once
#            a minute into the ledger. Authoritative, but 60s-granular, and a
#            session contributes only from its first sample inside the window.
#
# The "ours" figure is read off the SHIPPED renderer, not recomputed here.
# That is the whole difference between this being evidence and being theatre:
# a harness carrying its own copy of the algorithm cannot find a bug in the
# algorithm. Set NERDFLAIR_VALIDATE_IMPL to point it at the bash reference
# instead, and run it both ways.
#   ccusage  token counts read from the transcripts, multiplied by a pricing
#            table. Fine-grained, but only as good as that table.
#
# ccusage MUST be run with --no-offline. Its cached table is stale: it knows
# nothing newer than claude-opus-4-8 / claude-sonnet-4-6, so against
# claude-opus-5 it reported $86.48 where live pricing said $213.09, a 2.5x
# undercount. Comparing against the offline figure would "validate" us against
# a number that is simply wrong.
#
# KNOWN, MEASURED 2026-10-09: ccusage prices cache reads for claude-sonnet-5-5
# (and the other newest models) at $0.10 per MTok where the published rate is
# $0.20, so on a cache-heavy day it reports about 1.5x LESS than Claude Code's
# own cost figure, which matches the published price to the cent (see finding 6
# in reports/REVIEW-verification-methodology-2026-10-08.md). A FAIL here with
# ours well above ccusage is therefore expected until ccusage's table is
# fixed, and says nothing about the ledger; a gap that moves with block age,
# or ours BELOW ccusage, is the signal to investigate.
# Windows are matched explicitly. ccusage reports its block's remaining time,
# so elapsed = 5h - remaining, and our ledger is summed over that same span.
#
# Exit 0 if the two agree within TOLERANCE_PCT, 1 if they do not, and 77 (the
# conventional SKIP code) if it could not run: no ccusage, no ledger, an
# unparseable answer. A SKIP is never a pass; a gate must require exactly 0.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

LEDGER="${NERDFLAIR_REPO_COST_FILE:-$HOME/.claude/nerdflair-usage.tsv}"
TOLERANCE_PCT=${TOLERANCE_PCT:-25}
CCUSAGE=""
for c in "$HOME/.local/lib/node_modules/ccusage/node_modules/@ccusage/ccusage-linux-x64/bin/ccusage" \
         "$(command -v ccusage 2>/dev/null || true)"; do
  [[ -n "$c" && -x "$c" ]] && { CCUSAGE="$c"; break; }
done

[[ -f "$LEDGER" ]] || { printf 'validate: no ledger at %s\n' "$LEDGER" >&2; exit 77; }
[[ -n "$CCUSAGE" ]] || { printf 'validate: ccusage not installed, cannot cross-check\n' >&2; exit 77; }

# A stub would answer instantly and produce no figures. Catch that rather than
# reporting a confusing parse failure: the binary was replaced by a stub during
# the 2026-10-08 incident and could be again.
# By behaviour, not size: a real node shim is small and a stub is not always.
if ! "$CCUSAGE" --version 2>/dev/null | grep -qE '[0-9]+\.[0-9]+'; then
  printf 'validate: SKIP: %s does not report a version, not the real ccusage\n' "$CCUSAGE"
  exit 77
fi

now=$(date +%s)
# ccusage rejects a payload without transcript_path. Which one does not matter
# for the block and daily figures: it scans every transcript regardless. Use
# the newest so the file certainly exists.
TRANSCRIPT=$(find "$HOME/.claude/projects" -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
             | sort -rn | head -1 | cut -d' ' -f2-)
[[ -n "$TRANSCRIPT" ]] || { printf 'validate: no transcript to point ccusage at\n' >&2; exit 77; }
payload=$(TRANSCRIPT="$TRANSCRIPT" HOMEDIR="$HOME" python3 -c "
import json, os
print(json.dumps({'session_id':'validate-burn-block',
 'transcript_path': os.environ['TRANSCRIPT'],
 'workspace':{'current_dir':os.environ['HOMEDIR'],'project_dir':os.environ['HOMEDIR']},
 'model':{'display_name':'Opus 5','id':'claude-opus-5'},
 'context_window':{'context_window_size':1000000,'total_input_tokens':1,'total_output_tokens':1,'used_percentage':1},
 'cost':{'total_cost_usd':0.0,'total_duration_ms':1,'total_api_duration_ms':1}}))")

printf 'validate-burn-block\n  ledger:  %s\n  ccusage: %s\n  scanned: %s transcripts under %s (TZ=%s)\n\n' \
  "$LEDGER" "$CCUSAGE" "$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -name '*.jsonl' 2>/dev/null | wc -l)" \
  "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" "${TZ:-unset}"

cc=$(printf '%s' "$payload" | timeout -k 5 180 "$CCUSAGE" statusline --no-offline 2>/dev/null \
     | sed 's/\x1b\[[0-9;]*m//g')
[[ -n "$cc" ]] || { printf 'validate: ccusage produced nothing\n' >&2; exit 77; }
printf '  ccusage: %s\n\n' "$cc"

# "$213.09 block (25m left)" / "(4h 35m left)" / "(59s left)" / "$1,216.20".
# Taken AFTER ccusage returns: it can run for minutes, and every figure below
# is "how old is the block right now".
now=$(date +%s)
cc_block=$(grep -oE '\$[0-9,]+\.[0-9]+ block' <<<"$cc" | head -1 | tr -d '$,' | sed 's/ block//')
left=$(grep -oE 'block \(([0-9]+[hms] ?)+ left\)' <<<"$cc" | head -1 || true)
if [[ -z "$cc_block" ]]; then
  printf 'validate: could not parse a block cost out of ccusage output\n' >&2; exit 77
fi
if [[ -z "$left" ]]; then
  printf 'validate: no "(... left)" clause in ccusage output, cannot place the block in time\n' >&2; exit 77
fi
rem=0
for part in $(grep -oE '[0-9]+[hms]' <<<"$left"); do
  n=${part%[hms]}
  case "$part" in *h) rem=$((rem + n*3600)) ;; *m) rem=$((rem + n*60)) ;; *s) rem=$((rem + n)) ;; esac
done
elapsed=$(( 5*3600 - rem ))
(( elapsed < 0 )) && elapsed=0
(( elapsed > 18000 )) && elapsed=18000
if (( elapsed < 600 )); then
  printf 'validate: block only %ss old, too little signal to compare\n' "$elapsed" >&2; exit 77
fi

# Our figure, read off the SHIPPED renderer.
#
# This used to be a private awk sum, and that made the whole comparison
# worthless twice over. It proved that a throwaway script agreed with
# ccusage, not that the code we ship does; and the rule it used, (max - min)
# per session, is one a real defect had already broken: 11 sessions in the
# live ledger have a cumulative cost that goes DOWN, and across a drop that
# rule is simply wrong. The shipped renderer sums positive increments. A
# harness that reimplements the algorithm cannot find a bug in the
# algorithm, and this one would have reported agreement either way.
#
# So: drive the real binary with a payload whose five-hour window is exactly
# ccusage's elapsed block, and parse the figure it prints. resets_at is
# now + (5h - elapsed), which puts block_start at now - elapsed.
BIN="${NERDFLAIR_VALIDATE_IMPL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rust/target/release/nerdflair-statusline}"
# A .sh implementation (the bash reference) is run through bash.
RUN=("$BIN"); [[ "$BIN" == *.sh ]] && RUN=(bash "$BIN")
[[ -f "$BIN" ]] || { printf 'validate: not built: %s\n' "$BIN" >&2; exit 77; }
resets_at=$(( now + (5*3600 - elapsed) ))
ours_payload=$(TRANSCRIPT="$TRANSCRIPT" HOMEDIR="$HOME" RESETS="$resets_at" python3 -c "
import json, os
print(json.dumps({'session_id':'validate-burn-block',
 'transcript_path': os.environ['TRANSCRIPT'],
 'workspace':{'current_dir':os.environ['HOMEDIR'],'project_dir':os.environ['HOMEDIR']},
 'model':{'display_name':'Opus 5','id':'claude-opus-5'},
 'context_window':{'context_window_size':1000000,'total_input_tokens':1,'total_output_tokens':1,'used_percentage':1},
 # a session cost above zero is what puts burn and block on the row at all
 'cost':{'total_cost_usd':0.01,'total_duration_ms':1,'total_api_duration_ms':1},
 'rate_limits':{'five_hour':{'used_percentage':5,'resets_at':int(os.environ['RESETS'])}}}))")
# The tail cap must cover the window, or the renderer correctly refuses to
# print a figure it cannot vouch for: the live ledger is megabytes and the
# 1 MiB default does not reach back five hours, so the block is suppressed.
# That suppression is a FEATURE (a truncated tail silently undercounts), and
# the right move here is to give the cap room, not to work around it.
LCAP=$(( $(stat -c %s "$LEDGER" 2>/dev/null || echo 0) + 1048576 ))
ours_all=$(printf '%s' "$ours_payload" \
  | NERDFLAIR_REPO_COST_FILE="$LEDGER" NERDFLAIR_REPO_COST=0 NERDFLAIR_CCUSAGE=0 \
    NERDFLAIR_LEDGER_TAIL_BYTES="$LCAP" \
    COLUMNS=400 timeout -k 5 60 "${RUN[@]}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
# Read the figures by the renderer's own icons (block U+F094, burn U+F0238),
# from the whole output: which row they land on is the renderer's business.
ours=$(grep -oE $'\xef\x82\x94 \\$[0-9]+\\.[0-9][0-9]' <<<"$ours_all" | grep -oE '[0-9]+\.[0-9][0-9]' | tail -1 || true)
ours_burn=$(grep -oE $'\xf3\xb0\x88\xb8 \\$[0-9]+\\.[0-9][0-9]/h' <<<"$ours_all" | grep -oE '[0-9]+\.[0-9][0-9]' | tail -1 || true)
ours_line=$(tail -3 <<<"$ours_all")
if [[ -z "$ours" ]]; then
  printf 'validate: the renderer printed no block figure; row was:\n  %s\n' "$ours_line" >&2
  exit 77
fi

printf '  window: %.2fh (ccusage block elapsed)\n' "$(awk -v e="$elapsed" 'BEGIN{print e/3600}')"
printf '  ours:    $%s\n  ccusage: $%s\n' "$ours" "$cc_block"
# Burn is REPORTED, not judged. ccusage's rate is over its block; ours is a
# rolling 60-minute window. They answer different questions, so a tolerance
# between them would be a number with no meaning attached. Printing both is
# still worth it: a burn that has gone to zero or to orders of magnitude is
# visible here, and that is the failure this would actually catch.
printf '  burn:    ours $%s/h vs ccusage block rate (different windows, not judged)\n\n' \
  "${ours_burn:-none}"

if awk -v b="$cc_block" 'BEGIN{exit !(b+0 <= 0)}'; then
  printf 'validate: no ccusage spend in the block, nothing to compare against\n' >&2; exit 77
fi
if awk -v a="$ours" 'BEGIN{exit !(a+0 <= 0)}'; then
  printf 'validate: no ledger rows in the window, ours is zero; that is a failure to measure, not a match\n' >&2; exit 1
fi
read -r diff_pct verdict < <(awk -v a="$ours" -v b="$cc_block" -v tol="$TOLERANCE_PCT" 'BEGIN {
  if (b <= 0) { print "nan FAIL"; exit }
  d = (a - b) / b * 100; ad = (d < 0 ? -d : d)
  printf "%.1f %s", d, (ad <= tol ? "PASS" : "FAIL")
}')

if [[ "$verdict" == "PASS" ]]; then
  printf '  PASS  ours is %s%% from ccusage (tolerance %s%%)\n' "$diff_pct" "$TOLERANCE_PCT"
  exit 0
fi
printf '  FAIL  ours is %s%% from ccusage (tolerance %s%%)\n' "$diff_pct" "$TOLERANCE_PCT"
exit 1

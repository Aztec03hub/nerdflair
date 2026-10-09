#!/usr/bin/env bash
# validate-ledger.sh - the billing block our renderer shows, against an
# independent recount, at several window ages.
#
# Replaces tests/validate-burn-block.sh, which compared with ccusage. That
# comparison was retired because ccusage prices cache reads for the newest
# models at half the published rate (see finding 6 of the methodology review),
# so it could only ever say "close to something wrong". This one prices the
# transcripts by hand from published rates (price-recount.py) and needs no
# ccusage at all.
#
# For each window age (1 h, 3 h, 4.8 h, ending now), both shipped
# implementations are driven through the real renderer with a payload whose
# five-hour reset puts the block start exactly that far back, and the block
# figure is read off what they print. Three things are asserted:
#
#   - bash and Rust print the same figure;
#   - the figure is not ABOVE the recount by more than 2 percent. An overcount
#     is the dangerous direction: it is read as money spent;
#   - it is not BELOW by more than 10 percent. Below is expected and small,
#     because a session's first sample inside the window is its baseline and
#     the spend before it is not charged (a documented lower bound).
#
# A real defect drifts with window age; a steady few percent below does not.
#
# Exit 0 pass, 1 fail, 77 could not run (a SKIP is never a pass).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST="$REPO/rust/target/release/nerdflair-statusline"
SH="${NF_VALIDATE_SH:-$REPO/scripts/statusline.sh}"
LEDGER="${NERDFLAIR_REPO_COST_FILE:-$HOME/.claude/nerdflair-usage.tsv}"
ABOVE=${ABOVE_PCT:-2}
BELOW=${BELOW_PCT:-10}

[[ -x "$RUST" && -f "$LEDGER" ]] || { echo "validate-ledger: SKIP: need the built binary and a ledger" >&2; exit 77; }
python3 "$REPO/tests/price-recount.py" --selfcheck >/dev/null || { echo "validate-ledger: the recount's own selfcheck failed" >&2; exit 1; }

# Live sessions append to the ledger while this runs; bash and Rust must read
# the same bytes or a 0.1 difference is drift, not a defect. Snapshot once.
SNAP=$(mktemp "${TMPDIR:-/tmp}/nf-validate-ledger-XXXXXX")
trap 'rm -f "$SNAP"' EXIT
cp "$LEDGER" "$SNAP"; LEDGER="$SNAP"
LCAP=$(( $(stat -c %s "$LEDGER") + 1048576 ))
fail=0

block_of() { # impl-cmd... ; reads payload on stdin
  NERDFLAIR_REPO_COST_FILE="$LEDGER" NERDFLAIR_REPO_COST=0 \
    NERDFLAIR_LEDGER_TAIL_BYTES="$LCAP" COLUMNS=400 timeout 60 "$@" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -oE $'\xef\x82\x94 \\$[0-9]+\\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | tail -1
}

printf 'validate-ledger: ledger %s\n\n' "$LEDGER"
printf '  %-6s %10s %10s %10s %8s\n' window rust bash recount delta
for hours in 1 3 4.8; do
  now=$(date +%s)
  elapsed=$(python3 -c "print(int($hours * 3600))")
  payload=$(python3 -c "
import json
print(json.dumps({'session_id':'validate-ledger',
 'workspace':{'current_dir':'$HOME','project_dir':'$HOME'},
 'model':{'display_name':'Opus 5','id':'claude-opus-5'},
 'context_window':{'context_window_size':1000000,'total_input_tokens':1,'total_output_tokens':1,'used_percentage':1},
 'cost':{'total_cost_usd':0.01,'total_duration_ms':1,'total_api_duration_ms':1},
 'rate_limits':{'five_hour':{'used_percentage':5,'resets_at':$now + 18000 - $elapsed}}}))")
  rust=$(printf '%s' "$payload" | block_of "$RUST")
  bash_=$(printf '%s' "$payload" | block_of bash "$SH")
  recount=$(python3 "$REPO/tests/price-recount.py" "$hours" 2>/dev/null)
  if [[ -z "$rust" || -z "$bash_" || -z "$recount" ]]; then
    echo "validate-ledger: SKIP: could not read a figure (rust='$rust' bash='$bash_' recount='$recount')" >&2
    exit 77
  fi
  delta=$(awk -v a="$rust" -v b="$recount" 'BEGIN{ if (b <= 0) print "nan"; else printf "%+.1f", (a - b) / b * 100 }')
  verdict=ok
  if [[ "$rust" != "$bash_" ]]; then verdict="bash and Rust differ"; fail=1; fi
  if awk -v d="$delta" -v up="$ABOVE" -v dn="$BELOW" 'BEGIN{ exit !(d == "nan" || d + 0 > up || d + 0 < -dn) }'; then
    verdict="outside +${ABOVE}%/-${BELOW}%"; fail=1
  fi
  printf '  %-6s %10s %10s %10s %7s%%  %s\n' "${hours}h" "$rust" "$bash_" "$recount" "$delta" "$verdict"
done

printf '\n'
if (( fail )); then echo "validate-ledger: FAIL"; exit 1; fi
echo "validate-ledger: PASS"

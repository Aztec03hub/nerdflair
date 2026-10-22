#!/usr/bin/env bash
# ledger-uncovered-dedupe.sh - `ledger-uncovered` is logged once per 24 h, not once an hour.
# A long-lived session hits it on every refresh; the 1 h limit wrote a line every hour forever.
# Both renderers, temp HOME, private stamp dir; the stamp's mtime is the fake clock.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/rust/target/release/nerdflair-statusline"
[[ -x "$BIN" ]] || { echo "ledger-uncovered-dedupe: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-uncov-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
check() { if [[ "$3" == "$2" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }
NOW=$(date +%s)
# a ledger far bigger than the 4 KiB tail cap, so the burn window start is never reached
for i in $(seq 1 8000); do printf '%s\tS%s\trepo\t%s.00\n' $((NOW-18000+i*2)) $((i % 7)) "$i"; done > "$W/l.tsv"
PAY=$(python3 -c "
import json
print(json.dumps({'session_id':'u','transcript_path':'/nonexistent/t.jsonl','workspace':{'current_dir':'$W','project_dir':'$W'},
 'model':{'display_name':'Opus 5','id':'claude-opus-5'},
 'context_window':{'context_window_size':200000,'total_input_tokens':1,'total_output_tokens':1,'used_percentage':5},
 'cost':{'total_cost_usd':7.77,'total_duration_ms':1,'total_api_duration_ms':1},
 'rate_limits':{'five_hour':{'used_percentage':5,'resets_at':$NOW+9000}}}))")
for impl in rust bash; do
  D="$W/$impl"; mkdir -p "$D/home/.claude/nerdflair" "$D/stamps"; mkdir -m 700 "$D/c"
  r() {
    if [[ $impl == rust ]]; then cmd=("$BIN"); else cmd=(bash "$REPO/scripts/statusline.sh"); fi
    printf '%s' "$PAY" | env -i PATH="$PATH" HOME="$D/home" NERDFLAIR_CACHE_DIR="$D/c" NERDFLAIR_ERR_STAMP_DIR="$D/stamps" \
      NERDFLAIR_REPO_COST_FILE="$W/l.tsv" NERDFLAIR_REPO_COST=0 NERDFLAIR_MCP_HEALTH=0 NERDFLAIR_LEDGER_TAIL_BYTES="${CAP:-4096}" COLUMNS=400 "${cmd[@]}" >/dev/null 2>&1
  }
  n() { rg -c 'billing block start' "$D/home/.claude/nerdflair-errors.log" 2>/dev/null || echo 0; }
  # One stamp per reason text. Only the block cause is counted: both renderers hit it
  # deterministically here (the burn cause depends on how each one widens the tail).
  r; n0=$(n); check "$impl: first render logs the block line once" 1 "$n0"
  stamps=("$D"/stamps/*ledger?uncovered*block*)
  touch -d '5 hours ago' "${stamps[@]}"; r; check "$impl: 5 h later (a new process) stays silent" 1 "$(n)"
  touch -d '23 hours ago' "${stamps[@]}"; r; check "$impl: 23 h later stays silent" 1 "$(n)"
  touch -d '25 hours ago' "${stamps[@]}"; r; check "$impl: 25 h later logs again" 2 "$(n)"
  CAP=5000 r; check "$impl: a changed reason (new cap) under the same key logs at once" 3 "$(n)"
done
exit $fail

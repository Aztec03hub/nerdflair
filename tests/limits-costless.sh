#!/usr/bin/env bash
# limits-costless.sh - what the status line shows for the 5h / 7d limits when the
# payload lacks them (Claude Code drops a window once its resets_at passes, and
# sends none before the first response), and that a cost-less row with MCP
# configured keeps every readout that has data. Both renderers, exact text.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/rust/target/release/nerdflair-statusline"; SH="$REPO/scripts/statusline.sh"
[[ -x "$BIN" ]] || { echo "limits-costless: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-limcost-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
NOW=$(date +%s); fail=0

render() { # impl record-or-empty payload  -> ANSI-stripped output on stdout
  local impl=$1 rec=$2 payload=$3 d="$W/$1-$RANDOM" cmd
  mkdir -p "$d/home/.claude/nerdflair" "$d/work"; mkdir -m 700 "$d/cache"
  printf '{"numStartups":7,"mcpServers":{"context7":{"command":"x"}},"projects":{}}' > "$d/home/.claude.json"
  [[ -n "$rec" ]] && printf '%s\n' "$rec" > "$d/cache/limits-last"
  cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  printf '%s' "${payload//@DIR@/$d/work}" | env -i PATH="$PATH" HOME="$d/home" TMPDIR="$d" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=160 \
    NERDFLAIR_CACHE_DIR="$d/cache" NERDFLAIR_ERR_STAMP_DIR="$d/st" NERDFLAIR_MCP_HEALTH=0 \
    NERDFLAIR_REPO_COST_FILE="$d/ledger.tsv" "${cmd[@]}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
base() { # cost rate_limits-json-or-empty
  printf '{"session_id":"lc-%s","workspace":{"current_dir":"@DIR@","project_dir":"@DIR@"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":%s,"total_duration_ms":600000,"total_api_duration_ms":240000},"context_window":{"used_percentage":20,"context_window_size":200000}%s}' \
    "$RANDOM" "$1" "${2:+,\"rate_limits\":$2}"
}
FUT5=$((NOW + 9000)); FUT7=$((NOW + 200000)); PAST=$((NOW - 3600))
SEVEN="{\"seven_day\":{\"used_percentage\":59,\"resets_at\":$FUT7}}"

expect() { # label impl output needle... ; a needle starting with ! must be absent
  local label=$1 impl=$2 out=$3 n; shift 3
  for n in "$@"; do
    if [[ $n == '!'* ]]; then
      [[ "$out" != *"${n#!}"* ]] && continue
      printf '  FAIL  %s [%s]: must not contain %q\n        %s\n' "$label" "$impl" "${n#!}" "$out"; fail=1; return
    else
      [[ "$out" == *"$n"* ]] && continue
      printf '  FAIL  %s [%s]: lacks %q\n        %s\n' "$label" "$impl" "$n" "$out"; fail=1; return
    fi
  done
  printf '  PASS  %s [%s]\n' "$label" "$impl"
}

for impl in rust bash; do
  expect "5h absent, 7d present: dim 5h 0%, block idle" $impl "$(render $impl "" "$(base 1.25 "$SEVEN")")" "5h 0% 7d 59%" "idle"
  expect "both absent, record in the future: recorded figures with countdown" $impl \
    "$(render $impl "v1 42:$FUT5 71:$FUT7" "$(base 1.25 "")")" "5h 42%/2h" "7d 71%/2d"
  expect "both absent, record expired: dim 0% and block idle" $impl \
    "$(render $impl "v1 42:$PAST 71:$PAST" "$(base 1.25 "")")" "5h 0% 7d 0%" "idle"
  expect "both absent, no record: nothing" $impl "$(render $impl "" "$(base 1.25 "")")" "!5h" "!7d"
  expect "cost 0.00 with MCP configured: api time and block stay" $impl \
    "$(render $impl "v1 42:$PAST 71:$PAST" "$(base 0 "")")" "context7" " 4m" "idle" "5h 0%"
done
(( fail )) && { echo "limits-costless: FAIL"; exit 1; }
echo "limits-costless: PASS"

#!/usr/bin/env bash
# placeholders.sh - readouts that have no data yet keep a stable dim placeholder instead of appearing later:
# token rate "--/s" (tokens + api time in the payload, no rate yet), context ETA "~--" (under 5% used),
# repo cost "$--" (slug resolved, nothing in the ledger). And none of them shows when its input is absent.
# Both renderers, exact text. NF_BIN / NF_SH point at another build.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${NF_BIN:-$REPO/rust/target/release/nerdflair-statusline}"; SH="${NF_SH:-$REPO/scripts/statusline.sh}"
[[ -x "$BIN" ]] || { echo "placeholders: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-ph-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
mkdir -p "$W/home" "$W/work"

render() { # impl payload-extra-json (inside "cost" or top level is fixed) -> stripped output
  local impl=$1 tok=$2 d="$W/c-$1-$RANDOM" cmd; mkdir -m 700 "$d"; cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  printf '{"session_id":"ph-%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":0,"total_duration_ms":600000,"total_api_duration_ms":240000},"context_window":{"used_percentage":3,"context_window_size":200000%s}}' \
    "$RANDOM" "$W/work" "$W/work" "$tok" |
    env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=200 NERDFLAIR_CACHE_DIR="$d" \
      NERDFLAIR_ERR_STAMP_DIR="$W/st-$RANDOM" NERDFLAIR_MCP_HEALTH=0 NERDFLAIR_REPO_COST_FILE="$W/empty-ledger.tsv" \
      "${cmd[@]}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
want() { # label impl out needle
  [[ "$3" == *"$4"* ]] || { echo "FAIL $2 $1: want '$4' in: $(tail -n 1 <<<"$3")"; fail=1; }
}
refuse() { # label impl out needle
  [[ "$3" != *"$4"* ]] || { echo "FAIL $2 $1: '$4' must be absent in: $(tail -n 1 <<<"$3")"; fail=1; }
}
for impl in rust bash; do
  # tokens in the payload (cost block carries total_output_tokens at the top level of context_window here)
  out=$(render "$impl" ',"total_output_tokens":5000')
  want "repo cost placeholder" "$impl" "$out" '$--'
  want "eta placeholder" "$impl" "$out" '~--'
  want "rate placeholder" "$impl" "$out" '--/s'
  out2=$(render "$impl" '')
  refuse "rate placeholder without tokens" "$impl" "$out2" '--/s'
done
(( fail )) && exit 1
echo "placeholders: ok"

#!/usr/bin/env bash
# row3-gap.sh - row 3 (MCP readout left, everything else right) reads left to
# right: the gap between the groups is EXACTLY 3 spaces when there is slack, and
# 2 (the floor) when the row is full. Exact-text checks, so a bug present in both
# renderers fails too. Both renderers, MCP configured, with and without the RC chip.
# BIN / SH env override the renderers (used to show the test fails on main).
set -uo pipefail
export LC_ALL=C.UTF-8
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-$REPO/rust/target/release/nerdflair-statusline}"; SH="${SH:-$REPO/scripts/statusline.sh}"
[[ -x "$BIN" ]] || { echo "row3-gap: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-row3gap-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
NOW=$(date +%s); fail=0
render() { # impl columns rc-record-or-empty
  local impl=$1 cols=$2 rc=$3 d="$W/$1-$RANDOM" cmd payload
  mkdir -p "$d/home/.claude/nerdflair" "$d/work"; mkdir -m 700 "$d/cache"
  printf '{"numStartups":7,"mcpServers":{"context7":{"command":"x"}},"projects":{}}' > "$d/home/.claude.json"
  payload='{"session_id":"r3g","workspace":{"current_dir":"'"$d/work"'","project_dir":"'"$d/work"'"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.25,"total_duration_ms":600000,"total_api_duration_ms":240000},"context_window":{"used_percentage":20,"context_window_size":200000}}'
  [[ -n "$rc" ]] && printf '%s\n' "$rc" > "$d/cache/$("$BIN" --rc-name r3g </dev/null)"
  cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  printf '%s' "$payload" | env -i PATH="$PATH" HOME="$d/home" TMPDIR="$d" LC_ALL=C.UTF-8 TZ=UTC COLUMNS="$cols" \
    NERDFLAIR_CACHE_DIR="$d/cache" NERDFLAIR_ERR_STAMP_DIR="$d/st" NERDFLAIR_MCP_HEALTH=0 \
    NERDFLAIR_REPO_COST=0 NERDFLAIR_REPO_COST_FILE="$d/ledger.tsv" "${cmd[@]}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | rg -F context7 | head -n 1
}
# Expected text, built from the glyphs the row draws (nerd-font private use area).
MCP=$(printf '\uf1e6 context7'); TMUXLESS_TAIL=$(printf '\U000f051f ~40m · \uf017 4m · \U000f0238 $7.50/h · \uf1551.25')
RCCHIP=$(printf '\u2b24 RC web · ')
G3="   "; G2="  "
expect() { # label impl columns rc want
  local label=$1 impl=$2 cols=$3 rc=$4 want=$5 got
  got=$(render "$impl" "$cols" "$rc" | sed -E 's/ +$//')
  if [[ "$got" == "$want" ]]; then printf '  PASS  %s [%s]\n' "$label" "$impl"
  else printf '  FAIL  %s [%s]\n        want: %s\n        got:  %s\n' "$label" "$impl" "$want" "$got"; fail=1; fi
}
for impl in rust bash; do
  for cols in 150 80; do   # slack exists: exactly 3
    expect "COLUMNS=$cols MCP, gap exactly 3" $impl $cols "" "$MCP$G3$TMUXLESS_TAIL"
    expect "COLUMNS=$cols MCP + RC, gap exactly 3" $impl $cols "v1 on $NOW web" "$MCP$G3$RCCHIP$TMUXLESS_TAIL"
  done
  # COLUMNS=60: no slack for the RC row (floor of 2, same MCP form as main), 3 without RC
  expect "COLUMNS=60 MCP, gap 3" $impl 60 "" "$MCP$G3$TMUXLESS_TAIL"
  expect "COLUMNS=60 MCP + RC, floor gap 2" $impl 60 "v1 on $NOW web" "$MCP$G2$RCCHIP$TMUXLESS_TAIL"
done
(( fail )) && { echo "row3-gap: FAIL"; exit 1; }
echo "row3-gap: PASS"

#!/usr/bin/env bash
# row3-gap.sh - row 3 (MCP readout left, everything else right) must read left to
# right: no run of spaces longer than 3 inside the row, at COLUMNS=150 with MCP
# configured, with and without the RC chip. Both renderers, exact text.
# BIN / SH env override the renderers (used to show the test fails on main).
set -uo pipefail
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
for impl in rust bash; do
  for rc in "" "v1 on $NOW web"; do
    row=$(render $impl 150 "$rc")
    body=$(sed -E 's/ +$//' <<<"$row")
    if [[ -n "$row" && ! "$body" =~ [[:space:]]{4,} ]]; then
      printf '  PASS  COLUMNS=150 MCP%s [%s]\n' "${rc:+ + RC}" $impl
    else
      printf '  FAIL  COLUMNS=150 MCP%s [%s]: gap longer than 3\n        %s\n' "${rc:+ + RC}" $impl "$row"; fail=1
    fi
  done
done
(( fail )) && { echo "row3-gap: FAIL"; exit 1; }
echo "row3-gap: PASS"

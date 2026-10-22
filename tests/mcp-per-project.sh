#!/usr/bin/env bash
# mcp-per-project.sh - the MCP health cache and probe names are keyed per PROJECT dir
# (a 11/11 probed from one project must not show in another). Both renderers.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/rust/target/release/nerdflair-statusline"; SH="$REPO/scripts/statusline.sh"
[[ -x "$BIN" ]] || { echo "mcp-per-project: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-mcpproj-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
mkdir -p "$W/bin" "$W/projA" "$W/projB"; chmod 700 "$W"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/claude"; chmod +x "$W/bin/claude"   # on PATH, never probed (huge TTL)
A=$(cd "$W/projA" && pwd -P); B=$(cd "$W/projB" && pwd -P)
crc() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

render() { # impl dir cachedir
  local impl=$1 dir=$2 c=$3 cmd
  cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  printf '{"session_id":"mp-%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5,"total_duration_ms":600000,"total_api_duration_ms":240000},"context_window":{"used_percentage":20,"context_window_size":200000}}' "$RANDOM" "$dir" "$dir" |
    env -i PATH="$W/bin:$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=160 \
      NERDFLAIR_CACHE_DIR="$c" NERDFLAIR_ERR_STAMP_DIR="$W/st" NERDFLAIR_MCP_HEALTH=1 NERDFLAIR_MCP_HEALTH_TTL=999999999 \
      NERDFLAIR_REPO_COST=0 "${cmd[@]}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
mkdir -p "$W/home"; printf '{"numStartups":7,"mcpServers":{"context7":{"command":"x"}},"projects":{}}' > "$W/home/.claude.json"
for impl in rust bash; do
  c="$W/cache-$impl"; mkdir -m 700 "$c"
  printf '9\x1f0\x1f0\x1falphasrv\x1ebetasrv' > "$c/nerdflair-mcphealth-$(id -u)-$(crc "$A")"
  printf '5\x1f0\x1f0\x1fzzlegacy' > "$c/nerdflair-mcphealth-$(id -u)"
  oa=$(render "$impl" "$A" "$c"); ob=$(render "$impl" "$B" "$c")
  [[ "$oa" == *alphasrv* && "$oa" == *9/9* ]] || { echo "FAIL $impl: project A lost its own cache"; fail=1; }
  [[ "$ob" != *alphasrv* && "$ob" != *9/9* ]] || { echo "FAIL $impl: project A cache leaked into project B"; fail=1; }
  [[ "$oa$ob" != *zzlegacy* ]] || { echo "FAIL $impl: the shared legacy cache is still read"; fail=1; }
done
(( fail )) && exit 1
echo "mcp-per-project: ok"

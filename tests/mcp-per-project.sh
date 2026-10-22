#!/usr/bin/env bash
# mcp-per-project.sh - the MCP health cache and probe names are keyed per PROJECT dir
# (a 11/11 probed from one project must not show in another). Both renderers.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${NF_BIN:-$REPO/rust/target/release/nerdflair-statusline}"; SH="${NF_SH:-$REPO/scripts/statusline.sh}"
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

# ── one key rule for both renderers: cut at a newline, collapse runs of "/", strip a trailing "/" ──────────
for impl in rust bash; do
  c="$W/key-$impl"; mkdir -m 700 "$c"
  printf '9\x1f0\x1f0\x1falphasrv' > "$c/nerdflair-mcphealth-$(id -u)-$(crc "$A")"
  for v in "$A/" "$A//" "/$A" "${A}\\nsub"; do
    o=$(render "$impl" "$v" "$c")
    [[ "$o" == *9/9* ]] || { echo "FAIL $impl: project dir '$v' did not find the cache keyed on '$A'"; fail=1; }
  done
done

# ── a fake claude that records where it ran and can be held until released ──────────────────────────────
cat > "$W/bin/claude" <<'EOS'
#!/bin/sh
pwd -P >> "$NF_PROBE_LOG"
if [ -n "$NF_PROBE_HOLD" ]; then while [ ! -e "$NF_PROBE_HOLD" ]; do sleep 0.1; done; fi
echo "srv: http://x - ✓ Connected"
EOS
chmod +x "$W/bin/claude"
wait_for() { local i; for i in $(seq 1 200); do [[ -e $1 ]] && return 0; sleep 0.05; done; return 1; }  # polls the event file
probe_render() { # impl dir cachedir [extra env...]: no TTL, so the probe runs
  local impl=$1 dir=$2 c=$3 cmd; shift 3
  cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  printf '{"session_id":"pp-%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5},"context_window":{"used_percentage":20,"context_window_size":200000}}' "$RANDOM" "${PROBE_CWD:-$dir}" "$dir" |
    env -i PATH="$W/bin:$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=160 NF_PROBE_LOG="$W/probe.log" \
      NERDFLAIR_CACHE_DIR="$c" NERDFLAIR_ERR_STAMP_DIR="$W/st" NERDFLAIR_MCP_HEALTH=1 NERDFLAIR_REPO_COST=0 "$@" "${cmd[@]}" >/dev/null 2>&1
}
# F4: with NERDFLAIR_MCP_CACHE set the probe still runs from the project dir (Rust always did)
for impl in rust bash; do
  c="$W/f4-$impl"; mkdir -m 700 "$c"; rm -f "$W/probe.log"
  PROBE_CWD="$B" probe_render "$impl" "$A" "$c" NERDFLAIR_MCP_CACHE="$c/override" NERDFLAIR_MCP_HEALTH_TTL=0   # cwd is NOT the project dir
  wait_for "$c/override" || { echo "FAIL $impl: the override probe never wrote its cache"; fail=1; continue; }
  [[ "$(head -n 1 "$W/probe.log")" == "$A" ]] || { echo "FAIL $impl: probe ran in '$(head -n 1 "$W/probe.log")', not in '$A'"; fail=1; }
done
# F6: at most one probe at a time per user; the loser shows the last cached value and probes later
for impl in rust bash; do
  c="$W/f6-$impl"; mkdir -m 700 "$c"; rm -f "$W/probe.log" "$W/release"
  probe_render "$impl" "$A" "$c" NF_PROBE_HOLD="$W/release"
  wait_for "$W/probe.log" || { echo "FAIL $impl: first probe never started"; fail=1; continue; }
  probe_render "$impl" "$B" "$c" NF_PROBE_HOLD="$W/release"
  sleep 1   # a negative needs some time: a second probe would have logged by now
  n=$(wc -l < "$W/probe.log"); [[ $n -eq 1 ]] || { echo "FAIL $impl: $n probes ran at once (want 1)"; fail=1; }
  : > "$W/release"
  wait_for "$c/nerdflair-mcphealth-$(id -u)-$(crc "$A")" || { echo "FAIL $impl: probe A never wrote its cache"; fail=1; }
  probe_render "$impl" "$B" "$c" NF_PROBE_HOLD="$W/release"
  wait_for "$c/nerdflair-mcphealth-$(id -u)-$(crc "$B")" || { echo "FAIL $impl: project B never got its probe after A finished"; fail=1; }
done
# F6: per-project files untouched for 14+ days go in the daily prune, never under --json
U=$(id -u)
for impl in json rust bash; do
  c="$W/pr-$impl"; mkdir -m 700 "$c"; rm -f "$W/probe.log" "$W/release"; : > "$W/release"
  seed() { : > "$c/nerdflair-mcphealth-$U-111"; : > "$c/nerdflair-mcphealth-$U-111.lock"; touch -d '20 days ago' "$c/nerdflair-mcphealth-$U-111" "$c/nerdflair-mcphealth-$U-111.lock"; : > "$c/nerdflair-mcphealth-$U-222"; }
  seed
  if [[ $impl == json ]]; then
    printf '{"session_id":"pj","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5},"context_window":{"used_percentage":20,"context_window_size":200000}}' "$A" "$A" |
      env -i PATH="$W/bin:$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 NF_PROBE_LOG="$W/probe.log" NERDFLAIR_CACHE_DIR="$c" NERDFLAIR_ERR_STAMP_DIR="$W/st" \
        NERDFLAIR_MCP_HEALTH=1 NERDFLAIR_MCP_HEALTH_TTL=999999999 NERDFLAIR_REPO_COST=0 "$BIN" --json >/dev/null 2>&1
    [[ -e "$c/nerdflair-mcphealth-$U-111" && ! -e "$c/nerdflair-mcphealth-prune-$U" ]] || { echo "FAIL --json pruned (or stamped)"; fail=1; }
    continue
  fi
  probe_render "$impl" "$A" "$c" NERDFLAIR_MCP_HEALTH_TTL=999999999
  [[ ! -e "$c/nerdflair-mcphealth-$U-111" && ! -e "$c/nerdflair-mcphealth-$U-111.lock" ]] || { echo "FAIL $impl: stale per-project files were not pruned"; fail=1; }
  [[ -e "$c/nerdflair-mcphealth-$U-222" ]] || { echo "FAIL $impl: a recent per-project file was pruned"; fail=1; }
  seed; probe_render "$impl" "$A" "$c" NERDFLAIR_MCP_HEALTH_TTL=999999999
  [[ -e "$c/nerdflair-mcphealth-$U-111" ]] || { echo "FAIL $impl: prune ran twice within a day"; fail=1; }
done
(( fail )) && exit 1
echo "mcp-per-project: ok"

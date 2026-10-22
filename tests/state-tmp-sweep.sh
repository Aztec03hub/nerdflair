#!/usr/bin/env bash
# state-tmp-sweep.sh - state.json.tmp.<pid> leftovers (a kill between creating the temp and the
# rename) are swept when older than 1 h; a fresh one (a live writer) and a symlink are left alone.
# Also: a failing jq in _nf_write_state leaves no temp file at all. Both renderers, temp HOME.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${NF_BIN:-$REPO/rust/target/release/nerdflair-statusline}"; SH="${NF_SH:-$REPO/scripts/statusline.sh}"
[[ -x "$BIN" ]] || { echo "state-tmp-sweep: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-tmpsweep-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
check() { if [[ "$3" == "$2" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }
for impl in rust bash; do
  H="$W/$impl/home"; S="$H/.claude/nerdflair"; mkdir -p "$S" "$W/$impl/st"; mkdir -m 700 "$W/$impl/c"
  printf '{"mode":"full","width":"auto","flair":true,"terminal_bell":"on","chime_sound":"Glass","chime_volume":"loud","chime_style":"random","chime_events":"Notification,Stop","color":"vibrant","last_session":"","chime_recent_styles":[]}' > "$S/state.json"
  : > "$S/state.json.tmp.111"; touch -d '2 hours ago' "$S/state.json.tmp.111"
  : > "$S/state.json.tmp.222"                                  # fresh: a live writer's
  ln -s /nonexistent "$S/state.json.tmp.333"; touch -h -d '2 hours ago' "$S/state.json.tmp.333"
  cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  printf '{"session_id":"sw-%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5,"total_duration_ms":600000,"total_api_duration_ms":240000},"context_window":{"used_percentage":20,"context_window_size":200000}}' "$impl" "$W" "$W" |
    env -i PATH="$PATH" HOME="$H" NERDFLAIR_CACHE_DIR="$W/$impl/c" NERDFLAIR_ERR_STAMP_DIR="$W/$impl/st" NERDFLAIR_MCP_HEALTH=0 NERDFLAIR_REPO_COST=0 "${cmd[@]}" >/dev/null 2>&1
  check "$impl: the stale temp is swept" absent "$([[ -e "$S/state.json.tmp.111" ]] && echo present || echo absent)"
  check "$impl: a fresh temp is kept" present "$([[ -e "$S/state.json.tmp.222" ]] && echo present || echo absent)"
  check "$impl: a symlink is not touched" present "$([[ -L "$S/state.json.tmp.333" ]] && echo present || echo absent)"
done
# bash only: a jq that fails mid-write must not leave an (empty) temp file behind
mkdir -p "$W/fj/home/.claude/nerdflair" "$W/fj/bin"
printf '#!/bin/sh\nexit 3\n' > "$W/fj/bin/jq"; chmod +x "$W/fj/bin/jq"
out=$(env -i PATH="$W/fj/bin:$PATH" HOME="$W/fj/home" NERDFLAIR_ERR_STAMP_DIR="$W/fj/st" bash -c '
  . "$1"; NF_CUR_MODE=full NF_CUR_WIDTH=auto NF_CUR_TERMINAL_BELL=on NF_CUR_CHIME_SOUND=G NF_CUR_CHIME_VOLUME=l NF_CUR_CHIME_STYLE=r NF_CUR_CHIME_EVENTS=S NF_CUR_COLOR=v NF_CUR_LAST_SESSION=x
  _nf_write_state; echo "rc=$?"' _ "$REPO/scripts/lib.sh" 2>/dev/null | tail -1)
check "bash: a failing jq returns 1" "rc=1" "$out"
check "bash: ...and leaves no temp file" 0 "$(ls "$W/fj/home/.claude/nerdflair" | rg -c 'tmp' || echo 0)"
exit $fail

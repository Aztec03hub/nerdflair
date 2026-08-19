#!/usr/bin/env bash
# Differential harness: bash renderer vs Rust renderer, byte for byte.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BASH_SL="$REPO/scripts/statusline.sh"
RUST_SL="$REPO/rust/target/release/nerdflair-statusline"
FIX=/tmp/nf-fixture
OUT=/tmp/nf-diffout
rm -rf "$OUT"; mkdir -p "$OUT"

"$HERE/mkfixture.sh" "$FIX" >/dev/null
# point the project-scoped MCP block at the real fixture path
python3 - "$FIX" <<'PY'
import json,sys
fix=sys.argv[1]
p=f"{fix}/home/.claude.json"
d=json.load(open(p))
d["projects"][f"{fix}/work/my-project"]=d["projects"].pop("PROJ")
json.dump(d,open(p,"w"),indent=2)
PY

mkdir -p "$FIX/bin"
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ccusage"; chmod +x "$FIX/bin/ccusage"
UIDN=$(id -u)
# Frozen async caches: fresh forever, so neither renderer forks a refresh.
printf '%s' 'Claude Code: $12.34 block (2h 15m left) | $8.50/hr' > "/tmp/nerdflair-ccusage-${UIDN}"
printf '3\x1f1\x1f1' > "/tmp/nerdflair-mcphealth-${UIDN}"
printf '%s\n' \
  "$(( $(date +%s) - 100 ))	sess-old	my-project	1.50" \
  "$(( $(date +%s) - 50 ))	sess-fixed-0001	my-project	3.4567" > "$FIX/usage.tsv"


# Only inspect cache files belonging to THIS fixture: Phil's live statusline
# writes into the same /tmp namespace and would otherwise pollute the diff.
_snap_caches() {
  local dest="$1" h
  : > "$dest"
  while read -r dir; do
    h=$(printf '%s' "$dir" | cksum | cut -d' ' -f1)
    for pat in "/tmp/nerdflair-git-$h" "/tmp/nerdflair-multibranch-$h"; do
      [[ -f "$pat" ]] && { printf '%s: ' "$(basename "$pat")" >> "$dest"; cat "$pat" >> "$dest"; printf '\n' >> "$dest"; }
    done
  done < <(find "$FIX/work" -maxdepth 2 -type d 2>/dev/null; echo "$FIX/work")
  for f in /tmp/nerdflair-repocost-total-${UIDN}-my_project /tmp/nerdflair-repocost-total-${UIDN}-wrapper; do
    [[ -f "$f" ]] && { printf '%s: ' "$(basename "$f")" >> "$dest"; cat "$f" >> "$dest"; printf '\n' >> "$dest"; }
  done
  # strip the epoch column: the two runs happen a moment apart
  cut -f2- "$FIX/usage.live.tsv" >> "$dest" 2>/dev/null
}

_state() {  # $1 = variant keyword
  local mode=full width=auto color=vibrant vol='"1"' style=Vibraphone
  case "$1" in
    compact) mode=compact ;;
    minimal) mode=minimal ;;
    mono)    color=mono ;;
    muted)   color=muted ;;
    compact-mono) mode=compact; color=mono ;;
    fixedwidth) width=120 ;;
    volzero) vol='"0"' ;;
    randomchime) style=random ;;
    volhalf) vol='"0.5"'; style=random ;;
    compact-volzero) mode=compact; vol='"0"' ;;
  esac
  cat > "$FIX/home/.claude/nerdflair/state.json" <<JSON
{
  "mode": "$mode",
  "width": "$width",
  "flair": true,
  "terminal_bell": "on",
  "chime_sound": "Glass",
  "chime_volume": $vol,
  "chime_style": "$style",
  "chime_events": "Notification,PermissionRequest,PreCompact,SessionEnd,SessionStart,Stop",
  "color": "$color",
  "last_session": "sess-fixed-0001",
  "chime_recent_styles": [
    "TapedMarimba"
  ]
}
JSON
}

_clean_caches() {
  rm -f /tmp/nerdflair-git-* /tmp/nerdflair-multibranch-* \
        /tmp/nerdflair-repocost-* /tmp/nerdflair-tmux-* 2>/dev/null
  cp "$FIX/usage.tsv" "$FIX/usage.live.tsv"
}

pass=0; fail=0; failed=()
rm -rf "$FIX.pristine"; cp -a "$FIX" "$FIX.pristine"
PDIR="${PDIR:-$HERE/payloads}"
for pj in "$PDIR"/*.json; do
  rm -rf "$FIX"; cp -a "$FIX.pristine" "$FIX"
  name=$(basename "$pj" .json)
  [[ -n "${ONLY:-}" && "$name" != *"$ONLY"* ]] && continue
  envf="${pj%.json}.env"; statef="${pj%.json}.state"
  variant=default; [[ -f "$statef" ]] && variant=$(cat "$statef")
  extra=(); [[ -f "$envf" ]] && mapfile -t extra < "$envf"

  payload=$(sed -e "s|@FIX@|$FIX|g" -e "s|@HOME@|$FIX/home|g" "$pj")
  pref="${pj%.json}.pre"

  common=(
    "HOME=$FIX/home"
    "PATH=$FIX/bin:$PATH"
    "COLUMNS=120"
    "NERDFLAIR_CCUSAGE_TTL=999999"
    "NERDFLAIR_MCP_HEALTH_TTL=999999"
    "NERDFLAIR_REPO_COST_FILE=$FIX/usage.live.tsv"
    "TERM=xterm-256color"
    "LANG=C.UTF-8"
  )
  [[ ${#extra[@]} -gt 0 ]] && common+=("${extra[@]}")
  if [[ " ${common[*]} " == *"NF_TMUX=1"* ]]; then
    common+=("TMUX_PANE=%99" "TMUX=/tmp/fake,1,0")
  fi
  if [[ " ${common[*]} " == *"NF_UNSET_COLUMNS=1"* ]]; then
    local_common=(); for e in "${common[@]}"; do [[ "$e" == COLUMNS=* || "$e" == NF_UNSET_COLUMNS=* ]] || local_common+=("$e"); done
    common=("${local_common[@]}")
  fi

  _state "$variant"; _clean_caches
  [[ -f "$pref" ]] && FIX="$FIX" bash "$pref" >/dev/null 2>&1
  printf '%s' "$payload" | env -u TMUX_PANE -u TMUX -i "${common[@]}" bash "$BASH_SL" > "$OUT/$name.bash" 2>"$OUT/$name.bash.err"
  cp "$FIX/home/.claude/nerdflair/state.json" "$OUT/$name.bash.state"
  _snap_caches "$OUT/$name.bash.caches"

  _state "$variant"; _clean_caches
  [[ -f "$pref" ]] && FIX="$FIX" bash "$pref" >/dev/null 2>&1
  printf '%s' "$payload" | env -u TMUX_PANE -u TMUX -i "${common[@]}" "$RUST_SL" > "$OUT/$name.rust" 2>"$OUT/$name.rust.err"
  cp "$FIX/home/.claude/nerdflair/state.json" "$OUT/$name.rust.state"
  _snap_caches "$OUT/$name.rust.caches"

  if cmp -s "$OUT/$name.bash" "$OUT/$name.rust"; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed+=("$name")
  fi
done
cbad=0
for f in "$OUT"/*.bash.caches; do n=$(basename "$f" .bash.caches); cmp -s "$f" "$OUT/$n.rust.caches" || { echo "CACHE DIFF: $n"; cbad=$((cbad+1)); }; done
sbad=0
for f in "$OUT"/*.bash.state; do n=$(basename "$f" .bash.state); cmp -s "$f" "$OUT/$n.rust.state" || { echo "STATE DIFF: $n"; sbad=$((sbad+1)); }; done
echo "cache-identical: $(( $(ls "$OUT"/*.bash.caches | wc -l) - cbad ))/$(ls "$OUT"/*.bash.caches | wc -l)"
echo "state-identical: $(( $(ls "$OUT"/*.bash.state | wc -l) - sbad ))/$(ls "$OUT"/*.bash.state | wc -l)"
echo "byte-identical: $pass/$((pass+fail))"
if (( fail > 0 )); then
  printf 'FAILED: %s\n' "${failed[@]}"
fi

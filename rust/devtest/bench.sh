#!/usr/bin/env bash
# Median wall-clock over N runs, timed with EPOCHREALTIME (no fork per sample).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
N=${N:-120}
PAYLOAD=$(cat "${1:-$HERE/bench-payload.json}")
_median() {
  local -n arr=$1
  local sorted; mapfile -t sorted < <(printf '%s\n' "${arr[@]}" | sort -n)
  local n=${#sorted[@]}
  echo "${sorted[$((n/2))]}"
}
_run() {
  local label="$1"; shift
  local -a times=()
  for _ in $(seq 1 5); do printf '%s' "$PAYLOAD" | "$@" >/dev/null 2>&1; done   # warm
  for _ in $(seq 1 "$N"); do
    local t0=${EPOCHREALTIME/./}
    printf '%s' "$PAYLOAD" | "$@" >/dev/null 2>&1
    local t1=${EPOCHREALTIME/./}
    times+=( $(( t1 - t0 )) )
  done
  local med; med=$(_median times)
  local sorted; mapfile -t sorted < <(printf '%s\n' "${times[@]}" | sort -n)
  printf '%-8s n=%d  median=%6.3f ms   p10=%6.3f  p90=%6.3f\n' "$label" "$N" \
    "$(bc -l <<< "$med/1000")" \
    "$(bc -l <<< "${sorted[$((N/10))]}/1000")" \
    "$(bc -l <<< "${sorted[$((N*9/10))]}/1000")"
}
_run bash bash "$REPO/scripts/statusline.sh"
_run rust "$REPO/rust/target/release/nerdflair-statusline"

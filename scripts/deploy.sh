#!/usr/bin/env bash
# deploy.sh - the one command after a pull: rebuild and reinstall only what is out of date.
#
#   scripts/deploy.sh [--dry-run]
#
# The stamps are compared first (by doctor: renderer src hash, plugin version, hover file
# copies); only the steps whose stamp differs run, then doctor runs again to show the result.
# --dry-run prints the plan and changes nothing.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dry=0; [[ "${1:-}" == "--dry-run" ]] && dry=1

# doctor exits 1 when something is BROKEN, which is exactly the case this script is for.
report="$(bash "$REPO/scripts/doctor.sh" --json || true)"
status() { jq -r --arg c "$1" '.checks[] | select(.check == $c) | .status' <<<"$report"; }

steps=(); follow=()
# A step runs for a BROKEN stamp only: hover not installed at all is a warn, and deploy refreshes, it never opts you in.
[[ "$(status renderer)" == BROKEN ]] && { steps+=("$REPO/scripts/build-rust.sh"); follow+=("renderer: picked up on the next status line refresh"); }
[[ "$(status hover)" == BROKEN ]] && { steps+=("$REPO/band/hover/install.sh"); follow+=("hover: open new shells (running ones keep the old wrapper)"); }
[[ "$(status plugin)" == BROKEN ]] && { steps+=("$REPO/band/sync-local-plugin.sh"); follow+=("band plugin: run /reload-plugins in every open session"); }

if (( ${#steps[@]} == 0 )); then
  echo "deploy: renderer, hover and band plugin already match this checkout; nothing to do"
else
  echo "deploy: $( (( dry )) && echo would run || echo running ):"
  printf '  bash %s\n' "${steps[@]}"
fi
if (( dry )); then
  (( ${#follow[@]} )) && { echo "then:"; printf '  %s\n' "${follow[@]}"; }
  exit 0
fi
for s in "${steps[@]}"; do echo "== bash $s"; bash "$s"; done
echo "== doctor"
rc=0; bash "$REPO/scripts/doctor.sh" || rc=$?
(( ${#follow[@]} )) && { echo "follow-ups:"; printf '  %s\n' "${follow[@]}"; }
exit "$rc"

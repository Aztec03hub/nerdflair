#!/usr/bin/env bash
# deploy.sh - the one command after a pull: rebuild and reinstall only what is out of date.
#
#   scripts/deploy.sh [--dry-run] [--from-worktree]
#
# The stamps are compared first (by doctor: renderer src hash, plugin version, hover file
# copies); only the steps whose stamp differs run, then doctor runs again to show the result.
# --dry-run prints the plan and changes nothing. It refuses to run from a git worktree (it would
# install the worktree over the real install) unless --from-worktree is given.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dry=0; wt=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --from-worktree) wt=1 ;;
    -h|--help) echo "usage: deploy.sh [--dry-run] [--from-worktree]"; exit 0 ;;
    *) echo "deploy: unknown argument '$a'" >&2; echo "usage: deploy.sh [--dry-run] [--from-worktree]" >&2; exit 2 ;;
  esac
done
echo "deploy: checkout $REPO"
if [[ "$(git -C "$REPO" rev-parse --git-dir 2>/dev/null)" != "$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null)" ]] && (( ! wt )); then
  echo "deploy: $REPO is a git worktree; deploying from it would install the worktree's build and hover/plugin copies over the real install (and break the hover link when the worktree is removed). Run it from the main checkout, or pass --from-worktree." >&2
  exit 2
fi

# doctor exits 1 when something is BROKEN, which is exactly the case this script is for.
report="$(bash "$REPO/scripts/doctor.sh" --json || true)"
jq -e '.checks | length > 0' <<<"$report" >/dev/null 2>&1 || { echo "deploy: doctor produced no report (is jq installed?); nothing was changed" >&2; exit 2; }
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

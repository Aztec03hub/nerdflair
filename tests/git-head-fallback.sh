#!/usr/bin/env bash
# git-head-fallback.sh - when git hangs (or is missing) the branch still shows, read from
# .git/HEAD: plain repo, subdirectory, linked worktree (.git is a file), detached HEAD.
# A fake `git` that sleeps stands in for a hung filesystem. Both renderers.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${NF_BIN:-$REPO/rust/target/release/nerdflair-statusline}"; SH="${NF_SH:-$REPO/scripts/statusline.sh}"
[[ -x "$BIN" ]] || { echo "git-head-fallback: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-headfb-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
G() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }
mkdir -p "$W/repo/sub/deep" "$W/home" "$W/hang"
( cd "$W/repo" && G init -q && G commit -q --allow-empty -m one && G checkout -q -b feature-x \
  && G worktree add -q -b wt-branch "$W/wt" && G worktree add -q --detach "$W/dt" ) >/dev/null 2>&1 \
  || { echo "git-head-fallback: setup failed" >&2; exit 2; }
SHA=$(cd "$W/repo" && git rev-parse HEAD); SHORT=${SHA:0:7}
printf '#!/bin/sh\nexec sleep 30\n' > "$W/hang/git"; chmod +x "$W/hang/git"

render() { # impl dir
  local impl=$1 dir=$2 d="$W/c-$1-$RANDOM" cmd
  mkdir -m 700 "$d"; cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  printf '{"session_id":"hb-%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5,"total_duration_ms":600000,"total_api_duration_ms":240000},"context_window":{"used_percentage":20,"context_window_size":200000}}' "$RANDOM" "$dir" "$dir" |
    env -i PATH="$W/hang:$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=160 \
      NERDFLAIR_CACHE_DIR="$d" NERDFLAIR_ERR_STAMP_DIR="$W/st-$RANDOM" NERDFLAIR_PROC_TIMEOUT_MS=300 \
      NERDFLAIR_MCP_HEALTH=0 NERDFLAIR_REPO_COST=0 "${cmd[@]}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
for impl in rust bash; do
  while IFS='|' read -r label dir want; do
    out=$(render "$impl" "$dir" | head -n 1)
    [[ "$out" == *"$want"* ]] || { echo "FAIL $impl $label: want '$want' in: $out"; fail=1; }
  done <<EOF
repo|$W/repo|feature-x
subdir|$W/repo/sub/deep|feature-x
worktree|$W/wt|wt-branch
detached|$W/dt|$SHORT
EOF
done
(( fail )) && exit 1
echo "git-head-fallback: ok"

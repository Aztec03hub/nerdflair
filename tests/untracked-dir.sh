#!/usr/bin/env bash
# untracked-dir.sh - git lists a nested worktree or nested repo as an untracked DIRECTORY
# (`nested/`). The renderer read it like a file, failed with "Is a directory" and logged
# `git-untracked-read` every refresh. Directories are skipped; real untracked files still count.
# Both renderers, temp HOME, private cache and stamp dirs.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${NF_BIN:-$REPO/rust/target/release/nerdflair-statusline}"; SH="${NF_SH:-$REPO/scripts/statusline.sh}"
[[ -x "$BIN" ]] || { echo "untracked-dir: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-untrdir-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
check() { if [[ "$3" == "$2" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }
G() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }
mkdir -p "$W/repo" "$W/home/.claude/nerdflair"
( cd "$W/repo" && G init -q && G commit -q --allow-empty -m one \
  && G worktree add -q -b wt "$W/repo/nested-wt" \
  && mkdir nested-repo && cd nested-repo && G init -q && G commit -q --allow-empty -m n \
  && cd .. && printf 'a\nb\nc\n' > three.txt ) >/dev/null 2>&1 || { echo "untracked-dir: setup failed" >&2; exit 2; }
for impl in rust bash; do
  c="$W/c-$impl"; mkdir -m 700 "$c"; mkdir "$W/st-$impl"; cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  out=$(printf '{"session_id":"ud-%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5,"total_duration_ms":600000,"total_api_duration_ms":240000},"context_window":{"used_percentage":20,"context_window_size":200000}}' "$impl" "$W/repo" "$W/repo" |
    env -i PATH="$PATH" HOME="$W/home" TZ=UTC LC_ALL=C.UTF-8 COLUMNS=200 NERDFLAIR_CACHE_DIR="$c" NERDFLAIR_ERR_STAMP_DIR="$W/st-$impl" \
      NERDFLAIR_MCP_HEALTH=0 NERDFLAIR_REPO_COST=0 "${cmd[@]}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -n 1)
  check "$impl: three untracked lines are +3" 1 "$([[ "$out" == *"+3"* && "$out" != *"+3"[0-9]* ]] && echo 1 || echo 0)"
  check "$impl: no git-untracked-read line" 0 "$(rg -c 'git-untracked-read' "$W/home/.claude/nerdflair-errors.log" 2>/dev/null || echo 0)"
  : > "$W/home/.claude/nerdflair-errors.log"
done
exit $fail

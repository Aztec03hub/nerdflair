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
# ── hostile and odd HEAD contents: both renderers must clean them identically ──────────────────────────
# fake repos (a .git dir with HEAD): git is hung, so HEAD is the only source. `want` is what must show;
# ESC and the other control bytes are removed (so what is left of an escape sequence is plain text).
ESC=$'\x1b'; BEL=$'\x07'
n=0
mkcase() { # label head-bytes(printf format) want -> creates $W/h$n/.git/HEAD; prints the dir
  local d="$W/hc$RANDOM$RANDOM"; mkdir -p "$d/.git/refs"; printf "$2" > "$d/.git/HEAD"; echo "$d"
}
check_pair() { # label dir want
  local r b; r=$(render rust "$2" | head -n 1); b=$(render bash "$2" | head -n 1)
  [[ "$r" == *"$3"* ]] || { echo "FAIL rust $1: want '$3' in: $r"; fail=1; }
  [[ "$b" == *"$3"* ]] || { echo "FAIL bash $1: want '$3' in: $b"; fail=1; }
  [[ "$r" == "$b" ]] || { echo "FAIL $1: rust and bash differ:"; echo "  rust: $r"; echo "  bash: $b"; fail=1; }
  [[ "$r$b" != *"$ESC]"* && "$r$b" != *"$BEL"* ]] || { echo "FAIL $1: control bytes reached the output"; fail=1; }
}
check_pair "escape sequence" "$(mkcase x 'ref: refs/heads/a\033[31mRED\033[0m\n')" 'a[31mRED[0m'
check_pair "OSC title" "$(mkcase x 'ref: refs/heads/a\033]0;pwn\007b\n')" 'a]0;pwnb'
check_pair "CRLF" "$(mkcase x 'ref: refs/heads/feat\r\n')" 'feat'
check_pair "CR inside" "$(mkcase x 'ref: refs/heads/fe\rat\n')" 'feat'
check_pair "NUL" "$(mkcase x 'ref: refs/heads/fe\000at\n')" 'feat'
check_pair "invalid UTF-8" "$(mkcase x 'ref: refs/heads/fe\377at\n')" 'feat'
check_pair "truncated UTF-8" "$(mkcase x 'ref: refs/heads/fe\342\202at\n')" 'feat'
check_pair "C1 control" "$(mkcase x 'ref: refs/heads/a\302\205b\n')" 'ab'
check_pair "trailing spaces" "$(mkcase x 'ref: refs/heads/trail   \n')" 'trail'
# a `.git` FILE whose gitdir line ends in a space (and CR)
n=$((n + 1)); d="$W/h$n"; mkdir -p "$d/real.git/refs" "$d/wt"; printf 'ref: refs/heads/spaced\n' > "$d/real.git/HEAD"
printf 'gitdir: %s/real.git \r\n' "$d" > "$d/wt/.git"
check_pair "gitdir trailing space and CR" "$d/wt" 'spaced'
# bounded read: a first line longer than 4 KiB is cut at 4096 bytes in both, and a 20 MB HEAD costs nothing
n=$((n + 1)); d="$W/h$n"; mkdir -p "$d/.git/refs"
{ printf 'ref: refs/heads/'; head -c 20000000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$d/.git/HEAD"
t0=$EPOCHREALTIME; check_pair "huge HEAD" "$d" 'xxxx'; t1=$EPOCHREALTIME
(( (${t1/./} - ${t0/./}) / 1000 < 6000 )) || { echo "FAIL huge HEAD: took too long"; fail=1; }
# a bare repo nested inside a repo: its own branch, not the outer one
n=$((n + 1)); d="$W/h$n"; mkdir -p "$d/.git/refs" "$d/inner.git/refs"
printf 'ref: refs/heads/outer-branch\n' > "$d/.git/HEAD"; printf 'ref: refs/heads/inner-branch\n' > "$d/inner.git/HEAD"
check_pair "nested bare repo" "$d/inner.git" 'inner-branch'
r=$(render rust "$d/inner.git" | head -n 1); [[ "$r" != *outer-branch* ]] || { echo "FAIL nested bare repo: outer branch shown"; fail=1; }
(( fail )) && exit 1
echo "git-head-fallback: ok"

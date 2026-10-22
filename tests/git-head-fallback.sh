#!/usr/bin/env bash
# git-head-fallback.sh - when git hangs (or is missing) the branch still shows, read from
# .git/HEAD: plain repo, subdirectory, linked worktree (.git is a file), detached HEAD.
# A fake `git` that sleeps stands in for a hung filesystem. Both renderers.
#
# Usage: git-head-fallback.sh [--part N/M] [--list]
#   no argument   run every case (the default)
#   --part N/M    run the cases whose position (1-based, script order) satisfies (pos-1) % M == N-1; the M parts
#                 together run every case exactly once. Most of the time is renders waiting out the 300 ms hung git.
#   --list        print the case names (with --part: only that part's) and run nothing
set -uo pipefail
PART_N=1; PART_M=1; LIST=0
while (( $# )); do
  case "$1" in
    --part) [[ "${2:-}" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] && (( BASH_REMATCH[1] <= BASH_REMATCH[2] )) \
              || { echo "git-head-fallback: --part wants N/M with 1 <= N <= M, got '${2:-}'" >&2; exit 2; }
            PART_N=${BASH_REMATCH[1]}; PART_M=${BASH_REMATCH[2]}; shift 2 ;;
    --list) LIST=1; shift ;;
    *) echo "git-head-fallback: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
UNIT_POS=0
unit_on() { # name -> true when this part runs the case; --list prints it instead
  UNIT_POS=$((UNIT_POS + 1))
  (( (UNIT_POS - 1) % PART_M == PART_N - 1 )) || return 1
  if (( LIST )); then printf '%s\n' "$1"; return 1; fi
  return 0
}
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${NF_BIN:-$REPO/rust/target/release/nerdflair-statusline}"; SH="${NF_SH:-$REPO/scripts/statusline.sh}"
(( LIST )) || [[ -x "$BIN" ]] || { echo "git-head-fallback: not built: $BIN" >&2; exit 2; }
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
    unit_on "$impl $label" || continue
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
UNIT_ON=0
check_pair() { # label dir want
  UNIT_ON=0; unit_on "$1" || return 0; UNIT_ON=1
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
check_pair "above U+10FFFF" "$(mkcase x 'ref: refs/heads/a\364\220\200\200b\n')" 'ab'
check_pair "5-byte form" "$(mkcase x 'ref: refs/heads/a\370\210\200\200\200b\n')" 'ab'
check_pair "surrogate" "$(mkcase x 'ref: refs/heads/a\355\240\200b\n')" 'ab'
check_pair "valid 4-byte char" "$(mkcase x 'ref: refs/heads/a\360\237\230\200b\n')" 'a😀b'
check_pair "control byte between UTF-8 bytes" "$(mkcase x 'ref: refs/heads/a\342\001\202\254b\n')" 'ab'
check_pair "trailing spaces" "$(mkcase x 'ref: refs/heads/trail   \n')" 'trail'
# a `.git` FILE whose gitdir line ends in a space (and CR)
n=$((n + 1)); d="$W/h$n"; mkdir -p "$d/real.git/refs" "$d/wt"; printf 'ref: refs/heads/spaced\n' > "$d/real.git/HEAD"
printf 'gitdir: %s/real.git \r\n' "$d" > "$d/wt/.git"
check_pair "gitdir trailing space and CR" "$d/wt" 'spaced'
# bounded read: a first line longer than 4 KiB is cut at 4096 bytes in both, and a 20 MB HEAD costs nothing
n=$((n + 1)); d="$W/h$n"; mkdir -p "$d/.git/refs"
{ printf 'ref: refs/heads/'; head -c 20000000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$d/.git/HEAD"
# CPU time (user+sys of the renders), not wall time: under load wall time measures the scheduler. The hung git sleeps, it costs no CPU.
TIMEFORMAT='%3U %3S'; { time check_pair "huge HEAD" "$d" 'xxxx'; } 2> "$W/cpu"; read -r cu cs < <(tail -n 1 "$W/cpu")
(( UNIT_ON )) && { cpu_ms=$(( 10#${cu/./} + 10#${cs/./} )); echo "huge HEAD: ${cpu_ms} ms CPU"
  (( cpu_ms < ${NF_HEADFB_BUDGET_MS:-6000} )) || { echo "FAIL huge HEAD: ${cpu_ms} ms CPU"; fail=1; }; }
# a bare repo nested inside a repo: its own branch, not the outer one
n=$((n + 1)); d="$W/h$n"; mkdir -p "$d/.git/refs" "$d/inner.git/refs"
printf 'ref: refs/heads/outer-branch\n' > "$d/.git/HEAD"; printf 'ref: refs/heads/inner-branch\n' > "$d/inner.git/HEAD"
check_pair "nested bare repo" "$d/inner.git" 'inner-branch'
(( UNIT_ON )) && { r=$(render rust "$d/inner.git" | head -n 1); [[ "$r" != *outer-branch* ]] || { echo "FAIL nested bare repo: outer branch shown"; fail=1; }; }
# without a working iconv bash must not silently show nothing: printable ASCII, and the cause is logged
mkdir -p "$W/noiconv"; printf '#!/bin/sh\nexit 127\n' > "$W/noiconv/iconv"; chmod +x "$W/noiconv/iconv"
if unit_on "no iconv: ASCII branch and logged cause"; then
d=$(mkcase x 'ref: refs/heads/feat\303\251x\n')
cmd=(bash "$SH"); [[ -x "$BIN" ]] || true
nd="$W/c-noiconv"; mkdir -m 700 "$nd"; rm -f "$W/home/.claude/nerdflair-errors.log"
o=$(printf '{"session_id":"ni","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"}}' "$d" "$d" |
  env -i PATH="$W/noiconv:$W/hang:$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=160 NERDFLAIR_CACHE_DIR="$nd" \
    NERDFLAIR_ERR_STAMP_DIR="$W/st-noiconv" NERDFLAIR_PROC_TIMEOUT_MS=300 NERDFLAIR_MCP_HEALTH=0 NERDFLAIR_REPO_COST=0 "${cmd[@]}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -n 1)
[[ "$o" == *featx* ]] || { echo "FAIL no iconv: want the ASCII branch 'featx' in: $o"; fail=1; }
rg -q 'git-branch-fallback-noiconv' "$W/home/.claude/nerdflair-errors.log" 2>/dev/null || { echo "FAIL no iconv: the cause was not logged"; fail=1; }
fi
# no iconv: the ASCII-only cut applies to the branch, not to the gitdir path (a non-ASCII worktree path keeps its branch)
if unit_on "no iconv: non-ASCII gitdir path keeps its branch"; then
nd="$W/c-noiconv2"; mkdir -m 700 "$nd"
d="$W/wt-é"; mkdir -p "$d/real.git/refs" "$d/wt"; printf 'ref: refs/heads/wtbranch\n' > "$d/real.git/HEAD"
printf 'gitdir: %s/real.git\n' "$d" > "$d/wt/.git"
o=$(printf '{"session_id":"ni2","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"}}' "$d/wt" "$d/wt" |
  env -i PATH="$W/noiconv:$W/hang:$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=160 NERDFLAIR_CACHE_DIR="$nd" \
    NERDFLAIR_ERR_STAMP_DIR="$W/st-noiconv2" NERDFLAIR_PROC_TIMEOUT_MS=300 NERDFLAIR_MCP_HEALTH=0 NERDFLAIR_REPO_COST=0 bash "$SH" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -n 1)
[[ "$o" == *wtbranch* ]] || { echo "FAIL no iconv: non-ASCII gitdir path lost its branch: $o"; fail=1; }
fi
(( LIST )) && exit 0
(( fail )) && exit 1
echo "git-head-fallback: ok"

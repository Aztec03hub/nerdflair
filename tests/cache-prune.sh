#!/usr/bin/env bash
# cache-prune.sh - the daily cache-dir prune also removes per-session repo-cost stamps and orphan
# `*.tmp.*` files 14+ days old. Never the -total- memo, never a young file, never a directory,
# never a symlink or a foreign-named file, never in --json; NERDFLAIR_MCP_PRUNE_DAYS sets the age. Both renderers, temp HOME and cache dir.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${NF_BIN:-$REPO/rust/target/release/nerdflair-statusline}"; SH="${NF_SH:-$REPO/scripts/statusline.sh}"
[[ -x "$BIN" ]] || { echo "cache-prune: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-cprune-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
check() { if [[ "$3" == "$2" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }
here() { [[ -e "$1" || -L "$1" ]] && echo present || echo absent; }
mkdir -p "$W/bin" "$W/home" "$W/proj"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/claude"; chmod +x "$W/bin/claude"
U=$(id -u)
render() { # impl cachedir [--json | VAR=val]
  local impl=$1 c=$2 cmd extra=() a; shift 2
  for a in "$@"; do [[ $a == *=* ]] && extra+=("$a"); done
  set -- $(for a in "$@"; do [[ $a != *=* ]] && echo "$a"; done)
  cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  printf '{"session_id":"cp-live","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5},"context_window":{"used_percentage":20,"context_window_size":200000}}' "$W/proj" "$W/proj" |
    env -i PATH="$W/bin:$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=160 NERDFLAIR_CACHE_DIR="$c" NERDFLAIR_ERR_STAMP_DIR="$W/st" \
      NERDFLAIR_MCP_HEALTH=1 NERDFLAIR_MCP_HEALTH_TTL=999999999 NERDFLAIR_REPO_COST=0 ${extra[@]+"${extra[@]}"} "${cmd[@]}" "$@" >/dev/null 2>&1
}
seed() { # cachedir
  local c=$1
  : > "$c/nerdflair-old.tmp.4242";                  touch -d '20 days ago' "$c/nerdflair-old.tmp.4242"
  : > "$c/nerdflair-young.tmp.4243";                touch -d '2 days ago' "$c/nerdflair-young.tmp.4243"
  : > "$c/nerdflair-repocost-$U-oldsid";  touch -d '20 days ago' "$c/nerdflair-repocost-$U-oldsid"
  : > "$c/nerdflair-repocost-$U-newsid";  touch -d '3 days ago' "$c/nerdflair-repocost-$U-newsid"
  : > "$c/nerdflair-repocost-total-$U-memo"; touch -d '20 days ago' "$c/nerdflair-repocost-total-$U-memo"
  : > "$c/foreign.tmp.5";                 touch -d '20 days ago' "$c/foreign.tmp.5"
  mkdir "$c/nerdflair-dir.tmp.1";                   touch -d '20 days ago' "$c/nerdflair-dir.tmp.1"
  : > "$W/outside"; touch -d '20 days ago' "$W/outside"
  ln -s "$W/outside" "$c/nerdflair-link.tmp.9";     touch -h -d '20 days ago' "$c/nerdflair-link.tmp.9"
}
for impl in rust bash; do
  c="$W/c-$impl"; mkdir -m 700 "$c"; seed "$c"
  if [[ $impl == rust ]]; then   # --json is a Rust-only flag (the band's call)
    render "$impl" "$c" --json                     # --json never prunes
    check "$impl: --json leaves the old tmp" present "$(here "$c/nerdflair-old.tmp.4242")"
    check "$impl: --json leaves the old stamp" present "$(here "$c/nerdflair-repocost-$U-oldsid")"
  fi
  render "$impl" "$c"
  check "$impl: old tmp is pruned" absent "$(here "$c/nerdflair-old.tmp.4242")"
  check "$impl: young tmp is kept" present "$(here "$c/nerdflair-young.tmp.4243")"
  check "$impl: old per-session stamp is pruned" absent "$(here "$c/nerdflair-repocost-$U-oldsid")"
  check "$impl: recent per-session stamp is kept" present "$(here "$c/nerdflair-repocost-$U-newsid")"
  check "$impl: the -total- memo is kept" present "$(here "$c/nerdflair-repocost-total-$U-memo")"
  check "$impl: a directory is kept" present "$(here "$c/nerdflair-dir.tmp.1")"
  check "$impl: an old symlink is skipped (like the MCP prune)" present "$(here "$c/nerdflair-link.tmp.9")"
  check "$impl: ...and its target is untouched" present "$(here "$W/outside")"
  check "$impl: a tmp file not named nerdflair-* is kept" present "$(here "$c/foreign.tmp.5")"
  # NERDFLAIR_MCP_PRUNE_DAYS is honoured: 30 days keeps a 20-day-old file
  c2="$W/d-$impl"; mkdir -m 700 "$c2"; seed "$c2"
  render "$impl" "$c2" NERDFLAIR_MCP_PRUNE_DAYS=30
  check "$impl: PRUNE_DAYS=30 keeps a 20-day-old tmp" present "$(here "$c2/nerdflair-old.tmp.4242")"
  check "$impl: PRUNE_DAYS=30 keeps a 20-day-old stamp" present "$(here "$c2/nerdflair-repocost-$U-oldsid")"
done
exit $fail

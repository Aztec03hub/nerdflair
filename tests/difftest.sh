#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# difftest.sh — correctness gate for the bash → Rust statusline port.
#
#   For every payload in tests/payloads/, run BOTH implementations under an
#   identical, fully-pinned environment and require their stdout to be
#   BYTE-IDENTICAL. Exit status and stderr emptiness are compared too.
#
# Usage:
#   ./difftest.sh                          bash vs rust (falls back to bash vs bash)
#   ./difftest.sh --rust target/release/nerdflair-statusline
#   ./difftest.sh --bash /path/to/other/statusline.sh    (A/B two bash copies)
#   ./difftest.sh --bash-rev 18b1887       pin side A to a git revision
#   ./difftest.sh --only 42                run a single case
#   ./difftest.sh --only 40-60             run a range
#   ./difftest.sh --verbose                show a diff for every case, not just failures
#   ./difftest.sh --list                   print the corpus index and exit
#   ./difftest.sh --normalize-countdown    mask rate-limit countdowns before comparing
#   ./difftest.sh --rebuild-fixtures       force git fixture rebuild
#   ./difftest.sh --keep                   keep the run directory for inspection
#
# Everything the script under test can observe is pinned; see README section
# "Environment pinning" in worklogs/difftest-harness.md.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
PAYLOAD_DIR="$TESTS_DIR/payloads"

BASH_IMPL="$REPO_ROOT/scripts/statusline.sh"
BASH_IMPL_B=""                       # optional second bash impl (A/B mode)
BASH_REV=""                          # git rev to extract side A from
RUST_IMPL="$REPO_ROOT/rust/target/release/nerdflair-statusline"
ONLY=""
VERBOSE=0
LIST_ONLY=0
NORMALIZE_COUNTDOWN=0
REBUILD_FIXTURES=0
KEEP=0

while (( $# )); do
  case "$1" in
    --rust)  RUST_IMPL="$2"; shift 2 ;;
    --bash)  BASH_IMPL_B="$2"; shift 2 ;;
    --bash-rev) BASH_REV="$2"; shift 2 ;;
    --bash-a) BASH_IMPL="$2"; shift 2 ;;
    --only)  ONLY="$2"; shift 2 ;;
    --verbose|-v) VERBOSE=1; shift ;;
    --list)  LIST_ONLY=1; shift ;;
    --normalize-countdown) NORMALIZE_COUNTDOWN=1; shift ;;
    --rebuild-fixtures) REBUILD_FIXTURES=1; shift ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'difftest: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ── Pin side A to a git revision when asked ──────────────────────────────────
# The working-tree copy of scripts/statusline.sh is NOT frozen: a concurrent
# porting session can edit it underneath a run. --bash-rev extracts the script
# and its lib from a named revision so the gate has a stable reference.
if [[ -n "$BASH_REV" ]]; then
  _revdir=$(mktemp -d /tmp/nerdflair-difftest-rev.XXXXXX)
  git -C "$REPO_ROOT" show "${BASH_REV}:scripts/statusline.sh" > "$_revdir/statusline.sh" || exit 2
  git -C "$REPO_ROOT" show "${BASH_REV}:scripts/lib.sh"        > "$_revdir/lib.sh"        || exit 2
  chmod +x "$_revdir/statusline.sh"
  BASH_IMPL="$_revdir/statusline.sh"
fi

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'

# ── Pick the two sides ───────────────────────────────────────────────────────
SIDE_A_NAME="bash"; SIDE_A="$BASH_IMPL"
if [[ -n "$BASH_IMPL_B" ]]; then
  SIDE_B_NAME="bash-b"; SIDE_B="$BASH_IMPL_B"; MODE="bash-vs-bash"
elif [[ -x "$RUST_IMPL" ]]; then
  SIDE_B_NAME="rust"; SIDE_B="$RUST_IMPL"; MODE="bash-vs-rust"
else
  SIDE_B_NAME="bash"; SIDE_B="$BASH_IMPL"; MODE="bash-vs-bash (self)"
  printf '%s! Rust binary not found at %s — running bash vs bash (self-consistency only).%s\n' \
    "$C_YEL" "$RUST_IMPL" "$C_RST" >&2
fi
[[ -x "$SIDE_A" ]] || { printf 'difftest: side A not executable: %s\n' "$SIDE_A" >&2; exit 2; }
[[ -x "$SIDE_B" ]] || { printf 'difftest: side B not executable: %s\n' "$SIDE_B" >&2; exit 2; }

# ── Serialise concurrent difftest runs (shared /tmp cache paths) ─────────────
LOCKFILE="/tmp/nerdflair-difftest.lock"
exec 9>"$LOCKFILE"
flock -w 300 9 || { echo "difftest: another run holds the lock" >&2; exit 2; }

# ── Shared /tmp caches the script hard-codes: snapshot and restore ───────────
# statusline.sh writes /tmp/nerdflair-ccusage-$UID and /tmp/nerdflair-mcphealth-$UID
# with no override hook. Those are Phil's LIVE caches. Save them now, restore on
# exit, so a difftest run never leaves the real statusline holding our fixtures.
RUN_DIR=$(mktemp -d /tmp/nerdflair-difftest.XXXXXX)
SHARED_CACHES=("/tmp/nerdflair-ccusage-${UID}" "/tmp/nerdflair-mcphealth-${UID}")
for f in "${SHARED_CACHES[@]}"; do
  [[ -e "$f" ]] && cp -a "$f" "$RUN_DIR/$(basename "$f").orig"
done
_cleanup() {
  local f
  for f in "${SHARED_CACHES[@]}"; do
    if [[ -e "$RUN_DIR/$(basename "$f").orig" ]]; then
      cp -a "$RUN_DIR/$(basename "$f").orig" "$f" 2>/dev/null
    else
      rm -f "$f" 2>/dev/null
    fi
    rm -f "${f}.tmp" 2>/dev/null; rmdir "${f}.lock" 2>/dev/null
  done
  if (( KEEP )); then
    printf '%srun dir kept: %s%s\n' "$C_DIM" "$RUN_DIR" "$C_RST" >&2
  else
    rm -rf "$RUN_DIR"
  fi
}
trap _cleanup EXIT

# ═════════════════════════════════════════════════════════════════════════════
# Git fixtures
# ═════════════════════════════════════════════════════════════════════════════
FIXROOT="/tmp/nerdflair-difftest-fixtures"
FIX_STAMP="$FIXROOT/.built-v3"

_gitq() { git -c protocol.file.allow=always "$@" >/dev/null 2>&1; }

build_fixtures() {
  rm -rf "$FIXROOT"; mkdir -p "$FIXROOT"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME="Fixture" GIT_AUTHOR_EMAIL="fixture@example.invalid"
  export GIT_COMMITTER_NAME="Fixture" GIT_COMMITTER_EMAIL="fixture@example.invalid"
  export GIT_AUTHOR_DATE="2020-01-01T00:00:00+0000"
  export GIT_COMMITTER_DATE="2020-01-01T00:00:00+0000"

  # mkrepo <dir> [branch]
  mkrepo() {
    local d="$1" br="${2:-main}"
    mkdir -p "$d"
    _gitq init -q -b "$br" "$d"
    _gitq -C "$d" config user.name Fixture
    _gitq -C "$d" config user.email fixture@example.invalid
    _gitq -C "$d" config commit.gpgsign false
    printf 'line one\nline two\nline three\n' > "$d/README.md"
    _gitq -C "$d" add README.md
    _gitq -C "$d" commit -q -m "initial commit"
  }
  addremote() { _gitq -C "$1" remote add origin "git@github.com:nerdflair/${2}.git"; }

  # ── plain, non-git directory ───────────────────────────────────────────
  mkdir -p "$FIXROOT/nfdt-notarepo/somesub"
  printf 'hello\n' > "$FIXROOT/nfdt-notarepo/file.txt"

  # ── clean repo on main with origin, plus a nested subdir ───────────────
  mkrepo "$FIXROOT/nfdt-clean" main
  addremote "$FIXROOT/nfdt-clean" clean
  mkdir -p "$FIXROOT/nfdt-clean/sub/deeper"

  # ── dirty repo: 1 modified tracked file + 1 untracked ──────────────────
  mkrepo "$FIXROOT/nfdt-dirty" main
  addremote "$FIXROOT/nfdt-dirty" dirty
  printf 'line one CHANGED\nline two\nline three\nline four added\n' > "$FIXROOT/nfdt-dirty/README.md"
  printf 'a\nb\nc\nd\ne\n' > "$FIXROOT/nfdt-dirty/untracked.txt"

  # ── heavily dirty repo (file-count formatting) ─────────────────────────
  mkrepo "$FIXROOT/nfdt-bigdirty" main
  addremote "$FIXROOT/nfdt-bigdirty" bigdirty
  local i
  for (( i=0; i<37; i++ )); do printf 'x\ny\n' > "$FIXROOT/nfdt-bigdirty/u$i.txt"; done
  printf 'changed\n' > "$FIXROOT/nfdt-bigdirty/README.md"

  # ── detached HEAD ──────────────────────────────────────────────────────
  mkrepo "$FIXROOT/nfdt-detached" main
  addremote "$FIXROOT/nfdt-detached" detached
  _gitq -C "$FIXROOT/nfdt-detached" checkout --detach HEAD

  # ── no origin remote (the historical field-shift case) ─────────────────
  mkrepo "$FIXROOT/nfdt-noremote" main
  mkrepo "$FIXROOT/nfdt-noremote-dirty" main
  printf 'line one CHANGED\nline two\n' > "$FIXROOT/nfdt-noremote-dirty/README.md"
  printf 'q\nw\n' > "$FIXROOT/nfdt-noremote-dirty/extra.txt"

  # ── upstream divergence: ahead / behind / diverged ─────────────────────
  # Build an "upstream" bare repo and clone from it so @{upstream} resolves.
  _gitq init -q --bare "$FIXROOT/.upstream.git"
  mkrepo "$FIXROOT/.seed" main
  _gitq -C "$FIXROOT/.seed" remote add origin "$FIXROOT/.upstream.git"
  _gitq -C "$FIXROOT/.seed" push -q -u origin main

  local name
  for name in ahead behind diverged; do
    _gitq clone -q "$FIXROOT/.upstream.git" "$FIXROOT/nfdt-$name"
    _gitq -C "$FIXROOT/nfdt-$name" config user.name Fixture
    _gitq -C "$FIXROOT/nfdt-$name" config user.email fixture@example.invalid
  done
  # ahead: 2 local commits not pushed
  for i in 1 2; do
    printf 'ahead %s\n' "$i" > "$FIXROOT/nfdt-ahead/a$i.txt"
    _gitq -C "$FIXROOT/nfdt-ahead" add -A
    _gitq -C "$FIXROOT/nfdt-ahead" commit -q -m "ahead commit $i"
  done
  # push 3 commits upstream, then rewind the "behind" clone's remote ref view
  for i in 1 2 3; do
    printf 'up %s\n' "$i" > "$FIXROOT/.seed/u$i.txt"
    _gitq -C "$FIXROOT/.seed" add -A
    _gitq -C "$FIXROOT/.seed" commit -q -m "upstream commit $i"
  done
  _gitq -C "$FIXROOT/.seed" push -q origin main
  _gitq -C "$FIXROOT/nfdt-behind" fetch -q origin
  _gitq -C "$FIXROOT/nfdt-diverged" fetch -q origin
  for i in 1; do
    printf 'local %s\n' "$i" > "$FIXROOT/nfdt-diverged/d$i.txt"
    _gitq -C "$FIXROOT/nfdt-diverged" add -A
    _gitq -C "$FIXROOT/nfdt-diverged" commit -q -m "diverged local commit $i"
  done

  # ── very long branch name ──────────────────────────────────────────────
  mkrepo "$FIXROOT/nfdt-longbranch" \
    "feature/extremely-long-branch-name-that-will-definitely-need-truncating-at-any-width"
  addremote "$FIXROOT/nfdt-longbranch" longbranch

  # ── unicode + spaces in directory and branch names ─────────────────────
  mkrepo "$FIXROOT/nfdt-unicode/проект ✨ каталог" "фича/тест-ветка"
  addremote "$FIXROOT/nfdt-unicode/проект ✨ каталог" unicode

  # ── linked worktree ────────────────────────────────────────────────────
  mkrepo "$FIXROOT/.wt-main" main
  addremote "$FIXROOT/.wt-main" wt
  _gitq -C "$FIXROOT/.wt-main" worktree add -q -b wt/linked "$FIXROOT/nfdt-wt-linked"

  # ── wrapper folders ────────────────────────────────────────────────────
  mkdir -p "$FIXROOT/nfdt-wrap-one"
  mkrepo "$FIXROOT/nfdt-wrap-one/inner-repo" "feature/adopted"

  mkdir -p "$FIXROOT/nfdt-wrap-many"
  mkrepo "$FIXROOT/nfdt-wrap-many/alpha"   "feature/alpha-work"
  mkrepo "$FIXROOT/nfdt-wrap-many/bravo"   "bugfix/bravo-thing"
  mkrepo "$FIXROOT/nfdt-wrap-many/charlie" "spike/charlie-experiment"

  mkdir -p "$FIXROOT/nfdt-wrap-main"
  mkrepo "$FIXROOT/nfdt-wrap-main/one"   main
  mkrepo "$FIXROOT/nfdt-wrap-main/two"   main
  mkrepo "$FIXROOT/nfdt-wrap-main/three" master

  touch "$FIX_STAMP"
}

if (( REBUILD_FIXTURES )) || [[ ! -f "$FIX_STAMP" ]]; then
  printf '%sbuilding git fixtures in %s ...%s\n' "$C_DIM" "$FIXROOT" "$C_RST" >&2
  build_fixtures
fi

# Unicode fixture path resolves one level deeper than its directory name.
FIX_UNICODE="$FIXROOT/nfdt-unicode/проект ✨ каталог"

resolve_repo() {
  case "$1" in
    unicode) printf '%s' "$FIX_UNICODE" ;;
    *)       printf '%s' "$FIXROOT/nfdt-$1" ;;
  esac
}

# ── Per-fixture /tmp git-cache paths (cleared before every single run) ───────
GIT_CACHE_PATHS=()
_collect_cache_paths() {
  local d h
  while IFS= read -r d; do
    h=$(printf '%s' "$d" | cksum | cut -d' ' -f1)
    GIT_CACHE_PATHS+=("/tmp/nerdflair-git-${h}" "/tmp/nerdflair-multibranch-${h}")
  done < <(find "$FIXROOT" -mindepth 1 -maxdepth 2 -type d ! -name '.git' 2>/dev/null; printf '%s\n' "$FIXROOT")
}
_collect_cache_paths

# ═════════════════════════════════════════════════════════════════════════════
# Corpus index
# ═════════════════════════════════════════════════════════════════════════════
mapfile -t CASES < <(cd "$PAYLOAD_DIR" && ls -1 *.json 2>/dev/null | sed 's/\.json$//' | sort)
(( ${#CASES[@]} )) || { echo "difftest: no payloads in $PAYLOAD_DIR" >&2; exit 2; }

if (( LIST_ONLY )); then
  for c in "${CASES[@]}"; do printf '%s  %s\n' "$c" "$(cat "$PAYLOAD_DIR/$c.txt")"; done
  exit 0
fi

_selected() {
  local id="$1"
  [[ -z "$ONLY" ]] && return 0
  local n=$((10#$id))
  if [[ "$ONLY" == *-* ]]; then
    (( n >= 10#${ONLY%%-*} && n <= 10#${ONLY##*-} )) && return 0
  else
    (( n == 10#$ONLY )) && return 0
  fi
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# Sandbox construction
# ═════════════════════════════════════════════════════════════════════════════
# A sandbox is built FROM SCRATCH for every (case, side). It contains only:
#   .claude/nerdflair/state.json          layout / palette / chime state
#   .claude/nerdflair/sessions/<id>       per-session chime, when the case asks
#   .claude.json                          synthetic MCP configuration
#   .claude/nerdflair-usage.tsv           repo-cost log (empty, or seeded)
#   bin/{claude,ccusage,tmux}             stubs, so PATH never reaches real ones
# Phil's real ~/.claude is NEVER read or copied.

mcp_json_for() { # mcp_json_for <variant> <project_dir>
  local variant="$1" pdir="$2"
  case "$variant" in
    ""|none) printf '{"numStartups":7,"projects":{}}' ;;
    one)  printf '{"numStartups":7,"mcpServers":{"context7":{"command":"x"}},"projects":{}}' ;;
    many) printf '%s' '{"numStartups":7,"mcpServers":{
            "context7":{"command":"x"},"figma":{"command":"x"},"postman":{"command":"x"},
            "svelte":{"command":"x"},"claude-comms":{"command":"x"},"aletheia":{"command":"x"}},
            "projects":{}}' ;;
    disabled) jq -nc --arg p "$pdir" '{numStartups:7,
            mcpServers:{context7:{command:"x"},figma:{command:"x",disabled:true},postman:{command:"x"}},
            projects:{($p):{disabledMcpServers:["postman"]}}}' ;;
    projscoped) jq -nc --arg p "$pdir" '{numStartups:7,
            mcpServers:{context7:{command:"x"}},
            projects:{($p):{mcpServers:{"proj-local":{command:"x"},"zeta":{command:"x"}}}}}' ;;
    *) printf '{"projects":{}}' ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════
# Run one side of one case
# ═════════════════════════════════════════════════════════════════════════════
# run_side <impl> <side-tag> <case-id> <outdir>
#   writes <outdir>/<tag>.out, .err, .rc
run_side() {
  local impl="$1" tag="$2" id="$3" outdir="$4"
  local sbox="$outdir/home-$tag"

  # ── fresh sandbox HOME ──────────────────────────────────────────────────
  rm -rf "$sbox"
  mkdir -p "$sbox/.claude/nerdflair/sessions" "$sbox/bin" "$sbox/tmp" "$sbox/neutral"

  [[ -n "${CASE_STATE:-}" ]] && printf '%s' "$CASE_STATE" > "$sbox/.claude/nerdflair/state.json"

  local pdir; pdir=$(jq -r '.workspace.project_dir // empty' "$outdir/payload.json")
  mcp_json_for "${CASE_MCP:-none}" "$pdir" > "$sbox/.claude.json"

  if [[ -n "${CASE_SESSION_CHIME:-}" ]]; then
    local sid; sid=$(jq -r '.session_id // empty' "$outdir/payload.json")
    [[ -n "$sid" ]] && jq -nc --arg c "$CASE_SESSION_CHIME" '{chime:$c}' > "$sbox/.claude/nerdflair/sessions/$sid"
  fi

  # repo-cost log: private per side, so the segment is exercised deterministically
  local rc_file="$sbox/.claude/nerdflair-usage.tsv"
  : > "$rc_file"
  if [[ -n "${CASE_SEED_REPOCOST:-}" ]]; then
    # Fixed epochs well inside the 30-day window are computed from a pinned base.
    local b=$(( PINNED_NOW - 86400 ))
    { printf '%s\tprior-session-a\t%s\t2.50\n' "$b" "${pdir##*/}"
      printf '%s\tprior-session-a\t%s\t3.25\n' "$((b+60))" "${pdir##*/}"
      printf '%s\tprior-session-b\t%s\t1.10\n' "$((b+120))" "${pdir##*/}"; } >> "$rc_file"
  fi

  # ── PATH stubs: PATH never reaches the real claude/ccusage/tmux ─────────
  printf '#!/bin/sh\nexit 0\n' > "$sbox/bin/claude";  chmod +x "$sbox/bin/claude"
  printf '#!/bin/sh\nexit 0\n' > "$sbox/bin/ccusage"; chmod +x "$sbox/bin/ccusage"
  printf '#!/bin/sh\nprintf %%s "%s"\n' "${CASE_SEED_TMUX:-difftest-session}" > "$sbox/bin/tmux"
  chmod +x "$sbox/bin/tmux"

  # ── clear every /tmp cache this case can touch, for THIS side ───────────
  rm -f "${GIT_CACHE_PATHS[@]}" 2>/dev/null
  rm -f /tmp/nerdflair-ccusage-${UID} /tmp/nerdflair-ccusage-${UID}.tmp 2>/dev/null
  rmdir /tmp/nerdflair-ccusage-${UID}.lock 2>/dev/null
  rm -f /tmp/nerdflair-mcphealth-${UID} /tmp/nerdflair-mcphealth-${UID}.tmp 2>/dev/null
  rmdir /tmp/nerdflair-mcphealth-${UID}.lock 2>/dev/null
  rm -f /tmp/nerdflair-repocost-${UID}-* /tmp/nerdflair-repocost-total-${UID}-* 2>/dev/null
  rm -f /tmp/nerdflair-tmux-${UID}-* 2>/dev/null

  # ── seed the async caches this case asks for ────────────────────────────
  local -a extra_env=()
  if [[ -n "${CASE_SEED_CCUSAGE:-}" ]]; then
    printf '%s' "$CASE_SEED_CCUSAGE" > "/tmp/nerdflair-ccusage-${UID}"
    extra_env+=("NERDFLAIR_CCUSAGE=1" "NERDFLAIR_CCUSAGE_TTL=999999999"
                "NERDFLAIR_CCUSAGE_BIN=$sbox/bin/ccusage")
  else
    extra_env+=("NERDFLAIR_CCUSAGE=0")
  fi
  if [[ -n "${CASE_SEED_MCPHEALTH:-}" ]]; then
    local ok="${CASE_SEED_MCPHEALTH%%:*}" rest="${CASE_SEED_MCPHEALTH#*:}"
    printf '%s\x1f%s\x1f%s' "$ok" "${rest%%:*}" "${rest##*:}" > "/tmp/nerdflair-mcphealth-${UID}"
    extra_env+=("NERDFLAIR_MCP_HEALTH=1" "NERDFLAIR_MCP_HEALTH_TTL=999999999")
  else
    extra_env+=("NERDFLAIR_MCP_HEALTH=0")
  fi
  if [[ -n "${CASE_TMUX:-}" && -n "${CASE_SEED_TMUX:-}" ]]; then
    printf '%s' "$CASE_SEED_TMUX" > "/tmp/nerdflair-tmux-${UID}-${CASE_TMUX//[^a-zA-Z0-9]/_}"
  fi

  # ── the pinned environment ──────────────────────────────────────────────
  local -a envargs=(
    -i
    HOME="$sbox"
    TMPDIR="$sbox/tmp"
    PATH="$sbox/bin:/usr/local/bin:/usr/bin:/bin"
    SHELL=/bin/bash
    TERM=xterm-256color
    LC_ALL=C.UTF-8
    LANG=C.UTF-8
    TZ=UTC
    GIT_CONFIG_GLOBAL=/dev/null
    GIT_CONFIG_SYSTEM=/dev/null
    GIT_TERMINAL_PROMPT=0
    GIT_OPTIONAL_LOCKS=0
    NERDFLAIR_REPO_COST=1
    NERDFLAIR_REPO_COST_FILE="$rc_file"
    NERDFLAIR_REPO_COST_TTL=0
    NERDFLAIR_REPO_COST_DAYS=30
  )
  [[ -n "${CASE_COLUMNS:-}" ]] && envargs+=(COLUMNS="$CASE_COLUMNS")
  [[ -n "${CASE_TMUX:-}"    ]] && envargs+=(TMUX_PANE="$CASE_TMUX" TMUX="/tmp/tmux-fake,1,0")
  envargs+=("${extra_env[@]}")
  # per-case extra env lines: CASE_ENV_<n>=KEY=VALUE
  local ev
  for ev in ${CASE_EXTRA_ENV:-}; do envargs+=("$ev"); done

  # The process working directory is an INPUT: statusline.sh does
  # `cd "$cwd" 2>/dev/null` and silently keeps the inherited cwd when that
  # fails. Launching difftest from inside a dirty git repo would then leak that
  # repo's status into the output. Pin cwd to an empty non-git directory.
  ( cd "$sbox/neutral" && exec env "${envargs[@]}" "$impl" \
      < "$outdir/payload.json" \
      > "$outdir/$tag.out" 2> "$outdir/$tag.err" )
  printf '%s' "$?" > "$outdir/$tag.rc"

  # Detached refreshes are disabled by env for every case; make sure none
  # linger before the next side runs.
  wait 2>/dev/null
}

# ── Normalisation (opt-in, off by default) ───────────────────────────────────
# ONLY masks the rate-limit reset countdown: the DIM-coloured "/<countdown>"
# emitted by _rl_part -> _fmt_countdown. Payload resets_at values are pinned to
# EPOCHSECONDS + N + 30s so the integer-minute countdown is already stable for
# runs within ~29s of each other; this flag exists only as a CI safety net.
NORM_SED='s/\x1b\[38;2;85;90;100m\/[0-9]\{1,\}\(d\|m\|h[0-9]\{2\}m\)\x1b\[0m/\x1b[38;2;85;90;100m\/<COUNTDOWN>\x1b[0m/g'
maybe_normalize() {
  (( NORMALIZE_COUNTDOWN )) || return 0
  sed -i "$NORM_SED" "$1"
}

# ═════════════════════════════════════════════════════════════════════════════
# Main loop
# ═════════════════════════════════════════════════════════════════════════════
# PINNED_NOW is re-read immediately before EACH case (see loop), not once for
# the whole run: a corpus-wide epoch decays as the run proceeds and eventually
# lets a rate-limit countdown tick over a minute boundary BETWEEN the two sides.
PINNED_NOW=$EPOCHSECONDS
TOTAL=0; SAME=0; FAILED=(); NOISY=(); UNSTABLE=(); SKIPPED=0

printf '%s╭─ difftest: %s%s\n' "$C_DIM" "$MODE" "$C_RST"
printf '%s│  A = %s%s\n' "$C_DIM" "$SIDE_A" "$C_RST"
printf '%s│  B = %s%s\n' "$C_DIM" "$SIDE_B" "$C_RST"
printf '%s│  corpus = %d payloads   normalize-countdown = %s%s\n' \
  "$C_DIM" "${#CASES[@]}" "$( ((NORMALIZE_COUNTDOWN)) && echo on || echo off )" "$C_RST"
# ── Provenance of side A: a dirty reference invalidates the whole comparison ──
_prov="not in a git repo"
if _sha=$(git -C "$(dirname "$SIDE_A")" rev-parse --short HEAD 2>/dev/null); then
  _rel=$(git -C "$(dirname "$SIDE_A")" ls-files --full-name -- "$SIDE_A" 2>/dev/null)
  if [[ -n "$_rel" ]] && ! git -C "$(dirname "$SIDE_A")" diff --quiet -- "$SIDE_A" 2>/dev/null; then
    _prov="HEAD=$_sha ${C_RED}DIRTY${C_DIM} — $_rel has uncommitted edits"
  else
    _prov="HEAD=$_sha clean"
  fi
fi
[[ -n "$BASH_REV" ]] && _prov="pinned to rev $BASH_REV"
printf '%s│  A provenance = %s%s\n' "$C_DIM" "$_prov" "$C_RST"
printf '%s╰─%s\n' "$C_DIM" "$C_RST"

for id in "${CASES[@]}"; do
  _selected "$id" || { SKIPPED=$((SKIPPED+1)); continue; }
  TOTAL=$((TOTAL+1))
  DESC=$(cat "$PAYLOAD_DIR/$id.txt")
  # Re-pin the epoch per case. Payload offsets all carry a +30s remainder, so
  # both sides land on the same integer-minute countdown as long as they run
  # within ~29s of each other (they run within ~0.2s).
  PINNED_NOW=$EPOCHSECONDS
  OUTDIR="$RUN_DIR/$id"; mkdir -p "$OUTDIR"

  # ── per-case environment directives ───────────────────────────────────
  CASE_STATE=""; CASE_COLUMNS=""; CASE_TMUX=""; CASE_MCP=""
  CASE_SEED_CCUSAGE=""; CASE_SEED_MCPHEALTH=""; CASE_SEED_TMUX=""
  CASE_SEED_REPOCOST=""; CASE_SESSION_CHIME=""; CASE_EXTRA_ENV=""
  # shellcheck disable=SC1090
  [[ -s "$PAYLOAD_DIR/$id.env" ]] && source "$PAYLOAD_DIR/$id.env"

  # ── resolve placeholders ONCE; both sides read the identical bytes ─────
  {
    payload=$(cat "$PAYLOAD_DIR/$id.json")
    # @@REPO:name@@
    while [[ "$payload" =~ @@REPO:([a-z0-9-]+)@@ ]]; do
      rname="${BASH_REMATCH[1]}"
      payload="${payload//@@REPO:${rname}@@/$(resolve_repo "$rname")}"
    done
    payload="${payload//@@HOME@@/$OUTDIR/home-A}"   # placeholder, fixed below
    # @@NOW+N@@ / @@NOW-N@@ — pinned to one epoch read for the whole run
    while [[ "$payload" =~ @@NOW([+-])([0-9]+)@@ ]]; do
      sign="${BASH_REMATCH[1]}"; off="${BASH_REMATCH[2]}"
      if [[ "$sign" == "+" ]]; then v=$(( PINNED_NOW + off )); else v=$(( PINNED_NOW - off )); fi
      payload="${payload//@@NOW${sign}${off}@@/$v}"
    done
    printf '%s' "$payload" > "$OUTDIR/payload.json"
  }

  # @@HOME@@ must point at each side's own sandbox, which differ by path.
  # Cases that use @@HOME@@ get a shared sandbox root instead, so the two
  # sides see the SAME string.
  if grep -q "home-A" "$OUTDIR/payload.json"; then
    SHARED_HOME="$RUN_DIR/shared-home-$id"
    mkdir -p "$SHARED_HOME"
    sed -i "s|$OUTDIR/home-A|$SHARED_HOME|g" "$OUTDIR/payload.json"
    CASE_EXTRA_ENV="HOME=$SHARED_HOME"
  fi

  # A case is run, and on ANY mismatch run once more. /tmp/nerdflair-ccusage-$UID
  # and /tmp/nerdflair-mcphealth-$UID are hard-coded paths shared with the user's
  # LIVE Claude Code sessions, which can refresh them between our two sides. A
  # genuine divergence reproduces; a transient one does not. Cases that only pass
  # on the retry are reported as UNSTABLE, never silently swallowed.
  _attempt=0
  while :; do
    run_side "$SIDE_A" "A" "$id" "$OUTDIR"
    run_side "$SIDE_B" "B" "$id" "$OUTDIR"
    maybe_normalize "$OUTDIR/A.out"
    maybe_normalize "$OUTDIR/B.out"
    if cmp -s "$OUTDIR/A.out" "$OUTDIR/B.out" \
       && [[ "$(cat "$OUTDIR/A.rc")" == "$(cat "$OUTDIR/B.rc")" ]]; then
      break
    fi
    (( _attempt++ >= 1 )) && break
  done
  (( _attempt > 0 )) && UNSTABLE+=("$id")

  rcA=$(cat "$OUTDIR/A.rc"); rcB=$(cat "$OUTDIR/B.rc")
  errA=$(wc -c < "$OUTDIR/A.err"); errB=$(wc -c < "$OUTDIR/B.err")

  problems=()
  if ! cmp -s "$OUTDIR/A.out" "$OUTDIR/B.out"; then
    off=$(cmp "$OUTDIR/A.out" "$OUTDIR/B.out" 2>&1 | head -1)
    problems+=("stdout differs — $off")
  fi
  [[ "$rcA" != "$rcB" ]] && problems+=("exit status differs: A=$rcA B=$rcB")
  # stderr: compare EMPTINESS PARITY, not byte equality. A Rust diagnostic will
  # never match jq's wording, but "one side is silent and the other is not" is a
  # real behavioural difference and must fail. Both noisy is reported, not failed.
  if (( (errA > 0) != (errB > 0) )); then
    problems+=("stderr emptiness differs: A=${errA}B B=${errB}B")
  elif (( errA > 0 )); then
    NOISY+=("$id")
  fi

  if (( ${#problems[@]} == 0 )); then
    SAME=$((SAME+1))
    (( VERBOSE )) && printf '%s  ok  %s  %s%s\n' "$C_GRN" "$id" "$DESC" "$C_RST"
  else
    FAILED+=("$id")
    printf '\n%s╔═ FAIL %s ══ %s%s\n' "$C_RED" "$id" "$DESC" "$C_RST"
    for p in "${problems[@]}"; do printf '%s║ %s%s\n' "$C_RED" "$p" "$C_RST"; done
    printf '%s║ payload: %s%s\n' "$C_DIM" "$(jq -c . "$OUTDIR/payload.json" | cut -c1-220)" "$C_RST"
    [[ -s "$PAYLOAD_DIR/$id.env" ]] && \
      printf '%s║ env:     %s%s\n' "$C_DIM" "$(tr '\n' ' ' < "$PAYLOAD_DIR/$id.env" | cut -c1-220)" "$C_RST"
    printf '%s║ ── A (%s) ──%s\n' "$C_YEL" "$SIDE_A_NAME" "$C_RST"
    cat -v "$OUTDIR/A.out" | sed 's/^/║ /'
    printf '\n%s║ ── B (%s) ──%s\n' "$C_YEL" "$SIDE_B_NAME" "$C_RST"
    cat -v "$OUTDIR/B.out" | sed 's/^/║ /'
    printf '\n%s║ ── line diff (escaped) ──%s\n' "$C_YEL" "$C_RST"
    diff <(cat -v "$OUTDIR/A.out") <(cat -v "$OUTDIR/B.out") | head -40 | sed 's/^/║ /'
    if (( errA > 0 )); then printf '%s║ A stderr: %s%s\n' "$C_RED" "$(head -c 400 "$OUTDIR/A.err")" "$C_RST"; fi
    if (( errB > 0 )); then printf '%s║ B stderr: %s%s\n' "$C_RED" "$(head -c 400 "$OUTDIR/B.err")" "$C_RST"; fi
    printf '%s╚═ artifacts: %s%s\n' "$C_DIM" "$OUTDIR" "$C_RST"
    KEEP=1
  fi
done

printf '\n'
# UNSTABLE lists cases that differed on the first attempt and matched on the
# retry. If a case appears here AND is not in FAILED, the divergence was
# environmental; if it recurs across runs, treat it as a real nondeterminism bug.
_only_unstable=()
for u in ${UNSTABLE[@]+"${UNSTABLE[@]}"}; do
  [[ " ${FAILED[*]-} " == *" $u "* ]] || _only_unstable+=("$u")
done
(( ${#_only_unstable[@]} )) && printf '%sUNSTABLE (differed once, matched on retry): %s%s\n' \
  "$C_YEL" "${_only_unstable[*]}" "$C_RST"
(( ${#NOISY[@]} )) && printf '%snote: both sides wrote to stderr on: %s%s\n' \
  "$C_YEL" "${NOISY[*]}" "$C_RST"
if (( ${#FAILED[@]} == 0 )); then
  printf '%s%d/%d identical%s\n' "$C_GRN" "$SAME" "$TOTAL" "$C_RST"
  exit 0
else
  printf '%s%d/%d identical — %d differ: %s%s\n' \
    "$C_RED" "$SAME" "$TOTAL" "${#FAILED[@]}" "${FAILED[*]}" "$C_RST"
  exit 1
fi

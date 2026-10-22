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
#   ./difftest.sh --only 138-141,145,162   run a comma list of ids and ranges
#   ./difftest.sh --verbose                show a diff for every case, not just failures
#   ./difftest.sh --list                   print the corpus index and exit
#   ./difftest.sh --normalize-countdown    mask rate-limit countdowns before comparing
#   ./difftest.sh --rebuild-fixtures       force git fixture rebuild
#   ./difftest.sh --keep                   keep the run directory for inspection
#   ./difftest.sh -j N                     run N cases in parallel (default 1); report order and
#                                          content are the same as -j 1
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
ONLY=""; ONLY_SET=0
VERBOSE=0
LIST_ONLY=0
NORMALIZE_COUNTDOWN=0
REBUILD_FIXTURES=0
KEEP=0
JOBS=1

while (( $# )); do
  case "$1" in
    --rust)  RUST_IMPL="$2"; shift 2 ;;
    --bash)  BASH_IMPL_B="$2"; shift 2 ;;
    --bash-rev) BASH_REV="$2"; shift 2 ;;
    --bash-a) BASH_IMPL="$2"; shift 2 ;;
    --only)  ONLY="$2"; ONLY_SET=1; shift 2 ;;
    --verbose|-v) VERBOSE=1; shift ;;
    --list)  LIST_ONLY=1; shift ;;
    --normalize-countdown) NORMALIZE_COUNTDOWN=1; shift ;;
    --rebuild-fixtures) REBUILD_FIXTURES=1; shift ;;
    --keep)  KEEP=1; shift ;;
    -j)      JOBS="$2"; shift 2 ;;
    -j[0-9]*) JOBS="${1#-j}"; shift ;;
    -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'difftest: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# --only takes a comma list of ids and ranges: 138-141,145,162. Anything else is an error (exit 2),
# never "run everything".
if (( ONLY_SET )); then
  [[ "$ONLY" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] \
    || { echo "difftest: --only '$ONLY' is not a list of ids/ranges like 138-141,145,162" >&2; exit 2; }
  _r=${ONLY//,/ }
  for _it in $_r; do
    [[ "$_it" == *-* ]] && (( 10#${_it%%-*} > 10#${_it##*-} )) \
      && { echo "difftest: --only range '$_it' is reversed (first id is larger than the last)" >&2; exit 2; }
  done
fi

_selected() {
  local id="$1" item
  [[ -z "$ONLY" ]] && return 0
  local n=$((10#$id))
  local IFS=,
  for item in $ONLY; do
    if [[ "$item" == *-* ]]; then
      (( n >= 10#${item%%-*} && n <= 10#${item##*-} )) && return 0
    else
      (( n == 10#$item )) && return 0
    fi
  done
  return 1
}

# Selection is decided here, before the run dir, the fixtures or any process is started.
SEL=(); SKIPPED=0
for _f in "$PAYLOAD_DIR"/*.json; do
  [[ -e $_f ]] || continue
  _id=$(basename "$_f" .json)
  _selected "$_id" && SEL+=("$_id") || SKIPPED=$((SKIPPED+1))
done
# --list ignores --only (it prints the whole corpus index), so a no-match filter is only an error when cases would run
(( ${#SEL[@]} || LIST_ONLY )) || { echo "difftest: --only '$ONLY' matches no case in the corpus" >&2; exit 2; }
# Seeding (MCP health, RC records) asks the Rust binary for the cache file names: without it both sides would run unseeded and pass vacuously.
if [[ ! -x "$RUST_IMPL" ]]; then
  for _id in "${SEL[@]}"; do
    if [[ -f "$PAYLOAD_DIR/$_id.env" ]] && rg -q "^CASE_SEED_(MCPHEALTH|RC)='[^']" "$PAYLOAD_DIR/$_id.env"; then
      echo "difftest: case $_id seeds through the renderer, but RUST_IMPL is not executable: $RUST_IMPL (build it, pass --rust, or select other cases)" >&2; exit 2
    fi
  done
fi


[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { printf 'difftest: -j needs a positive integer\n' >&2; exit 2; }

# ── Pin side A to a git revision when asked ──────────────────────────────────
# The working-tree copy of scripts/statusline.sh is NOT frozen: a concurrent
# porting session can edit it underneath a run. --bash-rev extracts the script
# and its lib from a named revision so the gate has a stable reference.
if [[ -n "$BASH_REV" ]]; then
  _revdir=$(mktemp -d "${TMPDIR:-/tmp}/nerdflair-difftest-rev.XXXXXX")
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

# ponytail: no global run lock. The /tmp/nerdflair-ccusage-UID file is retired (no renderer reads it); the seeded
# cases only guard that a stray file is ignored, and cases inside one run are serialised by $RUN_DIR/ccusage.lock.
# Two concurrent runs can clear each other's stray file, which weakens that guard but never fails a case.

# ── Shared /tmp caches the script hard-codes: snapshot and restore ───────────
# The (retired) ccusage cache is a hard-coded /tmp path. It is Phil's LIVE cache. Save them now, restore on
# exit, so a difftest run never leaves the real statusline holding our fixtures.
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nerdflair-difftest.XXXXXX")
SHARED_CACHES=("/tmp/nerdflair-ccusage-${UID}")
# Every renderer cache lives in a private per-case dir (CACHE_DIR = $RUN_DIR/<case>/cache, set in
# run_case), so parallel cases can't see each other's files, and never in the user's real one.
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
  # Stop the workers THIS run started (their own process group, led by the xargs PID) and reap them before the rm,
  # or a dying worker is still creating $RUN_DIR/<case> entries and rm -rf loses the race (ENOTEMPTY, dir leaked).
  # xargs is our child (wait reaps it) but the workers are its children, so wait for the whole group to empty (bounded: KILL after 5 s).
  if [[ -n ${XPID:-} ]]; then
    kill -TERM -- "-$XPID" 2>/dev/null; wait "$XPID" 2>/dev/null
    for _ in {1..100}; do kill -0 -- "-$XPID" 2>/dev/null || break; sleep 0.05; done
    kill -KILL -- "-$XPID" 2>/dev/null
  fi
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
FIXROOT="$RUN_DIR/fixtures"   # private per run: a shared /tmp copy let concurrent agents race on the git index/rebuild (~1.5s to build)
FIX_STAMP="$FIXROOT/.built-v3"

# A failed fixture step aborts the build: both sides would otherwise read the same
# broken fixture, compare equal and pass vacuously.
_gitq() {
  local out
  out=$(git -c protocol.file.allow=always "$@" 2>&1) || { echo "difftest: fixture step failed: git $*: $out" >&2; exit 2; }
}

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

# ═════════════════════════════════════════════════════════════════════════════
# Corpus index
# ═════════════════════════════════════════════════════════════════════════════
mapfile -t CASES < <(cd "$PAYLOAD_DIR" && ls -1 *.json 2>/dev/null | sed 's/\.json$//' | sort)
(( ${#CASES[@]} )) || { echo "difftest: no payloads in $PAYLOAD_DIR" >&2; exit 2; }

if (( LIST_ONLY )); then
  for c in "${CASES[@]}"; do printf '%s  %s\n' "$c" "$(cat "$PAYLOAD_DIR/$c.txt")"; done
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# Sandbox construction
# ═════════════════════════════════════════════════════════════════════════════
# A sandbox is built FROM SCRATCH for every (case, side). It contains only:
#   .claude/nerdflair/state.json          layout / palette / chime state
#   .claude/nerdflair/sessions/<id>       per-session chime, when the case asks
#   .claude.json                          synthetic MCP configuration
#   .claude/nerdflair-usage.tsv           repo-cost log (empty, or seeded)
#   $CACHE_DIR/rc-<session>               Remote Control record, when the case seeds one
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

  # ── PATH stubs: PATH never reaches the real claude/tmux ─────────
  printf '#!/bin/sh\nexit 0\n' > "$sbox/bin/claude";  chmod +x "$sbox/bin/claude"
  printf '#!/bin/sh\nprintf %%s "%s"\n' "${CASE_SEED_TMUX:-difftest-session}" > "$sbox/bin/tmux"
  chmod +x "$sbox/bin/tmux"

  # ── clear every /tmp cache this case can touch, for THIS side ───────────
  rm -f "$CACHE_DIR"/nerdflair-git-* "$CACHE_DIR"/nerdflair-multibranch-* 2>/dev/null
  # /tmp/nerdflair-ccusage-UID is a hard-coded path shared by all cases: a case that seeds it holds the
  # lock exclusively for its whole run, every other case holds it shared (see the release below).
  local lk
  exec {lk}>"$RUN_DIR/ccusage.lock"
  if [[ -n "${CASE_SEED_CCUSAGE:-}" ]]; then flock -x "$lk"; else flock -s "$lk"; fi
  # Every case clears a stale seed, seeding or not: under the shared lock no seeder is running, and the
  # removal is idempotent, so readers can't clear each other's state.
  rm -f /tmp/nerdflair-ccusage-${UID} /tmp/nerdflair-ccusage-${UID}.tmp 2>/dev/null
  rmdir /tmp/nerdflair-ccusage-${UID}.lock 2>/dev/null
  rm -f "$CACHE_DIR/nerdflair-mcphealth-${UID}" "$CACHE_DIR/nerdflair-mcphealth-${UID}.tmp" "$CACHE_DIR/nerdflair-mcphealth-${UID}.lock" 2>/dev/null
  rm -f "$CACHE_DIR"/nerdflair-mcphealth-${UID}-* "$CACHE_DIR/nerdflair-mcphealth-prune-${UID}" 2>/dev/null
  rm -f "$CACHE_DIR"/nerdflair-repocost-${UID}-* "$CACHE_DIR"/nerdflair-repocost-total-${UID}-* 2>/dev/null
  rm -f "$CACHE_DIR"/nerdflair-sample-${UID}-* 2>/dev/null
  rm -f "$CACHE_DIR"/nerdflair-tmux-${UID}-* 2>/dev/null
  rm -f "$CACHE_DIR"/limits-last "$CACHE_DIR"/limits-last.tmp.* 2>/dev/null
  rm -f "$CACHE_DIR"/rc-* 2>/dev/null

  # ── seed the async caches this case asks for ────────────────────────────
  local -a extra_env=()
  if [[ -n "${CASE_SEED_CCUSAGE:-}" ]]; then
    # ccusage is gone; a stray cache file must be ignored (regression guard).
    printf '%s' "$CASE_SEED_CCUSAGE" > "/tmp/nerdflair-ccusage-${UID}"
  fi
  if [[ -n "${CASE_SEED_MCPHEALTH:-}" ]]; then
    local ok="${CASE_SEED_MCPHEALTH%%:*}" rest="${CASE_SEED_MCPHEALTH#*:}"
    # NO NERDFLAIR_MCP_CACHE: the renderers must find the per-project file by its own name,
    # nerdflair-mcphealth-UID-<cksum of the normalised project dir> (the dir comes from the payload).
    # The key rule lives in the renderer (--mcp-cache-name), not in a copy here.
    local kn; kn=$(NERDFLAIR_CACHE_DIR="$CACHE_DIR" "$RUST_IMPL" --mcp-cache-name "$(jq -r '.workspace.current_dir // ""' "$outdir/payload.json")" "$(jq -r '.workspace.project_dir // ""' "$outdir/payload.json")")
    printf '%s\x1f%s\x1f%s' "$ok" "${rest%%:*}" "${rest##*:}" > "$CACHE_DIR/$kn"
    extra_env+=("NERDFLAIR_MCP_HEALTH=1" "NERDFLAIR_MCP_HEALTH_TTL=999999999")
  else
    extra_env+=("NERDFLAIR_MCP_HEALTH=0")
  fi
  if [[ -n "${CASE_SEED_LIMITS:-}" ]]; then
    # The account-wide last-known rate-limit record. @@NOW+N@@ / @@NOW-N@@ as in payloads.
    local lim="$CASE_SEED_LIMITS" lsign loff lv
    while [[ "$lim" =~ @@NOW([+-])([0-9]+)@@ ]]; do
      lsign="${BASH_REMATCH[1]}"; loff="${BASH_REMATCH[2]}"
      if [[ "$lsign" == "+" ]]; then lv=$(( PINNED_NOW + loff )); else lv=$(( PINNED_NOW - loff )); fi
      lim="${lim//@@NOW${lsign}${loff}@@/$lv}"
    done
    printf '%s\n' "$lim" > "$CACHE_DIR/limits-last"
  fi
  if [[ -n "${CASE_SEED_RC:-}" ]]; then
    # The band plugin's Remote Control record for this payload's session (rc-<slug of session_id>).
    # CASE_SEED_RC_AGE backdates its mtime, for the stale rule.
    # CASE_SEED_RC_ID names a DIFFERENT session id to seed under (the collision cases).
    local rsid rcf; rsid=${CASE_SEED_RC_ID:-$(jq -r '.session_id // empty' "$outdir/payload.json")}
    rcf="$CACHE_DIR/$("$RUST_IMPL" --rc-name "$rsid" </dev/null)"
    printf '%s\n' "$CASE_SEED_RC" > "$rcf"
    [[ -n "${CASE_SEED_RC_AGE:-}" ]] && touch -d "@$(( EPOCHSECONDS - CASE_SEED_RC_AGE ))" "$rcf"
  fi
  if [[ -n "${CASE_TMUX:-}" && -n "${CASE_SEED_TMUX:-}" ]]; then
    printf '%s' "$CASE_SEED_TMUX" > "$CACHE_DIR/nerdflair-tmux-${UID}-${CASE_TMUX//[^a-zA-Z0-9]/_}"
  fi

  # ── the pinned environment ──────────────────────────────────────────────
  local -a envargs=(
    -i
    HOME="$sbox"
    NERDFLAIR_CACHE_DIR="$CACHE_DIR"
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
      > "$outdir/$tag.out" 2> "$outdir/$tag.err" {lk}>&- )   # the ccusage lock fd stays in this shell only
  printf '%s' "$?" > "$outdir/$tag.rc"
  exec {lk}>&-

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
TOTAL=0; SAME=0; FAILED=(); NOISY=(); UNSTABLE=(); BOTHFAIL=()

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

# run_case <id>: run one case; print its report; leave its verdict as marker files in its OUTDIR
# (fail, unstable, noisy, bothfail) for the aggregation below. Nothing here touches shared state.
run_case() {
  local id="$1" DESC OUTDIR _attempt rcA rcB errA errB problems p off ev
  DESC=$(cat "$PAYLOAD_DIR/$id.txt")
  # Re-pin the epoch per case. Payload offsets all carry a +30s remainder, so
  # both sides land on the same integer-minute countdown as long as they run
  # within ~29s of each other (they run within ~0.2s).
  PINNED_NOW=$EPOCHSECONDS
  OUTDIR="$RUN_DIR/$id"; mkdir -p "$OUTDIR"
  CACHE_DIR="$OUTDIR/cache"; mkdir -m 700 "$CACHE_DIR"

  # ── per-case environment directives ───────────────────────────────────
  CASE_STATE=""; CASE_COLUMNS=""; CASE_TMUX=""; CASE_MCP=""
  CASE_SEED_CCUSAGE=""; CASE_SEED_MCPHEALTH=""; CASE_SEED_TMUX=""
  CASE_SEED_REPOCOST=""; CASE_SESSION_CHIME=""; CASE_EXTRA_ENV=""; CASE_SEED_LIMITS=""; CASE_SEED_RC=""; CASE_SEED_RC_AGE=""; CASE_SEED_RC_ID=""
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

  # A case is run, and on ANY mismatch run once more. The retired
  # /tmp/nerdflair-ccusage-$UID is a hard-coded path shared with the user's
  # LIVE Claude Code sessions, which can refresh it between our two sides. A
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
    # keep the first (differing) attempt: it is the only evidence of what was unstable
    if (( _attempt == 0 )); then cp "$OUTDIR/A.out" "$OUTDIR/first-A.out"; cp "$OUTDIR/B.out" "$OUTDIR/first-B.out"; fi
    (( _attempt++ >= 1 )) && break
  done
  if (( _attempt > 0 )); then
    : > "$OUTDIR/unstable"
    # evidence: what differed on the first attempt (cp ran before the retry)
    printf '%sUNSTABLE %s first-attempt diff:%s\n' "$C_YEL" "$id" "$C_RST"
    diff <(cat -v "$OUTDIR/first-A.out") <(cat -v "$OUTDIR/first-B.out") | head -20 | cut -c1-1500
  fi

  rcA=$(cat "$OUTDIR/A.rc"); rcB=$(cat "$OUTDIR/B.rc")
  errA=$(wc -c < "$OUTDIR/A.err"); errB=$(wc -c < "$OUTDIR/B.err")

  problems=()
  if ! cmp -s "$OUTDIR/A.out" "$OUTDIR/B.out"; then
    off=$(cmp "$OUTDIR/A.out" "$OUTDIR/B.out" 2>&1 | head -1)
    problems+=("stdout differs — $off")
  fi
  [[ "$rcA" != "$rcB" ]] && problems+=("exit status differs: A=$rcA B=$rcB")
  # A seeded MCP health file is found by its per-project NAME (no override). If neither side shows the seeded
  # count, the name did not match and the case proves nothing.
  if [[ -n "$CASE_SEED_MCPHEALTH" ]]; then
    _sd_ok="${CASE_SEED_MCPHEALTH%%:*}"
    sed 's/\x1b\[[0-9;]*m//g' "$OUTDIR/A.out" | grep -q "${_sd_ok}/" \
      || problems+=("seeded MCP health ${CASE_SEED_MCPHEALTH} not shown: the per-project cache name did not match")
  fi
  # stderr: compare EMPTINESS PARITY, not byte equality. A Rust diagnostic will
  # never match jq's wording, but "one side is silent and the other is not" is a
  # real behavioural difference and must fail. Both noisy is reported, not failed.
  # Both sides failing the same way is "identical" but may be a shared fixture
  # problem rather than the behaviour under test: surfaced as a note, below.
  [[ "$rcA" == "$rcB" && "$rcA" != 0 ]] && printf '%s' "$rcA" > "$OUTDIR/bothfail"
  if (( (errA > 0) != (errB > 0) )); then
    problems+=("stderr emptiness differs: A=${errA}B B=${errB}B")
  elif (( errA > 0 )); then
    : > "$OUTDIR/noisy"
  fi

  if (( ${#problems[@]} == 0 )); then
    (( VERBOSE )) && printf '%s  ok  %s  %s%s\n' "$C_GRN" "$id" "$DESC" "$C_RST"
  else
    : > "$OUTDIR/fail"
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
  fi
  : > "$OUTDIR/done"   # a case that dies before this line is counted as FAILED, never SAME
}

export -f run_case run_side mcp_json_for maybe_normalize resolve_repo
export JOBS RUN_DIR PAYLOAD_DIR SIDE_A SIDE_B SIDE_A_NAME SIDE_B_NAME RUST_IMPL NORMALIZE_COUNTDOWN VERBOSE \
  FIXROOT FIX_UNICODE NORM_SED C_RED C_GRN C_YEL C_DIM C_RST

TOTAL=${#SEL[@]}
if (( JOBS == 1 )); then
  for id in "${SEL[@]}"; do run_case "$id"; done
else
  # Each case reports into its own file; the reports are printed below in case order.
  # One progress line per finished case on stderr (the reports themselves print at the end, in case order).
  export TOTAL
  set -m   # job control puts the background xargs in its own process group (pgid = XPID) so _cleanup can signal all workers by PID
  xargs -P "$JOBS" -I{} bash -c \
    'run_case "$1" > "$RUN_DIR/$1.report" 2>&1; echo "$1" >> "$RUN_DIR/progress"; printf "difftest: %s/%s cases done\n" "$(wc -l < "$RUN_DIR/progress")" "$TOTAL" >&2' _ {} <<<"$(printf '%s\n' "${SEL[@]}")" &
  XPID=$!; set +m
  # XPID stays set: if xargs dies early, _cleanup still signals the leftover worker group (kill on an empty group is a no-op).
  # A SIGKILL to difftest cannot be trapped; its workers then run on to the end of their case. Nothing to handle there.
  wait "$XPID"
  for id in "${SEL[@]}"; do cat "$RUN_DIR/$id.report" 2>/dev/null; done
  # a crashed case is caught below by its missing `done` marker (xargs' own status is the last printf's, always 0)
fi
for id in "${SEL[@]}"; do
  if [[ -e "$RUN_DIR/$id/fail" || ! -e "$RUN_DIR/$id/done" ]]; then FAILED+=("$id"); KEEP=1; else SAME=$((SAME+1)); fi
  [[ -e "$RUN_DIR/$id/unstable" ]] && UNSTABLE+=("$id")
  [[ -e "$RUN_DIR/$id/noisy" ]] && NOISY+=("$id")
  [[ -e "$RUN_DIR/$id/bothfail" ]] && BOTHFAIL+=("$id=$(<"$RUN_DIR/$id/bothfail")")
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
(( ${#BOTHFAIL[@]} )) && printf '%snote: both sides exited non-zero, identically, on: %s (check these are expected failures)%s\n' \
  "$C_YEL" "${BOTHFAIL[*]}" "$C_RST"
(( ${#NOISY[@]} )) && printf '%snote: both sides wrote to stderr on: %s%s\n' \
  "$C_YEL" "${NOISY[*]}" "$C_RST"
if (( ${#FAILED[@]} == 0 )); then
  printf '%s%d/%d identical%s\n' "$C_GRN" "$SAME" "$TOTAL" "$C_RST"
  # A case that needed its retry is nondeterminism, not a pass: fail the run.
  # NERDFLAIR_DIFFTEST_ALLOW_UNSTABLE=1 restores the old warn-only behaviour.
  (( ${#_only_unstable[@]} )) && [[ "${NERDFLAIR_DIFFTEST_ALLOW_UNSTABLE:-0}" != 1 ]] && exit 3
  exit 0
else
  printf '%s%d/%d identical — %d differ: %s%s\n' \
    "$C_RED" "$SAME" "$TOTAL" "${#FAILED[@]}" "${FAILED[*]}" "$C_RST"
  exit 1
fi

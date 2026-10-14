#!/usr/bin/env bash
# silent-failures.sh - no silent failures, silent fallbacks or swallowed errors.
#
# Owner's rule: a fallback is fine, but every absorbed failure must produce a
# durable log line somewhere, once, with the reason. This forces one failure
# class per case, in BOTH renderers (Rust and its bash twin), in a throwaway
# HOME, renders it N times and asserts:
#   * exactly ONE line for the class in $HOME/.claude/nerdflair-errors.log
#     (rate limited per key, however many renders hit it),
#   * the status line on stdout is byte-identical between the two renderers
#     (logging must never touch stdout),
#   * the NOISE cases (lock contention, not-a-repo, missing optional files)
#     stay completely silent.
# Rate-limit stamps go to a per-case dir (NERDFLAIR_ERR_STAMP_DIR), so nothing
# here shares state with a real session. Nothing touches the real HOME.
#
# The panic case needs NERDFLAIR_TEST_PANIC=1, a TEST-ONLY switch in the Rust
# build: there is no natural way to make the renderer panic.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$REPO/scripts/statusline.sh"
BIN="$REPO/rust/target/release/nerdflair-statusline"
[[ -x "$BIN" ]] || { echo "silent-failures: not built: $BIN" >&2; exit 2; }
BASH_BIN="$(command -v bash)"
RENDERS=4
NOW=$(date +%s)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nf-silent-XXXXXX") || exit 1
[[ -d "$WORK" ]] || exit 1
TAG="sf$$$RANDOM"          # unique session ids, so /tmp caches never collide
HOLDER_PID=""

cleanup() {
  [[ -n "$HOLDER_PID" ]] && kill "$HOLDER_PID" 2>/dev/null
  # Read-only dirs and 444 files were made on purpose; undo before removing.
  python3 - "$WORK" "$TAG" <<'PY'
import os, shutil, stat, sys
d, tag = sys.argv[1], sys.argv[2]
assert os.path.isdir(d) and not os.path.islink(d) and os.path.basename(d).startswith("nf-silent-"), d
for root, dirs, files in os.walk(d):
    for n in dirs + files:
        p = os.path.join(root, n)
        if not os.path.islink(p):
            try: os.chmod(p, os.stat(p).st_mode | stat.S_IRWXU)
            except OSError: pass
shutil.rmtree(d, ignore_errors=True)
# per-session /tmp caches the renderers cannot be told to move
for n in os.listdir("/tmp"):
    if tag in n and n.startswith("nerdflair-"):
        try: os.remove(os.path.join("/tmp", n))
        except OSError: pass
PY
}
trap cleanup EXIT

fail=0
check() { # label want got
  if [[ "$3" == "$2" ]]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}

# A tools dir holding every binary except git, for the "git is not installed" case.
NOGIT="$WORK/tools-nogit"
mkdir -p "$NOGIT"
for d in /usr/bin /bin; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    [[ "$n" == git* ]] && continue
    [[ -e "$NOGIT/$n" ]] || ln -s "$f" "$NOGIT/$n" 2>/dev/null
  done
done

# ── harness ───────────────────────────────────────────────────────
CASE_DIR=""
PAYLOAD=""
CASE_PATH=""
CASE_ENV=()
CASE_ULIMIT_F=""
IMPLS="rust bash"

payload() { # session-suffix [extra-json-fields]
  printf '{"session_id":"%s-%s","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"%s","project_dir":"%s"},"context_window":{"context_window_size":200000,"used_percentage":10,"total_input_tokens":1,"total_output_tokens":1},"cost":{"total_cost_usd":1.25,"total_duration_ms":60000,"total_api_duration_ms":1000}%s}' \
    "$TAG" "$1" "$CASE_DIR/work" "$CASE_DIR/work" "${2:-}"
}

render() { # impl n
  local impl=$1 n=$2 e args=()
  for e in ${CASE_ENV[@]+"${CASE_ENV[@]}"}; do args+=("${e//@DIR@/$CASE_DIR}"); done
  local cmd=("$BIN"); [[ "$impl" == bash ]] && cmd=("$BASH_BIN" "$SH")
  # `timeout`: a hung renderer must fail the test, never hang it. The optional
  # file-size limit (ENOSPC stand-in, see s_ledger_write) is inherited, with
  # SIGXFSZ ignored so an over-limit write returns EFBIG instead of killing.
  ( [[ -n "$CASE_ULIMIT_F" ]] && { ulimit -f "$CASE_ULIMIT_F"; trap '' XFSZ; }
    cd "$CASE_DIR/work" && printf '%s' "$PAYLOAD" | timeout 30 env -i \
      PATH="${CASE_PATH:-$PATH}" HOME="$CASE_DIR/home" TMPDIR="$CASE_DIR/tmp" \
      LC_ALL=C.UTF-8 LANG=C.UTF-8 TZ=UTC COLUMNS=120 \
      NERDFLAIR_ERR_STAMP_DIR="$CASE_DIR/stamps" NERDFLAIR_MCP_HEALTH=0 \
      NERDFLAIR_MCP_CACHE="$CASE_DIR/mcpcache" \
      ${args[@]+"${args[@]}"} "${cmd[@]}" >"$CASE_DIR/out.$n" 2>"$CASE_DIR/err.$n" ) 2>/dev/null
  echo $? > "$CASE_DIR/rc.$n"
}

log_count() { # fixed-string " key: " -> count of matching lines
  local c
  c=$(rg -cF -- " $1: " "$CASE_DIR/home/.claude/nerdflair-errors.log" 2>/dev/null) || c=0
  printf '%s' "${c:-0}"
}
log_lines() { # all lines, for failure output
  [[ -f "$CASE_DIR/home/.claude/nerdflair-errors.log" ]] && cat "$CASE_DIR/home/.claude/nerdflair-errors.log"
}

# poll (bounded) until a command succeeds: the probe is a detached job and there
# is no process to wait() on, so wait on the EVENT (the log line), not a duration.
wait_until() { # secs cmd...
  local secs=$1 i; shift
  for (( i = 0; i < secs * 20; i++ )); do "$@" && return 0; read -rt 0.05 <> <(:) || true; done
  return 1
}
have_line() { [[ "$(log_count "$KEY")" -ge 1 ]]; }

setup_dirs() { # name impl
  CASE_DIR="$WORK/$1-$2"
  mkdir -p "$CASE_DIR/home/.claude/nerdflair" "$CASE_DIR/stamps" "$CASE_DIR/tmp" "$CASE_DIR/work" "$CASE_DIR/bin"
}

# run_case NAME KEY WANT_COUNT SETUP_FN [CHECK_FN]
#   KEY "-" means: assert the whole log is empty (a NOISE case).
run_case() {
  local name=$1 key=$2 want=$3 setup=$4 chk=${5:-} impl n got
  KEY="$key"
  for impl in $IMPLS; do
    setup_dirs "$name" "$impl"
    PAYLOAD=$(payload "$name")
    CASE_PATH=""; CASE_ENV=(); CASE_ULIMIT_F=""
    "$setup" "$impl"
    for (( n = 1; n <= RENDERS; n++ )); do
      render "$impl" "$n"
      # A detached probe logs after the render returned: wait for the event once.
      if (( n == 1 )) && [[ "${WAIT_FOR_LOG:-0}" == 1 ]]; then
        wait_until 20 have_line || echo "  (timed out waiting for the $key line)" >&2
      fi
    done
    if [[ "$key" == "-" ]]; then
      got=$(log_lines | wc -l | tr -d ' ')
      check "$name [$impl]: log stays empty after $RENDERS renders" 0 "$got"
      [[ "$got" != 0 ]] && log_lines | sed 's/^/        /'
    else
      got=$(log_count "$key")
      check "$name [$impl]: exactly $want '$key' line after $RENDERS renders" "$want" "$got"
      [[ "$got" != "$want" ]] && log_lines | sed 's/^/        log: /'
    fi
    [[ -n "$chk" ]] && "$chk" "$impl"
  done
  # Logging must never change what is printed: the twins agree byte for byte.
  if [[ "$IMPLS" == "rust bash" ]]; then
    if cmp -s "$WORK/$name-rust/out.$RENDERS" "$WORK/$name-bash/out.$RENDERS"; then
      printf '  PASS  %s: stdout byte-identical (rust vs bash)\n' "$name"
    else
      printf '  FAIL  %s: stdout differs (rust vs bash)\n' "$name"; fail=1
      diff <(cat -v "$WORK/$name-rust/out.$RENDERS") <(cat -v "$WORK/$name-bash/out.$RENDERS") | head -6 | sed 's/^/        /'
    fi
  fi
  WAIT_FOR_LOG=0
}

contains() { # label needle   (checks the case's log)
  local want=$2
  if log_lines | rg -qF -- "$want"; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s (log lacks: %s)\n' "$1" "$want"; fail=1; log_lines | sed 's/^/        /'; fi
}

# ── setups ────────────────────────────────────────────────────────
ledger_env() { CASE_ENV+=("NERDFLAIR_REPO_COST_FILE=$1" NERDFLAIR_REPO_COST_TTL=0); }

# "Disk full" stand-in: a ledger already BIGGER than the renderer's RLIMIT_FSIZE,
# so every append fails (EFBIG). /dev/full is no use here: the renderers also
# READ the ledger, and reading /dev/full never ends.
s_ledger_write() {
  local i
  for i in $(seq 1 120); do printf '%s\tsessFill\tsf-fill\t0.%02d\n' $(( NOW - 7200 + i )) "$i"; done > "$CASE_DIR/ledger.tsv"
  CASE_ULIMIT_F=4     # 4 KiB (bash ulimit -f counts 1 KiB blocks); the ledger is ~6 KiB
  ledger_env "$CASE_DIR/ledger.tsv"
}
s_ledger_open()  { : > "$CASE_DIR/ledger.tsv"; chmod 444 "$CASE_DIR/ledger.tsv"; ledger_env "$CASE_DIR/ledger.tsv"; }
s_ledger_dir()   { mkdir "$CASE_DIR/ldir"; chmod 555 "$CASE_DIR/ldir"; ledger_env "$CASE_DIR/ldir/l.tsv"; }

s_compact_dropped() {
  local f="$CASE_DIR/ledger.tsv"
  {
    printf '%s\tsessA\tsf-repo\t1.00\n' $(( NOW - 200 ))
    printf '%s\tsessA\tsf-repo\t2.00\n' $(( NOW - 100 ))
    printf 'this is garbage\n'
    printf '1\t2\t3\n'
    printf '%s\tsessB\tsf-repo\tNaNx\n' $(( NOW - 50 ))
  } > "$f"
  ledger_env "$f"; CASE_ENV+=(NERDFLAIR_REPO_COST_MAXBYTES=100)
}
s_compact_refused() {   # every valid row is older than the 30-day cutoff, and the append is refused
  local f="$CASE_DIR/ledger.tsv" i
  for i in 1 2 3; do printf '%s\tsessOld\tsf-repo\t%s.00\n' $(( 1700000000 + i )) "$i"; done > "$f"
  chmod 444 "$f"
  ledger_env "$f"; CASE_ENV+=(NERDFLAIR_REPO_COST_MAXBYTES=50)
}

s_state_corrupt() { printf '{ this is not json' > "$CASE_DIR/home/.claude/nerdflair/state.json"; }
chk_state_corrupt() {
  local st="$CASE_DIR/home/.claude/nerdflair/state.json"
  if [[ "$1" == bash ]]; then
    check "state-corrupt [bash]: original kept as state.json.corrupt" "{ this is not json" "$(cat "$st.corrupt" 2>/dev/null)"
    check "state-corrupt [bash]: state.json rebuilt as valid JSON" ok "$(jq -e . "$st" >/dev/null 2>&1 && echo ok || echo bad)"
    contains "state-corrupt [bash]: rebuild is logged too" "state-rebuilt"
  else
    # The Rust build degrades to defaults and logs, but leaves the file for the
    # user to inspect (it never rewrote a corrupt file; output parity is unaffected).
    check "state-corrupt [rust]: corrupt file left untouched" "{ this is not json" "$(cat "$st")"
  fi
}
s_state_write() { chmod 555 "$CASE_DIR/home/.claude/nerdflair"; }

s_mcp_fail() {
  printf '#!/bin/sh\necho "boom: cannot reach servers" >&2\nexit 1\n' > "$CASE_DIR/bin/claude"; chmod +x "$CASE_DIR/bin/claude"
  CASE_PATH="$CASE_DIR/bin:$PATH"; CASE_ENV+=(NERDFLAIR_MCP_HEALTH=1); WAIT_FOR_LOG=1
}
s_mcp_timeout() {
  printf '#!/bin/sh\nexec sleep 30\n' > "$CASE_DIR/bin/claude"; chmod +x "$CASE_DIR/bin/claude"
  CASE_PATH="$CASE_DIR/bin:$PATH"; CASE_ENV+=(NERDFLAIR_MCP_HEALTH=1 NERDFLAIR_MCP_PROBE_TIMEOUT=1); WAIT_FOR_LOG=1
}
s_git_dubious() {   # git refusing the repo, as it does for a safe.directory / ownership problem
  printf '#!/bin/sh\necho "fatal: detected dubious ownership in repository at '"'"'$PWD'"'"'" >&2\nexit 128\n' > "$CASE_DIR/bin/git"
  chmod +x "$CASE_DIR/bin/git"; CASE_PATH="$CASE_DIR/bin:$PATH"
}
s_git_missing() { CASE_PATH="$NOGIT"; }
s_git_hang() {
  printf '#!/bin/sh\nexec sleep 30\n' > "$CASE_DIR/bin/git"; chmod +x "$CASE_DIR/bin/git"
  CASE_PATH="$CASE_DIR/bin:$PATH"; CASE_ENV+=(NERDFLAIR_PROC_TIMEOUT_MS=300)
}
# A git that answers "inside a work tree" at once but hangs on everything else (a stalled
# filesystem under the repo): the call that times out must not leave a cached "clean,
# no branch" for the repository, because that would be served for the cache TTL.
git_cache_path() { printf '/tmp/nerdflair-git-%s' "$(printf '%s' "$CASE_DIR/work" | cksum | cut -d' ' -f1)"; }
s_git_partial_hang() {
  printf '#!/bin/sh\ncase "$1" in rev-parse) case "$*" in *is-inside-work-tree*) echo true; exit 0 ;; *--git-dir*) echo .git; exit 0 ;; esac ;; esac\nexec sleep 30\n' > "$CASE_DIR/bin/git"
  chmod +x "$CASE_DIR/bin/git"; mkdir -p "$CASE_DIR/work/.git"
  CASE_PATH="$CASE_DIR/bin:$PATH"; CASE_ENV+=(NERDFLAIR_PROC_TIMEOUT_MS=300)
  rm -f -- "$(git_cache_path)"
}
chk_git_not_cached() {
  if [[ -e "$(git_cache_path)" ]]; then printf '  FAIL  git timeout: a git cache file was written (%s)\n' "$(git_cache_path)"; fail=1
  else printf '  PASS  git timeout: no cache file written for the repo\n'; fi
  rm -f -- "$(git_cache_path)"
}
s_git_fast() {   # CONTROL: the same repo with a git that answers, so the cache path above is the real one
  printf '#!/bin/sh\ncase "$*" in *is-inside-work-tree*) echo true ;; *--git-dir*) echo .git ;; *symbolic-ref*) echo main ;; *) ;; esac\nexit 0\n' > "$CASE_DIR/bin/git"
  chmod +x "$CASE_DIR/bin/git"; mkdir -p "$CASE_DIR/work/.git"
  CASE_PATH="$CASE_DIR/bin:$PATH"
  rm -f -- "$(git_cache_path)"
}
chk_git_cached() {
  if [[ -e "$(git_cache_path)" ]]; then printf '  PASS  control: a working git does write the cache (path is right)\n'
  else printf '  FAIL  control: no cache file for a working git; the not-cached check above proves nothing\n'; fail=1; fi
  rm -f -- "$(git_cache_path)"
}
s_git_backoff() {   # a hang was seen 10 s ago: this render must not run git at all
  s_git_hang
  : > "$CASE_DIR/stamps/nerdflair-err-$(id -u)-git_hung"
}
s_cwd_gone() { PAYLOAD=${PAYLOAD//"$CASE_DIR/work"/"$CASE_DIR/gone"}; }
s_mktemp_bad() { CASE_ENV+=(TMPDIR=/nonexistent/nf); }
s_git_term_ignored() {   # a git that ignores SIGTERM: bash's `timeout -k` ends it with KILL (rc 137), which is still a timeout
  printf '#!/bin/sh\ncase "$1" in rev-parse) case "$*" in *is-inside-work-tree*) echo true; exit 0 ;; *--git-dir*) echo .git; exit 0 ;; esac ;; esac\ntrap "" TERM\nexec sleep 30\n' > "$CASE_DIR/bin/git"
  chmod +x "$CASE_DIR/bin/git"; mkdir -p "$CASE_DIR/work/.git"
  CASE_PATH="$CASE_DIR/bin:$PATH"; CASE_ENV+=(NERDFLAIR_PROC_TIMEOUT_MS=300)
  rm -f -- "$(git_cache_path)"
}
s_cwd_locked() { mkdir "$CASE_DIR/locked"; chmod 000 "$CASE_DIR/locked"; PAYLOAD=${PAYLOAD//"$CASE_DIR/work"/"$CASE_DIR/locked"}; }
s_project_locked() { mkdir "$CASE_DIR/locked"; chmod 000 "$CASE_DIR/locked"; PAYLOAD=${PAYLOAD/\"project_dir\":\"$CASE_DIR\/work\"/\"project_dir\":\"$CASE_DIR\/locked\"}; }
s_multi_cache_locked() {   # a wrapper of two repos whose (fresh) multi-branch cache file cannot be read
  mkdir -p "$CASE_DIR/work/a/.git" "$CASE_DIR/work/b/.git"
  local f="/tmp/nerdflair-multibranch-$(printf '%s' "$CASE_DIR/work" | cksum | cut -d' ' -f1)"
  rm -f -- "$f"; printf '0\n' > "$f"; chmod 000 "$f"
  MULTI_CACHE_FILE="$f"
}
chk_multi_cache_rm() { chmod 644 -- "$MULTI_CACHE_FILE" 2>/dev/null; rm -f -- "$MULTI_CACHE_FILE"; }
s_chime_volume_bad() {
  printf '{"mode":"full","width":"auto","flair":true,"terminal_bell":"on","chime_sound":"Glass","chime_volume":"loud","chime_style":"random","chime_events":"Notification,Stop","color":"vibrant","last_session":"","chime_recent_styles":[]}' > "$CASE_DIR/home/.claude/nerdflair/state.json"
}
s_usage_float() {   # no usage figures in the payload; the transcript's last usage has a fractional count
  printf '{"message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":1,"cache_read_input_tokens":12.5,"output_tokens":3}}}\n' > "$CASE_DIR/t.jsonl"
  PAYLOAD=$(printf '{"session_id":"%s-u","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"%s","project_dir":"%s"},"transcript_path":"%s/t.jsonl","context_window":{"context_window_size":200000},"cost":{"total_cost_usd":1.25}}' "$TAG" "$CASE_DIR/work" "$CASE_DIR/work" "$CASE_DIR")
}
s_stamp_marker_dangling() {   # the marker cannot be written either, so it cannot rate limit: one line per render
  s_stamp_symlink; ln -s "$CASE_DIR/nowhere" "$CASE_DIR/home/.claude/.nerdflair-stamp-dir-bad"
}
s_git_killed() {   # a git SIGKILLed long before the deadline: logged as an external kill, no back-off stamp
  printf '#!/bin/sh\ncase "$1" in rev-parse) case "$*" in *is-inside-work-tree*) echo true; exit 0 ;; *--git-dir*) echo .git; exit 0 ;; esac ;; esac\nkill -9 $$\n' > "$CASE_DIR/bin/git"
  chmod +x "$CASE_DIR/bin/git"; mkdir -p "$CASE_DIR/work/.git"
  CASE_PATH="$CASE_DIR/bin:$PATH"; rm -f -- "$(git_cache_path)"
}
chk_git_killed() {
  if [[ -e "$CASE_DIR/stamps/nerdflair-err-$(id -u)-git_hung" ]]; then printf '  FAIL  git-killed: the hang back-off was armed by an external kill\n'; fail=1
  else printf '  PASS  git-killed: no git-hung back-off armed\n'; fi
}
s_state_empty() { : > "$CASE_DIR/home/.claude/nerdflair/state.json"; }
chk_state_empty() {   # bash rebuilds the file (and no write may fail); Rust leaves it and must log it
  local st="$CASE_DIR/home/.claude/nerdflair/state.json"
  if [[ "$1" == bash ]]; then
    check "state-empty-file [bash]: state.json rebuilt as valid JSON" ok "$(jq -e . "$st" >/dev/null 2>&1 && echo ok || echo bad)"
  else
    contains "state-empty-file [rust]: the unusable file is logged" "state-corrupt"
  fi
}
s_stamp_symlink() {   # the default stamp dir is a symlink: unusable, and that must be said (the override env is blanked)
  ln -s "$CASE_DIR/tmp" "$CASE_DIR/home/.claude/.nerdflair-stamps"; CASE_ENV+=(NERDFLAIR_ERR_STAMP_DIR=)
}
s_transcript_missing() {
  PAYLOAD=$(printf '{"session_id":"%s-tm","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"%s","project_dir":"%s"},"transcript_path":"%s/nope.jsonl","cost":{"total_cost_usd":1.25}}' \
    "$TAG" "$CASE_DIR/work" "$CASE_DIR/work" "$CASE_DIR")
}
s_payload_bad()   { PAYLOAD='{bad json'; }
s_payload_empty() { PAYLOAD=''; }
s_panic()         { CASE_ENV+=(NERDFLAIR_TEST_PANIC=1); }
chk_panic() {
  check "panic [rust]: stdout stays empty" 0 "$(wc -c < "$CASE_DIR/out.1" | tr -d ' ')"
  check "panic [rust]: process still dies non-zero" nonzero "$([[ "$(cat "$CASE_DIR/rc.1")" != 0 ]] && echo nonzero || echo zero)"
  contains "panic [rust]: message and location logged" "src/main.rs"
}
s_env_bad() { CASE_ENV+=(NERDFLAIR_BURN_WINDOW=abc); }

s_noise_lock() {   # the compactor "holds" the ledger lock: skipping a sample is correct and silent
  : > "$CASE_DIR/ledger.tsv"; ledger_env "$CASE_DIR/ledger.tsv"
  ( exec 9>"$CASE_DIR/ledger.tsv.lock"; flock -x 9; : > "$CASE_DIR/held"; exec sleep 60 ) &
  HOLDER_PID=$!
  wait_until 10 test -e "$CASE_DIR/held" || echo "  (lock holder did not start)" >&2
}
s_none() { :; }
chk_noise_lock() { kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""; }

# ── the cases ─────────────────────────────────────────────────────
echo "silent-failures: $RENDERS renders per case, throwaway HOME, both renderers"
echo
echo "FAILURE classes (each must log exactly one line):"
run_case ledger-unwritable-file   ledger-write           1 s_ledger_write
run_case ledger-readonly-file     ledger-open            1 s_ledger_open
run_case ledger-dir-unwritable    flock-open             1 s_ledger_dir
run_case corrupt-state            state-corrupt          1 s_state_corrupt chk_state_corrupt
run_case state-dir-unwritable     state-write            1 s_state_write
run_case compaction-corrupt-rows  ledger-compact-dropped 1 s_compact_dropped
run_case compaction-refused       ledger-compact-refused 1 s_compact_refused
run_case mcp-probe-exit1          mcp-probe              1 s_mcp_fail
run_case mcp-probe-timeout        mcp-probe              1 s_mcp_timeout
run_case git-dubious-ownership    git:inside-work-tree:128 1 s_git_dubious
run_case git-not-installed        spawn:git              1 s_git_missing
run_case git-hangs                timeout:git:inside-work-tree 1 s_git_hang
run_case git-partial-hang          timeout:git:status 1 s_git_partial_hang chk_git_not_cached
run_case git-fast-control          -   0 s_git_fast chk_git_cached
run_case git-term-ignored          timeout:git:status 1 s_git_term_ignored chk_git_not_cached
run_case git-hang-backoff          timeout:git:inside-work-tree 0 s_git_backoff
run_case cwd-cd-fails              cwd-cd 1 s_cwd_gone
run_case cwd-not-enterable         cwd-cd 1 s_cwd_locked
run_case project-dir-locked        project-dir-resolve 1 s_project_locked
run_case multi-cache-unreadable    multi-cache-read 1 s_multi_cache_locked chk_multi_cache_rm
run_case chime-volume-bad          chime-volume 1 s_chime_volume_bad
run_case usage-not-integer         ctx-usage-type 1 s_usage_float
run_case state-empty-file          state-write 0 s_state_empty chk_state_empty
run_case stamp-dir-symlink         stamp-dir 1 s_stamp_symlink
run_case stamp-marker-dangling     stamp-dir 4 s_stamp_marker_dangling
IMPLS=bash
run_case git-killed-externally     killed:git:status 1 s_git_killed chk_git_killed
IMPLS=rust
run_case git-killed-externally-rs  git:status:signal 1 s_git_killed chk_git_killed
IMPLS="rust bash"
IMPLS=bash
run_case mktemp-fails              buf-mktemp 1 s_mktemp_bad
IMPLS="rust bash"
run_case missing-transcript       ctx-transcript-missing 1 s_transcript_missing
run_case bad-payload-json         payload-parse          1 s_payload_bad
run_case empty-payload            payload-empty          1 s_payload_empty
run_case nonnumeric-tunable       env-bad:NERDFLAIR_BURN_WINDOW 1 s_env_bad
IMPLS="rust"
run_case panic                    panic                  1 s_panic chk_panic
IMPLS="rust bash"

# _nf_err's once-per-process memo must compare keys literally: 'spawn:*' is a new key
# after 'spawn:abc', not a glob that matches it (nor may it silence later keys).
_memo_lines=$( ( export HOME="$WORK/memo-home" NERDFLAIR_ERR_STAMP_DIR="$WORK/memo-stamps"; mkdir -p "$HOME/.claude" "$NERDFLAIR_ERR_STAMP_DIR"
  source "$REPO/scripts/lib.sh"; _nf_err 'spawn:abc' one; _nf_err 'spawn:*' two; _nf_err 'spawn:xyz' three
  wc -l < "$HOME/.claude/nerdflair-errors.log" ) 2>/dev/null )
check "lib.sh _nf_err memo: keys with glob characters are literal (3 lines)" 3 "${_memo_lines//[[:space:]]/}"

# hooks/bell.sh reads the same state file but not the renderer: a non-numeric chime_volume must be
# defaulted and logged by lib.sh, or awk reads "loud" as 0 and the hook mutes itself silently.
BV="$WORK/bell-vol"; mkdir -p "$BV/home/.claude/nerdflair" "$BV/stamps" "$BV/work"
printf '{"mode":"full","width":"auto","flair":true,"terminal_bell":"off","chime_sound":"Glass","chime_volume":"loud","chime_style":"random","chime_events":"Notification,Stop","color":"vibrant","last_session":"","chime_recent_styles":[]}' > "$BV/home/.claude/nerdflair/state.json"
( cd "$BV/work" && printf '{"hook_event_name":"Stop","session_id":"%s-b"}' "$TAG" | timeout 20 env -i PATH="$PATH" HOME="$BV/home" TMPDIR="$BV" \
    NERDFLAIR_ERR_STAMP_DIR="$BV/stamps" bash "$REPO/hooks/bell.sh" >/dev/null 2>&1 )
check "bell.sh: a non-numeric chime_volume is logged by the hook (1 line)" 1 "$(rg -cF ' chime-volume: ' "$BV/home/.claude/nerdflair-errors.log" 2>/dev/null || echo 0)"
_bv=$( ( export HOME="$BV/home" NERDFLAIR_ERR_STAMP_DIR="$BV/stamps2"; mkdir -p "$NERDFLAIR_ERR_STAMP_DIR"; source "$REPO/scripts/lib.sh"; _nf_read_state; printf '%s' "$NF_CUR_CHIME_VOLUME" ) 2>/dev/null )
check "lib.sh: a non-numeric chime_volume is defaulted to 1 for every consumer" 1 "$_bv"

echo
echo "NOISE (must stay completely silent):"
run_case noise-lock-contention    -  0 s_noise_lock chk_noise_lock
run_case noise-baseline-not-a-repo-missing-optional-files - 0 s_none

echo
(( fail )) && { echo "silent-failures: FAIL"; exit 1; }
echo "silent-failures: PASS"

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
run_case missing-transcript       ctx-transcript-missing 1 s_transcript_missing
run_case bad-payload-json         payload-parse          1 s_payload_bad
run_case empty-payload            payload-empty          1 s_payload_empty
run_case nonnumeric-tunable       env-bad:NERDFLAIR_BURN_WINDOW 1 s_env_bad
IMPLS="rust"
run_case panic                    panic                  1 s_panic chk_panic
IMPLS="rust bash"

echo
echo "NOISE (must stay completely silent):"
run_case noise-lock-contention    -  0 s_noise_lock chk_noise_lock
run_case noise-baseline-not-a-repo-missing-optional-files - 0 s_none

echo
(( fail )) && { echo "silent-failures: FAIL"; exit 1; }
echo "silent-failures: PASS"

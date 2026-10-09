#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# loadtest.sh — prove the statusline cannot melt the machine again.
#
# On 2026-10-08 the ccusage bridge put WSL into unrecoverable swap: 22
# concurrent `ccusage statusline` processes, ~46 GB RSS, load ~240. The cause
# was a background refresh whose runtime had outgrown its own stale-lock
# breaker, so every breaker firing added a runner instead of replacing one.
#
# This harness reproduces the conditions that triggered it (N sessions, each
# invoking the statusline far faster than any refresh interval) and samples the
# things that ran away, so a regression shows up as a trend rather than a
# verdict at the end.
#
# Usage:
#   ./loadtest.sh                       20 workers, 600s
#   ./loadtest.sh --workers 30 --secs 120
#   ./loadtest.sh --bin /path/to/nerdflair-statusline
#   ./loadtest.sh --ccusage             re-enable the bridge (expected to FAIL)
#
# Pass criteria. Each is written to catch the 2026-10-08 failure specifically,
# and NOT to catch the harness working as intended:
#
#   - no accumulation: the peak helper count never exceeds WORKERS. This is
#     the exact invariant. Each worker drives one render at a time, so the
#     count can only pass WORKERS if something is outliving the render that
#     started it, which is precisely what the outage was: 22 processes against
#     14 sessions. A mean-of-thirds trend was tried first and is WRONG here --
#     the count is bimodal (0 between renders, a burst during them), so the
#     comparison only measures which samples happened to land on a burst, and
#     it both failed clean runs and passed by luck.
#   - helper RSS total stays under RSS_CAP_MB (no memory runaway).
#   - no orphans: once the workers are killed, every helper is gone within
#     ORPHAN_GRACE seconds. This is the direct test for the detached spawn that
#     outlived its parent and could not be reaped by anything.
#   - no zombies PARENTED TO THIS TEST. System-wide zombie counts are not ours
#     to pass or fail on; other tooling on this box leaves some.
#
# Load average is reported but deliberately NOT a criterion in --hammer mode:
# spinning WORKERS tight loops pegs the CPU by construction, which measures the
# harness, not the statusline. In the default paced mode it is a criterion.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

BIN="$REPO_ROOT/rust/target/release/nerdflair-statusline"
WORKERS=20
SECS=600
RSS_CAP_MB=1500
WITH_CCUSAGE=0
WITH_MCP=0
ORPHAN_GRACE=10
# Claude Code debounces the status line to ~300ms and refreshes on a 30s timer.
# 0.2s per worker is already far faster than it can ever be driven for real;
# --hammer removes the pacing entirely for the pathological case.
PACE=0.2

while (( $# )); do
  case "$1" in
    --bin) BIN="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --secs) SECS="$2"; shift 2 ;;
    --rss-cap-mb) RSS_CAP_MB="$2"; shift 2 ;;
    --hammer) PACE=0; shift ;;
    --pace) PACE="$2"; shift 2 ;;
    --ccusage) WITH_CCUSAGE=1; shift ;;
    --mcp) WITH_MCP=1; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'loadtest: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -x "$BIN" ]] || { printf 'loadtest: not executable: %s\n' "$BIN" >&2; exit 2; }

RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nerdflair-loadtest-XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null' EXIT

# Each worker gets its own session_id, as real sessions do: that is what makes
# the per-session sampler and repo-cost stamp files multiply.
now=$(date +%s)
mk_payload() {
  cat <<JSON
{"session_id":"loadtest-$1",
 "transcript_path":"/nonexistent/transcript.jsonl",
 "model":{"display_name":"Opus 5.5","id":"claude-opus-5-5"},
 "workspace":{"current_dir":"$REPO_ROOT","project_dir":"$REPO_ROOT"},
 "context_window":{"context_window_size":200000,"total_input_tokens":74000,
                   "total_output_tokens":12000,"used_percentage":37},
 "cost":{"total_cost_usd":4.73,"total_duration_ms":1860000,
         "total_api_duration_ms":240000},
 "rate_limits":{"five_hour":{"used_percentage":23,
                             "resets_at":"$(date -u -d @$((now+9000)) +%Y-%m-%dT%H:%M:%SZ)"}}}
JSON
}

export NERDFLAIR_CCUSAGE=$WITH_CCUSAGE
# Off by default: the probe shells out to `claude mcp list`, which starts
# every configured MCP server. A load test must not drive the real ones, and
# leaving it unset meant it silently did. --mcp exercises that path on
# purpose, and the census below can see it pile up when it is on.
export NERDFLAIR_MCP_HEALTH=${WITH_MCP:-0}
# Point per-repo cost accounting at the scratch dir so a load test never
# contaminates the real ledger that drives the dollar readouts.
export NERDFLAIR_REPO_COST_FILE="$RUN_DIR/usage.tsv"

printf 'loadtest: %s\n' "$BIN"
printf '  workers=%s secs=%s pace=%ss ccusage=%s rss_cap=%sMB\n' \
  "$WORKERS" "$SECS" "$PACE" "$WITH_CCUSAGE" "$RSS_CAP_MB"
printf '  run dir: %s\n\n' "$RUN_DIR"

load_start=$(awk '{print $1}' /proc/loadavg)

WORKER_PIDS=()
for i in $(seq 1 "$WORKERS"); do
  (
    payload=$(mk_payload "$i")
    while :; do
      printf '%s' "$payload" | "$BIN" >/dev/null 2>&1
      [[ "$PACE" != "0" ]] && read -r -t "$PACE" _ < /dev/zero 2>/dev/null
      :
    done
  ) &
  WORKER_PIDS+=($!)
done

# ── sample ───────────────────────────────────────────────────────────────────
# Scope every measurement to THIS TEST's process group. On a machine that is
# also running real Claude Code sessions, a system-wide `pgrep nerdflair` counts
# their status lines too, and the test then fails on someone else's work. That
# is what the first version of this harness did.
#
# The process group is the right scope because nerdflair's background refresh
# is spawned with a plain fork+exec and no setsid (see proc.rs spawn_detached),
# so a detached refresh stays in our group and IS counted here. If that ever
# changes to setsid, this census goes blind and the orphan check below is the
# one that still catches it, system-wide.
MY_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
# Every process already in our group before the workers start is the HARNESS,
# not a helper: this script, its shell, and whatever wrapper the caller used.
# A `timeout 200 ./loadtest.sh` wrapper has comm "timeout", which the census
# pattern matches, so without this the test counts its own invocation as a
# surviving orphan and fails. Captured once, excluded forever after.
BASELINE=$(ps -eo pid,pgid --no-headers 2>/dev/null \
  | awk -v g="$MY_PGID" '$2 == g { printf "%s ", $1 }')

# Match on comm (the executable name, truncated to 15 chars by the kernel), not
# args: an args match also matches the awk program text that names them.
census() {
  ps -eo pgid,rss,comm,pid --no-headers 2>/dev/null \
    | awk -v g="$MY_PGID" -v base=" $BASELINE " '
    $1 == g && index(base, " " $4 " ") == 0 \
      && $3 ~ /^(nerdflair-stat|ccusage|nvidia-smi|claude|timeout)/ { n++; kb += $2 }
    END { printf "%d %d\n", n+0, kb+0 }'
}

# Anything of ours still alive anywhere once the workers are gone, regardless
# of process group, so a future setsid cannot hide an orphan from this check.
census_global() {
  ps -eo rss,comm,etimes --no-headers 2>/dev/null | awk -v t="$1" '
    $2 ~ /^(ccusage)/ && $3 <= t { n++ }
    END { print n+0 }'
}
# Only zombies this test is responsible for. Other tooling on this machine
# leaves its own behind, and failing on those would make the result depend on
# whatever else is running.
# Prints the PIDs, not a count, because identity is the whole point. A count
# cannot tell "one child nobody reaped" from "a different transient each time",
# and the workers fork a pipeline continuously, so transients are constant and
# land in consecutive samples by chance alone. Counting them made this check
# fail on healthy runs while still being unable to prove the thing it claims.
our_zombies() {
  local ours
  ours=$(printf '%s|' "${WORKER_PIDS[@]}"); ours="${ours%|}"
  ps -eo stat,ppid,pid --no-headers 2>/dev/null \
    | awk -v re="^(${ours})$" '$1 ~ /^Z/ && $2 ~ re { print $3 }'
}

max_n=0; max_rss_mb=0; max_zomb=0; samples=0; zomb_run=0; zomb_run_max=0
counts=()
printf '%-8s %-8s %-10s %-9s %s\n' elapsed procs rss_mb zombies load
deadline=$(( $(date +%s) + SECS ))
while (( $(date +%s) < deadline )); do
  read -r n kb < <(census)
  mb=$(( kb / 1024 ))
  z=$(our_zombies)
  l=$(awk '{print $1}' /proc/loadavg)
  (( n > max_n )) && max_n=$n
  (( mb > max_rss_mb )) && max_rss_mb=$mb
  (( z > max_zomb )) && max_zomb=$z
  # A single Z between a child's exit and its parent's wait is normal. Only a
  # zombie that SURVIVES consecutive samples means nobody is reaping.
  if (( z > 0 )); then
    zomb_run=$((zomb_run+1))
    (( zomb_run > zomb_run_max )) && zomb_run_max=$zomb_run
  else
    zomb_run=0
  fi
  counts+=("$n")
  samples=$((samples+1))
  printf '%-8s %-8s %-10s %-9s %s\n' \
    "$(( SECS - (deadline - $(date +%s)) ))s" "$n" "$mb" "$z" "$l"
  read -r -t 5 _ < /dev/zero 2>/dev/null || true
done

load_end=$(awk '{print $1}' /proc/loadavg)
kill "${WORKER_PIDS[@]}" 2>/dev/null; wait 2>/dev/null

# ── orphan check: nothing of ours may outlive the workers ────────────────────
orphans=-1
for _ in $(seq 1 "$ORPHAN_GRACE"); do
  read -r n _ < <(census)
  if (( n == 0 )); then orphans=0; break; fi
  orphans=$n
  read -r -t 1 _ < /dev/zero 2>/dev/null || true
done

# ── verdict ──────────────────────────────────────────────────────────────────
fail=0
chk() { # label actual limit truth
  if (( $4 )); then printf '  PASS  %-30s %s (limit %s)\n' "$1" "$2" "$3"
  else printf '  FAIL  %-30s %s (limit %s)\n' "$1" "$2" "$3"; fail=1; fi
}
printf '\nsamples: %s over %ss\n' "$samples" "$SECS"

chk "peak helpers <= workers" "$max_n" "$WORKERS" "$(( max_n <= WORKERS ))"
chk "peak helper RSS (MB)" "$max_rss_mb" "$RSS_CAP_MB" "$(( max_rss_mb <= RSS_CAP_MB ))"
chk "consecutive samples w/ zombie" "$zomb_run_max" 1 "$(( zomb_run_max <= 1 ))"
chk "orphans after workers killed" "$orphans" 0 "$(( orphans == 0 ))"
chk "young ccusage runs left alive" "$(census_global "$SECS")" 0 "$(( $(census_global "$SECS") == 0 ))"
# Reported, not judged: see the header on why a trend is the wrong statistic
# for a bimodal instantaneous count.
third=$(( samples / 3 ))
if (( third >= 2 )); then
  printf '  ----  mean helpers, first third %s, last third %s (context only)\n' \
    "$(printf '%s\n' "${counts[@]:0:$third}" | awk '{s+=$1} END {printf "%.2f", s/NR}')" \
    "$(printf '%s\n' "${counts[@]: -$third}" | awk '{s+=$1} END {printf "%.2f", s/NR}')"
fi
# Load average is NOT a criterion. It belongs to the whole machine, and this
# box runs real Claude Code sessions while the test runs, so a rise here is not
# attributable to the status line. Peak RSS and the count trend are.
printf '  ----  system load %s -> %s (context only, not attributable)\n' \
  "$load_start" "$load_end"

rm -rf "$RUN_DIR"
(( fail )) && { printf '\nloadtest: FAIL\n'; exit 1; }
printf '\nloadtest: PASS\n'

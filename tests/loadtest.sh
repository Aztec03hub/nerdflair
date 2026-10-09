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
#   - no zombies PARENTED TO THIS TEST, tracked BY PID across samples: the
#     criterion is "the same child is still unreaped", which a count cannot
#     express. `--prove-zombie-check` plants one deliberately and the run must
#     then FAIL; a PASS means the check is blind. Written in Python, because
#     bash reaps its own background children and the obvious one-liner plants
#     nothing while looking like it works.
#   - the run actually applied load. Workers must be alive at the end, and the
#     invocation counter must be non-zero. Both exist because this harness
#     spent a while passing every check on a machine where nothing ran.
#
# WHY "peak helpers" READS ZERO ON A HEALTHY RUN. A render lives about 2ms and
# the sampler fires every 5s, so it is caught roughly 6 times in 100
# (measured). Zero is the normal reading and is NOT evidence the workers are
# idle; the invocation counter is what answers that. The criterion is aimed at
# the meltdown shape, where the runaway processes persist and cannot be missed.
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
PROVE_ZOMBIE=0
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
    # Plant an unreaped child, so the zombie criterion must FAIL. The way to
    # find out whether that check still works.
    --prove-zombie-check) PROVE_ZOMBIE=1; shift ;;
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
      # One byte per invocation, so the run can prove it applied load. The
      # sampler cannot: a healthy render lives about 2ms and is caught in ps
      # roughly 6 times in 100 (measured), so "peak helpers 0" is the normal
      # reading on a working machine and says nothing about whether the
      # workers ran at all. Appends this small are atomic between processes.
      printf '.' >> "$RUN_DIR/iters"
      [[ "$PACE" != "0" ]] && read -r -t "$PACE" _ < /dev/zero 2>/dev/null
      :
    done
  ) &
  WORKER_PIDS+=($!)
done

# A worker that dies at once makes every census below read zero, and every
# check then PASSES on a test that measured nothing. That is worse than a
# failure, because it is indistinguishable from a healthy run, and it is
# exactly what this harness was doing: six workers were started and one
# survived, so "peak helpers 0, limit 6" was certifying an empty machine.
sleep 1
alive=0
for p in "${WORKER_PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done
printf '  workers alive after start: %s of %s\n' "$alive" "$WORKERS"
if (( alive < WORKERS )); then
  printf 'loadtest: workers died at startup; the run would measure nothing\n' >&2
  exit 2
fi

# ── positive control ─────────────────────────────────────────────────────────
# A green zombie check from a run that never had a zombie proves nothing: the
# criterion has to be shown capable of failing. This plants ONE child that
# exits and is deliberately never reaped, parented to a process in
# WORKER_PIDS so it is ours. With it, the run MUST report FAIL on the zombie
# line; a PASS means the check is blind and everything it has ever certified
# is worthless.
#
# NOT written in bash. `( exit 0 ) &` leaves nothing behind: bash reaps its
# own background children asynchronously so it can report their status, so
# the obvious one-liner plants no zombie and the control passes, which looks
# exactly like a working check. Python's parent never calls waitpid unless
# told to, so the child really does sit in Z.
if (( PROVE_ZOMBIE )); then
  python3 -c '
import os, sys, time
if os.fork() == 0:
    os._exit(0)          # dies at once, and nobody will wait for it
time.sleep(float(sys.argv[1]))
' "$(( SECS + 30 ))" &
  WORKER_PIDS+=($!)
  printf '  positive control: one unreaped child planted; the zombie check MUST fail\n'
fi

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

max_n=0; max_rss_mb=0; max_zomb=0; samples=0
counts=()
# Zombies are tracked BY PID across samples, because the criterion is "the
# same child is still unreaped", which a count cannot express. Keyed by pid,
# the value is how many consecutive samples that pid has been a zombie for.
declare -A zomb_runs=()
stuck_pids=""; max_zomb_run=0
printf '%-8s %-8s %-10s %-9s %s\n' elapsed procs rss_mb zombies load
deadline=$(( $(date +%s) + SECS ))
while (( $(date +%s) < deadline )); do
  read -r n kb < <(census)
  mb=$(( kb / 1024 ))
  z_pids=$(our_zombies)
  l=$(awk '{print $1}' /proc/loadavg)
  (( n > max_n )) && max_n=$n
  (( mb > max_rss_mb )) && max_rss_mb=$mb
  # A single Z between a child's exit and its parent's wait is normal, so the
  # count is for the operator to read, not a criterion.
  z=0
  for p in $z_pids; do z=$((z+1)); done
  (( z > max_zomb )) && max_zomb=$z
  # The criterion: has any ONE pid stayed a zombie across samples. A pid seen
  # again carries its run forward; every pid not seen this time is reaped and
  # drops out. Counting instead of tracking identity made this fail on healthy
  # runs, because the workers fork a pipeline continuously and a different
  # transient lands in consecutive samples by chance alone.
  declare -A seen_now=()
  for p in $z_pids; do
    seen_now[$p]=1
    zomb_runs[$p]=$(( ${zomb_runs[$p]:-0} + 1 ))
    if (( zomb_runs[$p] > max_zomb_run )); then
      max_zomb_run=${zomb_runs[$p]}
      case " $stuck_pids " in *" $p "*) ;; *) stuck_pids="$stuck_pids $p" ;; esac
    fi
  done
  for p in "${!zomb_runs[@]}"; do
    [[ -n "${seen_now[$p]:-}" ]] || unset 'zomb_runs[$p]'
  done
  counts+=("$n")
  samples=$((samples+1))
  printf '%-8s %-8s %-10s %-9s %s\n' \
    "$(( SECS - (deadline - $(date +%s)) ))s" "$n" "$mb" "$z" "$l"
  read -r -t 5 _ < /dev/zero 2>/dev/null || true
done

load_end=$(awk '{print $1}' /proc/loadavg)
# Workers must still be driving the binary at the END, not just at the start.
# If they die halfway the later samples measure an idle machine and drag every
# peak down towards a pass.
alive_end=0
for p in "${WORKER_PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive_end=$((alive_end+1)); done
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

# Against the list, not $WORKERS: the positive control appends itself, and
# counting it as a surplus worker made that run fail for the wrong reason.
chk "workers alive at end" "$alive_end" "${#WORKER_PIDS[@]}" \
  "$(( alive_end == ${#WORKER_PIDS[@]} ))"
# Did the run apply any load at all. Without this the whole verdict can be
# green on a machine where nothing ever ran, which is the one outcome that
# looks identical to a perfect result.
iters=$(wc -c < "$RUN_DIR/iters" 2>/dev/null || echo 0)
chk "binary invocations" "$iters" 1 "$(( iters >= 1 ))"
printf '  ----  %s invocations over %ss across %s workers (%s/s)\n' \
  "$iters" "$SECS" "$WORKERS" "$(( iters / (SECS > 0 ? SECS : 1) ))"
# Peak concurrent helpers. Expect ZERO on a healthy run: a render lives ~2ms
# and the sampler fires every 5s, so it catches one about 6 times in 100.
# This criterion is for the meltdown shape, where runaway processes PERSIST
# and are therefore impossible to miss.
chk "peak helpers <= workers" "$max_n" "$WORKERS" "$(( max_n <= WORKERS ))"
chk "peak helper RSS (MB)" "$max_rss_mb" "$RSS_CAP_MB" "$(( max_rss_mb <= RSS_CAP_MB ))"
chk "samples one zombie survived" "$max_zomb_run" 1 "$(( max_zomb_run <= 1 ))"
(( max_zomb_run > 1 )) && printf '        unreaped pids:%s\n' "$stuck_pids"
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

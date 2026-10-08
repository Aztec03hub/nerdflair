#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ledger-concurrency.sh — can a compaction drop a row appended under it?
#
# ~14 Claude Code sessions append to ~/.claude/nerdflair-usage.tsv every 60s
# while any one of them may decide to compact it. Compaction is
# read-all / rewrite-temp / rename, so every row that lands between the read
# and the rename lives on the old inode and dies with it, unless appenders are
# excluded for the whole operation.
#
# The real path holds a SHARED flock to append and an EXCLUSIVE one to
# compact. This exercises that under contention.
#
# Two arms, because a test that cannot fail proves nothing:
#   locked    appenders take the shared lock, as production does  -> expect 0 lost
#   unlocked  appenders skip the lock (the pre-flock behaviour)   -> expect >0 lost
#
# Usage:
#   ./ledger-concurrency.sh                 both arms
#   ./ledger-concurrency.sh --rounds 40 --writers 14
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

WRITERS=14          # Phil's observed concurrent session count
ROUNDS=30           # compaction attempts per arm
PER_WRITER=60       # rows each writer appends

while (( $# )); do
  case "$1" in
    --writers) WRITERS="$2"; shift 2 ;;
    --rounds)  ROUNDS="$2";  shift 2 ;;
    --rows)    PER_WRITER="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'ledger-concurrency: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

RUN=$(mktemp -d "${TMPDIR:-/tmp}/nerdflair-ledgertest-XXXXXX")
trap 'rm -rf "$RUN"' EXIT

# The compactor under test: the same awk and the same temp-then-rename the
# renderer runs, so this tests the real algorithm rather than a sketch of it.
compact() {  # $1=ledger $2=lockfile $3=now
  local L="$1" LK="$2" NOW="$3"
  (
    flock -x -n 9 || exit 1
    awk -F'\t' -v cutoff=$(( NOW - 30*86400 )) -v full_from=$(( NOW - 3*86400 )) \
        -v maxcost=100000 '
      NF==4 && $1+0 >= 1600000000 && $1+0 <= 4000000000 \
        && $4+0 > 0 && $4+0 < maxcost && $1+0 >= cutoff {
        if ($1+0 >= full_from) { recent[++r] = $0; next }
        k = $2 "\t" $3
        if (!(k in ot) || $1+0 >= ot[k]) { ot[k] = $1+0; ol[k] = $0 }
      }
      END {
        n = 0
        for (k in ol) { n++; ts[n] = ot[k]; ln[n] = ol[k] }
        for (i = 2; i <= n; i++) {
          vt = ts[i]; vl = ln[i]; j = i - 1
          while (j >= 1 && (ts[j] > vt || (ts[j] == vt && ln[j] > vl))) {
            ts[j+1] = ts[j]; ln[j+1] = ln[j]; j--
          }
          ts[j+1] = vt; ln[j+1] = vl
        }
        for (i = 1; i <= n; i++) print ln[i]
        for (i = 1; i <= r; i++) print recent[i]
      }' "$L" > "$L.tmp" 2>/dev/null \
      && mv -f "$L.tmp" "$L"
  ) 9>>"$LK" 2>/dev/null
}

arm() {  # $1 = "locked" | "unlocked"
  local mode="$1"
  local L="$RUN/$mode.tsv" LK="$RUN/$mode.lock" EXP="$RUN/$mode.expected"
  local now; now=$(date +%s)
  : > "$L"; : > "$LK"; : > "$EXP"

  # Seed rows older than full_days so compaction always has work to do.
  for s in $(seq 1 20); do
    printf '%s\tseed-%s\trepo\t%s\n' "$(( now - 10*86400 ))" "$s" "1.5" >> "$L"
  done

  local pids=()
  for w in $(seq 1 "$WRITERS"); do
    (
      for i in $(seq 1 "$PER_WRITER"); do
        # Cumulative cost, as the real ledger records it.
        row=$(printf '%s\tsess-%s\trepo\t%s.00' "$now" "$w" "$i")
        if [[ "$mode" == "locked" ]]; then
          # Blocking shared lock: every row definitely lands, so anything
          # missing afterwards was destroyed by a compaction, not skipped.
          ( flock -s 9; printf '%s\n' "$row" >> "$L" ) 9>>"$LK"
        else
          printf '%s\n' "$row" >> "$L"
        fi
        printf '%s\n' "$row" >> "$EXP"
      done
    ) &
    pids+=($!)
  done

  for _ in $(seq 1 "$ROUNDS"); do
    compact "$L" "$LK" "$now"
    read -r -t 0.05 _ < /dev/zero 2>/dev/null || true
  done
  wait "${pids[@]}" 2>/dev/null
  compact "$L" "$LK" "$now"

  local wrote lost malformed
  wrote=$(wc -l < "$EXP")
  lost=$(comm -23 <(sort -u "$EXP") <(sort -u "$L") | wc -l)
  malformed=$(awk -F'\t' 'NF != 4 {n++} END {print n+0}' "$L")
  # Progress to stderr, the machine-readable result to stdout: the caller
  # reads stdout into two variables and a stray human line lands in them.
  printf '  %-9s wrote=%-5s lost=%-5s malformed=%s\n' "$mode" "$wrote" "$lost" "$malformed" >&2
  printf '%s %s' "$lost" "$malformed"
}

printf 'ledger-concurrency: %s writers, %s rows each, %s compactions per arm\n\n' \
  "$WRITERS" "$PER_WRITER" "$ROUNDS"

read -r locked_lost locked_bad < <(arm locked)
read -r unlocked_lost unlocked_bad < <(arm unlocked)

printf '\n'
fail=0
if (( locked_lost == 0 )); then
  printf '  PASS  %-44s %s\n' "locked: no row lost under compaction" "$locked_lost"
else
  printf '  FAIL  %-44s %s rows lost\n' "locked: rows lost under compaction" "$locked_lost"; fail=1
fi
if (( locked_bad == 0 )); then
  printf '  PASS  %-44s %s\n' "locked: no malformed rows" "$locked_bad"
else
  printf '  FAIL  %-44s %s\n' "locked: malformed rows" "$locked_bad"; fail=1
fi
# The control. If the unlocked arm also loses nothing, the test is not
# reproducing the race at all and the locked arm's pass is meaningless.
if (( unlocked_lost > 0 )); then
  printf '  PASS  %-44s %s rows lost, as it must\n' "control: unlocked arm DOES lose rows" "$unlocked_lost"
else
  printf '  FAIL  %-44s race not reproduced, locked arm proves nothing\n' "control: unlocked arm lost nothing"; fail=1
fi

(( fail )) && { printf '\nledger-concurrency: FAIL\n'; exit 1; }
printf '\nledger-concurrency: PASS\n'

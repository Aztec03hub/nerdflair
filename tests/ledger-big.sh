#!/usr/bin/env bash
# ledger-big.sh - a huge ledger must not make a render read the whole file: with NERDFLAIR_REPO_COST on, a
# 50 MB synthetic ledger and a cold repo-total memo, one render stays under a CPU-time budget (user+sys: wall time under load measures the scheduler) and its peak
# RSS stays small (both renderers). Also: burn and block still show when the 1 MB tail does not reach the
# block start but the 16x widen does. Prints before/after numbers; NF_BIN / NF_SH point at another build.
set -uo pipefail
export LC_NUMERIC=C   # /usr/bin/time prints %U %S with the locale's radix; the parsing below wants a dot
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${NF_BIN:-$REPO/rust/target/release/nerdflair-statusline}"; SH="${NF_SH:-$REPO/scripts/statusline.sh}"
[[ -x "$BIN" ]] || { echo "ledger-big: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-ledbig-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
NOW=$(date +%s); fail=0
mkdir -p "$W/home" "$W/work"
# 50 MB: 400k rows over the last 20 days, 40 sessions, slug "bigrepo", plus a recent hour for burn.
python3 - "$W/ledger.tsv" "$NOW" <<'EOF'
import sys
p, now = sys.argv[1], int(sys.argv[2])
rows = 1600000
with open(p, "w") as f:
    for i in range(rows):
        t = now - 20 * 86400 + (i * (20 * 86400 - 7200)) // rows
        s = "sess-%d" % (i % 40)
        f.write("%d\t%s\tbigrepo\t%.2f\n" % (t, s, i / 1000.0))
    for k in range(120):  # the last two hours, one live session, steady spend
        f.write("%d\tlive-1\tbigrepo\t%.2f\n" % (now - 7200 + k * 60, 1.0 + k * 0.5))
EOF
SZ=$(stat -c %s "$W/ledger.tsv")
render() { # impl -> prints "cpu_ms rssKB" then the output on later lines
  local impl=$1 d="$W/c-$1-$RANDOM" cmd; mkdir -m 700 "$d"; cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  printf '{"session_id":"lb-%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5,"total_duration_ms":600000,"total_api_duration_ms":240000},"context_window":{"used_percentage":20,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' \
    "$RANDOM" "$W/work" "$W/work" "$((NOW + 9000))" > "$W/in.json"
  local t0=$SECONDS
  /usr/bin/time -f '%M %U %S' -o "$W/rss" env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=160 \
    NERDFLAIR_CACHE_DIR="$d" NERDFLAIR_ERR_STAMP_DIR="$W/st-$RANDOM" NERDFLAIR_MCP_HEALTH=0 \
    NERDFLAIR_REPO_COST_FILE="$W/ledger.tsv" NERDFLAIR_REPO_COST_MAXBYTES=999999999 "${cmd[@]}" < "$W/in.json" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$W/out.txt"
  local rss u sy; read -r rss u sy < <(tail -n 1 "$W/rss")   # %U %S are seconds with two decimals, e.g. 0.12 0.03
  echo "$(( 10#${u/./} * 10 + 10#${sy/./} * 10 )) $rss $(( SECONDS - t0 ))"
}
echo "ledger: $((SZ / 1048576)) MB"
for impl in rust bash; do
  read -r ms rss wall < <(render "$impl")
  echo "$impl: cold render ${ms} ms CPU, peak RSS ${rss} KB"
  limit_ms=${NF_LEDGER_BUDGET_MS:-1400}; limit_kb=${NF_LEDGER_BUDGET_KB:-75000}
  (( ms <= limit_ms )) || { echo "FAIL $impl: ${ms} ms CPU > ${limit_ms} ms budget"; fail=1; }
  # loose wall backstop: CPU time can't see a render that sleeps or blocks on a lock or I/O
  (( wall <= ${NF_LEDGER_WALL_S:-30} )) || { echo "FAIL $impl: ${wall} s wall > ${NF_LEDGER_WALL_S:-30} s backstop"; fail=1; }
  (( rss <= limit_kb )) || { echo "FAIL $impl: ${rss} KB > ${limit_kb} KB budget"; fail=1; }
  grep -q '/h' "$W/out.txt" || { echo "FAIL $impl: burn missing from: $(tail -n 1 "$W/out.txt")"; fail=1; }
done
(( fail )) && exit 1
echo "ledger-big: ok"

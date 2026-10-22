#!/usr/bin/env bash
# ledger-widen.sh - when the capped ledger tail starts after the billing block start (5 h window), the
# reader widens once (16x) instead of hiding burn and block. Both renderers. NF_BIN / NF_SH point at another build.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${NF_BIN:-$REPO/rust/target/release/nerdflair-statusline}"; SH="${NF_SH:-$REPO/scripts/statusline.sh}"
[[ -x "$BIN" ]] || { echo "ledger-widen: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-ledwide-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
NOW=$(date +%s); fail=0
mkdir -p "$W/home" "$W/work"
# 3 h of one row per 2 s per session, 3 sessions (~190 KB): a 64 KB cap reaches back about 1 h only.
python3 - "$W/ledger.tsv" "$NOW" <<'PY'
import sys
p, now = sys.argv[1], int(sys.argv[2])
with open(p, "w") as f:
    for t in range(now - 10800, now, 2):
        for k in range(3):
            f.write("%d\tws-%d\twrepo\t%.2f\n" % (t, k, 1.0 + (t - (now - 10800)) / 600.0))
PY
for impl in rust bash; do
  d="$W/c-$impl"; mkdir -m 700 "$d"; cmd=("$BIN"); [[ $impl == bash ]] && cmd=(bash "$SH")
  printf '{"session_id":"lw-1","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5,"total_duration_ms":600000,"total_api_duration_ms":240000},"context_window":{"used_percentage":20,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' \
    "$W/work" "$W/work" "$((NOW + 9000))" > "$W/in.json"
  out=$(env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=200 NERDFLAIR_CACHE_DIR="$d" \
    NERDFLAIR_ERR_STAMP_DIR="$W/st-$impl" NERDFLAIR_MCP_HEALTH=0 NERDFLAIR_REPO_COST=0 NERDFLAIR_REPO_COST_FILE="$W/ledger.tsv" \
    NERDFLAIR_LEDGER_TAIL_BYTES=65536 "${cmd[@]}" < "$W/in.json" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
  printf '%s\n' "$out" > "$W/out-$impl.txt"
  [[ "$out" == *"/h"* ]] || { echo "FAIL $impl: burn hidden: $(tail -n 1 <<<"$out")"; fail=1; }
  [[ "$out" =~ /h\ ·\ .{1,3}\ \$[0-9.]+\ ·\ 5h ]] || { echo "FAIL $impl: block hidden: $(tail -n 1 <<<"$out")"; fail=1; }
done
cat "$W/out-rust.txt" >&2; (( fail )) && exit 1
echo "ledger-widen: ok"

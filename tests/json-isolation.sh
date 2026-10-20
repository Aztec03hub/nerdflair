#!/usr/bin/env bash
# json-isolation.sh - `nerdflair-statusline --json` (the plugin band's call, with a
# made-up payload) must not touch per-session or account-wide state. Before this
# guarantee the band shared the real line's sample file under the same session id:
# its api_ms=1 sample wiped the ETA history and skewed the token rate.
#
# A real render builds the state, a --json render with the SAME session id but a
# different, made-up payload follows, and every file the real render wrote (sample
# ring, repo-cost stamp, usage ledger, limits-last) must be byte-identical after.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/rust/target/release/nerdflair-statusline"
[[ -x "$BIN" ]] || { echo "json-isolation: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-jsoniso-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
mkdir -p "$W/home/.claude" "$W/work"; mkdir -m 700 "$W/cache"
NOW=$(date +%s); SID="jsoniso-$$"

run() { # extra-arg payload
  printf '%s' "$2" | env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W" LC_ALL=C.UTF-8 TZ=UTC COLUMNS=120 \
    NERDFLAIR_CACHE_DIR="$W/cache" NERDFLAIR_ERR_STAMP_DIR="$W/stamps" NERDFLAIR_MCP_HEALTH=0 \
    NERDFLAIR_REPO_COST_FILE="$W/ledger.tsv" NERDFLAIR_REPO_COST_TTL=0 \
    "$BIN" ${1:+"$1"} 2>/dev/null
}
payload() { # api_ms used_pct cost five_pct
  printf '{"session_id":"%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":%s,"total_duration_ms":600000,"total_api_duration_ms":%s},"context_window":{"used_percentage":%s,"total_output_tokens":4000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":50,"resets_at":%s}}}' \
    "$SID" "$W/work" "$W/work" "$3" "$1" "$2" "$4" $((NOW + 9000)) $((NOW + 300000))
}
snap() { ( cd "$W" && find cache ledger.tsv -type f 2>/dev/null | sort | xargs sha256sum ); }

run "" "$(payload 100000 30.5 2.00 10)" >/dev/null
run "" "$(payload 110000 30.5 2.10 10)" >/dev/null
touch -d '2 hours ago' "$W/cache/limits-last" 2>/dev/null   # past the write throttle: a stray write would show
# the plugin's Remote Control record for this session (--rc-sync is the only writer), aged past its 30 s throttle
env -i PATH="$PATH" HOME="$W/home" NERDFLAIR_CACHE_DIR="$W/cache" NERDFLAIR_ERR_STAMP_DIR="$W/stamps" "$BIN" --rc-sync "$SID" web >/dev/null
RCF="$W/cache/$("$BIN" --rc-name "$SID" </dev/null)"
[[ -s "$RCF" ]] || { echo "json-isolation: FAIL --rc-sync wrote no record"; exit 1; }
touch -d '2 hours ago' "$RCF"
before=$(snap)
grep -q "cache/rc-" <<<"$before" || { echo "json-isolation: FAIL the rc record is not among the files compared"; exit 1; }
[[ -n "$before" ]] || { echo "json-isolation: FAIL real renders wrote no state to compare"; exit 1; }
jout=$(run --json "$(payload 1 30 9.99 77)")
after=$(snap)
if grep -q '"id":"rc"' <<<"$jout"; then echo "  FAIL  --json emitted an rc segment (the band draws its own chip)"; echo "json-isolation: FAIL"; exit 1; fi
if [[ "$before" == "$after" ]]; then
  echo "  PASS  --json leaves the sample, stamp, ledger, limits-last and rc record files byte-identical"
  echo "json-isolation: PASS"
else
  echo "  FAIL  --json changed state the real line owns:"
  diff <(echo "$before") <(echo "$after") | sed 's/^/        /'
  echo "json-isolation: FAIL"; exit 1
fi

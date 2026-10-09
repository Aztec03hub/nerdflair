#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# transcript-tail.sh — the context gauge must survive a real transcript.
#
# The gauge reads the newest `usage` object from the tail of the transcript,
# because streaming a 617 MB file on the render path is the mistake that took
# the machine down on 2026-10-08. Reading only the tail has two failure modes
# that both show up as a confident 0% on a session that is nearly full, which
# is indistinguishable from a fresh session:
#
#   A. One assistant message can be larger than the cap on its own (a big tool
#      result). The read lands inside it, the partial first line is dropped,
#      and no usage object remains.
#   B. The file is appended to while we read it, so the final line is
#      routinely a fragment. Taking the newest line blind parses nothing.
#
# The difftest corpus contains neither shape: it is 162 payloads, and both
# implementations agreed on 0% because both were wrong the same way. Parity is
# not correctness, so this file asserts VALUES, and asserts the limit case too
# so a fix that simply reads more can be told from one that works.
#
# Every case runs through BOTH implementations and they must agree.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SH="$REPO_ROOT/scripts/statusline.sh"
BIN="$REPO_ROOT/rust/target/release/nerdflair-statusline"

[[ -x "$BIN" ]] || { printf 'transcript-tail: not built: %s\n' "$BIN" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nerdflair-ttail-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# A session at exactly 25%: the four token fields sum to 50000 of 200000.
usage_line() { # tokens_total
  printf '{"message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$1"
}
pad() { head -c "$1" /dev/zero | tr '\0' 'x'; }

# No context_window in the payload, which is what sends the renderer to the
# transcript in the first place.
payload() { # transcript_path
  printf '{"session_id":"ttail","transcript_path":"%s","model":{"display_name":"Opus 5","id":"claude-opus-5"},"workspace":{"current_dir":"%s","project_dir":"%s"}}' \
    "$1" "$REPO_ROOT" "$REPO_ROOT"
}

fail=0
run() { # label transcript expected_pct [env assignments...]
  local label=$1 tr=$2 want=$3; shift 3
  local p a b
  p=$(payload "$tr")
  a=$(printf '%s' "$p" | env "$@" NERDFLAIR_CCUSAGE=0 NERDFLAIR_MCP_HEALTH=0 \
        NERDFLAIR_REPO_COST_FILE="$WORK/usage.tsv" bash "$SH" 2>/dev/null)
  b=$(printf '%s' "$p" | env "$@" NERDFLAIR_CCUSAGE=0 NERDFLAIR_MCP_HEALTH=0 \
        NERDFLAIR_REPO_COST_FILE="$WORK/usage.tsv" "$BIN" 2>/dev/null)
  local got
  got=$(printf '%s' "$a" | sed 's/\x1b\[[0-9;]*m//g' | grep -o '[0-9]\+%' | head -1)
  got=${got:-none}
  if [[ "$a" != "$b" ]]; then
    printf '  FAIL  %-34s bash and rust disagree\n' "$label"; fail=1; return
  fi
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL  %-34s got %s, want %s\n' "$label" "$got" "$want"; fail=1; return
  fi
  printf '  PASS  %-34s %s (both)\n' "$label" "$got"
}

# ── C. the ordinary case, so a pass elsewhere is not just "always 25%" ───────
usage_line 50000 > "$WORK/plain.jsonl"
run "plain transcript" "$WORK/plain.jsonl" "25%"

usage_line 20000 > "$WORK/other.jsonl"
run "plain transcript, different fill" "$WORK/other.jsonl" "10%"

# ── A. last message larger than the 1 MiB cap ────────────────────────────────
{
  usage_line 20000
  printf '{"pad":"%s","message":{"usage":{"input_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$(pad 2000000)"
} > "$WORK/huge.jsonl"
# Must read the NEWEST one (50000 = 25%), not the older one that happens to
# fit (20000 = 10%). Getting 10% here would mean the widened read still
# missed the last line; 0% would mean the old behaviour.
run "last line exceeds the cap" "$WORK/huge.jsonl" "25%"

# ── B. final line is a fragment, as it is during an append ───────────────────
{
  usage_line 50000
  printf '{"message":{"usage":{"input_tok'
} > "$WORK/torn.jsonl"
run "final line torn mid-append" "$WORK/torn.jsonl" "25%"

# A fragment that is also the ONLY usage line leaves nothing to fall back to.
# At zero the gauge prints no percentage label at all, so "none" is what an
# unreadable transcript looks like, and it is exactly what the two bugs above
# were producing on a nearly-full session.
printf '{"message":{"usage":{"input_tok' > "$WORK/torn-only.jsonl"
run "torn line is the only one" "$WORK/torn-only.jsonl" "none"

# ── D. the limit, stated rather than discovered later ────────────────────────
# Widening is 16x and bounded. A line bigger than the widened cap is still
# unreachable, and both implementations must agree on that rather than one of
# them quietly streaming the file.
{
  usage_line 20000
  printf '{"pad":"%s","message":{"usage":{"input_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$(pad 200000)"
} > "$WORK/beyond.jsonl"
run "beyond even the widened cap" "$WORK/beyond.jsonl" "none" \
  NERDFLAIR_TRANSCRIPT_TAIL_BYTES=4096

printf '\n'
(( fail )) && { printf 'transcript-tail: FAIL\n'; exit 1; }
printf 'transcript-tail: PASS\n'

#!/usr/bin/env bash
# mcp-cap.sh - the MCP names readout must read the same in every state.
#
# It used to list as many names as the row had room for. On a fresh session
# row 2 is nearly empty, so 9 names fit; as the cost, rate and limit readouts
# arrived the list collapsed to 3. The row jumped, and every hover region
# after it moved. The fix is a cap on names, so this asserts VALUES: the same
# text at a wide and a narrow terminal, never more names than the cap, and a
# short list shown in full. Both implementations, and they must agree.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$REPO/scripts/statusline.sh"
BIN="$REPO/rust/target/release/nerdflair-statusline"
[[ -x "$BIN" ]] || { printf 'mcp-cap: not built: %s\n' "$BIN" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nerdflair-mcpcap-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Probe cache: connected, needs-auth, failed, then \x1e-separated names. The
# renderer sorts them, so the expectations below are in sorted order.
cache() { # names...
  local names="" n
  for n in "$@"; do names+="${names:+$'\x1e'}$n"; done
  printf '%s\x1f%s\x1f%s\x1f%s' "$#" "0" "0" "$names" > "$WORK/cache"
}

payload='{"session_id":"mcpcap","model":{"display_name":"Opus 5","id":"claude-opus-5"},"workspace":{"current_dir":"'"$WORK"'","project_dir":"'"$WORK"'"},"context_window":{"context_window_size":1000000,"total_input_tokens":1,"total_output_tokens":1,"used_percentage":1},"cost":{"total_cost_usd":0}}'

render() { # impl cols [env...]
  local impl=$1 cols=$2; shift 2
  printf '%s' "$payload" | env "$@" NERDFLAIR_REPO_COST=0 \
    NERDFLAIR_MCP_CACHE="$WORK/cache" COLUMNS="$cols" $impl 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | rg -F "$(printf '\xef\x87\xa6')" | head -1 | sed 's/^ *//; s/   *.*//'
}

fail=0
check() { # label want got
  if [[ "$3" == "$2" ]]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}

cache alpha beta gamma delta epsilon zeta eta theta iota
want=$' alpha, beta, delta, 6 more'
for impl in "bash $SH" "$BIN"; do
  tag=${impl%% *}; [[ "$tag" == "$BIN" ]] && tag=rust
  check "$tag: 9 names, wide row"   "$want" "$(render "$impl" 400)"
  check "$tag: 9 names, 140 cols"   "$want" "$(render "$impl" 140)"
done

# Under the cap nothing is hidden.
cache alpha beta
for impl in "bash $SH" "$BIN"; do
  tag=${impl%% *}; [[ "$tag" == "$BIN" ]] && tag=rust
  check "$tag: 2 names shown in full" $' alpha, beta' "$(render "$impl" 400)"
done

# The cap is adjustable, and a bad value falls back rather than breaking.
cache alpha beta gamma delta epsilon
for impl in "bash $SH" "$BIN"; do
  tag=${impl%% *}; [[ "$tag" == "$BIN" ]] && tag=rust
  check "$tag: NERDFLAIR_MCP_NAMES=1" $' alpha, 4 more' "$(render "$impl" 400 NERDFLAIR_MCP_NAMES=1)"
  check "$tag: NERDFLAIR_MCP_NAMES=junk" $' alpha, beta, delta, 2 more' "$(render "$impl" 400 NERDFLAIR_MCP_NAMES=junk)"
done

printf '\n'
(( fail )) && { printf 'mcp-cap: FAIL\n'; exit 1; }
printf 'mcp-cap: PASS\n'

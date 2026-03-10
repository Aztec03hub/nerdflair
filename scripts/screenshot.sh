#!/bin/bash
# screenshot.sh — Generate deterministic nerdflair screenshots for docs.
#
# Renders multiple statusline variations by calling the real
# statusline-command.sh with controlled inputs:
#   (1) Full layout × 3 color modes (default, mono, muted)
#   (2) Compact layout (default color)
#   (3) Minimal layout (default color)
#   (4) Progress bar gallery: gradient tiers at varying percentages
#
# Usage:
#   ./scripts/screenshot.sh              # render to terminal
#   ./scripts/screenshot.sh > out.txt    # capture with ANSI codes
#
# The script creates a throwaway git repo in /tmp so the real renderer
# picks up the folder name, branch, and diff stats we want.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDERER="$SCRIPT_DIR/statusline-command.sh"

# ── Configurable dummy values ────────────────────────────────────
FOLDER="todos-app"
BRANCH="feature/reminders"
MODEL_ID="us.anthropic.claude-opus-4-6-v1"
OUTPUT_STYLE="explanatory"
SESSION_ID="screenshot-session-fixed-id-0001"
COST_USD="12.83"
API_DURATION_MS="1560000"  # 26 minutes
CONTEXT_USED_PCT="42"
INPUT_TOKENS="60000"
OUTPUT_TOKENS="24000"
CTX_WINDOW_SIZE="200000"
# Edit stats: 3 dirty files, +153 / -14 lines
DIRTY_FILE_COUNT=3
LINES_ADDED=153
LINES_REMOVED=14

# ── Build sandboxed environment ──────────────────────────────────
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

FAKE_HOME="$TMPDIR_ROOT/home"
mkdir -p "$FAKE_HOME/.claude"

FAKE_CWD="$TMPDIR_ROOT/workspace/$FOLDER"
mkdir -p "$FAKE_CWD"

# Create a git repo with the right branch and dirty state
(
  cd "$FAKE_CWD"
  git init -q
  git checkout -q -b main

  # Initial commit: put LINES_REMOVED lines in file1 only (will be erased)
  for j in $(seq 1 "$LINES_REMOVED"); do
    echo "original line $j" >> "file1.txt"
  done
  # file2 and file3 start empty (will gain new lines → pure additions)
  touch file2.txt file3.txt
  git add -A
  git commit -q -m "initial"

  # Switch to feature branch
  git checkout -q -b "$BRANCH"

  # Dirty state: erase file1 → all LINES_REMOVED counted as removals
  > file1.txt
  # Spread LINES_ADDED across all 3 files
  lines_per_file=$(( LINES_ADDED / DIRTY_FILE_COUNT ))
  remainder=$(( LINES_ADDED % DIRTY_FILE_COUNT ))
  for i in $(seq 1 "$DIRTY_FILE_COUNT"); do
    count=$lines_per_file
    (( i <= remainder )) && (( count++ ))
    for j in $(seq 1 "$count"); do
      echo "new line $j in file $i" >> "file${i}.txt"
    done
  done
) >/dev/null 2>&1

# Write MCP config (Glean, Gmail, Slack)
cat > "$FAKE_HOME/.claude.json" << 'MCPEOF'
{"mcpServers":{"Glean":{},"Gmail":{},"Slack":{}}}
MCPEOF


# ── Helper: write state file and render ──────────────────────────
render_variation() {
  local mode="$1"
  local color="$2"
  local flair_seed="${3:-42}"
  local pct_override="${4:-}"
  local label="$5"
  local bar_only="${6:-false}"
  local cost_override="${7:-}"

  # Section header (skip for bar_only gallery entries)
  if [[ "$bar_only" != "true" ]]; then
    local HEADER_COLOR='\033[1;38;2;120;135;155m'
    local HEADER_RESET='\033[0m'
    printf '\n\n%b%s%b\n' "$HEADER_COLOR" "$label" "$HEADER_RESET"
  fi

  # Write state file into the sandboxed HOME
  cat > "$FAKE_HOME/.claude/statusline-state.json" << STATEEOF
{"mode": "$mode", "width": "auto", "flair": true, "bell": "both", "bell_sound": "Glass", "context": "full", "color": "$color", "flair_seed": $flair_seed, "last_tokens": 80000}
STATEEOF

  # Build JSON payload
  local json_input json_pct json_tokens json_cost json_api_ms
  json_pct="${pct_override:-$CONTEXT_USED_PCT}"
  json_tokens=$(( CTX_WINDOW_SIZE * json_pct / 100 ))
  json_cost="${cost_override:-$COST_USD}"
  # Scale API duration proportionally to cost for visual consistency
  json_api_ms="$API_DURATION_MS"
  json_input=$(cat << JSONEOF
{
  "workspace": {
    "current_dir": "$FAKE_CWD",
    "project_dir": "$FAKE_CWD"
  },
  "model": {
    "id": "$MODEL_ID"
  },
  "cost": {
    "total_cost_usd": $json_cost,
    "total_duration_ms": $json_api_ms,
    "total_api_duration_ms": $json_api_ms
  },
  "output_style": {
    "name": "$OUTPUT_STYLE"
  },
  "session_id": "$SESSION_ID",
  "context_window": {
    "used_percentage": $json_pct,
    "total_input_tokens": $json_tokens,
    "total_output_tokens": 0,
    "context_window_size": $CTX_WINDOW_SIZE
  }
}
JSONEOF
  )

  # Run renderer in a subshell with overridden HOME so it reads our state file
  # bar_only: strip everything except the progress bar line (for gallery)
  if [[ "$bar_only" == "true" ]]; then
    # Compact mode output: row1\nbar  — strip row 1, keep just the bar.
    # _render_bar's leading \n becomes the first line, so tail -n +2 gives
    # just the bar content. We print our own \n before it so bars stack.
    printf '\n'
    printf '%s' "$json_input" | HOME="$FAKE_HOME" bash "$RENDERER" | tail -n +2
  else
    printf '%s' "$json_input" | HOME="$FAKE_HOME" bash "$RENDERER"
  fi
}

# ── Randomize seeds ──────────────────────────────────────────────
# One shared seed for the layout variations (full/compact/minimal)
SHARED_SEED=$((RANDOM % 10000))

# ── (1) Full layout × 3 color modes ─────────────────────────────
render_variation "full" "default" "$SHARED_SEED"  "" "Layout: full"

render_variation "full" "muted"   "$SHARED_SEED"  "" "Layout: full · Color: muted"

render_variation "full" "mono"    "$SHARED_SEED"  "" "Layout: full · Color: mono"

# ── (2) Compact layout ───────────────────────────────────────────
render_variation "compact" "default" "$SHARED_SEED" "" "Layout: compact"

# ── (3) Minimal layout ──────────────────────────────────────────
render_variation "minimal" "default" "$SHARED_SEED" "" "Layout: minimal"

# ── (4) Progress bar gallery ─────────────────────────────────────
# Each bar gets its own random seed for unique flair (icon + texture).
# bar_only=true strips row 1, showing just the progress bar.
# Costs are deliberately varied (seemingly random) up to $150.
HEADER_COLOR='\033[1;38;2;120;135;155m'
HEADER_RESET='\033[0m'
printf '\n\n%b%s%b' "$HEADER_COLOR" "Progress Bar Gallery" "$HEADER_RESET"

render_variation "compact" "default" $((RANDOM % 10000))  "3"   ""  true  "0.47"
render_variation "compact" "default" $((RANDOM % 10000))  "9"   ""  true  "2.18"
render_variation "compact" "default" $((RANDOM % 10000))  "17"  ""  true  "5.93"
render_variation "compact" "default" $((RANDOM % 10000))  "24"  ""  true  "11.07"
render_variation "compact" "default" $((RANDOM % 10000))  "33"  ""  true  "18.42"
render_variation "compact" "default" $((RANDOM % 10000))  "41"  ""  true  "27.65"
render_variation "compact" "default" $((RANDOM % 10000))  "50"  ""  true  "43.19"
render_variation "compact" "default" $((RANDOM % 10000))  "58"  ""  true  "61.84"
render_variation "compact" "default" $((RANDOM % 10000))  "66"  ""  true  "89.37"
render_variation "compact" "default" $((RANDOM % 10000))  "74"  ""  true  "112.50"
render_variation "compact" "default" $((RANDOM % 10000))  "79"  ""  true  "147.03"

printf '\n'

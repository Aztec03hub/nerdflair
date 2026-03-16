#!/bin/bash
# animated-preview.sh — Print statusline variations sequentially for recording.
# Used by vhs (scripts/preview.tape) to generate an animated GIF preview.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDERER="$SCRIPT_DIR/statusline.sh"

# ── Dummy values ──────────────────────────────────────────────────
FOLDER="todos-app"
BRANCH="feature/reminders"
MODEL_ID="us.anthropic.claude-opus-4-6-v1"
OUTPUT_STYLE="explanatory"
SESSION_ID="screenshot-session-fixed-id-0001"
CTX_WINDOW_SIZE="200000"
DIRTY_FILE_COUNT=3
LINES_ADDED=153
LINES_REMOVED=14
SHARED_SEED=826

# ── Build sandboxed environment ───────────────────────────────────
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

FAKE_HOME="$TMPDIR_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/nerdflair"

FAKE_CWD="$TMPDIR_ROOT/workspace/$FOLDER"
mkdir -p "$FAKE_CWD"

(
  cd "$FAKE_CWD"
  git init -q
  git checkout -q -b main
  for j in $(seq 1 "$LINES_REMOVED"); do
    echo "original line $j" >> "file1.txt"
  done
  touch file2.txt file3.txt
  git add -A
  git commit -q -m "initial"
  git checkout -q -b "$BRANCH"
  > file1.txt
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

cat > "$FAKE_HOME/.claude.json" << 'MCPEOF'
{"mcpServers":{"Glean":{},"Gmail":{},"Slack":{}}}
MCPEOF

# ── Render a single variation ─────────────────────────────────────
render() {
  local mode="$1" color="$2" pct="${3:-42}" cost="${4:-12.83}" duration="${5:-1560000}"
  local chime_style="${6:-random}"
  local tokens=$(( CTX_WINDOW_SIZE * pct / 100 ))

  cat > "$FAKE_HOME/.claude/nerdflair/state.json" << EOF
{"mode": "$mode", "width": "auto", "flair": true, "terminal_bell": "on", "chime_sound": "Glass", "chime_style": "$chime_style", "chime_events": "Notification,PermissionRequest,SessionEnd,SessionStart,Stop", "chime_volume": "1", "context": "full", "color": "$color", "flair_seed": $SHARED_SEED, "last_tokens": 80000, "last_session": "$SESSION_ID", "chime_recent_styles": ["BalladPiano"]}
EOF

  # Write a resolved chime session file so the label shows
  mkdir -p "$FAKE_HOME/.claude/nerdflair/chime-sessions"
  echo "DelicateBells" > "$FAKE_HOME/.claude/nerdflair/chime-sessions/$SESSION_ID"

  local json
  json=$(cat << EOF
{
  "workspace": {"current_dir": "$FAKE_CWD", "project_dir": "$FAKE_CWD"},
  "model": {"id": "$MODEL_ID"},
  "cost": {"total_cost_usd": $cost, "total_duration_ms": $duration, "total_api_duration_ms": $duration},
  "output_style": {"name": "$OUTPUT_STYLE"},
  "session_id": "$SESSION_ID",
  "context_window": {"used_percentage": $pct, "total_input_tokens": $tokens, "total_output_tokens": 0, "context_window_size": $CTX_WINDOW_SIZE}
}
EOF
  )

  printf '%s' "$json" | HOME="$FAKE_HOME" bash "$RENDERER"
}

# ── Show a frame: clear, centered title, render, pause ────────────
show_frame() {
  local label="$1"
  shift
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)
  local label_len=${#label}
  local pad=$(( (cols - label_len) / 2 ))
  (( pad < 0 )) && pad=0
  local spaces
  spaces=$(printf '%*s' "$pad" '')

  printf '\033[?25l\033[2J\033[H'
  printf '\033[1;37m%s%s\033[0m\n\n' "$spaces" "$label"
  render "$@"
  sleep 2.5
}

# ── Frame sequence ────────────────────────────────────────────────
# 1. Full vibrant (normal usage)
show_frame "Full — vibrant"          full    default

# 2. Compact vibrant
show_frame "Compact"                 compact default

# 3. Minimal vibrant
show_frame "Minimal"                 minimal default

# 4. Muted colors
show_frame "Muted colors"            full    muted

# 5. Monochrome
show_frame "Monochrome"              full    mono

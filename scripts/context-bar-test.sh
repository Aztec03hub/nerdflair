#!/bin/bash
# context-bar-test.sh — Render every texture at multiple widths for visual QA.
#
# Usage:
#   ./scripts/context-bar-test.sh              # render to terminal
#   ./scripts/context-bar-test.sh > out.txt    # capture with ANSI codes

set -euo pipefail

RENDERER="$(cd "$(dirname "$0")" && pwd)/statusline.sh"

SESSION_ID="context-bar-test-session"
CTX_WINDOW_SIZE=200000
PCT=80
TOKENS=$(( CTX_WINDOW_SIZE * PCT / 100 ))

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

FAKE_HOME="$TMPDIR_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/nerdflair/sessions"
FAKE_CWD="$TMPDIR_ROOT/workspace/test-app"
mkdir -p "$FAKE_CWD"

# Minimal git repo
(
  cd "$FAKE_CWD"
  git init -q
  git checkout -q -b main
  echo "x" > f.txt
  git add -A && git commit -q -m "init"
  git checkout -q -b dev
) >/dev/null 2>&1

cat > "$FAKE_HOME/.claude.json" << 'EOF'
{"mcpServers":{}}
EOF

TEXTURES=(Wind ThickDots SinWave SquareWave Beads Arrows DotChain Soundwaves Pulse Sparkle InfinityLoop)
WIDTHS=(50 70 80 100 150)

render_bar() {
  local texture="$1"
  local width="$2"

  cat > "$FAKE_HOME/.claude/nerdflair/state.json" << STATEEOF
{"mode": "compact", "width": "$width", "flair": true, "color": "default", "last_session": "$SESSION_ID"}
STATEEOF

  printf '{"chime":"TestStyle","texture":"%s"}\n' "$texture" > "$FAKE_HOME/.claude/nerdflair/sessions/$SESSION_ID"

  local json_input
  json_input=$(cat << JSONEOF
{
  "workspace": {"current_dir": "$FAKE_CWD", "project_dir": "$FAKE_CWD"},
  "model": {"id": "us.anthropic.claude-opus-4-6-v1"},
  "cost": {"total_cost_usd": 8.50, "total_duration_ms": 600000, "total_api_duration_ms": 600000},
  "output_style": {"name": "explanatory"},
  "session_id": "$SESSION_ID",
  "context_window": {
    "used_percentage": $PCT,
    "total_input_tokens": $TOKENS,
    "total_output_tokens": 0,
    "context_window_size": $CTX_WINDOW_SIZE
  }
}
JSONEOF
  )

  printf '%s' "$json_input" | HOME="$FAKE_HOME" bash "$RENDERER" | tail -n +2
}

LABEL_COLOR='\033[1;38;2;35;38;42m'
DIM='\033[38;2;100;105;115m'
RST='\033[0m'

for texture in "${TEXTURES[@]}"; do
  printf '\n%b%s%b' "$LABEL_COLOR" "$texture" "$RST"
  for w in "${WIDTHS[@]}"; do
    printf '\n%b w=%s%b' "$DIM" "$w" "$RST"
    render_bar "$texture" "$w"
  done
done

printf '\n\n'

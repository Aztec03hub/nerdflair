#!/bin/bash
# Play a nerdflair chime. Called by ~/.cursor/hooks.json on Cursor agent events.
# Reads style/volume/audioDir from the state file written by the VS Code extension.
#
# Usage: play-chime.sh <Event>
#   Events: Stop, SessionStart, SessionEnd, Notification

set -euo pipefail

EVENT="${1:-Stop}"
STATE_FILE="$HOME/.cursor/nerdflair-chimes.json"

[[ ! -f "$STATE_FILE" ]] && exit 0

if ! command -v jq &>/dev/null; then
  exit 0
fi

style=$(jq -r '.style // empty' "$STATE_FILE" 2>/dev/null) || exit 0
volume=$(jq -r '.volume // "1"' "$STATE_FILE" 2>/dev/null) || exit 0
audio_dir=$(jq -r '.audioDir // empty' "$STATE_FILE" 2>/dev/null) || exit 0

[[ -z "$style" || -z "$audio_dir" ]] && exit 0

if awk -v v="$volume" 'BEGIN { exit (v+0 <= 0) ? 0 : 1 }'; then
  exit 0
fi

audio_file="$audio_dir/$style/$style-$EVENT.mp3"
[[ ! -f "$audio_file" ]] && exit 0

if command -v afplay &>/dev/null; then
  afplay --volume "$volume" "$audio_file" &>/dev/null &
elif command -v paplay &>/dev/null; then
  pa_vol=$(awk -v v="$volume" 'BEGIN { printf "%d", v * 65536 }')
  paplay --volume="$pa_vol" "$audio_file" &>/dev/null &
fi

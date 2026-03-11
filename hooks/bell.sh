#!/bin/bash
# Audio/visual notifications for Claude Code hook events.
# Called with event name as $1: Stop, Notification, PermissionRequest,
# SessionStart, SessionEnd, UserPromptSubmit, PreCompact.
#
# Reads settings from ~/.claude/statusline-state.json:
#   terminal_bell: on | off        (BEL char — hard-coded to Stop, Notification, PermissionRequest)
#   chime_sound:   macOS system sound name (fallback when no chime style)
#   chime_style:   style folder name from audio/ (or "random")
#   chime_events:  comma-separated list of enabled events for chimes
#   chime_volume:  0.0–1.0 (0 = muted, no audio plays)

set -euo pipefail

EVENT="${1:-Stop}"

# Read stdin payload (Claude Code passes JSON with session context)
_stdin_data=""
if ! [ -t 0 ]; then
  _stdin_data=$(cat)
fi

# Suppress SessionStart for resumed sessions and post-compaction restarts.
# We check the state file's last_session (written by the statusline) to see if
# this session_id has already been seen. This persists across process restarts,
# so /resume (which reuses the same session_id) won't re-trigger the sound.
_session_id=""
if [[ -n "$_stdin_data" ]]; then
  _session_id=$(echo "$_stdin_data" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
fi

# Resolve plugin root (hooks/ is one level down from plugin root)
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIO_DIR="$PLUGIN_ROOT/assets/audio"

# Hard-coded events that trigger the terminal bell (BEL character)
TERMINAL_BELL_EVENTS="Stop,Notification,PermissionRequest"

# Read settings from state file
terminal_bell="on"
chime_sound="Glass"
chime_style="random"
chime_events="Stop,Notification,PermissionRequest,SessionStart,SessionEnd"
chime_volume="1"
STATE_FILE="$HOME/.claude/statusline-state.json"
if [[ -f "$STATE_FILE" ]]; then
  _tbell=$(grep -o '"terminal_bell"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
  _sound=$(grep -o '"chime_sound"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
  _style=$(grep -o '"chime_style"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
  _events=$(grep -o '"chime_events"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
  _volume=$(grep -o '"chime_volume"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
  terminal_bell="${_tbell:-on}"
  chime_sound="${_sound:-Glass}"
  chime_style="${_style:-random}"
  chime_events="${_events:-Stop,Notification,PermissionRequest,SessionStart,SessionEnd}"
  chime_volume="${_volume:-1}"
  # Legacy migration: read old "bell" field if new fields are missing
  if [[ -z "$_tbell" ]]; then
    _old_bell=$(grep -o '"bell"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
    case "$_old_bell" in
      both)   terminal_bell="on" ;;
      visual) terminal_bell="on"; chime_volume="0" ;;
      audio)  terminal_bell="off" ;;
      off)    terminal_bell="off"; chime_volume="0" ;;
    esac
  fi
  if [[ -z "$_style" ]]; then
    _old_style=$(grep -o '"audio_style"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
    chime_style="${_old_style:-random}"
  fi
  if [[ -z "$_events" ]]; then
    _old_events=$(grep -o '"audio_events"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
    chime_events="${_old_events:-Stop,Notification,PermissionRequest,SessionStart,SessionEnd}"
  fi
  if [[ -z "$_volume" ]]; then
    _old_volume=$(grep -o '"bell_volume"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
    chime_volume="${_old_volume:-1}"
  fi
fi

# Suppress SessionStart for resumed sessions and post-compaction restarts.
# The stdin payload includes "source":"resume" for /resume and "source":"startup"
# for new sessions. Also suppress if last_session already matches (compaction).
if [[ "$EVENT" == "SessionStart" ]]; then
  _source=""
  if [[ -n "$_stdin_data" ]]; then
    _source=$(echo "$_stdin_data" | grep -o '"source"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
  fi
  if [[ "$_source" == "resume" ]]; then
    exit 0
  fi
  if [[ -n "$_session_id" && -f "$STATE_FILE" ]]; then
    _last_session=$(grep -o '"last_session"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
    if [[ "$_session_id" == "$_last_session" ]]; then
      exit 0
    fi
  fi
fi

# ── Resolve chime style ──
# bell.sh is the authority for picking random styles on SessionStart.
# It writes resolved_chime_style to the state file; the statusline reads it.
# For non-SessionStart events, reuse whatever was previously resolved.
_resolved_style="$chime_style"
if [[ "$_resolved_style" == "random" ]]; then
  if [[ "$EVENT" == "SessionStart" && -d "$AUDIO_DIR" ]]; then
    # New session: pick a fresh random style, avoiding recently used ones
    _styles=()
    while IFS= read -r d; do
      _styles+=("$(basename "$d")")
    done < <(find "$AUDIO_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    if [[ ${#_styles[@]} -gt 0 ]]; then
      _recent=()
      if [[ -f "$STATE_FILE" ]]; then
        _recent_raw=$(grep -o '"chime_recent_styles"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$STATE_FILE" | head -1 | sed 's/.*\[\(.*\)\]/\1/' | tr -d '"' | tr -d ' ' || true)
        if [[ -n "$_recent_raw" ]]; then
          IFS=',' read -ra _recent <<< "$_recent_raw"
        fi
      fi
      _candidates=()
      for s in "${_styles[@]}"; do
        _is_recent=false
        for r in "${_recent[@]}"; do
          if [[ "$s" == "$r" ]]; then _is_recent=true; break; fi
        done
        if [[ "$_is_recent" == "false" ]]; then
          _candidates+=("$s")
        fi
      done
      if [[ ${#_candidates[@]} -eq 0 ]]; then
        _candidates=("${_styles[@]}")
      fi
      _resolved_style="${_candidates[$((RANDOM % ${#_candidates[@]}))]}"
      # Update recent history (keep last 10)
      _recent+=("$_resolved_style")
      while [[ ${#_recent[@]} -gt 10 ]]; do
        _recent=("${_recent[@]:1}")
      done
      _recent_json=$(printf '"%s",' "${_recent[@]}")
      _recent_json="[${_recent_json%,}]"
      if [[ -f "$STATE_FILE" ]]; then
        if grep -q '"chime_recent_styles"' "$STATE_FILE"; then
          sed -i '' "s/\"chime_recent_styles\"[[:space:]]*:[[:space:]]*\[[^]]*\]/\"chime_recent_styles\": $_recent_json/" "$STATE_FILE"
        else
          sed -i '' "s/}$/,\"chime_recent_styles\": $_recent_json}/" "$STATE_FILE"
        fi
      fi
    fi
  elif [[ -f "$STATE_FILE" ]]; then
    # Non-SessionStart: reuse the previously resolved style
    _prev=$(grep -o '"resolved_chime_style"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
    if [[ -n "$_prev" && "$_prev" != "random" ]]; then
      _resolved_style="$_prev"
    fi
  fi
fi

# Write resolved style to state file so the statusline can display it
if [[ "$_resolved_style" != "random" && -f "$STATE_FILE" ]]; then
  if grep -q '"resolved_chime_style"' "$STATE_FILE"; then
    sed -i '' "s/\"resolved_chime_style\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"resolved_chime_style\": \"$_resolved_style\"/" "$STATE_FILE"
  else
    sed -i '' "s/}$/,\"resolved_chime_style\": \"$_resolved_style\"}/" "$STATE_FILE"
  fi
fi

# Exit early if terminal bell is off and chime volume is 0
_chime_muted=$(awk -v v="$chime_volume" 'BEGIN {print (v+0 <= 0) ? 1 : 0}')
if [[ "$terminal_bell" == "off" && "$_chime_muted" == "1" ]]; then
  exit 0
fi

# Hooks run without a controlling TTY, so /dev/tty won't work.
# Walk up the process tree to find the TTY of the parent Claude process.
_find_tty() {
  local pid=$$
  while [ "$pid" -gt 1 ]; do
    local tty
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$tty" ] && [ "$tty" != "??" ]; then
      echo "/dev/$tty"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}

# Send terminal bell (BEL character) — hard-coded to attention-seeking events only
if [[ "$terminal_bell" == "on" ]] && echo ",$TERMINAL_BELL_EVENTS," | grep -q ",$EVENT,"; then
  if tty_path=$(_find_tty); then
    printf '\a' > "$tty_path"
  fi
fi

# Play chime — user-configurable events, skip if volume is 0 or afplay unavailable
if [[ "$_chime_muted" != "1" ]] && command -v afplay &>/dev/null && echo ",$chime_events," | grep -q ",$EVENT,"; then
  _audio_file="$AUDIO_DIR/$_resolved_style/$_resolved_style-$EVENT.mp3"
  if [[ -f "$_audio_file" ]]; then
    nohup afplay --volume "$chime_volume" "$_audio_file" &>/dev/null &
  else
    # Fallback to macOS system sound
    _sys_sound="/System/Library/Sounds/${chime_sound}.aiff"
    if [[ -f "$_sys_sound" ]]; then
      nohup afplay --volume "$chime_volume" "$_sys_sound" &>/dev/null &
    fi
  fi
fi

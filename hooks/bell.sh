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
# On a genuinely new session the marker won't exist yet; we create it and
# proceed. On subsequent SessionStart events (resume, compaction) the marker
# is already present, so we skip the sound/style-randomization entirely.
# SessionEnd cleans up the marker.
_ppid="$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || true)"
_session_marker="/tmp/claude-session-${_ppid}"

if [[ "$EVENT" == "SessionStart" ]]; then
  if [[ -f "$_session_marker" ]]; then
    # Not a fresh session — suppress
    exit 0
  fi
  touch "$_session_marker"
fi

if [[ "$EVENT" == "SessionEnd" ]]; then
  rm -f "$_session_marker"
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
  _tbell=$(grep -o '"terminal_bell"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  _sound=$(grep -o '"chime_sound"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  _style=$(grep -o '"chime_style"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  _events=$(grep -o '"chime_events"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  _volume=$(grep -o '"chime_volume"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  terminal_bell="${_tbell:-on}"
  chime_sound="${_sound:-Glass}"
  chime_style="${_style:-random}"
  chime_events="${_events:-Stop,Notification,PermissionRequest,SessionStart,SessionEnd}"
  chime_volume="${_volume:-1}"
  # Legacy migration: read old "bell" field if new fields are missing
  if [[ -z "$_tbell" ]]; then
    _old_bell=$(grep -o '"bell"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
    case "$_old_bell" in
      both)   terminal_bell="on" ;;
      visual) terminal_bell="on"; chime_volume="0" ;;
      audio)  terminal_bell="off" ;;
      off)    terminal_bell="off"; chime_volume="0" ;;
    esac
  fi
  if [[ -z "$_style" ]]; then
    _old_style=$(grep -o '"audio_style"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
    chime_style="${_old_style:-random}"
  fi
  if [[ -z "$_events" ]]; then
    _old_events=$(grep -o '"audio_events"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
    chime_events="${_old_events:-Stop,Notification,PermissionRequest,SessionStart,SessionEnd}"
  fi
  if [[ -z "$_volume" ]]; then
    _old_volume=$(grep -o '"bell_volume"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
    chime_volume="${_old_volume:-1}"
  fi
fi

# ── Resolve chime style ──
# On SessionStart, prefer the style the statusline already resolved so the
# displayed name matches the sound played. Fall back to picking a fresh
# random style if no resolved style is available yet.
_resolved_style="$chime_style"
if [[ "$_resolved_style" == "random" && -d "$AUDIO_DIR" ]]; then
  if [[ "$EVENT" == "SessionStart" ]]; then
    # New session: prefer the style already resolved by the statusline renderer
    # to avoid a race where we pick a different random style than what's displayed.
    if [[ -f "$STATE_FILE" ]]; then
      _already_resolved=$(grep -o '"resolved_chime_style"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
      if [[ -n "$_already_resolved" && "$_already_resolved" != "random" && -f "$AUDIO_DIR/$_already_resolved/$_already_resolved-$EVENT.mp3" ]]; then
        _resolved_style="$_already_resolved"
      fi
    fi
  fi
  if [[ "$_resolved_style" == "random" && "$EVENT" == "SessionStart" ]]; then
    # No pre-resolved style available: pick a random style, avoiding the last 10
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

      # Build candidates: all styles not in recent history
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
  elif [[ "$EVENT" != "SessionStart" ]]; then
    # Mid-session: reuse the previously resolved style
    if [[ -f "$STATE_FILE" ]]; then
      _prev=$(grep -o '"resolved_chime_style"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"/\1/' || true)
      if [[ -n "$_prev" ]]; then
        _resolved_style="$_prev"
      fi
    fi
    # If still unresolved (no state file or no saved style), pick one now
    if [[ "$_resolved_style" == "random" ]]; then
      _styles=()
      while IFS= read -r d; do
        _styles+=("$(basename "$d")")
      done < <(find "$AUDIO_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
      if [[ ${#_styles[@]} -gt 0 ]]; then
        _resolved_style="${_styles[$((RANDOM % ${#_styles[@]}))]}"
      fi
    fi
  fi
fi

# Write resolved style to state file so the statusline can display it
if [[ -f "$STATE_FILE" ]]; then
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

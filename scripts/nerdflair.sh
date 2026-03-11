#!/bin/bash
# nerdflair — Configure Claude Code statusline layout and width.
#
# Usage:
#   nerdflair                      # cycle layout to next mode
#   nerdflair layout               # cycle layout: full → compact → minimal → full
#   nerdflair layout full          # set layout directly
#   nerdflair chime-events         # show/edit which events play chimes
#   nerdflair chime-style          # cycle chime style: random → BalladPiano → ... → random
#   nerdflair chime-style random   # set chime style directly
#   nerdflair chime-volume 50      # set chime volume to 50% (0 = muted)
#   nerdflair color-palette        # cycle color palette: vibrant → muted → mono → vibrant
#   nerdflair color-palette mono   # set color palette directly
#   nerdflair flair                # toggle progress bar decorations on/off (icon + texture)
#   nerdflair terminal-bell        # toggle terminal bell on/off (BEL char on Stop/Notification/PermissionRequest)
#   nerdflair width 60             # set layout width to 60
#   nerdflair width auto           # reset to auto (terminal width)
#   nerdflair info                 # show current settings without changing anything
#
# State is persisted in ~/.claude/nerdflair/state.json
# The statusline script reads this file on every render.

STATE_FILE="$HOME/.claude/nerdflair/state.json"
VALID_MODES="full compact minimal"

# Ensure the directory exists
mkdir -p "$(dirname "$STATE_FILE")"

# Read current state
current_mode="full"
current_width="auto"
current_flair="true"
current_color="vibrant"
current_terminal_bell="on"
current_chime_sound="Glass"
current_chime_style="random"
current_chime_events="Stop,Notification,PermissionRequest,SessionStart,SessionEnd"
current_chime_volume="1"
if [[ -f "$STATE_FILE" ]]; then
  current_mode=$(cat "$STATE_FILE" | grep -o '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  current_width=$(cat "$STATE_FILE" | grep -o '"width"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  current_flair=$(cat "$STATE_FILE" | grep -o '"flair"[[:space:]]*:[[:space:]]*[a-z]*' | head -1 | sed 's/.*:[[:space:]]*//')
  current_color=$(cat "$STATE_FILE" | grep -o '"color"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  current_terminal_bell=$(cat "$STATE_FILE" | grep -o '"terminal_bell"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  current_chime_sound=$(cat "$STATE_FILE" | grep -o '"chime_sound"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  current_chime_style=$(cat "$STATE_FILE" | grep -o '"chime_style"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  current_chime_events=$(cat "$STATE_FILE" | grep -o '"chime_events"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  current_chime_volume=$(cat "$STATE_FILE" | grep -o '"chime_volume"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  current_last_session=$(cat "$STATE_FILE" | grep -o '"last_session"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  current_mode="${current_mode:-full}"
  current_width="${current_width:-auto}"
  current_flair="${current_flair:-true}"
  # Legacy migration: "default" color → "vibrant"
  if [[ "$current_color" == "default" ]]; then
    current_color="vibrant"
  fi
  current_color="${current_color:-vibrant}"
  # Legacy migration: read old "bell" field if new fields are missing
  if [[ -z "$current_terminal_bell" ]]; then
    _old_bell=$(cat "$STATE_FILE" | grep -o '"bell"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
    case "$_old_bell" in
      both)   current_terminal_bell="on" ;;
      visual) current_terminal_bell="on"; current_chime_volume="0" ;;
      audio)  current_terminal_bell="off" ;;
      off)    current_terminal_bell="off"; current_chime_volume="0" ;;
    esac
  fi
  current_terminal_bell="${current_terminal_bell:-on}"
  current_chime_sound="${current_chime_sound:-Glass}"
  if [[ -z "$current_chime_style" ]]; then
    current_chime_style=$(cat "$STATE_FILE" | grep -o '"audio_style"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  fi
  current_chime_style="${current_chime_style:-random}"
  if [[ -z "$current_chime_events" ]]; then
    current_chime_events=$(cat "$STATE_FILE" | grep -o '"audio_events"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  fi
  current_chime_events="${current_chime_events:-Stop,Notification,PermissionRequest,SessionStart,SessionEnd}"
  if [[ -z "$current_chime_volume" ]]; then
    current_chime_volume=$(cat "$STATE_FILE" | grep -o '"bell_volume"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  fi
  current_chime_volume="${current_chime_volume:-1}"
fi

# ── Parse arguments ──────────────────────────────────────────────
next_mode=""
next_width=""
toggle_flair=false
cycle_color=false
set_color=""
toggle_terminal_bell=false
set_chime_style=""
cycle_chime_style=false
toggle_chime_event=""
set_volume=""
show_info=false
cycle_layout=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    info)
      show_info=true
      shift
      ;;
    layout)
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        if ! echo "$VALID_MODES" | grep -qw "$2"; then
          printf '\033[38;2;224;108;117m✗ Unknown layout "%s"\033[0m\n' "$2"
          printf '  Valid layouts: %s\n' "$VALID_MODES"
          exit 1
        fi
        next_mode="$2"
        shift 2
      else
        cycle_layout=true
        shift
      fi
      ;;
    width|--width|-w)
      if [[ -z "${2:-}" ]]; then
        printf '\033[38;2;224;108;117m✗ width requires a value (number or "auto")\033[0m\n'
        exit 1
      fi
      if [[ "$2" == "auto" ]]; then
        next_width="auto"
      elif [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 50 && $2 <= 150 )); then
        next_width="$2"
      else
        printf '\033[38;2;224;108;117m✗ Width must be 50-150 or "auto"\033[0m\n'
        exit 1
      fi
      shift 2
      ;;
    flair)
      toggle_flair=true
      shift
      ;;
    terminal-bell|bell)
      toggle_terminal_bell=true
      shift
      ;;
    chimes)
      # Legacy: treat as alias for chime-volume toggle (not documented)
      # If chimes are muted, set to 100%; otherwise mute
      _cur_muted=$(awk -v v="$current_chime_volume" 'BEGIN {print (v+0 <= 0) ? 1 : 0}')
      if [[ "$_cur_muted" == "1" ]]; then
        set_volume="1"
      else
        set_volume="0"
      fi
      shift
      ;;
    chime-style)
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        set_chime_style="$2"
        shift 2
      else
        cycle_chime_style=true
        shift
      fi
      ;;
    bell-sound|audio-style)
      # Legacy aliases
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        set_chime_style="$2"
        shift 2
      else
        cycle_chime_style=true
        shift
      fi
      ;;
    chime-events|audio-events)
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        toggle_chime_event="$2"
        shift 2
      else
        toggle_chime_event="__show__"
        shift
      fi
      ;;
    chime-volume|volume)
      if [[ -z "${2:-}" ]]; then
        printf '\033[38;2;224;108;117m✗ chime-volume requires a value (0-100)\033[0m\n'
        exit 1
      fi
      _vol="$2"
      if [[ "$_vol" =~ ^[0-9]+%?$ ]]; then
        _vol="${_vol%\%}"
        if (( _vol < 0 || _vol > 100 )); then
          printf '\033[38;2;224;108;117m✗ Volume must be 0-100\033[0m\n'
          exit 1
        fi
        set_volume=$(awk -v v="$_vol" 'BEGIN {printf "%.2f", v / 100}')
      else
        printf '\033[38;2;224;108;117m✗ Volume must be 0-100 (integer)\033[0m\n'
        exit 1
      fi
      shift 2
      ;;
    context-bar)
      # Legacy: silently ignore
      shift
      ;;
    color-palette|color)
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        case "$2" in
          vibrant|muted|mono) set_color="$2"; shift 2 ;;
          *) printf '\033[38;2;224;108;117m✗ Unknown palette "%s"\033[0m\n' "$2"
             printf '  Valid palettes: vibrant, muted, mono\n'
             exit 1 ;;
        esac
      else
        cycle_color=true
        shift
      fi
      ;;
    *)
      # Treat as layout mode for backwards compat
      if [[ -z "$next_mode" ]]; then
        if ! echo "$VALID_MODES" | grep -qw "$1"; then
          printf '\033[38;2;224;108;117m✗ Unknown command "%s"\033[0m\n' "$1"
          printf '  Commands: chime-events, chime-style, chime-volume, color-palette,\n'
          printf '            flair, layout, terminal-bell, width\n'
          exit 1
        fi
        next_mode="$1"
      fi
      shift
      ;;
  esac
done

# ── Info mode: print current state and exit ─────────────────────
if [[ "$show_info" == "true" ]]; then
  CYAN='\033[38;2;86;182;194m'
  DIM='\033[38;2;120;135;155m'
  GREEN='\033[38;2;152;195;121m'
  RST='\033[0m'

  case "$current_mode" in
    full)    mode_desc="3 rows -- folder/branch, progress bar, mcp/cost" ;;
    compact) mode_desc="2 rows -- folder/branch, progress bar (cost in bar)" ;;
    minimal) mode_desc="1 row  -- progress bar only" ;;
  esac

  printf "${CYAN}Statusline: %s${RST} (%s)" "$current_mode" "$mode_desc"
  if [[ "$current_width" == "auto" ]]; then
    printf " ${DIM}width: auto${RST}"
  else
    printf " ${DIM}width: %s${RST}" "$current_width"
  fi
  if [[ "$current_flair" == "true" ]]; then
    printf " ${GREEN}flair: on${RST}"
  else
    printf " ${DIM}flair: off${RST}"
  fi
  if [[ "$current_terminal_bell" == "on" ]]; then
    printf " ${GREEN}terminal-bell: on${RST}"
  else
    printf " ${DIM}terminal-bell: off${RST}"
  fi
  _vol_pct=$(awk -v v="$current_chime_volume" 'BEGIN {printf "%g", v * 100}')
  if [[ "$_vol_pct" == "0" ]]; then
    printf " ${DIM}chime-volume: muted${RST}"
  else
    printf " ${GREEN}chime-volume: %s%%${RST} ${DIM}(%s)${RST}" "$_vol_pct" "$current_chime_style"
    _evt_count=$(echo "$current_chime_events" | tr ',' '\n' | grep -c . || true)
    printf " ${DIM}(%s events)${RST}" "$_evt_count"
  fi
  if [[ "$current_color" == "vibrant" ]]; then
    printf " ${DIM}color-palette: vibrant${RST}"
  elif [[ "$current_color" == "mono" ]]; then
    printf " ${GREEN}color-palette: mono${RST}"
  elif [[ "$current_color" == "muted" ]]; then
    printf " ${GREEN}color-palette: muted${RST}"
  fi
  printf '\n'
  exit 0
fi

# Handle flair toggle
next_flair="$current_flair"
if [[ "$toggle_flair" == "true" ]]; then
  if [[ "$current_flair" == "true" ]]; then
    next_flair="false"
  else
    next_flair="true"
  fi
fi

# Handle terminal-bell toggle: on → off → on
next_terminal_bell="$current_terminal_bell"
if [[ "$toggle_terminal_bell" == "true" ]]; then
  if [[ "$current_terminal_bell" == "on" ]]; then
    next_terminal_bell="off"
  else
    next_terminal_bell="on"
  fi
fi

next_chime_sound="$current_chime_sound"

# Handle chime-style: cycle or set directly
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIO_DIR="$(cd "$SCRIPT_DIR/../assets/audio" 2>/dev/null && pwd)" || AUDIO_DIR=""
_available_styles=("random")
if [[ -n "$AUDIO_DIR" && -d "$AUDIO_DIR" ]]; then
  while IFS= read -r d; do
    _available_styles+=("$(basename "$d")")
  done < <(find "$AUDIO_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
fi

next_chime_style="$current_chime_style"
if [[ -n "$set_chime_style" ]]; then
  _matched=""
  for s in "${_available_styles[@]}"; do
    if [[ "${s,,}" == "${set_chime_style,,}" ]]; then
      _matched="$s"
      break
    fi
  done
  if [[ -n "$_matched" ]]; then
    next_chime_style="$_matched"
  else
    printf '\033[38;2;224;108;117m✗ Unknown chime style "%s"\033[0m\n' "$set_chime_style"
    printf '  Available: %s\n' "${_available_styles[*]}"
    exit 1
  fi
elif [[ "$cycle_chime_style" == "true" ]]; then
  _found=false
  for i in "${!_available_styles[@]}"; do
    if [[ "${_available_styles[$i]}" == "$current_chime_style" ]]; then
      _next_idx=$(( (i + 1) % ${#_available_styles[@]} ))
      next_chime_style="${_available_styles[$_next_idx]}"
      _found=true
      break
    fi
  done
  if [[ "$_found" == "false" ]]; then
    next_chime_style="random"
  fi
fi

# Handle chime-events: toggle individual events or show current
ALL_CHIME_EVENTS="Stop Notification PermissionRequest SessionStart SessionEnd UserPromptSubmit PreCompact"
next_chime_events="$current_chime_events"
if [[ "$toggle_chime_event" == "__show__" ]]; then
  CYAN='\033[38;2;86;182;194m'
  GREEN='\033[38;2;152;195;121m'
  DIM='\033[38;2;120;135;155m'
  RST='\033[0m'
  printf "${CYAN}Chime events:${RST}\n"
  for evt in $ALL_CHIME_EVENTS; do
    if echo ",$current_chime_events," | grep -q ",$evt,"; then
      printf "  ${GREEN}✓ %s${RST}\n" "$evt"
    else
      printf "  ${DIM}✗ %s${RST}\n" "$evt"
    fi
  done
  printf "\n${DIM}Toggle with: nerdflair chime-events <EventName>${RST}\n"
  exit 0
elif [[ -n "$toggle_chime_event" ]]; then
  _valid_event=false
  for evt in $ALL_CHIME_EVENTS; do
    if [[ "$evt" == "$toggle_chime_event" ]]; then
      _valid_event=true
      break
    fi
  done
  if [[ "$_valid_event" == "false" ]]; then
    printf '\033[38;2;224;108;117m✗ Unknown event "%s"\033[0m\n' "$toggle_chime_event"
    printf '  Valid events: %s\n' "$ALL_CHIME_EVENTS"
    exit 1
  fi
  if echo ",$current_chime_events," | grep -q ",$toggle_chime_event,"; then
    # Remove event from comma-separated list using exact-match sandwich to avoid
    # substring corruption (e.g. removing "Stop" must not damage "UserPromptSubmit")
    next_chime_events=$(printf ',%s,' "$current_chime_events" | sed "s/,$toggle_chime_event,/,/" | sed 's/^,//;s/,$//')
  else
    if [[ -z "$current_chime_events" ]]; then
      next_chime_events="$toggle_chime_event"
    else
      next_chime_events="$current_chime_events,$toggle_chime_event"
    fi
  fi
fi

# Handle color-palette: set directly or cycle
next_color="$current_color"
if [[ -n "$set_color" ]]; then
  next_color="$set_color"
elif [[ "$cycle_color" == "true" ]]; then
  case "$current_color" in
    vibrant) next_color="muted" ;;
    muted)   next_color="mono" ;;
    mono)    next_color="vibrant" ;;
    *)       next_color="vibrant" ;;
  esac
fi

# If no action specified at all — cycle layout
if [[ -z "$next_mode" && "$cycle_layout" == "false" && "$toggle_flair" == "false" && "$toggle_terminal_bell" == "false" && "$cycle_chime_style" == "false" && -z "$set_chime_style" && -z "$toggle_chime_event" && -z "$set_volume" && "$cycle_color" == "false" && -z "$set_color" && -z "$next_width" ]]; then
  cycle_layout=true
fi

if [[ "$cycle_layout" == "true" && -z "$next_mode" ]]; then
  case "$current_mode" in
    full)    next_mode="compact" ;;
    compact) next_mode="minimal" ;;
    *)       next_mode="full" ;;
  esac
fi

# Apply: keep current values for anything not explicitly changed
next_mode="${next_mode:-$current_mode}"
next_width="${next_width:-$current_width}"
next_chime_volume="${set_volume:-$current_chime_volume}"

# Write new state (preserve renderer-managed fields)
_extra=""
if [[ -n "$current_last_session" ]]; then
  _extra=", \"last_session\": \"${current_last_session}\""
fi
_tmp_state="${STATE_FILE}.tmp.$$"
cat > "$_tmp_state" << EOF
{"mode": "$next_mode", "width": "$next_width", "flair": $next_flair, "terminal_bell": "$next_terminal_bell", "chime_sound": "$next_chime_sound", "chime_volume": "$next_chime_volume", "chime_style": "$next_chime_style", "chime_events": "$next_chime_events", "color": "$next_color"${_extra}}
EOF
mv "$_tmp_state" "$STATE_FILE"

# ── Visual feedback ──────────────────────────────────────────────
CYAN='\033[38;2;86;182;194m'
DIM='\033[38;2;120;135;155m'
GREEN='\033[38;2;152;195;121m'
RED='\033[38;2;224;108;117m'
RST='\033[0m'

case "$next_mode" in
  full)    mode_desc="3 rows -- folder/branch, progress bar, mcp/cost" ;;
  compact) mode_desc="2 rows -- folder/branch, progress bar (cost in bar)" ;;
  minimal) mode_desc="1 row  -- progress bar only" ;;
esac

printf "${CYAN}⟳ Statusline → %s${RST} (%s)" "$next_mode" "$mode_desc"

if [[ "$next_width" == "auto" ]]; then
  printf " ${DIM}width: auto${RST}"
else
  printf " ${DIM}width: %s${RST}" "$next_width"
fi

if [[ "$next_flair" == "true" ]]; then
  printf " ${GREEN}flair: on${RST}"
else
  printf " ${DIM}flair: off${RST}"
fi

if [[ "$next_terminal_bell" == "on" ]]; then
  printf " ${GREEN}terminal-bell: on${RST}"
else
  printf " ${DIM}terminal-bell: off${RST}"
fi
_vol_pct=$(awk -v v="$next_chime_volume" 'BEGIN {printf "%g", v * 100}')
if [[ "$_vol_pct" == "0" ]]; then
  printf " ${DIM}chime-volume: muted${RST}"
else
  printf " ${GREEN}chime-volume: %s%%${RST} ${DIM}(%s)${RST}" "$_vol_pct" "$next_chime_style"
  _evt_count=$(echo "$next_chime_events" | tr ',' '\n' | grep -c . || true)
  printf " ${DIM}(%s events)${RST}" "$_evt_count"
fi

if [[ "$next_color" == "vibrant" ]]; then
  printf " ${DIM}color-palette: vibrant${RST}"
elif [[ "$next_color" == "mono" ]]; then
  printf " ${GREEN}color-palette: mono${RST}"
elif [[ "$next_color" == "muted" ]]; then
  printf " ${GREEN}color-palette: muted${RST}"
fi
printf '\n'

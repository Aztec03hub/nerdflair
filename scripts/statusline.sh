#!/bin/bash

input=$(cat)

# ── Layout mode & width from state file ──────────────────────────
_SL_STATE_FILE="$HOME/.claude/nerdflair/state.json"
if [[ -f "$_SL_STATE_FILE" ]]; then
  _SL_STATE=$(cat "$_SL_STATE_FILE")
  _SL_MODE=$(echo "$_SL_STATE" | grep -o '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  _SL_WIDTH=$(echo "$_SL_STATE" | grep -o '"width"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  # _SL_FLAIR removed — texture always shown
  _SL_COLOR_MODE=$(echo "$_SL_STATE" | grep -o '"color"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  _SL_TERMINAL_BELL=$(echo "$_SL_STATE" | grep -o '"terminal_bell"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  _SL_CHIME_VOLUME=$(echo "$_SL_STATE" | grep -o '"chime_volume"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  _SL_CHIME_STYLE=$(echo "$_SL_STATE" | grep -o '"chime_style"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  _SL_LAST_SESSION=$(echo "$_SL_STATE" | grep -o '"last_session"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
fi
_SL_MODE="${_SL_MODE:-full}"
_SL_WIDTH="${_SL_WIDTH:-auto}"
_SL_COLOR_MODE="${_SL_COLOR_MODE:-vibrant}"
# Legacy migration: "default" color → "vibrant"
if [[ "$_SL_COLOR_MODE" == "default" ]]; then
  _SL_COLOR_MODE="vibrant"
fi
_SL_TERMINAL_BELL="${_SL_TERMINAL_BELL:-on}"
_SL_CHIME_VOLUME="${_SL_CHIME_VOLUME:-1}"
_SL_CHIME_STYLE="${_SL_CHIME_STYLE:-random}"
# The resolved chime style is stored per-session in ~/.claude/nerdflair/chime-sessions/<session_id>
# by bell.sh on SessionStart. The statusline reads it from there.
# ── Sanitize external strings ─────────────────────────────────────
# Strip backslashes so that printf '%b' cannot expand backslash-escape
# sequences (e.g. \033, \e, \x1b) into terminal control characters.
# Applied to user-controlled values: branch names, directory names, MCP
# server names, and model IDs.
_sanitize() { printf '%s' "$1" | sed 's/\\//g'; }

# ── Extract fields from Claude Code JSON ──────────────────────────
if ! command -v jq &>/dev/null; then
  echo "jq not found — install with: brew install jq"
  exit 1
fi
cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')

# Model: extract friendly name + version from ID
raw_model=$(echo "$input" | jq -r '.model.id // .model.display_name // .model // empty')
model=""
if [[ "$raw_model" =~ (opus|sonnet|haiku) ]]; then
  name="${BASH_REMATCH[1]}"
  # Capitalize first letter
  model="$(tr '[:lower:]' '[:upper:]' <<< "${name:0:1}")${name:1}"
  # Extract version like "4-6" → "4.6"
  if [[ "$raw_model" =~ [0-9]+-[0-9]+ ]]; then
    ver="${BASH_REMATCH[0]}"
    model+=" ${ver//-/.}"
  fi
else
  model=$(_sanitize "$raw_model")
fi

cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
total_duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
total_api_ms=$(echo "$input" | jq -r '.cost.total_api_duration_ms // empty')
output_style=$(echo "$input" | jq -r '.output_style.name // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
# Context window
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
input_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
output_tokens=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

# MCP servers — aggregate from global ~/.claude.json and project .mcp.json
mcp_total=0
mcp_enabled=0
mcp_names=()
for mcp_file in "$HOME/.claude.json" "${project_dir}/.mcp.json" "${cwd}/.mcp.json"; do
  if [[ -f "$mcp_file" ]]; then
    file_total=$(jq -r '.mcpServers // {} | length' "$mcp_file" 2>/dev/null)
    file_disabled=$(jq -r '[.mcpServers // {} | to_entries[] | select(.value.disabled == true)] | length' "$mcp_file" 2>/dev/null)
    mcp_total=$(( mcp_total + ${file_total:-0} ))
    mcp_enabled=$(( mcp_enabled + ${file_total:-0} - ${file_disabled:-0} ))
    # Collect enabled server names
    while IFS= read -r _name; do
      [[ -n "$_name" ]] && mcp_names+=("$(_sanitize "$_name")")
    done < <(jq -r '[.mcpServers // {} | to_entries[] | select(.value.disabled != true) | .key] | sort[] ' "$mcp_file" 2>/dev/null)
  fi
done
# Sort names alphabetically (handles names from multiple files)
IFS=$'\n' mcp_names_sorted=($(printf '%s\n' "${mcp_names[@]}" | sort -f)); unset IFS

# ── Colors (4-color palette + brand) ──────────────────────────────────
# Primary: workspace identity
BLUE="\033[38;2;95;179;255m"
MAGENTA="\033[38;2;198;120;221m"
CYAN="\033[38;2;86;182;194m"
# Muted: secondary info (MCP, mode, timing)
MAUVE="\033[38;2;145;130;155m"
# Accent: money
DARK_GREEN="\033[38;2;110;155;95m"
# Alert: warnings (progress bar caution)
ALERT="\033[38;2;220;175;100m"
# Danger: critical (progress bar 80%+)
RED="\033[38;2;224;108;117m"
# Progress bar healthy state
GREEN="\033[38;2;152;195;121m"
# Accent: dirty files
MUSTARD="\033[38;2;180;155;95m"
# Time/cost
SAGE="\033[38;2;190;150;120m"
# Cost
COST_GREEN="\033[38;2;90;120;82m"
# Diff
DIFF_PLUS="\033[38;2;130;190;110m"
DIFF_MINUS="\033[38;2;235;100;90m"
# Utility
DIM="\033[38;2;85;90;100m"
RESET="\033[0m"

# ── Color mode overrides ────────────────────────────────────────
# Palette swaps based on _SL_COLOR_MODE. The vibrant palette above
# is left untouched; mono/dim simply reassign the same variable names.
if [[ "$_SL_COLOR_MODE" == "mono" ]]; then
  # Monochrome: shades of gray only
  BLUE="\033[38;2;190;190;190m"
  MAGENTA="\033[38;2;170;170;170m"
  CYAN="\033[38;2;180;180;180m"
  MAUVE="\033[38;2;140;140;140m"
  DARK_GREEN="\033[38;2;150;150;150m"
  ALERT="\033[38;2;200;200;200m"
  RED="\033[38;2;210;210;210m"
  GREEN="\033[38;2;170;170;170m"
  MUSTARD="\033[38;2;185;185;185m"
  SAGE="\033[38;2;145;145;145m"
  COST_GREEN="\033[38;2;150;150;150m"
  DIFF_PLUS="\033[38;2;160;160;160m"
  DIFF_MINUS="\033[38;2;160;160;160m"
  DIM="\033[38;2;90;90;90m"
elif [[ "$_SL_COLOR_MODE" == "muted" ]]; then
  # Muted: same hues, ~40% saturation
  BLUE="\033[38;2;140;170;210m"
  MAGENTA="\033[38;2;170;145;185m"
  CYAN="\033[38;2;130;165;170m"
  MAUVE="\033[38;2;140;135;150m"
  DARK_GREEN="\033[38;2;125;145;115m"
  ALERT="\033[38;2;185;165;125m"
  RED="\033[38;2;185;140;140m"
  GREEN="\033[38;2;150;170;135m"
  MUSTARD="\033[38;2;185;170;115m"
  SAGE="\033[38;2;165;145;125m"
  COST_GREEN="\033[38;2;120;135;118m"
  DIFF_PLUS="\033[38;2;115;135;110m"
  DIFF_MINUS="\033[38;2;175;125;118m"
  DIM="\033[38;2;95;95;105m"
fi

SEP="  "
BULLET="${DIM} · ${RESET}"

# ── Detect effective git repo (current dir or one level deep) ────
git_dir=""
if [[ -n "$cwd" ]]; then
  cd "$cwd" 2>/dev/null
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_dir="$cwd"
  else
    # Look one level deep for a git repo (wrapper folder pattern)
    # Only adopt it if there's exactly ONE git subfolder
    git_subs=()
    for sub in "$cwd"/*/; do
      if [[ -d "$sub/.git" ]]; then
        git_subs+=("${sub%/}")
      fi
    done
    if (( ${#git_subs[@]} == 1 )); then
      git_dir="${git_subs[0]}"
    fi
  fi
fi

# ── Helper: format number with commas ──────────────────────────
_fmt_num() {
  printf "%'d" "$1" 2>/dev/null || printf "%d" "$1"
}

# ── Uncommitted files segment ────────────────────────────────────
dirty_segment=""
if [[ -n "$git_dir" ]]; then
  cd "$git_dir" 2>/dev/null
  dirty_count=$(git -c core.useBuiltinFSMonitor=false status --porcelain --ignore-submodules=dirty 2>/dev/null | wc -l | tr -d ' ')
  if (( dirty_count > 0 )); then
    dirty_icon=$(printf '\xef\x81\x84')  # U+F044 nf-fa-pencil
    dirty_segment="${MUSTARD}${dirty_icon} $(_fmt_num "$dirty_count")${RESET}"
    # Compute lines added/removed from git diff (staged + unstaged)
    lines_added=0
    lines_removed=0
    while IFS=$'\t' read -r added removed _; do
      [[ "$added" == "-" ]] && continue  # skip binary files
      (( lines_added += added ))
      (( lines_removed += removed ))
    done < <(git diff --numstat HEAD 2>/dev/null || git diff --numstat 2>/dev/null)
    # Also count untracked files' lines as added (cap at 100 files to avoid freezing)
    _ucount=0
    while IFS= read -r ufile; do
      (( _ucount++ ))
      (( _ucount > 100 )) && break
      ulines=$(wc -l < "$ufile" 2>/dev/null | tr -d ' ')
      (( lines_added += ${ulines:-0} ))
    done < <(git ls-files --others --exclude-standard 2>/dev/null)
    # Append lines added/removed
    plus_icon="+"
    minus_icon="-"
    diff_parts=""
    if (( lines_added > 0 )); then
      diff_parts+="${DIFF_PLUS}${plus_icon}$(_fmt_num "$lines_added")${RESET}"
    fi
    if (( lines_removed > 0 )); then
      [[ -n "$diff_parts" ]] && diff_parts+=" "
      diff_parts+="${DIFF_MINUS}${minus_icon}$(_fmt_num "$lines_removed")${RESET}"
    fi
    if [[ -n "$diff_parts" ]]; then
      dirty_segment+=" \033[1;38;2;72;78;74m[${RESET}${diff_parts}\033[1;38;2;72;78;74m]${RESET}"
    fi
  fi
fi

ELLIPSIS=$(printf '\xef\x85\x81')  # U+F141
MIN_BRANCH=10

# ── Folder + branch segment ──────────────────────────────────────
# Folder always reflects cwd; branch comes from git_dir (which may differ).
folder_name=""
branch=""
folder_segment=""
_display_dir="${project_dir:-$cwd}"
if [[ -n "$_display_dir" ]]; then
  # Folder name: based on project_dir (launch directory) so it stays stable
  # even when Claude cd's into subdirectories during a session
  if [[ "$_display_dir" == "$HOME" ]]; then
    folder_name="~"
  else
    folder_name=$(_sanitize "$(basename "$_display_dir")")
  fi
  # Branch: from whichever git repo we detected
  if [[ -n "$git_dir" ]]; then
    cd "$git_dir" 2>/dev/null
    branch=$(_sanitize "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)")
  fi
fi

# ── Helper: format milliseconds ──────────────────────────────────
# Seconds/minutes: whole numbers only. Hours: up to 2 decimals, trim trailing zeros.
_fmt_duration() {
  local ms=$1
  local total_secs=$(( ms / 1000 ))
  local total_mins=$(( total_secs / 60 ))
  if (( total_mins >= 60 )); then
    # Decimal hours: e.g. 1.25h, 2.5h, 3h — with commas for 1,000+
    local hundredths=$(( total_mins * 100 / 60 ))
    local whole=$(( hundredths / 100 ))
    local frac=$(( hundredths % 100 ))
    local whole_fmt
    whole_fmt=$(_fmt_num "$whole")
    local tenths=$(( (frac + 5) / 10 ))
    if (( tenths >= 10 )); then
      whole=$(( whole + 1 ))
      tenths=0
      whole_fmt=$(_fmt_num "$whole")
    fi
    if (( tenths == 0 )); then
      printf '%sh' "$whole_fmt"
    else
      printf '%s.%dh' "$whole_fmt" "$tenths"
    fi
  elif (( total_mins > 0 )); then
    printf '%dm' "$total_mins"
  else
    printf '%ds' "$total_secs"
  fi
}

# ── MCP servers segment ─────────────────────────────────────────
mcp_segment=""
mcp_segment_expanded=""
if (( mcp_enabled > 0 )); then
  mcp_icon=$(printf '\xef\x90\xa5')  # U+F425 nf-oct-plug
  mcp_segment="${MAUVE}${mcp_icon} ${mcp_enabled} MCP${RESET}"
  # Build expanded form with sorted names: "MCP proxy, slack" (list only, no count)
  # Also build truncated variants: "Slack, Glean, 4 more"
  if (( ${#mcp_names_sorted[@]} > 0 )); then
    _mcp_name_list=""
    for _mn in "${mcp_names_sorted[@]}"; do
      [[ -n "$_mcp_name_list" ]] && _mcp_name_list+=", "
      _mcp_name_list+="$_mn"
    done
    mcp_segment_expanded="${MAUVE}${mcp_icon} ${_mcp_name_list}${RESET}"

    # Build truncated variants showing first N names + ", X more"
    _mcp_count=${#mcp_names_sorted[@]}
    mcp_segments_truncated=()
    if (( _mcp_count > 1 )); then
      for (( _i = _mcp_count - 1; _i >= 1; _i-- )); do
        _partial=""
        for (( _j = 0; _j < _i; _j++ )); do
          [[ -n "$_partial" ]] && _partial+=", "
          _partial+="${mcp_names_sorted[$_j]}"
        done
        _remaining=$(( _mcp_count - _i ))
        _partial+=", ${_remaining} more"
        mcp_segments_truncated+=("${MAUVE}${mcp_icon} ${_partial}${RESET}")
      done
    fi
  fi
fi


# ── Context usage segment ───────────────────────────────────────
ctx_segment=""
ctx_total=200000  # default context window size

if [[ -n "$used_pct" && -n "$input_tokens" && -n "$ctx_size" ]]; then
  # We have full context_window data from Claude Code
  total_used=$((input_tokens + ${output_tokens:-0}))
  ctx_total="$ctx_size"
  pct="$used_pct"
else
  # Fall back: parse last usage entry from transcript JSONL
  transcript=$(echo "$input" | jq -r '.transcript_path // empty')
  if [[ -n "$transcript" && -f "$transcript" ]]; then
    last_usage=$(grep '"usage"' "$transcript" 2>/dev/null | tail -1 | jq -r '.message.usage // empty' 2>/dev/null)
    if [[ -n "$last_usage" && "$last_usage" != "null" ]]; then
      u_input=$(echo "$last_usage" | jq -r '.input_tokens // 0')
      u_cache_create=$(echo "$last_usage" | jq -r '.cache_creation_input_tokens // 0')
      u_cache_read=$(echo "$last_usage" | jq -r '.cache_read_input_tokens // 0')
      u_output=$(echo "$last_usage" | jq -r '.output_tokens // 0')
      total_used=$(( u_input + u_cache_create + u_cache_read + u_output ))
      pct=$(( total_used * 100 / ctx_total ))
      (( pct > 100 )) && pct=99
    fi
  fi
fi

# Default to 0 usage so we always show the context gauge (even on startup)
if [[ -z "$total_used" ]] || ! (( total_used > 0 )) 2>/dev/null; then
  total_used=0
  pct=0
fi

# ── Flair seed: per-session, re-randomize on 0→nonzero context ────
# Stored in ~/.claude/nerdflair/flair-sessions/<session_id> so parallel
# sessions don't clobber each other. Re-seeded when context transitions
# from 0 to nonzero (new conversation or after /clear).
_FLAIR_SESSION_DIR="$HOME/.claude/nerdflair/flair-sessions"
mkdir -p "$_FLAIR_SESSION_DIR"
_flair_session_file=""
_flair_seed=""
if [[ -n "$session_id" ]]; then
  _flair_session_file="$_FLAIR_SESSION_DIR/${session_id}"
  if [[ -f "$_flair_session_file" ]]; then
    _flair_seed=$(cat "$_flair_session_file" 2>/dev/null || true)
  fi
fi

if [[ -z "$_flair_seed" ]] && (( total_used > 0 )); then
  # Context just became nonzero (first prompt, or first prompt after /clear)
  _flair_seed=$(( $(date +%s) * 1000 + RANDOM ))
  if [[ -n "$_flair_session_file" ]]; then
    printf '%s' "$_flair_seed" > "$_flair_session_file"
  fi
elif [[ -n "$_flair_seed" ]] && (( total_used == 0 )); then
  # Context reset to zero (/clear) — remove seed so next nonzero re-picks
  _flair_seed=""
  if [[ -n "$_flair_session_file" && -f "$_flair_session_file" ]]; then
    rm -f "$_flair_session_file"
  fi
fi
# On SessionStart, prune stale flair session files older than 7 days
if [[ -n "$session_id" && -n "$_SL_LAST_SESSION" && "$session_id" != "$_SL_LAST_SESSION" ]]; then
  find "$_FLAIR_SESSION_DIR" -type f -mtime +7 -delete 2>/dev/null || true
fi

# Chime style: bell.sh picks random styles on SessionStart and writes
# them to per-session files in ~/.claude/nerdflair/chime-sessions/.

# Persist last_session to shared state file (used by bell.sh to suppress
# duplicate SessionStart on compaction). Re-read to avoid clobbering
# changes made by nerdflair.sh or bell.sh.
if [[ -n "$session_id" && -f "$_SL_STATE_FILE" ]]; then
  _fresh_state=$(cat "$_SL_STATE_FILE")
  _new_state=$(echo "$_fresh_state" \
    | sed 's/"last_session"[[:space:]]*:[[:space:]]*"[^"]*"//' \
    | sed 's/"flair_seed"[[:space:]]*:[[:space:]]*[0-9]*//' \
    | sed 's/"last_tokens"[[:space:]]*:[[:space:]]*[0-9]*//' \
    | sed 's/}[[:space:]]*$//' \
    | sed 's/,[[:space:]]*,/,/g' \
    | sed 's/,[[:space:]]*,/,/g' \
    | sed 's/,[[:space:]]*$//' \
    | sed 's/{[[:space:]]*,/{/')
  _tmp_state="${_SL_STATE_FILE}.tmp.$$"
  printf '%s, "last_session": "%s"}\n' "$_new_state" "$session_id" > "$_tmp_state"
  mv "$_tmp_state" "$_SL_STATE_FILE"
elif [[ -n "$session_id" ]]; then
  mkdir -p "$(dirname "$_SL_STATE_FILE")"
  _tmp_state="${_SL_STATE_FILE}.tmp.$$"
  printf '{"last_session": "%s"}\n' "$session_id" > "$_tmp_state"
  mv "$_tmp_state" "$_SL_STATE_FILE"
fi

if (( total_used >= 1000000 )); then
  used_fmt="$(( total_used / 1000000 ))M"
elif (( total_used >= 1000 )); then
  used_fmt="$(( total_used / 1000 ))k"
else
  used_fmt="$total_used"
fi
if (( ctx_total >= 1000000 )); then
  size_fmt="$(( ctx_total / 1000000 ))M"
elif (( ctx_total >= 1000 )); then
  size_fmt="$(( ctx_total / 1000 ))k"
else
  size_fmt="$ctx_total"
fi

if (( pct >= 70 )); then
  ctx_color="$RED"
elif (( pct >= 40 )); then
  ctx_color="$ALERT"
else
  ctx_color="$GREEN"
fi

# Context label for embedding in progress bar
ctx_label="${used_fmt}/${size_fmt} ${pct}%"

# ── Helper: visible width of an ANSI string ──────────────────────
_vis_len() {
  # Strip ANSI escapes, then count characters (wc -m handles multibyte)
  local stripped
  stripped=$(printf '%b' "$1" | sed $'s/\033\\[[0-9;]*m//g')
  printf '%s' "$stripped" | wc -m | tr -d ' '
}

# ── Helper: join parts with separator ────────────────────────────
_join_parts() {
  local result="\033[0m"
  local i=0
  for part in "$@"; do
    (( i > 0 )) && result+="${SEP}"
    result+="$part"
    (( i++ ))
  done
  printf '%s' "$result"
}

# ── Helper: build justified row (left parts | padding | right parts)
# Usage: _justified_row max_width left_parts_str sep right_parts_str
_justified_row() {
  local max_w=$1
  shift
  local left_str="$1"
  local right_str="$2"
  local left_len=$(_vis_len "$left_str")
  local right_len=$(_vis_len "$right_str")
  local pad_len=$(( max_w - left_len - right_len ))
  (( pad_len < 1 )) && pad_len=1
  local pad=""
  for (( p=0; p<pad_len; p++ )); do pad+=" "; done
  printf '%b%s%b%b' "$left_str" "$pad" "$right_str" "${RESET}"
}

# ── Total row width = bar max + 2 caps ────────────────────────────
# Limits: min 50, default 80, max 150 (enforced here regardless of state)
if [[ "$_SL_WIDTH" != "auto" && "$_SL_WIDTH" =~ ^[0-9]+$ ]]; then
  MAX_BAR=$_SL_WIDTH
  (( MAX_BAR < 50 )) && MAX_BAR=50
  (( MAX_BAR > 150 )) && MAX_BAR=150
else
  MAX_BAR=80
fi
ROW_WIDTH=$(( MAX_BAR + 2 ))

# ── Row 1: proactive budget-based truncation ──────────────────────
# Right side (dirty segment) is never truncated — measure it first.
# In minimal mode everything goes on the left, so right side is empty.
row1_right="\033[0m"
if [[ "$_SL_MODE" != "minimal" ]]; then
  [[ -n "$dirty_segment" ]] && row1_right+="$dirty_segment"
fi
right_width=$(_vis_len "$row1_right")

# Left side budget = total width minus right side minus 3 char min padding
# In minimal mode, reserve space for pill + dirty (both appended to left later)
_extra_reserve=0
if [[ "$_SL_MODE" == "minimal" ]]; then
  # bullet(3) + pill: cap(1) + space(1) + label + space(1) + cap(1) = label_len + 7
  _extra_reserve=$(( ${#pct} + 8 ))
  # dirty segment (if present): bullet(3) + dirty visual width
  if [[ -n "$dirty_segment" ]]; then
    _extra_reserve=$(( _extra_reserve + 3 + $(_vis_len "$dirty_segment") ))
  fi
fi
left_budget=$(( ROW_WIDTH - right_width - 3 - _extra_reserve ))
(( left_budget < 20 )) && left_budget=20

# Chrome overhead on the left side (icons + spaces, not counting text):
#   folder: "󰉋 " (2)  branch: " 󰘬 " (3)  bullet: " · " (3)  model: "icon " (2)
# With branch:  2 + folder_name + 3 + branch + 3 + 2 + model_text = 10 + text
# Without branch: 2 + folder_name + 3 + 2 + model_text = 7 + text
model_icon=$(printf '\xef\x94\x9b')  # U+F51B

# Build model text (may include style icon)
model_text="$model"
style_suffix=""  # icon suffix appended after model_text in the segment
if [[ -n "$output_style" && "$output_style" != "default" ]]; then
  _style_lower="$(tr '[:upper:]' '[:lower:]' <<< "${output_style:0:1}")"
  case "$_style_lower" in
    e) style_suffix=" $(printf '\xf3\xb0\xac\x8c')" ;;  # U+F0B0C for Explanatory
    l) style_suffix=" $(printf '\xf3\xb0\xac\x93')" ;;  # U+F0B13 for Learning
    *) style_suffix=" $(tr '[:lower:]' '[:upper:]' <<< "$_style_lower")" ;;
  esac
fi

# Calculate chrome: folder_icon(2) + [bullet(3) + branch_icon(2) if branch] + bullet(3) + model_icon(2)
chrome=7  # folder_icon(2) + bullet(3) + model_icon(2)
[[ -n "$branch" ]] && chrome=12  # add bullet(3) + branch_icon(2)

# Available text budget after chrome
text_budget=$(( left_budget - chrome ))
(( text_budget < 10 )) && text_budget=10

# Allocate: path/branch get priority, model gets the remainder
style_suffix_len=${#style_suffix}
model_text_len=$(( ${#model_text} + style_suffix_len ))
path_len=${#folder_name}
branch_len=${#branch}
path_branch_len=$(( path_len + branch_len ))

# Model needs at least 10 chars so "icon + name" stays readable (e.g. " Opus 4.6")
min_model=10
model_budget=$(( text_budget - path_branch_len ))
(( model_budget < min_model )) && model_budget=$min_model

# Path+branch budget is what remains after model
pb_budget=$(( text_budget - model_budget ))
# But if model fits fully, give all remaining back to path+branch
if (( model_text_len <= model_budget )); then
  model_budget=$model_text_len
  pb_budget=$(( text_budget - model_budget ))
fi

# Truncate path and branch to fit pb_budget
if (( path_branch_len > pb_budget )); then
  if [[ -n "$branch" ]]; then
    # Split budget 50/50, but if one side fits, give surplus to the other
    half=$(( pb_budget / 2 ))
    if (( path_len <= half )); then
      # Path fits in its half — branch gets the rest
      max_path=$path_len
      max_branch=$(( pb_budget - max_path ))
    elif (( branch_len <= half )); then
      # Branch fits in its half — path gets the rest
      max_branch=$branch_len
      max_path=$(( pb_budget - max_branch ))
    else
      # Both contest — split evenly
      max_path=$half
      max_branch=$(( pb_budget - max_path ))
    fi
    (( max_path < 4 )) && max_path=4
    (( max_branch < 4 )) && max_branch=4
    if (( branch_len > max_branch )); then
      branch="${ELLIPSIS}${branch:$((branch_len - max_branch + 1))}"
    fi
    if (( ${#folder_name} > max_path )); then
      folder_name="${ELLIPSIS}${folder_name:$((${#folder_name} - max_path + 1))}"
    fi
  else
    if (( path_len > pb_budget )); then
      folder_name="${ELLIPSIS}${folder_name:$((path_len - pb_budget + 1))}"
    fi
  fi
fi

# Truncate model text if needed (drop style/suffix first, then truncate name)
if (( model_text_len > model_budget )); then
  # Step 1: drop the style suffix
  model_text="$model"
  style_suffix=""
  style_suffix_len=0
  model_text_len=${#model_text}
  # Step 2: truncate model name if still too long
  if (( model_text_len > model_budget )); then
    model_text="${model_text:0:$((model_budget - 1))}${ELLIPSIS}"
  fi
fi

# Assemble folder segment
if [[ -n "$folder_name" ]]; then
  if [[ -n "$branch" ]]; then
    folder_segment="${BLUE}󰉋 ${folder_name}${BULLET}${MAGENTA}󰘬 ${branch}${RESET}"
  else
    folder_segment="${BLUE}󰉋 ${folder_name}${RESET}"
  fi
fi

# Assemble model segment
model_segment=""
if [[ -n "$model_text" ]]; then
  model_segment="${CYAN}${model_icon} ${model_text}${style_suffix}${RESET}"
fi

# Build row 1 left
row1_left="\033[0m"
[[ -n "$folder_segment" ]] && row1_left+="$folder_segment"
if [[ -n "$model_segment" ]]; then
  [[ -n "$folder_segment" ]] && row1_left+="${BULLET}"
  row1_left+="$model_segment"
fi

# Row 1: folder/branch/model + dirty (non-minimal modes render now;
# minimal deferred until after TIER arrays are defined for the pill)
if [[ "$_SL_MODE" != "minimal" ]]; then
  _justified_row "$ROW_WIDTH" "$row1_left" "$row1_right"
fi

# ── Build time + cost segments for row 3 ─────────────────────────
time_segment=""
cost_icon=$(printf '\xef\x85\x95')       # U+F155 dollar
time_icon=$(printf '\xef\x80\x97')       # U+F017 clock

TIME_COLOR="$MAUVE"
api_fmt=""
if [[ -n "$total_api_ms" && "$total_api_ms" -gt 999 ]] 2>/dev/null; then
  api_fmt=$(_fmt_duration "$total_api_ms")
  time_segment="${TIME_COLOR}${api_fmt}${RESET}"
fi

COST_COLOR="${COST_GREEN}"
formatted_cost=$(printf '%.2f' "${cost:-0}")
cost_segment=""
if [[ "$formatted_cost" != "0.00" ]]; then
  cost_segment="${COST_COLOR}${cost_icon}${formatted_cost}${RESET}"
fi

# ── Row 3 (built here, printed last): left: mcp | right: time · cost
# Build right side first so we can measure it for MCP name fit check
row3_right="\033[0m"

# Always resolve chime style label for display
_chime_label=""
if awk "BEGIN {exit (${_SL_CHIME_VOLUME:-1} > 0) ? 0 : 1}"; then
  # Read this session's resolved style from its per-session file
  _session_style_file="$HOME/.claude/nerdflair/chime-sessions/${session_id}"
  _session_resolved=""
  if [[ -n "$session_id" && -f "$_session_style_file" ]]; then
    _session_resolved=$(cat "$_session_style_file" 2>/dev/null || true)
  fi
  if [[ -n "$_session_resolved" && "$_session_resolved" != "random" ]]; then
    _chime_label="$_session_resolved"
  elif [[ "$_SL_CHIME_STYLE" == "random" && -f "$_SL_STATE_FILE" ]]; then
    # No per-session style yet — show the last entry from chime_recent_styles
    _last_recent=$(grep -o '"chime_recent_styles"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$_SL_STATE_FILE" | head -1 | sed 's/.*\[\(.*\)\]/\1/' | tr -d '"' | tr -d ' ' | awk -F',' '{print $NF}')
    _chime_label="${_last_recent:-random}"
  elif [[ -n "$_SL_CHIME_STYLE" ]]; then
    _chime_label="$_SL_CHIME_STYLE"
  fi
fi

# Build chime style segment
# Only show the resolved style name when on "random" and before any cost is incurred
_chime_segment=""
if [[ -n "$_chime_label" ]]; then
  _show_label=false
  if [[ "$_SL_CHIME_STYLE" == "random" && "$formatted_cost" == "0.00" ]]; then
    _show_label=true
  fi
  _vol_icon=$(printf '\xef\x80\xa8')  # U+F028  volume icon
  _vol_pct=$(awk "BEGIN {printf \"%g\", ${_SL_CHIME_VOLUME:-1} * 100}")
  if [[ "$_show_label" == "true" ]]; then
    if [[ "$_vol_pct" != "100" ]]; then
      _chime_segment="${MAUVE}${_vol_icon}  ${_chime_label} ${_vol_pct}%${RESET}"
    else
      _chime_segment="${MAUVE}${_vol_icon}  ${_chime_label}${RESET}"
    fi
  fi
fi

if [[ -n "$cost_segment" ]]; then
  if [[ -n "$_chime_segment" ]]; then
    row3_right+="${_chime_segment}${BULLET}"
  fi
  if [[ -n "$time_segment" ]]; then
    row3_right+="${time_segment}${BULLET}"
  fi
  row3_right+="$cost_segment"
elif [[ -n "$_chime_segment" ]]; then
  row3_right+="$_chime_segment"
fi

_row3_right_len=$(_vis_len "$row3_right")

# Determine which MCP segment variant to use.
# Priority: expanded names if they fit, otherwise short count.
_mcp_to_use=""
if [[ -n "$mcp_segment" ]]; then
  _mcp_to_use="$mcp_segment"

  _row3_fits() {
    local _candidate="$1"
    local _clen=$(_vis_len "$_candidate")
    (( _clen + _row3_right_len + 1 <= ROW_WIDTH ))
  }

  if [[ -n "$mcp_segment_expanded" ]]; then
    _try="\033[0m${mcp_segment_expanded}"
    if _row3_fits "$_try"; then
      _mcp_to_use="$mcp_segment_expanded"
    elif (( ${#mcp_segments_truncated[@]} > 0 )); then
      # Try truncated variants (most names first, fewest last)
      for _trunc in "${mcp_segments_truncated[@]}"; do
        _try="\033[0m${_trunc}"
        if _row3_fits "$_try"; then
          _mcp_to_use="$_trunc"
          break
        fi
      done
    fi
  fi
fi

row3_left="\033[0m"
if [[ -n "$_mcp_to_use" ]]; then
  row3_left+="${_mcp_to_use}"
fi

# ── Row 2: progress bar with Powerline caps ─────────────────────
bar_width=$ROW_WIDTH

# Bar fill colors — 10-tier gradient: grey-green → green → gold → orange
# Each tier: BG (fill background), FG (powerline cap foreground), TEXT (label text)
# Starts near the empty bar color (35;38;45) with a subtle green tint,
# then gradually saturates through green to gold to orange.
#   0–10%  off grey-green    (barely distinguishable from empty bar)
#   11–20% grey-green        (subtle hint of green)
#   21–30% muted green       (green becoming visible)
#   31–40% soft green        (clearly green now)
#   41–50% green             (solid green)
#   51–60% green             (still green, barely warming)
#   61–70% green-gold        (first hint of warmth)
#   71–80% gold              (noticeable transition)
#   81–90% warm gold-orange  (approaching compaction)
#   91–100% orange            (near compaction, not red)
TIER_BG=(
  "\033[48;2;42;48;46m"     # 0–10   off grey-green (close to empty bar 35;38;45)
  "\033[48;2;46;56;48m"     # 11–20  grey-green
  "\033[48;2;50;65;50m"     # 21–30  muted green
  "\033[48;2;56;76;54m"     # 31–40  soft green
  "\033[48;2;64;88;56m"     # 41–50  green
  "\033[48;2;76;100;56m"    # 51–60  green (barely warming)
  "\033[48;2;95;105;55m"    # 61–70  green-gold
  "\033[48;2;120;115;58m"   # 71–80  soft gold
  "\033[48;2;148;125;60m"   # 81–90  muted gold-orange
  "\033[48;2;170;130;62m"   # 91–100 muted orange
)
TIER_FG=(
  "\033[38;2;42;48;46m"
  "\033[38;2;46;56;48m"
  "\033[38;2;50;65;50m"
  "\033[38;2;56;76;54m"
  "\033[38;2;64;88;56m"
  "\033[38;2;76;100;56m"
  "\033[38;2;95;105;55m"
  "\033[38;2;120;115;58m"
  "\033[38;2;148;125;60m"
  "\033[38;2;170;130;62m"
)
# Label + lead icon: dark enough to read on both bar fill and minimal pill
TIER_TEXT=(
  "\033[38;2;72;78;74m"     # 0–10   lighter text for dark bg
  "\033[38;2;74;82;74m"     # 11–20
  "\033[38;2;40;52;38m"     # 21–30
  "\033[38;2;38;55;35m"     # 31–40
  "\033[38;2;40;60;33m"     # 41–50
  "\033[38;2;48;66;31m"     # 51–60
  "\033[38;2;60;68;30m"     # 61–70
  "\033[38;2;76;74;34m"     # 71–80
  "\033[38;2;92;80;36m"     # 81–90
  "\033[38;2;102;78;36m"    # 91–100
)
# Wind icons: darker than fill BG (~30-40 units)
TIER_WIND=(
  "\033[38;2;22;28;26m"     # 0–10
  "\033[38;2;24;34;26m"     # 11–20
  "\033[38;2;28;42;28m"     # 21–30
  "\033[38;2;32;50;28m"     # 31–40
  "\033[38;2;36;58;26m"     # 41–50
  "\033[38;2;44;66;24m"     # 51–60
  "\033[38;2;62;72;20m"     # 61–70
  "\033[38;2;86;82;22m"     # 71–80
  "\033[38;2;112;92;24m"    # 81–90
  "\033[38;2;134;96;24m"    # 91–100
)
EMPTY_BG="\033[48;2;35;38;45m"
EMPTY_FG="\033[38;2;35;38;45m"
LIGHT_FG="\033[38;2;85;90;100m"    # dim text on empty bg

# ── Color mode overrides for progress bar gradient ───────────────
if [[ "$_SL_COLOR_MODE" == "mono" ]]; then
  # Monochrome gradient: 10 gray tiers from dark to bright
  TIER_BG=(
    "\033[48;2;60;60;60m"     # 0–10
    "\033[48;2;72;72;72m"     # 11–20
    "\033[48;2;84;84;84m"     # 21–30
    "\033[48;2;96;96;96m"     # 31–40
    "\033[48;2;108;108;108m"  # 41–50
    "\033[48;2;120;120;120m"  # 51–60
    "\033[48;2;135;135;135m"  # 61–70
    "\033[48;2;150;150;150m"  # 71–80
    "\033[48;2;170;170;170m"  # 81–90
    "\033[48;2;190;190;190m"  # 91–100
  )
  TIER_FG=(
    "\033[38;2;60;60;60m"
    "\033[38;2;72;72;72m"
    "\033[38;2;84;84;84m"
    "\033[38;2;96;96;96m"
    "\033[38;2;108;108;108m"
    "\033[38;2;120;120;120m"
    "\033[38;2;135;135;135m"
    "\033[38;2;150;150;150m"
    "\033[38;2;170;170;170m"
    "\033[38;2;190;190;190m"
  )
  TIER_TEXT=(
    "\033[38;2;110;110;110m"
    "\033[38;2;118;118;118m"
    "\033[38;2;126;126;126m"
    "\033[38;2;134;134;134m"
    "\033[38;2;65;65;65m"
    "\033[38;2;72;72;72m"
    "\033[38;2;80;80;80m"
    "\033[38;2;88;88;88m"
    "\033[38;2;100;100;100m"
    "\033[38;2;110;110;110m"
  )
  TIER_WIND=(
    "\033[38;2;30;30;30m"
    "\033[38;2;38;38;38m"
    "\033[38;2;48;48;48m"
    "\033[38;2;58;58;58m"
    "\033[38;2;70;70;70m"
    "\033[38;2;82;82;82m"
    "\033[38;2;97;97;97m"
    "\033[38;2;112;112;112m"
    "\033[38;2;132;132;132m"
    "\033[38;2;152;152;152m"
  )
  EMPTY_BG="\033[48;2;38;38;38m"
  EMPTY_FG="\033[38;2;38;38;38m"
  LIGHT_FG="\033[38;2;90;90;90m"
elif [[ "$_SL_COLOR_MODE" == "muted" ]]; then
  # Muted gradient: same green → yellow → orange hues, reduced saturation (~40%)
  TIER_BG=(
    "\033[48;2;68;82;66m"     # 0–10   muted soft green
    "\033[48;2;70;85;68m"     # 11–20  muted green
    "\033[48;2;73;88;69m"     # 21–30  muted green
    "\033[48;2;76;90;68m"     # 31–40  muted green
    "\033[48;2;80;93;67m"     # 41–50  muted green
    "\033[48;2;85;96;65m"     # 51–60  muted green (barely warming)
    "\033[48;2;100;103;64m"   # 61–70  muted green-gold
    "\033[48;2;130;122;68m"   # 71–80  muted gold
    "\033[48;2;158;132;70m"   # 81–90  muted gold-orange
    "\033[48;2;178;132;68m"   # 91–100 muted orange
  )
  TIER_FG=(
    "\033[38;2;68;82;66m"
    "\033[38;2;70;85;68m"
    "\033[38;2;73;88;69m"
    "\033[38;2;76;90;68m"
    "\033[38;2;80;93;67m"
    "\033[38;2;85;96;65m"
    "\033[38;2;100;103;64m"
    "\033[38;2;130;122;68m"
    "\033[38;2;158;132;70m"
    "\033[38;2;178;132;68m"
  )
  TIER_TEXT=(
    "\033[38;2;40;55;38m"
    "\033[38;2;42;58;40m"
    "\033[38;2;44;60;41m"
    "\033[38;2;47;62;40m"
    "\033[38;2;50;64;39m"
    "\033[38;2;54;66;37m"
    "\033[38;2;68;70;36m"
    "\033[38;2;88;82;38m"
    "\033[38;2;108;90;42m"
    "\033[38;2;115;88;42m"
  )
  TIER_WIND=(
    "\033[38;2;36;50;34m"
    "\033[38;2;38;52;36m"
    "\033[38;2;40;55;37m"
    "\033[38;2;43;57;35m"
    "\033[38;2;47;60;34m"
    "\033[38;2;52;63;32m"
    "\033[38;2;67;70;30m"
    "\033[38;2;97;88;35m"
    "\033[38;2;125;98;37m"
    "\033[38;2;145;98;35m"
  )
  EMPTY_BG="\033[48;2;38;40;45m"
  EMPTY_FG="\033[38;2;38;40;45m"
  LIGHT_FG="\033[38;2;88;92;102m"
fi

# ── Smooth gradient control points per color mode ────────────────
# 10 control points (one per tier), linearly interpolated per-cell in _render_bar.
# Default: grey-green → green → gold → orange → red at the very end
GRAD_BG_R=(48 50 55 65  88  115 140 160 180 200)
GRAD_BG_G=(62 74 88 105 112 116 122 125 120 55)
GRAD_BG_B=(48 48 50 52  54  55  58  60  58  50)
GRAD_TX_R=(72 74 40 40 52  65  80  94  104 118)
GRAD_TX_G=(78 82 52 58 65  70  76  78  74  38)
GRAD_TX_B=(74 74 38 33 30  30  33  35  34  30)
GRAD_WN_R=(38 40 44 53 72  95  120 142 162 184)
GRAD_WN_G=(48 58 70 84 92  98  107 110 104 46)
GRAD_WN_B=(40 40 42 42 42  42  44  46  44  38)

if [[ "$_SL_COLOR_MODE" == "mono" ]]; then
  # Monochrome: dark grey → bright grey, subtle brightness ramp
  GRAD_BG_R=(45 55 65 76 88  100 115 132 155 185)
  GRAD_BG_G=(45 55 65 76 88  100 115 132 155 185)
  GRAD_BG_B=(45 55 65 76 88  100 115 132 155 185)
  GRAD_TX_R=(85 90 95 105 50  55  62  72  90  110)
  GRAD_TX_G=(85 90 95 105 50  55  62  72  90  110)
  GRAD_TX_B=(85 90 95 105 50  55  62  72  90  110)
  GRAD_WN_R=(35 43 52 62 74  86  100 118 140 170)
  GRAD_WN_G=(35 43 52 62 74  86  100 118 140 170)
  GRAD_WN_B=(35 43 52 62 74  86  100 118 140 170)
elif [[ "$_SL_COLOR_MODE" == "muted" ]]; then
  # Muted: same hue progression as default but desaturated (~40% saturation)
  GRAD_BG_R=(48 52 55 62 76  92  110 132 150 168)
  GRAD_BG_G=(52 58 65 74 86  96  104 108 104 68)
  GRAD_BG_B=(50 52 54 56 58  58  60  62  60  56)
  GRAD_TX_R=(74 76 44 45 54  66  78  90  100 110)
  GRAD_TX_G=(78 80 54 58 64  68  72  74  70  46)
  GRAD_TX_B=(74 74 42 38 34  34  36  38  37  34)
  GRAD_WN_R=(40 44 46 53 65  80  96  118 136 154)
  GRAD_WN_G=(44 50 57 65 75  84  91  95  90  58)
  GRAD_WN_B=(42 42 44 46 46  46  46  48  46  42)
fi

# Powerline semicircle glyphs
PL_RIGHT=$(printf '\xee\x82\xb4')  # U+E0B4 right semicircle (closing cap)
PL_LEFT=$(printf '\xee\x82\xb6')   # U+E0B6 left semicircle (opening cap)

# ── Mini context pill for minimal mode ─────────────────────────────
# A compact Powerline-capped badge showing just the percentage, colored
# with the same tier gradient the full progress bar would use.
if [[ "$_SL_MODE" == "minimal" ]]; then
  _pill_pct=$(( pct * 100 / 80 ))
  (( _pill_pct > 100 )) && _pill_pct=100
  _pill_tier=$(( _pill_pct / 10 ))
  (( _pill_tier > 9 )) && _pill_tier=9
  (( _pill_tier < 0 )) && _pill_tier=0
  _PILL_BG="${TIER_BG[$_pill_tier]}"
  _PILL_FG="${TIER_FG[$_pill_tier]}"
  _PILL_TEXT_FG="\033[38;2;18;20;25m"
  pill_label="${pct}%"
  pill_segment="${_PILL_FG}${PL_LEFT}${_PILL_BG}${_PILL_TEXT_FG} ${pill_label} ${RESET}${_PILL_FG}${PL_RIGHT}${RESET}"
  # Append bullet + pill to row 1 left
  row1_left+="${BULLET}${pill_segment}"
  # Move dirty segment from right to left with bullet (if present)
  if [[ -n "$dirty_segment" ]]; then
    row1_left+="${BULLET}${dirty_segment}"
  fi
  _justified_row "$ROW_WIDTH" "$row1_left" "\033[0m"
fi

# ── Session hash for texture selection ─────────────────
# Use flair_seed (re-randomized on context clear) for stable per-session picks.
# Falls back to session_id hash for backwards compatibility.
if [[ -n "$_flair_seed" ]]; then
  _icon_hash=$_flair_seed
elif [[ -n "$session_id" ]]; then
  _icon_hash=$(cksum <<< "$session_id" | cut -d' ' -f1)
else
  _icon_hash=$PPID
fi

# ── _render_bar: render a progress bar given pct and label ──────
# Usage: _render_bar <pct> <label> [suffix_colored] [texture] [compact_mark_pct] [right_label]
# Textures: "wind" (default), or named texture from BAR_TEXTURES
# compact_mark_pct: if set (0–100), draws a vertical divider at that % and
#   darkens the empty region beyond it.
# right_label: if set, displayed right-aligned in the empty area with 2-char padding.
_render_bar() {
  local _pct=$1
  local _label="$2"
  local _suffix="${3:-}"
  local _texture="${4:-wind}"
  local _compact_mark_pct="${5:-}"
  local _right_label="${6:-}"

  # NerdFlair logo: shown right-aligned in empty area of bar
  local _logo_icons=()
  local _logo_start=0
  # Logo color: consistent mauve matching MCP list
  local _NF_BRAND_COLORS=(
    "\033[38;2;145;130;155m" "\033[38;2;145;130;155m"
    "\033[38;2;145;130;155m" "\033[38;2;145;130;155m"
    "\033[38;2;145;130;155m" "\033[38;2;145;130;155m"
    "\033[38;2;145;130;155m" "\033[38;2;145;130;155m"
    "\033[38;2;145;130;155m" "\033[38;2;145;130;155m"
    "\033[38;2;145;130;155m" "\033[38;2;145;130;155m"
    "\033[38;2;145;130;155m" "\033[38;2;145;130;155m"
    "\033[38;2;145;130;155m" "\033[38;2;145;130;155m"
    "\033[38;2;145;130;155m"
  )
  local _NF_BRAND_COLOR="${_NF_BRAND_COLORS[0]}"
  _logo_icons=(
    "$(printf '\UE838')" " "
    "$(printf '\U000F0BF7')" " "
    "$(printf '\U000F0C1E')" " "
    "$(printf '\U000F0BF4')" " "
    "$(printf '\UF335')" " "
    "$(printf '\U000F0C0C')" " "
    "$(printf '\U000F0BEB')" " "
    "$(printf '\U000F0C03')" " "
    "$(printf '\U000F0C1E')"
  )
  local _logo_end=0  # will be computed after _bar_area is known

  # Multi-segment fill: each cell gets its tier color based on what percentage
  # of the bar that position represents. Tier boundaries get curved cap transitions.
  # When a compact mark is set, scale so the mark pct reaches tier 9 (full orange).
  # We compute per-cell colors in the render loop below; here we just set up
  # the top-tier values for the outer cap and label colors.
  local _tier_pct=$_pct
  if [[ -n "$_compact_mark_pct" ]] && (( _compact_mark_pct > 0 && _compact_mark_pct < 100 )); then
    _tier_pct=$(( _pct * 100 / _compact_mark_pct ))
    (( _tier_pct > 100 )) && _tier_pct=100
  fi
  local _top_tier_idx=$(( _tier_pct / 10 ))
  (( _top_tier_idx > 9 )) && _top_tier_idx=9
  (( _top_tier_idx < 0 )) && _top_tier_idx=0
  # These are used for outer caps and label text (use the highest tier reached)
  local _FILL_BG="${TIER_BG[$_top_tier_idx]}"
  local _FILL_FG="${TIER_FG[$_top_tier_idx]}"
  local _FILL_TEXT="${TIER_TEXT[$_top_tier_idx]}"
  local _WIND_FG="${TIER_WIND[$_top_tier_idx]}"  # wind icons: darker than fill

  # Bar area: fixed width, clamped to MAX_BAR
  local _bar_area=$(( bar_width - 2 ))
  (( _bar_area > MAX_BAR )) && _bar_area=$MAX_BAR
  (( _bar_area < 20 )) && _bar_area=20

  # Position logo centered in the bar area (only when bar is empty)
  # Once context is used, the label comes back and the logo goes away forever.
  if (( ${#_logo_icons[@]} > 0 && _pct == 0 )); then
    _logo_start=$(( (_bar_area - ${#_logo_icons[@]}) / 2 ))
    (( _logo_start < 0 )) && _logo_start=0
    _logo_end=$(( _logo_start + ${#_logo_icons[@]} ))
  elif (( _pct > 0 )); then
    _logo_icons=()
  fi

  # ── Logo background gradient: light → dark → light across the bar ──
  # Pre-compute per-cell BG when logo is showing for a smooth ambient glow.
  local _logo_bg_cache=()
  local _logo_fg_cache=()
  if (( ${#_logo_icons[@]} > 0 )); then
    # Endpoints: dark center (near terminal black), light edges (visible glow)
    local _lg_dark_r=8 _lg_dark_g=8 _lg_dark_b=12
    local _lg_peak_r _lg_peak_g _lg_peak_b
    case "$_SL_COLOR_MODE" in
      mono)  _lg_peak_r=38; _lg_peak_g=38; _lg_peak_b=38 ;;
      muted) _lg_peak_r=38; _lg_peak_g=40; _lg_peak_b=45 ;;
      *)     _lg_peak_r=35; _lg_peak_g=38; _lg_peak_b=45 ;;
    esac
    # Dark zone = center 35% of bar; gradient wings = outer 32.5% each side
    local _dark_start=$(( _bar_area * 325 / 1000 ))
    local _dark_end=$(( _bar_area * 675 / 1000 ))
    for (( _gi=0; _gi<_bar_area; _gi++ )); do
      # Cells in center dark zone → t=0 (darkest). Wings interpolate
      # from 0 at dark zone edge to 100 at bar edge.
      local _t=0
      if (( _gi < _dark_start )); then
        # Left wing: 100 at bar edge (gi=0), 0 at dark zone start
        _t=$(( 100 - _gi * 100 / _dark_start ))
      elif (( _gi >= _dark_end )); then
        # Right wing: 0 at dark zone end, 100 at bar edge
        local _wing_len=$(( _bar_area - _dark_end ))
        if (( _wing_len > 0 )); then
          _t=$(( (_gi - _dark_end) * 100 / _wing_len ))
        fi
      fi
      local _r=$(( _lg_dark_r + (_lg_peak_r - _lg_dark_r) * _t / 100 ))
      local _g=$(( _lg_dark_g + (_lg_peak_g - _lg_dark_g) * _t / 100 ))
      local _b=$(( _lg_dark_b + (_lg_peak_b - _lg_dark_b) * _t / 100 ))
      _logo_bg_cache[$_gi]="\033[48;2;${_r};${_g};${_b}m"
      _logo_fg_cache[$_gi]="\033[38;2;${_r};${_g};${_b}m"
    done
  fi

  # Compact mark: visual position of the compaction divider (-1 = none)
  local _compact_mark_pos=-1
  # Darker empty BG for the compaction zone (beyond the mark)
  local _COMPACT_EMPTY_BG="\033[48;2;18;20;25m"
  local _COMPACT_EMPTY_FG="\033[38;2;18;20;25m"
  if [[ -n "$_compact_mark_pct" ]] && (( _compact_mark_pct > 0 && _compact_mark_pct < 100 )); then
    _compact_mark_pos=$(( _bar_area * _compact_mark_pct / 100 ))
  fi

  # When partially filled, one cell is consumed by the inner transition cap
  local _has_inner_cap=0
  if (( _pct > 0 && _pct < 100 )); then
    _has_inner_cap=1
  fi
  local _body_area=$(( _bar_area - _has_inner_cap ))

  local _filled=$(( _body_area * _pct / 100 ))
  (( _filled > _body_area )) && _filled=$_body_area

  # Padded label centered in the full bar_area (visual width)
  # When logo is showing (pct==0, flair on), suppress the label entirely.
  local _label_padded=" ${_label} "
  local _label_len=${#_label_padded}
  local _label_start=$(( (_bar_area - _label_len) / 2 ))
  (( _label_start < 0 )) && _label_start=0
  local _label_end=$(( _label_start + _label_len ))
  if (( ${#_logo_icons[@]} > 0 )); then
    _label_start=-1
    _label_end=-1
  fi

  # Right-aligned label in empty area (2-char padding from right edge)
  local _rlabel_start=-1
  local _rlabel_end=-1
  local _rlabel_padded=""
  if [[ -n "$_right_label" ]]; then
    _rlabel_padded="${_right_label}"
    local _rlabel_len=${#_rlabel_padded}
    _rlabel_start=$(( _bar_area - _rlabel_len ))
    (( _rlabel_start < 0 )) && _rlabel_start=0
    _rlabel_end=$(( _rlabel_start + _rlabel_len ))
  fi

  # Outer cap colors — left cap uses first filled cell, right cap uses last
  local _left_cap_fg _right_cap_fg
  if (( _pct > 0 )); then
    _left_cap_fg="${TIER_FG[0]}"  # will be overridden after cache is built
  elif (( ${#_logo_icons[@]} > 0 && ${#_logo_bg_cache[@]} > 0 )); then
    _left_cap_fg="${_logo_fg_cache[0]}"
  elif (( ${#_logo_icons[@]} > 0 )); then
    _left_cap_fg="$_COMPACT_EMPTY_FG"
  else
    _left_cap_fg="$EMPTY_FG"
  fi

  if (( _pct >= 100 )); then
    _right_cap_fg="$_FILL_FG"
  elif (( ${#_logo_icons[@]} > 0 && ${#_logo_bg_cache[@]} > 0 )); then
    _right_cap_fg="${_logo_fg_cache[$((_bar_area - 1))]}"
  elif (( ${#_logo_icons[@]} > 0 )); then
    _right_cap_fg="$_COMPACT_EMPTY_FG"
  elif (( _compact_mark_pos >= 0 )); then
    _right_cap_fg="$_COMPACT_EMPTY_FG"
  else
    _right_cap_fg="$EMPTY_FG"
  fi

  # Build bar body with solid fill color
  local _bar=""
  local _vis=0  # visual position (0..bar_area-1)
  local _body_i=0  # body cell index (0..body_area-1)
  local _fill_icon_a _fill_icon_b _fill_icon_c _fill_cycle=2
  # Select texture icons
  case "$_texture" in
    wind)
      _fill_icon_a=$(printf '\xee\xbc\x96')  # U+EF16
      _fill_icon_b=$(printf '\xee\x8d\x8b')  # U+E34B
      ;;
    thick_dots)
      _fill_icon_a=$(printf '\xc2\xb7')      # U+00B7 middle dot (bullet)
      _fill_icon_b=$(printf '\xef\x91\x84')  # U+F444
      ;;
    sin_wave)
      _fill_icon_a=$(printf '\xf3\xb1\x91\xb9')  # U+F1479
      _fill_icon_b=$(printf '\xf3\xb1\x91\xb9')  # U+F1479
      ;;
    square_wave)
      _fill_icon_a=$(printf '\xee\xbe\x9d')  # U+EF9D
      _fill_icon_b=$(printf '\xee\xbe\x9d')  # U+EF9D
      ;;
    beads)
      _fill_icon_a=$(printf '\xef\x85\xb2')  # U+F172
      _fill_icon_b=$(printf '\xef\x92\x8b')  # U+F48B
      ;;
    arrows)
      _fill_icon_a=$(printf '\xef\x91\x8a')  # U+F44A (small arrow)
      _fill_icon_b=$(printf '\xee\xad\xb0')  # U+EB70
      ;;
    sparkle)
      _fill_icon_a=$(printf '\xf3\xb1\x8d\xbf')  # U+F137F
      _fill_icon_b=$(printf '\xc2\xb7')            # U+00B7 middle dot (bullet)
      ;;
    dot_chain)
      _fill_icon_a=$(printf '\xef\x85\x81')  # U+F141 ellipsis (nf-fa-ellipsis_h)
      _fill_icon_b=$(printf '\xef\x85\x81')  # U+F141 ellipsis (repeated)
      ;;
    donuts)
      _fill_icon_a=$(printf '\xee\x89\xb3')  # U+E273
      _fill_icon_b=$(printf '\xc2\xb7')      # U+00B7 middle dot (bullet)
      ;;
    soundwaves)
      _fill_icon_a=$(printf '\xf3\xb1\x91\xbd')  # U+F147D
      _fill_icon_b=$(printf '\xf3\xb1\x91\xbd')  # U+F147D (repeated)
      ;;
    pulse)
      _fill_icon_a=$(printf '\xee\x88\xb4')  # U+E234
      _fill_icon_b=$(printf '\xee\x88\xb4')  # U+E234 (repeated)
      ;;
    infinity_loop)
      _fill_icon_a=$(printf '\xef\x93\xa6')  # U+F4E6
      _fill_icon_b=$(printf '\xc2\xb7')    # U+00B7 middle dot (bullet)
      ;;
    *)
      _fill_icon_a=$(printf '\xee\xbc\x96')  # U+EF16 (fallback to wind)
      _fill_icon_b=$(printf '\xee\x8d\x8b')  # U+E34B
      ;;
  esac
  # ── Smooth per-cell gradient: interpolate RGB between control points ──
  # Uses GRAD_BG/TX/WN arrays set per color mode above.

  # Pre-compute ANSI escape strings for each filled cell position.
  # Maps cell position → fractional tier (0–900 scale, i.e. 100ths of a tier).
  local _cell_bg_cache=()
  local _cell_text_cache=()
  local _cell_wind_cache=()
  local _cell_fg_cache=()
  for (( _ci=0; _ci<_filled; _ci++ )); do
    # Cell's percentage of the total bar
    local _cpct=$(( (_ci + 1) * 100 / _body_area ))
    if [[ -n "$_compact_mark_pct" ]] && (( _compact_mark_pct > 0 && _compact_mark_pct < 100 )); then
      _cpct=$(( _cpct * 100 / _compact_mark_pct ))
      (( _cpct > 100 )) && _cpct=100
    fi
    # Map to 0–900 scale (fractional tier × 100)
    local _ft=$(( _cpct * 9 ))
    (( _ft > 900 )) && _ft=900
    # Integer tier and fractional part (0–99)
    local _lo=$(( _ft / 100 ))
    (( _lo > 8 )) && _lo=8
    local _hi=$(( _lo + 1 ))
    local _frac=$(( _ft - _lo * 100 ))
    # Interpolate BG
    local _r=$(( GRAD_BG_R[_lo] + (GRAD_BG_R[_hi] - GRAD_BG_R[_lo]) * _frac / 100 ))
    local _g=$(( GRAD_BG_G[_lo] + (GRAD_BG_G[_hi] - GRAD_BG_G[_lo]) * _frac / 100 ))
    local _b=$(( GRAD_BG_B[_lo] + (GRAD_BG_B[_hi] - GRAD_BG_B[_lo]) * _frac / 100 ))
    _cell_bg_cache[$_ci]="\033[48;2;${_r};${_g};${_b}m"
    _cell_fg_cache[$_ci]="\033[38;2;${_r};${_g};${_b}m"
    # Interpolate text
    _r=$(( GRAD_TX_R[_lo] + (GRAD_TX_R[_hi] - GRAD_TX_R[_lo]) * _frac / 100 ))
    _g=$(( GRAD_TX_G[_lo] + (GRAD_TX_G[_hi] - GRAD_TX_G[_lo]) * _frac / 100 ))
    _b=$(( GRAD_TX_B[_lo] + (GRAD_TX_B[_hi] - GRAD_TX_B[_lo]) * _frac / 100 ))
    _cell_text_cache[$_ci]="\033[38;2;${_r};${_g};${_b}m"
    # Interpolate wind
    _r=$(( GRAD_WN_R[_lo] + (GRAD_WN_R[_hi] - GRAD_WN_R[_lo]) * _frac / 100 ))
    _g=$(( GRAD_WN_G[_lo] + (GRAD_WN_G[_hi] - GRAD_WN_G[_lo]) * _frac / 100 ))
    _b=$(( GRAD_WN_B[_lo] + (GRAD_WN_B[_hi] - GRAD_WN_B[_lo]) * _frac / 100 ))
    _cell_wind_cache[$_ci]="\033[38;2;${_r};${_g};${_b}m"
  done

  # Override outer caps with smooth gradient endpoints
  if (( _filled > 0 )); then
    _left_cap_fg="${_cell_fg_cache[0]}"
    if (( _pct >= 100 )); then
      _right_cap_fg="${_cell_fg_cache[$((_filled - 1))]}"
    fi
  fi

  while (( _vis < _bar_area )); do
    # Insert inner transition cap at the fill boundary (fill → empty)
    if (( _has_inner_cap && _body_i == _filled )); then
      # Pick correct empty BG based on whether we're past the compact mark
      # or logo is showing (uses darker BG everywhere)
      local _cap_empty_bg="$EMPTY_BG"
      if (( ${#_logo_icons[@]} > 0 )); then
        _cap_empty_bg="$_COMPACT_EMPTY_BG"
      elif (( _compact_mark_pos >= 0 && _vis >= _compact_mark_pos )); then
        _cap_empty_bg="$_COMPACT_EMPTY_BG"
      fi
      # Use the last filled cell's FG for the transition cap
      local _last_fill_fg="$_FILL_FG"
      if (( _filled > 0 )); then
        _last_fill_fg="${_cell_fg_cache[$((_filled - 1))]}"
      fi
      if (( _vis >= _label_start && _vis < _label_end )); then
        local _ci=$(( _vis - _label_start ))
        local _ch="${_label_padded:$_ci:1}"
        _bar+="${_cap_empty_bg}${LIGHT_FG}${_ch}"
      else
        _bar+="${_cap_empty_bg}${_last_fill_fg}${PL_RIGHT}"
      fi
      _has_inner_cap=0
      (( _vis++ ))
      continue
    fi

    # Determine the empty BG for this position (darker at and beyond compact mark,
    # or gradient when logo is showing)
    local _cur_empty_bg="$EMPTY_BG"
    local _cur_light_fg="$LIGHT_FG"
    if (( ${#_logo_icons[@]} > 0 && ${#_logo_bg_cache[@]} > 0 )); then
      _cur_empty_bg="${_logo_bg_cache[$_vis]}"
    elif (( ${#_logo_icons[@]} > 0 )); then
      _cur_empty_bg="$_COMPACT_EMPTY_BG"
    elif (( _compact_mark_pos >= 0 && _vis >= _compact_mark_pos )); then
      _cur_empty_bg="$_COMPACT_EMPTY_BG"
    fi

    # Render compact mark divider (│) at the mark position in the empty zone
    # Skip when logo is showing — nothing to divide at 0%
    if (( ${#_logo_icons[@]} == 0 && _compact_mark_pos >= 0 && _vis == _compact_mark_pos && _body_i >= _filled )); then
      if (( _vis >= _label_start && _vis < _label_end )); then
        local _ci=$(( _vis - _label_start ))
        local _ch="${_label_padded:$_ci:1}"
        _bar+="${_cur_empty_bg}${_cur_light_fg}${_ch}"
      else
        _bar+="${_COMPACT_EMPTY_BG}${EMPTY_FG}${PL_RIGHT}"
      fi
      (( _body_i++ ))
      (( _vis++ ))
      continue
    fi

    # Per-cell smooth gradient colors from pre-computed cache
    local _cell_bg="$_FILL_BG"
    local _cell_fg="$_FILL_FG"
    local _cell_text="$_FILL_TEXT"
    local _cell_wind="$_WIND_FG"
    if (( _body_i < _filled )); then
      _cell_bg="${_cell_bg_cache[$_body_i]}"
      _cell_fg="${_cell_fg_cache[$_body_i]}"
      _cell_text="${_cell_text_cache[$_body_i]}"
      _cell_wind="${_cell_wind_cache[$_body_i]}"
    fi

    if (( _vis >= _label_start && _vis < _label_end )); then
      local _ci=$(( _vis - _label_start ))
      local _ch="${_label_padded:$_ci:1}"
      if (( _body_i < _filled )); then
        _bar+="${_cell_bg}${_cell_text}${_ch}"
      else
        _bar+="${_cur_empty_bg}${_cur_light_fg}${_ch}"
      fi
    elif (( _rlabel_start >= 0 && _vis >= _rlabel_start && _vis < _rlabel_end && _body_i >= _filled )); then
      # Right-aligned label in empty area
      local _ri=$(( _vis - _rlabel_start ))
      local _rch="${_rlabel_padded:$_ri:1}"
      _bar+="${_cur_empty_bg}${_cur_light_fg}${_rch}"
    else
      if (( _body_i < _filled )); then
        # Guard: use middle dot adjacent to label for textures with wide glyphs
        if [[ "$_texture" == "sparkle" || "$_texture" == "thick_dots" || "$_texture" == "infinity_loop" ]] && (( _label_start >= 0 && ( _vis == _label_start - 1 || _vis == _label_end ) )); then
          _bar+="${_cell_bg}${_cell_wind}·"
        else
          local _ci_mod=$(( _body_i % _fill_cycle ))
          if (( _ci_mod == 0 )); then
            _bar+="${_cell_bg}${_cell_wind}${_fill_icon_a}"
          elif (( _ci_mod == 1 )); then
            _bar+="${_cell_bg}${_cell_wind}${_fill_icon_b}"
          else
            _bar+="${_cell_bg}${_cell_wind}${_fill_icon_c}"
          fi
        fi
      else
        if (( ${#_logo_icons[@]} > 0 && _vis >= _logo_start && _vis < _logo_end )); then
          local _li=$(( _vis - _logo_start ))
          local _lc="${_NF_BRAND_COLORS[$_li]:-${_NF_BRAND_COLOR}}"
          _bar+="${_cur_empty_bg}${_lc}${_logo_icons[$_li]}"
        else
          _bar+="${_cur_empty_bg} "
        fi
      fi
    fi
    (( _body_i++ ))
    (( _vis++ ))
  done

  # Assemble and print the bar
  printf '\n%b%b%b%b%b' \
    "${RESET}${_left_cap_fg}${PL_LEFT}" \
    "${_bar}" \
    "${RESET}${_right_cap_fg}${PL_RIGHT}" \
    "${_suffix}" \
    "${RESET}"
}

# Select texture per session (stable like the icon)
BAR_TEXTURES=(wind thick_dots sin_wave square_wave beads arrows dot_chain soundwaves pulse sparkle infinity_loop)
BAR_TEXTURE="${BAR_TEXTURES[$((_icon_hash % ${#BAR_TEXTURES[@]}))]}"

_bar_label="$ctx_label"

# Render the real progress bar (skip in minimal — context pill is on row 1)
if [[ "$_SL_MODE" != "minimal" ]]; then
  _compact_mark=80
  # In compact mode, show cost right-aligned inside the bar's empty area
  _bell_icon=""
  if awk "BEGIN {exit (${_SL_CHIME_VOLUME:-1} <= 0) ? 0 : 1}"; then
    _bell_icon=$(printf '\xf3\xb0\xe5\xa9')  # U+F0969 speaker-off
  fi

  _bar_right_label=""
  # Calculate available space in the dark zone for right-aligned content
  # Dark zone = bar_area * (100 - compact_mark%) / 100, minus 1 for the right cap
  _bar_area_est=$(( bar_width - 2 ))
  (( _bar_area_est > 78 )) && _bar_area_est=78
  (( _bar_area_est < 20 )) && _bar_area_est=20
  _dark_zone=$(( _bar_area_est - _bar_area_est * 80 / 100 ))

  # Build compact mode right label: time  cost + bell, dropping time then cost if too wide
  _compact_time=""
  if [[ -n "$api_fmt" ]]; then
    _compact_time="${api_fmt} "
  fi
  _compact_cost=""
  if [[ "$formatted_cost" != "0.00" ]]; then
    _compact_cost="\$${formatted_cost} "
  fi

  if [[ "$_SL_MODE" == "compact" ]]; then
    # Try full: time + cost + bell
    _try="${_compact_time}${_compact_cost}${_bell_icon}"
    if (( ${#_try} > _dark_zone )); then
      # Drop time, keep cost + bell
      _try="${_compact_cost}${_bell_icon}"
    fi
    if (( ${#_try} > _dark_zone )); then
      # Drop cost too, keep bell only
      _try="${_bell_icon}"
    fi
    _bar_right_label="$_try"
  fi
  _render_bar "$pct" "$_bar_label" "" "$BAR_TEXTURE" "$_compact_mark" "$_bar_right_label"
fi

# Row 3: mcp | time + cost (full mode only)
if [[ "$_SL_MODE" == "full" ]]; then
  printf '\n'
  _justified_row "$ROW_WIDTH" "$row3_left" "$row3_right"
fi

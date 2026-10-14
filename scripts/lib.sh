#!/bin/bash
# lib.sh — Shared constants, helpers, and state management for nerdflair.
# Sourced by nerdflair.sh, statusline.sh, and bell.sh.

# ── Paths ────────────────────────────────────────────────────────
NF_STATE_FILE="$HOME/.claude/nerdflair/state.json"
NF_SESSION_DIR="$HOME/.claude/nerdflair/sessions"
NF_SETTINGS_FILE="$HOME/.claude/settings.json"

# ── Defaults ─────────────────────────────────────────────────────
NF_DEFAULT_MODE="full"
NF_DEFAULT_WIDTH="auto"
NF_DEFAULT_COLOR="vibrant"
NF_DEFAULT_TERMINAL_BELL="on"
NF_DEFAULT_CHIME_SOUND="Glass"
NF_DEFAULT_CHIME_STYLE="random"
NF_DEFAULT_CHIME_EVENTS="Notification,PermissionRequest,PreCompact,SessionEnd,SessionStart,Stop"
NF_DEFAULT_CHIME_VOLUME="1"

NF_ALL_CHIME_EVENTS="Notification PermissionRequest PreCompact SessionEnd SessionStart Stop UserPromptSubmit"
NF_VALID_MODES="full compact minimal"

# ── ANSI colors (shared across scripts) ──────────────────────────
NF_CYAN='\033[38;2;86;182;194m'
NF_GREEN='\033[38;2;152;195;121m'
NF_DIM='\033[38;2;120;135;155m'
NF_RED='\033[38;2;224;108;117m'
NF_RST='\033[0m'

# ── Durable error log ────────────────────────────────────────────
# Owner's rule: a fallback is fine, but every absorbed failure leaves one log
# line, with the reason. Twin of rust/src/errlog.rs: same file, same line
# format (`ISO-time pid key: reason`), same stamp names, same one-per-key-
# per-hour rate limit. NEVER prints to stdout (that is the status line) and
# never fails the caller: swallowing its OWN failure is the one correct
# `2>/dev/null` in here.
#   _nf_err key reason   log once per hour per key
#   _nf_ok key           log "recovered: key" once if key had logged
#   _nf_recent/_nf_touch/_nf_clear  retry back-off markers (no logging)
# NERDFLAIR_ERR_STAMP_DIR moves the stamps (tests); default ~/.claude/.nerdflair-stamps (0700).
NF_ERR_LOG="${HOME:-}/.claude/nerdflair-errors.log"
_NF_UID="${UID:-$(id -u)}"
_NF_MEM=" "                      # keys already logged by THIS process (an unwritable stamp dir must not repeat a line)
# Stamps live in a private 0700 directory under ~/.claude, NOT /tmp: /tmp is
# shared and the names are predictable, so another user could plant a file or
# symlink to silence a key or make us truncate something of theirs. Twin of
# errlog::stamp_dir. _NF_SDIR is empty when no safe directory can be had (then
# rate limiting is in memory only). No fork on the healthy path: -O and -L are
# shell tests; mkdir runs only when the directory is missing.
_nf_stamp_dir() {
  [[ -n "${_NF_SDIR_DONE:-}" ]] && return 0
  _NF_SDIR_DONE=1; _NF_SDIR=""
  local _d _h="${HOME:-}"
  if [[ -n "${NERDFLAIR_ERR_STAMP_DIR:-}" ]]; then _NF_SDIR="$NERDFLAIR_ERR_STAMP_DIR"; return 0; fi
  _d="${_h%/}/.claude/.nerdflair-stamps"        # HOME unset or empty means /, as in Rust
  [[ -d "$_d" ]] || mkdir -p -m 700 "$_d" 2>/dev/null
  if [[ -d "$_d" && ! -L "$_d" && -O "$_d" ]]; then
    # Ours but possibly lax (an old umask): tighten rather than reject, like errlog::stamp_dir.
    [[ -w "$_d" ]] && chmod 700 "$_d" 2>/dev/null
    _NF_SDIR="$_d"
  fi
  return 0
}
# Sets _NF_STAMP (empty when there is no safe directory). No subshell.
_nf_stamp() {
  local _s="${1//[^a-zA-Z0-9]/_}"
  _nf_stamp_dir
  _NF_STAMP=""
  [[ -n "$_NF_SDIR" ]] && _NF_STAMP="${_NF_SDIR}/nerdflair-err-${_NF_UID}-${_s:0:100}"
  return 0
}
# Age in seconds of a stamp. Missing or future-dated = very old, like util::file_age.
_nf_stamp_age() {
  local _m _a
  [[ -e "$1" || -L "$1" ]] || { printf '%s' 4611686018427387903; return; }
  _m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
  _a=$(( ${EPOCHSECONDS:-$(date +%s)} - _m ))
  (( _a < 0 )) && _a=4611686018427387903
  printf '%s' "$_a"
}
# Create or touch a stamp WITHOUT following a symlink: touch -h acts on a link
# itself, noclobber refuses to write through one that appeared meanwhile.
_nf_stamp_write() {
  if [[ -e "$1" || -L "$1" ]]; then touch -h "$1" 2>/dev/null
  else ( set -o noclobber; : > "$1" ) 2>/dev/null; fi
}
# Appends one line. Returns 0 when it was written, 1 when it fell back to stderr.
_nf_log_line() {
  local _k="$1" _r="${2:-}" _sz _tmp
  _r="${_r//[[:cntrl:]]/ }"
  (( ${#_r} > 400 )) && _r="${_r:0:400}..."
  mkdir -p "$(dirname "$NF_ERR_LOG")" 2>/dev/null
  # Cap: keep the last 64 KB once over 256 KB. Only on the (rate limited) write path.
  _sz=$(stat -c %s "$NF_ERR_LOG" 2>/dev/null || stat -f %z "$NF_ERR_LOG" 2>/dev/null || echo 0)
  if (( _sz > 262144 )); then
    _tmp="${NF_ERR_LOG}.tmp.$$"
    if { tail -c 65536 "$NF_ERR_LOG" | tail -n +2 > "$_tmp"; } 2>/dev/null; then
      mv -f "$_tmp" "$NF_ERR_LOG" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
    else
      rm -f "$_tmp" 2>/dev/null
    fi
  fi
  # One pre-built line, one O_APPEND write. The braces send the SHELL's own
  # "Permission denied" to /dev/null too (a redirection error is printed before
  # a trailing 2>/dev/null takes effect). stderr is the last resort.
  if { printf '%s %s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$_k" "$_r" >> "$NF_ERR_LOG"; } 2>/dev/null; then
    return 0
  fi
  printf 'nerdflair: cannot write %s | %s: %s\n' "$NF_ERR_LOG" "$_k" "$_r" >&2
  return 1
}
_nf_err() {
  local _k="$1" _st
  case "$_NF_MEM" in *" "${_k}" "*) return 0 ;; esac    # once per process whatever the stamp says
  _NF_MEM+="${_k} "
  _nf_stamp "$_k"
  _st="$_NF_STAMP"
  if [[ -n "$_st" ]] && (( $(_nf_stamp_age "$_st") < 3600 )); then return 0; fi
  # Log, then stamp whether or not the append worked: an unwritable log would
  # otherwise make every render retry and write to stderr.
  _nf_log_line "$_k" "${2:-}"
  [[ -n "$_st" ]] && _nf_stamp_write "$_st"
  return 0
}
# A keyed condition that had logged has cleared: say so, once per failure line.
# The failure stamp is kept (a condition that flaps stays limited to one failure
# line an hour); a second stamp records that the recovery was reported.
_nf_ok() {
  local _st _rec _age
  _nf_stamp "$1"; _st="$_NF_STAMP"
  [[ -n "$_st" ]] || return 0
  [[ -e "$_st" || -L "$_st" ]] || return 0
  _nf_stamp "recovered-$1"; _rec="$_NF_STAMP"
  _age=$(_nf_stamp_age "$_st")
  if (( _age >= 604800 )); then rm -f "$_st" "$_rec" 2>/dev/null; return 0; fi   # a week old: long forgotten, say nothing
  if [[ -e "$_rec" || -L "$_rec" ]] && (( $(_nf_stamp_age "$_rec") <= _age )); then return 0; fi
  _nf_log_line recovered "$1"
  _nf_stamp_write "$_rec"
  return 0
}
_nf_recent() { _nf_stamp "$1"; [[ -n "$_NF_STAMP" && ( -e "$_NF_STAMP" || -L "$_NF_STAMP" ) ]] && (( $(_nf_stamp_age "$_NF_STAMP") < $2 )); }
_nf_touch() { _nf_stamp "$1"; [[ -n "$_NF_STAMP" ]] && _nf_stamp_write "$_NF_STAMP"; return 0; }
_nf_clear() { _nf_stamp "$1"; [[ -n "$_NF_STAMP" ]] && rm -f "$_NF_STAMP" 2>/dev/null; return 0; }

# ── jq check ─────────────────────────────────────────────────────
_nf_require_jq() {
  if ! command -v jq &>/dev/null; then
    # stderr is hidden by the host; the log is not. (Rate limited like the rest.)
    _nf_err "jq-missing" "jq not found; nerdflair requires it"
    printf '%b✗ jq not found — nerdflair requires jq.%b\n' "$NF_RED" "$NF_RST" >&2
    printf '  Install with: %bbrew install jq%b (macOS) or %bsudo apt install jq%b (Debian/Ubuntu)\n' \
      "$NF_CYAN" "$NF_RST" "$NF_CYAN" "$NF_RST" >&2
    exit 1
  fi
}

# ── Read a single field from the state file ──────────────────────
# Usage: _nf_read_field <field_name> [default_value]
# Returns the value via stdout. Handles missing file/field gracefully.
_nf_read_field() {
  local field="$1" default="${2:-}"
  if [[ -f "$NF_STATE_FILE" ]]; then
    local val
    val=$(jq -r ".$field // empty" "$NF_STATE_FILE" 2>/dev/null)
    if [[ -n "$val" ]]; then
      printf '%s' "$val"
      return
    fi
  fi
  printf '%s' "$default"
}

# ── Read the chime_recent_styles array as comma-separated ────────
_nf_read_recent_styles() {
  if [[ -f "$NF_STATE_FILE" ]]; then
    local _rerr _rcsv
    if _rcsv=$(jq -r '.chime_recent_styles // [] | join(",")' "$NF_STATE_FILE" 2>/dev/null); then
      printf '%s\n' "$_rcsv"
    else
      _rerr=$(jq -r '.chime_recent_styles // [] | join(",")' "$NF_STATE_FILE" 2>&1 >/dev/null)
      _nf_err "state-read" "jq could not read chime_recent_styles from $NF_STATE_FILE: ${_rerr%%$'\n'*}"
    fi
  fi
}

# ── Read all state fields into NF_CUR_* variables ────────────────
# Applies legacy migrations inline.
_nf_read_state() {
  if [[ -f "$NF_STATE_FILE" ]]; then
    # Read all fields in a single jq call
    local _json
    _json=$(jq -r '[
      .mode // "",
      .width // "",
      .flair // "",
      .color // "",
      .terminal_bell // "",
      .chime_sound // "",
      .chime_style // "",
      .chime_events // "",
      .chime_volume // "",
      .last_session // "",
      .bell // "",
      .audio_style // "",
      .audio_events // "",
      .bell_volume // ""
    ] | @tsv' "$NF_STATE_FILE" 2>/dev/null)
    # A state file that EXISTS but will not parse silently reverts every
    # setting to its default. Degrade (defaults) AND say so. A missing file
    # is first run and stays silent.
    if (( $? != 0 )); then
      _nf_err "state-corrupt" "$NF_STATE_FILE is not a valid JSON object ($(jq . "$NF_STATE_FILE" 2>&1 >/dev/null | head -n 1)); using defaults"
    else
      _nf_ok "state-corrupt"
    fi

    IFS=$'\t' read -r \
      NF_CUR_MODE NF_CUR_WIDTH NF_CUR_FLAIR NF_CUR_COLOR \
      NF_CUR_TERMINAL_BELL NF_CUR_CHIME_SOUND NF_CUR_CHIME_STYLE \
      NF_CUR_CHIME_EVENTS NF_CUR_CHIME_VOLUME NF_CUR_LAST_SESSION \
      _old_bell _old_audio_style _old_audio_events _old_bell_volume \
      <<< "$_json"
  fi

  # Apply defaults
  NF_CUR_MODE="${NF_CUR_MODE:-$NF_DEFAULT_MODE}"
  NF_CUR_WIDTH="${NF_CUR_WIDTH:-$NF_DEFAULT_WIDTH}"
  NF_CUR_FLAIR="${NF_CUR_FLAIR:-true}"
  NF_CUR_COLOR="${NF_CUR_COLOR:-$NF_DEFAULT_COLOR}"
  NF_CUR_TERMINAL_BELL="${NF_CUR_TERMINAL_BELL:-}"
  NF_CUR_CHIME_SOUND="${NF_CUR_CHIME_SOUND:-$NF_DEFAULT_CHIME_SOUND}"
  NF_CUR_CHIME_STYLE="${NF_CUR_CHIME_STYLE:-}"
  NF_CUR_CHIME_EVENTS="${NF_CUR_CHIME_EVENTS:-}"
  NF_CUR_CHIME_VOLUME="${NF_CUR_CHIME_VOLUME:-}"
  NF_CUR_LAST_SESSION="${NF_CUR_LAST_SESSION:-}"

  # Legacy migration: "default" color → "vibrant"
  if [[ "$NF_CUR_COLOR" == "default" ]]; then
    NF_CUR_COLOR="vibrant"
  fi

  # Legacy migration: old "bell" field → terminal_bell + chime_volume
  if [[ -z "$NF_CUR_TERMINAL_BELL" && -n "${_old_bell:-}" ]]; then
    case "$_old_bell" in
      both)   NF_CUR_TERMINAL_BELL="on" ;;
      visual) NF_CUR_TERMINAL_BELL="on"; NF_CUR_CHIME_VOLUME="0" ;;
      audio)  NF_CUR_TERMINAL_BELL="off" ;;
      off)    NF_CUR_TERMINAL_BELL="off"; NF_CUR_CHIME_VOLUME="0" ;;
    esac
  fi
  NF_CUR_TERMINAL_BELL="${NF_CUR_TERMINAL_BELL:-$NF_DEFAULT_TERMINAL_BELL}"

  # Legacy migration: audio_style → chime_style
  if [[ -z "$NF_CUR_CHIME_STYLE" && -n "${_old_audio_style:-}" ]]; then
    NF_CUR_CHIME_STYLE="$_old_audio_style"
  fi
  NF_CUR_CHIME_STYLE="${NF_CUR_CHIME_STYLE:-$NF_DEFAULT_CHIME_STYLE}"

  # Legacy migration: audio_events → chime_events
  if [[ -z "$NF_CUR_CHIME_EVENTS" && -n "${_old_audio_events:-}" ]]; then
    NF_CUR_CHIME_EVENTS="$_old_audio_events"
  fi
  NF_CUR_CHIME_EVENTS="${NF_CUR_CHIME_EVENTS:-$NF_DEFAULT_CHIME_EVENTS}"

  # Legacy migration: bell_volume → chime_volume
  if [[ -z "$NF_CUR_CHIME_VOLUME" && -n "${_old_bell_volume:-}" ]]; then
    NF_CUR_CHIME_VOLUME="$_old_bell_volume"
  fi
  NF_CUR_CHIME_VOLUME="${NF_CUR_CHIME_VOLUME:-$NF_DEFAULT_CHIME_VOLUME}"
}

# ── Write state file atomically using jq ─────────────────────────
# Usage: _nf_write_state [extra_jq_filter]
# Writes NF_CUR_* variables to state.json, preserving chime_recent_styles
# and last_session. Optional jq filter is applied last (e.g. to set
# additional fields).
_nf_write_state() {
  local extra_filter="${1:-}"
  mkdir -p "$(dirname "$NF_STATE_FILE")"

  # Preserve chime_recent_styles from existing file
  local recent_styles="[]"
  if [[ -f "$NF_STATE_FILE" ]]; then
    if ! recent_styles=$(jq -c '.chime_recent_styles // []' "$NF_STATE_FILE" 2>/dev/null); then
      recent_styles="[]"
      _nf_err "state-corrupt" "$NF_STATE_FILE unparseable; chime_recent_styles history reset"
    fi
  fi

  local _tmp="${NF_STATE_FILE}.tmp.$$" _werr
  # stdout to the temp file, stderr (2>&1 first) into the variable.
  _werr=$(jq -n \
    --arg mode "$NF_CUR_MODE" \
    --arg width "$NF_CUR_WIDTH" \
    --argjson flair "${NF_CUR_FLAIR:-true}" \
    --arg terminal_bell "$NF_CUR_TERMINAL_BELL" \
    --arg chime_sound "$NF_CUR_CHIME_SOUND" \
    --arg chime_volume "$NF_CUR_CHIME_VOLUME" \
    --arg chime_style "$NF_CUR_CHIME_STYLE" \
    --arg chime_events "$NF_CUR_CHIME_EVENTS" \
    --arg color "$NF_CUR_COLOR" \
    --arg last_session "$NF_CUR_LAST_SESSION" \
    --argjson recent "$recent_styles" \
    '{
      mode: $mode,
      width: $width,
      flair: $flair,
      terminal_bell: $terminal_bell,
      chime_sound: $chime_sound,
      chime_volume: $chime_volume,
      chime_style: $chime_style,
      chime_events: $chime_events,
      color: $color,
      last_session: $last_session,
      chime_recent_styles: $recent
    }' 2>&1 > "$_tmp") && _werr=$(mv "$_tmp" "$NF_STATE_FILE" 2>&1)
  local _wrc=$?
  if (( _wrc != 0 )); then
    _nf_err "state-write" "$NF_STATE_FILE not written (rc=$_wrc): ${_werr%%$'\n'*}"
    rm -f "$_tmp" 2>/dev/null   # no orphan temp
    return 1
  fi
  _nf_ok "state-write"
}

# ── Heal a missing or corrupt state file ─────────────────────────
# A missing file gets defaults, and so does a CORRUPT one (jq cannot update
# what it cannot parse). Before overwriting a corrupt file keep ONE copy of it
# as state.json.corrupt, so the evidence survives, and log that it happened.
_nf_state_heal() {
  local _herr
  if [[ ! -f "$NF_STATE_FILE" ]]; then
    _nf_read_state
    _nf_write_state
    return
  fi
  if ! _herr=$(jq -e . "$NF_STATE_FILE" 2>&1 >/dev/null); then
    if cp -f "$NF_STATE_FILE" "${NF_STATE_FILE}.corrupt" 2>/dev/null; then
      _nf_log_line "state-rebuilt" "$NF_STATE_FILE unparseable (${_herr%%$'\n'*}); copied to ${NF_STATE_FILE}.corrupt and rebuilt from defaults"
    else
      _nf_log_line "state-rebuilt" "$NF_STATE_FILE unparseable (${_herr%%$'\n'*}); COULD NOT copy to .corrupt, rebuilt from defaults anyway"
    fi
    _nf_read_state
    _nf_write_state
  fi
}

# ── Update a single field in state.json atomically ───────────────
# Usage: _nf_update_field <field> <value>
# Creates the file with defaults if it doesn't exist.
_nf_update_field() {
  local field="$1" value="$2" _uerr
  # The caller retries on EVERY render while last_session differs, so after a
  # failed write back off for a minute (the log line is rate limited apart).
  _nf_recent "state-write-retry" 60 && return 1
  if ! _uerr=$(mkdir -p "$(dirname "$NF_STATE_FILE")" 2>&1); then
    _nf_err "state-write" "cannot create $(dirname "$NF_STATE_FILE"): ${_uerr%%$'\n'*}"
    _nf_touch "state-write-retry"
    return 1
  fi
  # A missing file gets defaults, and so does a CORRUPT one. jq cannot update
  # what it cannot parse, so a malformed state file used to be both unreadable
  # and unwritable for good: every reader fell back to defaults, every write
  # failed, and the only evidence was jq printing a parse error on the status
  # line's stderr, where it can land in the user's terminal. Rebuilding from
  # defaults loses the stored preferences once; staying wedged loses them
  # every render and says nothing.
  _nf_state_heal
  # jq to a variable first, so the temp file is only ever created on the path
  # that immediately renames it. Writing the temp first and relying on `&&`
  # left one orphan per PID behind in the state directory on every failure.
  local _new
  if _new=$(jq --arg v "$value" ".$field = \$v" "$NF_STATE_FILE" 2>&1) \
     && [[ -n "$_new" ]]; then
    local _tmp="${NF_STATE_FILE}.tmp.$$"
    if _uerr=$({ printf '%s\n' "$_new" > "$_tmp" && mv "$_tmp" "$NF_STATE_FILE"; } 2>&1); then
      _nf_ok "state-write"
      _nf_clear "state-write-retry"
    else
      _nf_err "state-write" "$NF_STATE_FILE not updated ($field): ${_uerr%%$'\n'*}"
      rm -f "$_tmp" 2>/dev/null
      _nf_touch "state-write-retry"
      return 1
    fi
  else
    _nf_err "state-write" "jq could not set $field in $NF_STATE_FILE: ${_new%%$'\n'*}"
    _nf_touch "state-write-retry"
    return 1
  fi
}

# ── Play audio file (cross-platform) ──────────────────────────────
# Usage: _nf_play_audio <file> <volume>
# volume: 0.0–1.0 float (afplay scale)
# Supports: afplay (macOS), paplay (PulseAudio/PipeWire on Linux)
_nf_play_audio() {
  local file="$1" volume="${2:-1}"
  [[ ! -f "$file" ]] && return 1
  # Drop the chime if one is already sounding. Every Agent-tool subagent is its
  # own Claude Code session, so a machine running several at once fires several
  # chimes within milliseconds -- and simultaneous playback SUMS, which lands as
  # a sudden jump in loudness rather than as distinct sounds. One chime means
  # "something finished"; N chimes at once carry no extra information and are
  # just louder. Skip rather than queue, so the alert stays timely.
  # Opt out with NERDFLAIR_ALLOW_OVERLAP=1.
  if [[ "${NERDFLAIR_ALLOW_OVERLAP:-0}" != "1" ]]; then
    local _snd_lock="/tmp/nerdflair-chime-${UID:-$(id -u)}.lock"
    # Stale lock (player killed, machine slept): clear anything older than 30s,
    # comfortably longer than the 4.6s of the longest clip.
    if [[ -d "$_snd_lock" ]]; then
      local _sl_age=$(( ${EPOCHSECONDS:-$(date +%s)} - $(stat -c %Y "$_snd_lock" 2>/dev/null || stat -f %m "$_snd_lock" 2>/dev/null || echo 0) ))
      (( _sl_age > 30 )) && rmdir "$_snd_lock" 2>/dev/null
    fi
    # mkdir is atomic; pgrep was check-then-act and lost the race.
    mkdir "$_snd_lock" 2>/dev/null || return 0
    ( sleep 6; rmdir "$_snd_lock" 2>/dev/null ) &>/dev/null &
    disown 2>/dev/null || true
  fi
  if command -v afplay &>/dev/null; then
    nohup afplay --volume "$volume" "$file" &>/dev/null &
  elif command -v paplay &>/dev/null; then
    # paplay volume: 0–65536 (65536 = 100%)
    local _pa_vol
    _pa_vol=$(awk -v v="$volume" 'BEGIN {printf "%d", v * 65536}')
    nohup paplay --volume="$_pa_vol" "$file" &>/dev/null &
  fi
}

# ── Update chime_recent_styles array ─────────────────────────────
# Usage: _nf_update_recent_styles <comma_separated_styles>
_nf_update_recent_styles() {
  local styles_csv="$1"
  mkdir -p "$(dirname "$NF_STATE_FILE")"
  # Same two reasons as _nf_update_field: a corrupt file is as unwritable as a
  # missing one, and the temp file is only created on the path that renames it.
  _nf_state_heal
  local _new _uerr
  if _new=$(jq --arg csv "$styles_csv" \
              '.chime_recent_styles = ($csv | split(","))' \
              "$NF_STATE_FILE" 2>&1) && [[ -n "$_new" ]]; then
    local _tmp="${NF_STATE_FILE}.tmp.$$"
    if ! _uerr=$({ printf '%s\n' "$_new" > "$_tmp" && mv "$_tmp" "$NF_STATE_FILE"; } 2>&1); then
      _nf_err "state-write" "$NF_STATE_FILE not updated (chime_recent_styles): ${_uerr%%$'\n'*}"
      rm -f "$_tmp" 2>/dev/null
      return 1
    fi
  else
    _nf_err "state-write" "jq could not set chime_recent_styles in $NF_STATE_FILE: ${_new%%$'\n'*}"
    return 1
  fi
}

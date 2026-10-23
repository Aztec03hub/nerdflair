#!/bin/bash
set -uo pipefail

# Width math (wc -m, ${#var}, ${var:i:1}) needs a UTF-8 locale, but Claude Code
# spawns the statusline without LANG. _fmt_num stays locale-free on purpose.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
  *)
    if locale -a 2>/dev/null | grep -qiE '^C\.UTF-?8$'; then
      export LC_ALL=C.UTF-8
    else
      export LC_ALL=en_US.UTF-8
    fi
    ;;
esac
# Note: -e is intentionally omitted because arithmetic expressions like
# (( x == 0 )) return exit code 1, which would cause spurious termination.

input=$(cat)

# Buffer all output and flush at exit so Claude Code sees complete output
# atomically — prevents partial first-render from locking statusline height.
if ! _SL_BUF=$(mktemp "${TMPDIR:-/tmp}/nerdflair-sl.XXXXXX" 2>/dev/null); then
  # /tmp full or TMPDIR bad: log it (lib.sh is not sourced yet) and buffer under ~/.claude.
  source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
  _nf_err buf-mktemp "mktemp failed in ${TMPDIR:-/tmp}; buffering under ~/.claude"
  _SL_BUF="${HOME:-}/.claude/.nerdflair-sl.$$"
fi
exec 3>&1 1>"$_SL_BUF"
# Claude Code clamps its output to 256 colours when $TMUX is set and
# CLAUDE_CODE_TMUX_TRUECOLOR is empty (chalk level 2, ansi-styles
# rgbToAnsi256). Schemes remap indices 16 and 17 (Catppuccin Mocha: peach,
# rosewater), so near-black colours that land there would show orange. In that
# mode _nf_flush sends every 38;2/48;2 colour through _nf_safe256, which swaps
# a would-be 16/17 for a grey on the 232-255 ramp. Twin of colors::safe256 /
# safe256_sgr in rust/src/colors.rs; both must agree byte for byte.
_nf_safe256() { # r g b -> sets _s256 to "r;g;b"
  local r=$((10#$1)) g=$((10#$2)) b=$((10#$3)) l
  if (( r == g && g == b ? r < 8 : (r <= 25 && g <= 25 && b <= 76) )); then
    l=$(( (299*r + 587*g + 114*b + 500) / 1000 )); (( l < 8 )) && l=8
    _s256="$l;$l;$l"
  else
    _s256="$1;$2;$3"
  fi
}
_nf_flush() {
  if [[ -z "${TMUX:-}" || -n "${CLAUDE_CODE_TMUX_TRUECOLOR:-}" ]]; then
    cat "$_SL_BUF" >&3; return
  fi
  local rest out="" re='[[;]([34]8);2;([0-9]+);([0-9]+);([0-9]+)' _s256
  IFS= read -r -d '' rest < "$_SL_BUF"
  while [[ $rest =~ $re ]]; do
    out+="${rest%%"${BASH_REMATCH[0]}"*}${BASH_REMATCH[0]:0:1}${BASH_REMATCH[1]};2;"
    _nf_safe256 "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    out+="$_s256"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  printf '%s' "$out$rest" >&3
}
trap '_nf_rc=$?; _nf_flush; rm -f "$_SL_BUF" "$_SL_BUF.err"; (( _nf_rc != 0 )) && _nf_err "render-abort" "statusline.sh exited with status $_nf_rc (fatal arithmetic or shell error); output truncated"' EXIT

# ── Shared library ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
_nf_require_jq

# ── Absorbed-failure helpers (_nf_err and friends live in lib.sh) ──
# Everything below logs to ~/.claude/nerdflair-errors.log and NEVER to stdout,
# which is the status line. `$_SL_BUF.err` is this render's scratch file for a
# command's stderr (removed by the EXIT trap).
#
# Wall-clock guard for child processes: a git on a hung filesystem would block
# the render until the host kills it, leaving no trace.
_NF_TCMD=(); _NF_TMO=""
if command -v timeout >/dev/null 2>&1; then
  _nf_ms=${NERDFLAIR_PROC_TIMEOUT_MS:-10000}
  [[ "$_nf_ms" =~ ^[0-9]+$ ]] || _nf_ms=10000
  printf -v _NF_TMO '%d.%03d' $(( _nf_ms / 1000 )) $(( _nf_ms % 1000 ))
  _NF_TMO_US=$(( _nf_ms * 1000 ))
  _NF_TCMD=(timeout -k 1 "$_NF_TMO")
elif command -v gtimeout >/dev/null 2>&1; then
  _nf_ms=${NERDFLAIR_PROC_TIMEOUT_MS:-10000}
  [[ "$_nf_ms" =~ ^[0-9]+$ ]] || _nf_ms=10000
  printf -v _NF_TMO '%d.%03d' $(( _nf_ms / 1000 )) $(( _nf_ms % 1000 ))
  _NF_TMO_US=$(( _nf_ms * 1000 ))
  _NF_TCMD=(gtimeout -k 1 "$_NF_TMO")
else
  _nf_err no-timeout "timeout(1) not found; git runs without a deadline"
fi
# 0 when the command that started at $1 (EPOCHREALTIME without the dot) ran at least the whole
# deadline. Without EPOCHREALTIME (bash < 5) it assumes it did, as before.
_nf_ran_to_deadline() {
  [[ -n "${EPOCHREALTIME:-}" && -n "${_NF_TMO_US:-}" && -n "$1" ]] || return 0
  local _n=${EPOCHREALTIME//[.,]/}   # the radix follows the locale
  [[ "$_n" =~ ^[0-9]+$ && "$1" =~ ^[0-9]+$ ]] || return 0
  (( _n - $1 >= _NF_TMO_US ))
}
# _nf_cmd LABEL QUIET_ERE cmd args...   stdout -> $_NF_OUT, returns the command's rc.
# Cannot-run (126/127) and timeout (124) are always logged. A plain non-zero exit
# is logged as LABEL:rc with stderr's first line, unless LABEL is "-" (a probe
# whose failure just means "no") or stderr matches QUIET_ERE (a documented "no").
_nf_cmd() {
  local _l="$1" _q="$2" _rc _e
  shift 2
  if [[ "$1" == git ]]; then
    # Cross-render back-off (twin of proc::run): a hang in the last 60 s skips git.
    [[ -z "${_NF_GIT_TIMED_OUT:-}" ]] && _nf_recent git-hung 60 && _NF_GIT_TIMED_OUT=1
    if [[ -n "${_NF_GIT_TIMED_OUT:-}" ]]; then _NF_OUT=""; return 124; fi
  fi
  local _t0=${EPOCHREALTIME//[.,]/}
  _NF_OUT=$("${_NF_TCMD[@]+"${_NF_TCMD[@]}"}" "$@" 2>"$_SL_BUF.err"); _rc=$?
  if (( _rc != 0 )); then
    _e=$(< "$_SL_BUF.err")
    if (( _rc == 126 || _rc == 127 )); then
      _nf_err "spawn:$1" "cannot run $1 (rc=$_rc): ${_e%%$'\n'*}"
    elif (( _rc == 124 )) || { (( _rc == 137 )) && [[ -n "${_NF_TMO_US:-}" ]] && _nf_ran_to_deadline "$_t0"; }; then
      # 137 = `timeout -k` had to SIGKILL a child that ignored TERM
      if [[ "$1" == git ]]; then _NF_GIT_TIMED_OUT=1; _nf_touch git-hung; fi
      _nf_err "timeout:${_l/#-/$1}" "$* still running after ${_NF_TMO}s, killed"
    elif (( _rc == 137 )); then
      # SIGKILL well before the deadline: something else killed it (OOM, a user). The output
      # cannot be trusted, but this is not a hang, so no back-off.
      [[ "$1" == git ]] && _NF_GIT_TIMED_OUT=1
      _nf_err "killed:${_l/#-/$1}" "$* was killed (rc=137)${_NF_TMO:+ before the ${_NF_TMO}s deadline}; killed externally?"
    elif [[ "$_l" != "-" ]] && { [[ -z "$_q" ]] || [[ ! "$_e" =~ $_q ]]; }; then
      _e="${_e%%$'\n'*}"
      _nf_err "$_l:$_rc" "$* failed: ${_e:-(no stderr)}"
    fi
  fi
  return $_rc
}
# _nf_jq KEY jq-args...   stdout -> $_NF_JQ_OUT; a failure is logged under KEY.
_nf_jq() {
  local _k="$1" _rc
  shift
  _NF_JQ_OUT=$(jq "$@" 2>"$_SL_BUF.err"); _rc=$?
  if (( _rc != 0 )); then
    _nf_err "$_k" "jq failed on ${!#} (rc=$_rc): $(head -n 1 "$_SL_BUF.err" 2>/dev/null)"
  fi
  return $_rc
}
# A NERDFLAIR_* tunable that is set but not an integer silently loses to its
# default (the Rust build) or aborts the render (bash arithmetic). Either way
# it is a configuration mistake the owner must be able to see.
for _nf_v in NERDFLAIR_BURN_MIN_SPAN NERDFLAIR_BURN_STALE_AFTER NERDFLAIR_BURN_WINDOW \
  NERDFLAIR_COMPACT_AT_TENTHS NERDFLAIR_ETA_IDLE_GAP NERDFLAIR_LEDGER_COMPACT_EVERY \
  NERDFLAIR_LEDGER_FULL_DAYS NERDFLAIR_LEDGER_TAIL_BYTES NERDFLAIR_MCP_HEALTH_TTL \
  NERDFLAIR_MCP_NAMES NERDFLAIR_REPO_COST_DAYS NERDFLAIR_REPO_COST_MAX \
  NERDFLAIR_REPO_COST_MAXBYTES NERDFLAIR_REPO_COST_TTL NERDFLAIR_SAMPLES \
  NERDFLAIR_TRANSCRIPT_TAIL_BYTES NERDFLAIR_WIDTH_INSET; do
  _nf_val="${!_nf_v:-}"
  [[ -z "$_nf_val" || "$_nf_val" =~ ^-?[0-9]+$ ]] \
    || _nf_err "env-bad:$_nf_v" "$_nf_v=\"$_nf_val\" is not an integer; the default is ignored or the render aborts"
done
unset _nf_v _nf_val

# ── Layout mode & width from state file ──────────────────────────
_nf_read_state
_SL_MODE="$NF_CUR_MODE"
_SL_WIDTH="$NF_CUR_WIDTH"
_SL_COLOR_MODE="$NF_CUR_COLOR"
_SL_CHIME_VOLUME="$NF_CUR_CHIME_VOLUME"
_SL_CHIME_STYLE="$NF_CUR_CHIME_STYLE"
_SL_LAST_SESSION="$NF_CUR_LAST_SESSION"
# Per-session data (chime style) is stored in ~/.claude/nerdflair/sessions/<session_id>
# by bell.sh on SessionStart. The statusline reads it from there.
# ── Sanitize external strings ─────────────────────────────────────
# Strip backslashes so that printf '%b' cannot expand backslash-escape
# sequences (e.g. \033, \e, \x1b) into terminal control characters.
# Applied to user-controlled values: branch names, directory names, MCP
# server names, and model IDs.
# Control bytes (C0 except newline, and DEL) go too, as upstream 43c42f5 does, so a
# name from the filesystem or a repo .mcp.json can't inject escape sequences. Newline
# stays: _multi_branch_list is one branch per line. Pure bash, no fork.
_sanitize() { local LC_ALL=C _s="${1//\\/}"; printf '%s' "${_s//[$'\001'-$'\011'$'\013'-$'\037'$'\177']/}"; }

# ── Extract fields from Claude Code JSON ──────────────────────────
_nf_fields=$(printf '%s' "$input" | jq -r '[(.workspace.current_dir),(.workspace.project_dir),(if .model|type=="object" then (.model.display_name // .model.id // null) else (.model // null) end),(.worktree.branch),(.cost.total_cost_usd),(.cost.total_duration_ms),(.cost.total_api_duration_ms),(.output_style.name),(.effort.level),(.thinking.enabled),(.fast_mode),(.session_id),(.context_window.used_percentage),(.context_window.total_input_tokens),(.context_window.total_output_tokens),(.context_window.context_window_size),(.rate_limits.five_hour.used_percentage),(.rate_limits.five_hour.resets_at),(.rate_limits.seven_day.used_percentage),(.rate_limits.seven_day.resets_at)]|map(if .==null then "" else tostring end)|join("\u001f")' 2>"$_SL_BUF.err")
_nf_jrc=$?
# A bad payload still renders (as an empty one), but "the host changed its
# schema" must not look like a quiet, slightly degraded bar.
if [[ -z "${input//[[:space:]]/}" ]]; then
  _nf_err payload-empty "empty status payload on stdin"
elif (( _nf_jrc != 0 )) && [[ "$(head -n 1 "$_SL_BUF.err")" != *"parse error"* ]]; then
  # jq exits 5 for BOTH a parse error and a runtime type error; tell them apart.
  _nf_err payload-shape "unexpected payload shape; ALL payload fields blanked: $(head -n 1 "$_SL_BUF.err")"
elif (( _nf_jrc != 0 )); then
  _nf_err payload-parse "$(head -n 1 "$_SL_BUF.err"); first 200 chars: ${input:0:200}"
fi
IFS=$'\x1f' read -r cwd project_dir raw_model worktree_branch cost total_duration_ms total_api_ms output_style effort_level thinking_enabled fast_mode session_id used_pct input_tokens output_tokens ctx_size rl_5h_pct rl_5h_reset rl_7d_pct rl_7d_reset _nfrest <<< "$_nf_fields"


# Resolve symlinks so the path matches the key stored in ~/.claude.json
if [[ -n "$project_dir" && -d "$project_dir" ]]; then
  _pd=$(cd "$project_dir" 2>/dev/null && pwd -P) && project_dir="$_pd" \
    || _nf_err project-dir-resolve "cannot resolve $project_dir; keeping the raw path"
fi

# Model: prefer the display_name Claude Code provides; fall back to parsing the ID.
# Parse out just the family + version so suffixes like "(1M context)" or a date
# stamp are never shown. Matching is case-insensitive because display_name is
# title-cased ("Opus 4.8 (1M context)") while IDs are lowercase ("claude-opus-4-8").

model=""
# Drop a parenthesised suffix such as "(1M context)" before looking for a version,
# so a display_name with no version does not turn into "Sonnet 1".
_model_core="${raw_model%%(*}"
shopt -s nocasematch
if [[ "$_model_core" =~ (opus|sonnet|haiku|fable) ]]; then
  name="${BASH_REMATCH[1]}"
  # Capitalize first letter
  model="${name:0:1}"; model="${model^^}${name:1}"
  # Version: "4.8" or "4-8" → "4.8"; else a bare major like "5". A dotted/dashed
  # pair is matched first so a date stamp (e.g. "-20251001") is not picked up.
  if [[ "$_model_core" =~ [0-9]+[.-][0-9]+ ]]; then
    model+=" ${BASH_REMATCH[0]//-/.}"
  elif [[ "$_model_core" =~ [0-9]+ ]]; then
    model+=" ${BASH_REMATCH[0]}"
  fi
else
  model=$(_sanitize "$raw_model")
fi
shopt -u nocasematch

# Worktree info (optional, absent in normal sessions)






# Reasoning effort level (low/medium/high/xhigh/max). Absent when the model
# does not support the effort parameter; ultracode reports as "xhigh".

# Extended thinking toggle and fast mode. Session state indicators.



# Context window





# Rate limits (Pro/Max plans only; absent until the first API response of a
# session). used_percentage is 0-100, resets_at is Unix epoch SECONDS.





# MCP servers — aggregate from global ~/.claude.json, project-scoped servers
# in ~/.claude.json, and project/cwd .mcp.json files.
# Only active (non-disabled, not project-disabled) servers are collected.
mcp_enabled=0
mcp_names=()
_claude_json="$HOME/.claude.json"
# Project-level disabled servers (from ~/.claude.json .projects[project_dir].disabledMcpServers)
_proj_disabled_names=()
if [[ -n "$project_dir" && -f "$_claude_json" ]]; then
  _nf_jq claude-json -r --arg p "$project_dir" '.projects[$p].disabledMcpServers // [] | .[]' "$_claude_json"
  while IFS= read -r _dname; do
    [[ -n "$_dname" ]] && _proj_disabled_names+=("$_dname")
  done <<< "$_NF_JQ_OUT"
fi
_is_proj_disabled() {
  local _n="$1"
  for _pd in ${_proj_disabled_names[@]+"${_proj_disabled_names[@]}"}; do
    [[ "$_pd" == "$_n" ]] && return 0
  done
  return 1
}
# Project .mcp.json servers are only active once the user approves them in
# Claude Code, recorded as enabledMcpjsonServers / disabledMcpjsonServers /
# enableAllProjectMcpServers (per project in ~/.claude.json, or globally in
# settings.json). With no approval data anywhere, list every server.
_mcpjson_all=false
_mcpjson_has_policy=false
_mcpjson_enabled=()
_mcpjson_disabled=()
_read_mcpjson_policy() {  # $1 = json file, $2 = jq expression selecting the object
  [[ -f "$1" ]] || return 0
  local _line
  while IFS= read -r _line; do
    case "$_line" in
      POLICY) _mcpjson_has_policy=true ;;
      ALL)    _mcpjson_all=true ;;
      EN:*)   _mcpjson_enabled+=("${_line#EN:}") ;;
      DIS:*)  _mcpjson_disabled+=("${_line#DIS:}") ;;
    esac
  done < <(jq -r --arg p "${project_dir:-}" "$2"' | select(type == "object")
    | (if (has("enableAllProjectMcpServers") or has("enabledMcpjsonServers") or has("disabledMcpjsonServers")) then "POLICY" else empty end),
      (if .enableAllProjectMcpServers == true then "ALL" else empty end),
      ((.enabledMcpjsonServers // [])[] | "EN:" + .),
      ((.disabledMcpjsonServers // [])[] | "DIS:" + .)' "$1" 2>/dev/null)
}
_read_mcpjson_policy "$_claude_json" '.projects[$p]'
_read_mcpjson_policy "$NF_SETTINGS_FILE" '.'
_mcpjson_approved() {
  local _n="$1" _e
  for _e in ${_mcpjson_disabled[@]+"${_mcpjson_disabled[@]}"}; do [[ "$_e" == "$_n" ]] && return 1; done
  [[ "$_mcpjson_has_policy" == "false" || "$_mcpjson_all" == "true" ]] && return 0
  for _e in ${_mcpjson_enabled[@]+"${_mcpjson_enabled[@]}"}; do [[ "$_e" == "$_n" ]] && return 0; done
  return 1
}
# cwd and project_dir usually name the same directory; -ef compares inodes so a
# differently spelled path to the same .mcp.json is still read only once.
_mcp_files=("$_claude_json" "${project_dir}/.mcp.json")
if [[ ! "${cwd}/.mcp.json" -ef "${project_dir}/.mcp.json" ]]; then
  _mcp_files+=("${cwd}/.mcp.json")
fi
for mcp_file in "${_mcp_files[@]}"; do
  if [[ -f "$mcp_file" ]]; then
    _mcp_key=mcp-json; [[ "$mcp_file" == "$_claude_json" ]] && _mcp_key=claude-json
    _nf_jq "$_mcp_key" -r '[.mcpServers // {} | to_entries[] | select(.value.disabled != true) | .key] | sort[]' "$mcp_file"
    while IFS= read -r _name; do
      if [[ -n "$_name" ]]; then
        if [[ "$mcp_file" == "$_claude_json" ]] && _is_proj_disabled "$_name"; then
          continue
        fi
        if [[ "$mcp_file" != "$_claude_json" ]] && ! _mcpjson_approved "$_name"; then
          continue
        fi
        mcp_names+=("$(_sanitize "$_name")")
        (( mcp_enabled++ ))
      fi
    done <<< "$_NF_JQ_OUT"
  fi
done
# Also read project-scoped MCP servers from ~/.claude.json .projects[project_dir].mcpServers
if [[ -n "$project_dir" && -f "$_claude_json" ]]; then
  _nf_jq claude-json -r --arg p "$project_dir" '[.projects[$p].mcpServers // {} | to_entries[] | select(.value.disabled != true) | .key] | sort[]' "$_claude_json"
  while IFS= read -r _name; do
    if [[ -n "$_name" ]] && ! _is_proj_disabled "$_name"; then
      mcp_names+=("$(_sanitize "$_name")")
      (( mcp_enabled++ ))
    fi
  done <<< "$_NF_JQ_OUT"
fi
mcp_total=$mcp_enabled
# The config-file scan above sees ONLY ~/.claude.json mcpServers and project
# .mcp.json. Plugin-provided servers (context7, figma, postman, svelte, github)
# live elsewhere entirely and are invisible to it -- which is why the names
# segment showed "jira" while the health probe counted 8. When the probe cache
# is populated, use its names instead: same source as the health counts, so the
# two can no longer disagree.
_mcp_probe_names=""
# ONE definition of the cache path, used by both readers and the writer below.
# It was spelled out literally in three places, so overriding it in one (to
# isolate a test) silently left the other two reading the live machine's cache:
# the health counts came from the override and the NAMES from /tmp, which is
# exactly the disagreement between the two that the probe exists to prevent.
# Empty when there is no private cache dir (then no probe cache and no probe).
# The ONE rule for the per-project key (twin of norm_key_dir): cut at the first newline, collapse runs of "/",
# strip a trailing "/" (the root stays "/"). Set whether or not NERDFLAIR_MCP_CACHE is: the probe cds to it.
_mcp_key_dir="${project_dir:-$cwd}"; _mcp_key_dir="${_mcp_key_dir%%$'\n'*}"
while [[ "$_mcp_key_dir" == *//* ]]; do _mcp_key_dir="${_mcp_key_dir//\/\//\/}"; done
[[ ${#_mcp_key_dir} -gt 1 ]] && _mcp_key_dir="${_mcp_key_dir%/}"
if [[ -n "${NERDFLAIR_MCP_CACHE:-}" ]]; then _MCP_CACHE="$NERDFLAIR_MCP_CACHE"
else
  # Keyed by the project dir (cksum, like the git cache): `claude mcp list` is cwd-dependent, so one shared
  # file let a 11/11 from one project show in another. The probe also runs from this dir.
  _mcp_key_crc=$(printf '%s' "$_mcp_key_dir" | cksum | cut -d' ' -f1)
  _nf_cache_path "nerdflair-mcphealth-${UID}-${_mcp_key_crc}"; _MCP_CACHE="$_NF_CP"
fi
if [[ "${NERDFLAIR_MCP_HEALTH:-1}" != "0" && -r "$_MCP_CACHE" ]]; then
  # `read` exits 1 at EOF without a trailing newline and the probe writes none:
  # the variables ARE set, so the `|| true` is correct, not an absorbed error.
  IFS=$'\x1f' read -r _ _ _ _mcp_probe_names < "$_MCP_CACHE" || true
elif [[ "${NERDFLAIR_MCP_HEALTH:-1}" != "0" && -e "$_MCP_CACHE" ]]; then
  _nf_err mcp-cache-read "$_MCP_CACHE exists but is not readable"
fi
if [[ -n "${_mcp_probe_names:-}" ]]; then
  IFS=$'\x1e' read -ra _probe_arr <<< "$_mcp_probe_names"
  if (( ${#_probe_arr[@]} > 0 )); then
    mcp_names=("${_probe_arr[@]}")
    mcp_enabled=${#_probe_arr[@]}
    mcp_total=$mcp_enabled
  fi
fi

# Sort names alphabetically (handles names from multiple files)
IFS=$'\n' mcp_names_sorted=($(printf '%s\n' "${mcp_names[@]}" | sort -f)); unset IFS

# ── Colors (4-color palette + brand) ──────────────────────────────────
# Primary: workspace identity
BLUE="\033[38;2;95;179;255m"
MAGENTA="\033[38;2;198;120;221m"
CYAN="\033[38;2;86;182;194m"
# Model-state suffixes (effort, thinking, style, fast)
STATE_COLOR="\033[38;2;72;200;170m"
# Muted: secondary info (mode, timing)
MAUVE="\033[38;2;145;130;155m"
# MCP tool list
MCP_COLOR="\033[38;2;195;130;140m"
# Accent: money
DARK_GREEN="\033[38;2;110;155;95m"
# Alert: warnings
ALERT="\033[38;2;220;175;100m"
# Accent: dirty files
MUSTARD="\033[38;2;180;155;95m"
# Cost
COST_GREEN="\033[38;2;90;120;82m"
# Diff
DIFF_PLUS="\033[38;2;130;190;110m"
DIFF_MINUS="\033[38;2;235;100;90m"
DIFF_BRACKET="\033[1;38;2;72;78;74m"
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
  STATE_COLOR="\033[38;2;150;150;150m"
  MAUVE="\033[38;2;140;140;140m"
  MCP_COLOR="\033[38;2;170;170;170m"
  DARK_GREEN="\033[38;2;150;150;150m"
  ALERT="\033[38;2;200;200;200m"
  MUSTARD="\033[38;2;185;185;185m"
  COST_GREEN="\033[38;2;150;150;150m"
  DIFF_PLUS="\033[38;2;160;160;160m"
  DIFF_MINUS="\033[38;2;160;160;160m"
  DIM="\033[38;2;90;90;90m"
elif [[ "$_SL_COLOR_MODE" == "muted" ]]; then
  # Muted: same hues, ~40% saturation
  BLUE="\033[38;2;140;170;210m"
  MAGENTA="\033[38;2;170;145;185m"
  CYAN="\033[38;2;130;165;170m"
  STATE_COLOR="\033[38;2;95;175;150m"
  MAUVE="\033[38;2;140;135;150m"
  MCP_COLOR="\033[38;2;170;138;142m"
  DARK_GREEN="\033[38;2;125;145;115m"
  ALERT="\033[38;2;185;165;125m"
  MUSTARD="\033[38;2;185;170;115m"
  COST_GREEN="\033[38;2;120;135;118m"
  DIFF_PLUS="\033[38;2;115;135;110m"
  DIFF_MINUS="\033[38;2;175;125;118m"
  DIM="\033[38;2;95;95;105m"
fi

SEP="  "
BULLET="${DIM} · ${RESET}"
# Separator before the state-suffix run. No trailing space. The first
# suffix supplies it, so it reads like BULLET but spans 2 columns.
OPT_BULLET="${DIM} ·${RESET}"

# ── Detect effective git repo (current dir or one level deep) ────
# Sets one of: git_dir (cwd is a repo, or wraps exactly one), or
# _multi_git_subs (cwd wraps 2+ repos, so a multi-branch summary). When git_dir is
# adopted from a subfolder, _adopted_repo_name holds its basename for the prefix.
# First line of a small file into _NF_CL, read as at most 4 KiB: invalid UTF-8 dropped, control characters
# (C0, DEL, C1, so ESC, CR and NUL too) removed, trailing spaces trimmed. Twin of clean_first_line.
# Invalid UTF-8 is dropped by a round trip through UTF-16 (which, unlike UTF-8 to UTF-8, also drops code points
# above U+10FFFF, as Rust does). Without a working iconv the line is cut to printable ASCII instead and
# git-branch-fallback-noiconv is logged: a non-ASCII branch name then differs from the Rust renderer's.
_nf_clean_line() {
  local LC_ALL=C _ascii="${2:-}"   # $2 = "ascii": cut the result to printable ASCII (the no-iconv degrade) only for the BRANCH
  if [[ -z "${_NF_ICONV:-}" ]]; then
    if iconv -f UTF-8 -t UTF-16LE </dev/null >/dev/null 2>&1; then _NF_ICONV=1
    else _NF_ICONV=0; _nf_err git-branch-fallback-noiconv "iconv is missing or broken; the .git/HEAD branch fallback shows printable ASCII only"; fi
  fi
  # The control characters go AFTER the round trip: removing them first could join the bytes around them into a
  # valid sequence (E2 01 82 AC would become the euro sign), which Rust never does. Only GNU iconv is verified.
  if [[ "$_NF_ICONV" == 1 ]]; then
    _NF_CL=$(head -c 4096 "$1" 2>/dev/null | head -n 1 | iconv -f UTF-8 -t UTF-16LE -c 2>/dev/null | iconv -f UTF-16LE -t UTF-8 -c 2>/dev/null | tr -d '\000-\037\177') || true
  else
    _NF_CL=$(head -c 4096 "$1" 2>/dev/null | head -n 1 | tr -d '\000-\037\177') || true
    [[ -n "$_ascii" ]] && _NF_CL=$(printf '%s' "$_NF_CL" | tr -cd '\040-\176')
  fi
  _NF_CL=${_NF_CL//$'\xc2'[$'\x80'-$'\x9f']/}
  _NF_CL=${_NF_CL%"${_NF_CL##*[! ]}"}
}
# Branch name read straight from .git/HEAD, for when git itself is hung or missing (twin of
# head_fallback_branch). Walks up and stops at the FIRST .git entry or bare layout (HEAD plus refs/); a
# linked worktree has a .git FILE with "gitdir: <path>". "ref: refs/heads/x" -> x; a bare 40/64 hex sha ->
# its first 7. Sets _NF_HB.
_nf_head_branch() {
  local _d="$1" _dot _gd="" _l=""
  _NF_HB=""
  while :; do
    _dot="$_d/.git"
    if [[ -d "$_dot" ]]; then _gd="$_dot"
    elif [[ -f "$_dot" ]]; then
      _nf_clean_line "$_dot"; _l="$_NF_CL"
      [[ "$_l" == "gitdir: "* ]] || return 1
      _gd="${_l#gitdir: }"; [[ "$_gd" == /* ]] || _gd="$_d/$_gd"
    elif [[ -f "$_d/HEAD" && -d "$_d/refs" ]]; then _gd="$_d"
    fi
    if [[ -n "$_gd" ]]; then
      _nf_clean_line "$_gd/HEAD" ascii; _l="$_NF_CL"
      if [[ "$_l" == "ref: refs/heads/"?* ]]; then _NF_HB="${_l#ref: refs/heads/}"
      elif [[ "$_l" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then _NF_HB="${_l:0:7}"; fi
      [[ -n "$_NF_HB" ]]; return
    fi
    [[ -z "$_d" || "$_d" == / ]] && return 1
    _d="${_d%/*}"; _d="${_d:-/}"
  done
}

git_dir=""
_multi_git_subs=()
_adopted_repo_name=""
if [[ -n "$cwd" ]]; then
  if ! cd "$cwd" 2>/dev/null; then
    _nf_err cwd-cd "cannot cd to $cwd; git UI skipped"
    _cd_ok=""
  fi
fi
if [[ -n "$cwd" && -n "${_cd_ok-1}" ]]; then
  # "not a git repository" is the normal answer for a plain directory: silent.
  # Any other failure (dubious ownership, corrupt repo) drops the whole git UI.
  if _nf_cmd git:inside-work-tree 'not a git repository' git rev-parse --is-inside-work-tree \
     || { [[ -n "${_NF_GIT_TIMED_OUT:-}" ]] && _nf_head_branch "$cwd"; }; then
    git_dir="$cwd"   # on a hung git: still a repo on disk, the cache/HEAD fallback fills in
  else
    # Look one level deep for git repos (wrapper folder pattern).
    git_subs=()
    for sub in "$cwd"/*/; do
      if [[ -d "$sub/.git" ]]; then
        git_subs+=("${sub%/}")
      fi
    done
    if (( ${#git_subs[@]} == 1 )); then
      git_dir="${git_subs[0]}"
      _adopted_repo_name=$(basename "$git_dir")
    elif (( ${#git_subs[@]} > 1 )); then
      _multi_git_subs=("${git_subs[@]}")
    fi
  fi
fi

# ── Helper: format number with commas ──────────────────────────
_fmt_num() {
  # Locale-independent thousands grouping. printf "%'d" is a no-op under the
  # C/POSIX locale that Claude Code spawns hooks with, so group by hand.
  local n="$1" sign="" out=""
  [[ "$n" == -* ]] && { sign="-"; n="${n#-}"; }
  while (( ${#n} > 3 )); do
    out=",${n: -3}${out}"
    n="${n:0:${#n}-3}"
  done
  printf '%s%s%s' "$sign" "$n" "$out"
}

# Coerce a cached or external value to a non-negative integer. Cache files feed
# (( )) arithmetic, and bash evaluates a[$(cmd)] there, so never trust them raw.
_int_or_zero() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then printf "%s" "$1"; else printf "0"; fi
}

# ── Git cache (3-second TTL) ──────────────────────────────────────
# Cache git status/diff results to avoid running git on every render.
_GIT_CACHE_TTL=3
_git_cache_file=""
_git_cache_fresh=false
if [[ -n "$git_dir" ]]; then
  _git_dir_hash=$(printf '%s' "$git_dir" | cksum | cut -d' ' -f1)
  _nf_cache_path "nerdflair-git-${_git_dir_hash}"; _git_cache_file="$_NF_CP"   # empty: no cache dir, compute every render
  if [[ -f "$_git_cache_file" ]]; then
    _cache_age=$(( ${EPOCHSECONDS} - $(stat -c %Y "$_git_cache_file" 2>/dev/null || stat -f %m "$_git_cache_file" 2>/dev/null || echo 0) ))
    (( _cache_age < _GIT_CACHE_TTL )) && _git_cache_fresh=true
  fi
  if [[ "$_git_cache_fresh" == "false" ]]; then
    if ! cd "$git_dir" 2>/dev/null; then
      _nf_err cwd-cd "cannot cd to $git_dir; git UI skipped"
      git_dir=""
    fi
  fi
  if [[ -n "$git_dir" && "$_git_cache_fresh" == "false" ]]; then
    _gc_computed=1
    _nf_cmd git:status '' git -c core.useBuiltinFSMonitor=false status --porcelain --ignore-submodules=dirty
    _gc_dirty=0
    [[ -n "$_NF_OUT" ]] && _gc_dirty=$(printf '%s\n' "$_NF_OUT" | wc -l | tr -d ' ')
    _gc_added=0
    _gc_removed=0
    if (( _gc_dirty > 0 )); then
      # A repo with no commits has no HEAD, so the fallback is expected there.
      _nf_cmd git:diff-head "ambiguous argument 'HEAD'|bad revision 'HEAD'" git diff --numstat HEAD \
        || _nf_cmd git:diff '' git diff --numstat
      while IFS=$'\t' read -r added removed _; do
        # a here-string always yields one line, even for empty output
        [[ -z "$added" ]] && continue
        [[ "$added" == "-" ]] && continue
        (( _gc_added += added ))
        (( _gc_removed += removed ))
      done <<< "$_NF_OUT"
      _ucount=0
      _nf_cmd git:ls-files '' git ls-files --others --exclude-standard
      while IFS= read -r ufile; do
        [[ -z "$ufile" ]] && continue
        (( _ucount++ ))
        (( _ucount > 100 )) && break
        [[ -d "$ufile" ]] && continue   # a nested worktree or repo is listed as a directory
        # a file listed then gone is a race and normal; unreadable is not
        if [[ -e "$ufile" && ! -r "$ufile" ]]; then _nf_err git-untracked-read "cannot read $ufile"; fi
        ulines=$(wc -l < "$ufile" 2>/dev/null | tr -d ' ')
        (( _gc_added += ${ulines:-0} ))
      done <<< "$_NF_OUT"
    fi
    # symbolic-ref exits 1 quietly on a detached HEAD; both failing is not normal.
    if _nf_cmd - '' git symbolic-ref --quiet --short HEAD; then
      _gc_branch="$_NF_OUT"
    else
      _nf_cmd git:rev-parse-head '' git rev-parse --short HEAD \
        || [[ -n "${_NF_GIT_TIMED_OUT:-}" ]] || _nf_err git-branch "neither symbolic-ref nor rev-parse HEAD worked in $git_dir"
      _gc_branch="$_NF_OUT"
    fi
    # In a linked worktree --git-dir and --git-common-dir differ; in the main checkout they match.
    _gc_worktree=0
    _nf_cmd git:common-dir '' git rev-parse --git-common-dir; _gc_common="$_NF_OUT"
    _nf_cmd git:git-dir '' git rev-parse --git-dir
    if [[ "$_gc_common" != "$_NF_OUT" ]]; then
      _gc_worktree=1
    fi
    # Remote URL for clickable links (convert SSH → HTTPS)
    # No origin is normal (exit 2, "No such remote"): a probe, silent.
    _nf_cmd - '' git remote get-url origin; _gc_remote="$_NF_OUT"
    _gc_remote=$(printf '%s' "$_gc_remote" | sed 's|^git@github\.com:|https://github.com/|' | sed 's|^git@\([^:]*\):|https://\1/|' | sed 's|\.git$||')
    # Divergence from upstream. One rev-list, only on a cache miss. Empty when
    # there is no upstream configured, which is the common case for a fresh branch.
    _gc_ahead=0; _gc_behind=0
    # No upstream is the common case for a fresh branch: a probe, silent.
    if _nf_cmd - '' git rev-list --count --left-right '@{upstream}...HEAD'; then
      _gc_ud="$_NF_OUT"
      _gc_behind="${_gc_ud%%[!0-9]*}"
      _gc_ahead="${_gc_ud##*[!0-9]}"
      : "${_gc_behind:=0}" "${_gc_ahead:=0}"
    fi
    # \x1f, not \t: tab is IFS-whitespace, so `IFS=$'\t' read` collapses runs of
    # separators and empty fields vanish -- a repo with no `origin` would shift
    # every field after _gc_remote by one. \x1f is not IFS-whitespace.
    # Not after a git timeout: the empty result is not "clean, no branch".
    if [[ -z "${_NF_GIT_TIMED_OUT:-}" ]]; then
      if [[ -n "$_git_cache_file" ]]; then
        printf -v _gc_payload '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' "$_gc_dirty" "$_gc_added" "$_gc_removed" "$_gc_branch" "$_gc_remote" "$_gc_worktree" "$_gc_ahead" "$_gc_behind"
        _nf_cache_put "$_git_cache_file" "$_gc_payload" \
          || _nf_err "tmp-write:${_git_cache_file##*/}" "cannot write $_git_cache_file (git re-runs every render)"
      fi
    fi
  fi
  # A fresh computation beats the file (a failed write leaves the old one); after a
  # timeout the computation is empty, so prefer the last file when there is one.
  if [[ -n "$git_dir" ]] && [[ -z "${_gc_computed:-}" || -n "${_NF_GIT_TIMED_OUT:-}" ]]; then
    if [[ -r "$_git_cache_file" ]]; then
      IFS=$'\x1f' read -r _gc_dirty _gc_added _gc_removed _gc_branch _gc_remote _gc_worktree _gc_ahead _gc_behind < "$_git_cache_file"
    elif [[ -z "${_gc_computed:-}" ]]; then
      _nf_err git-cache-read "cannot read $_git_cache_file"
    fi
  fi
  # git hung, was skipped or is missing: the branch is still on disk.
  if [[ -n "$git_dir" && -z "${_gc_branch:-}" ]] && _nf_head_branch "$git_dir"; then
    _nf_err git-branch-fallback "git gave no branch for $git_dir; read .git/HEAD instead"
    _gc_branch="$_NF_HB"
  fi
fi

# ── Uncommitted files segment ────────────────────────────────────
dirty_segment=""
if [[ -n "$git_dir" ]]; then
  dirty_count="${_gc_dirty:-0}"
  if (( dirty_count > 0 )); then
    printf -v dirty_icon '\xef\x81\x84'  # U+F044 nf-fa-pencil
    dirty_segment="${MUSTARD}${dirty_icon} $(_fmt_num "$dirty_count")${RESET}"
    lines_added="${_gc_added:-0}"
    lines_removed="${_gc_removed:-0}"
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
      dirty_segment+=" ${DIFF_BRACKET}[${RESET}${diff_parts}${DIFF_BRACKET}]${RESET}"
    fi
  fi
fi

# ── Multi-repo branch summary (wrapper folder with 2+ git subfolders) ──
# Repos NOT on main/master show as "folder:branch" (joined) when they fit, else
# collapse to "N branches" (off-default count). When all are on main/master,
# show "N repos" (total count). Cached for the git TTL, keyed on cwd.
_multi_branch_list=""
_multi_off_count=0
_multi_total_count=0
if (( ${#_multi_git_subs[@]} > 0 )); then
  _multi_total_count=${#_multi_git_subs[@]}
  _multi_cache_fresh=false
  _cwd_hash=$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)
  _nf_cache_path "nerdflair-multibranch-${_cwd_hash}"; _multi_cache_file="$_NF_CP"   # empty: no cache dir
  if [[ -f "$_multi_cache_file" ]]; then
    _mcache_age=$(( ${EPOCHSECONDS} - $(stat -c %Y "$_multi_cache_file" 2>/dev/null || stat -f %m "$_multi_cache_file" 2>/dev/null || echo 0) ))
    (( _mcache_age < _GIT_CACHE_TTL )) && _multi_cache_fresh=true
  fi
  if [[ "$_multi_cache_fresh" == "false" ]]; then
    _mb_list=""
    _mb_off=0
    for _sub in "${_multi_git_subs[@]}"; do
      if _nf_cmd - '' git -C "$_sub" symbolic-ref --quiet --short HEAD; then
        _sub_branch="$_NF_OUT"
      else
        _nf_cmd git:multi-branch '' git -C "$_sub" rev-parse --short HEAD \
          || [[ -n "${_NF_GIT_TIMED_OUT:-}" ]] || _nf_err git-branch "neither symbolic-ref nor rev-parse HEAD worked in $_sub"
        _sub_branch="$_NF_OUT"
      fi
      [[ -z "$_sub_branch" ]] && continue
      if [[ "$_sub_branch" == "main" || "$_sub_branch" == "master" ]]; then
        continue
      fi
      (( _mb_off++ ))
      [[ -n "$_mb_list" ]] && _mb_list+=", "
      _mb_list+="$(basename "$_sub"):${_sub_branch}"
    done
    # Cache: off-count on line 1, joined list on line 2 (list may be empty).
    if [[ -z "${_NF_GIT_TIMED_OUT:-}" ]]; then
      if [[ -n "$_multi_cache_file" ]]; then
        printf -v _mb_payload '%s\n%s' "$_mb_off" "$_mb_list"
        _nf_cache_put "$_multi_cache_file" "$_mb_payload" \
          || _nf_err "tmp-write:${_multi_cache_file##*/}" "cannot write $_multi_cache_file"
      fi
      _mb_have=1
    fi
  fi
  if [[ -n "${_mb_have:-}" ]]; then
    _multi_off_count=$_mb_off
    _multi_branch_list=$_mb_list
  else
    if [[ -r "$_multi_cache_file" ]]; then
      IFS= read -r _multi_off_count < "$_multi_cache_file"
      _multi_branch_list=$(sed -n '2,$p' "$_multi_cache_file" 2>/dev/null)
    elif [[ -z "${_NF_GIT_TIMED_OUT:-}" ]]; then
      _nf_err multi-cache-read "cannot read $_multi_cache_file"
    fi
  fi
  _multi_off_count=${_multi_off_count:-0}
  _multi_branch_list=$(_sanitize "$_multi_branch_list")
fi

printf -v ELLIPSIS '\xe2\x80\xa6'  # U+2026 horizontal ellipsis (matches spinner verb)
MIN_BRANCH=10
# Floor a single-repo branch truncates to when we shrink it to make room for
# the effort label. Above this the branch yields width to keep effort visible;
# at or below it, effort drops instead of crushing the branch further.
MIN_BRANCH_FIT=15

# Min visible chars each side (repo, branch) of a multi-repo entry keeps when
# truncated, before the colon and ELLIPSIS.
_MULTI_SIDE_MIN=5

# Separator between entries. Rendered inside the magenta branch run, so it reads
# as a purple bullet. The cached list uses ", " internally; this is applied only
# when joining for display. Its visible width is 3.
_MULTI_SEP=" · "
# Chars of the second entry shown after the first (then ELLIPSIS).
_MULTI_PEEK=5

# ── Render one "repo:branch" entry to a target visible width ────────
# Truncates repo and/or branch independently (start kept, ELLIPSIS appended),
# each floored at _MULTI_SIDE_MIN, colon always kept. Whichever side fits whole
# yields its surplus to the other; otherwise the budget (minus colon) splits
# evenly. Width is counted in characters (as _vis_len does), so wide characters (CJK repo or branch names) overflow the cells; display width is a separate change.
_render_multi_entry() {
  local _e="$1" _width=$2
  local _repo="${_e%%:*}" _br="${_e#*:}"
  local _rlen=${#_repo} _blen=${#_br}
  (( ${#_e} <= _width )) && { printf '%s' "$_e"; return; }

  local _avail=$(( _width - 1 ))  # minus colon
  (( _avail < 2 )) && _avail=2
  local _half=$(( _avail / 2 ))
  local _max_repo _max_br
  if (( _rlen <= _half )); then
    _max_repo=$_rlen
    _max_br=$(( _avail - _max_repo ))
  elif (( _blen <= _avail - _half )); then
    _max_br=$_blen
    _max_repo=$(( _avail - _max_br ))
  else
    _max_repo=$_half
    _max_br=$(( _avail - _max_repo ))
  fi
  (( _max_repo < _MULTI_SIDE_MIN )) && _max_repo=$_MULTI_SIDE_MIN
  (( _max_br < _MULTI_SIDE_MIN )) && _max_br=$_MULTI_SIDE_MIN

  local _repo_out="$_repo" _br_out="$_br"
  (( _rlen > _max_repo )) && _repo_out="${_repo:0:$((_max_repo - 1))}${ELLIPSIS}"
  (( _blen > _max_br )) && _br_out="${_br:0:$((_max_br - 1))}${ELLIPSIS}"
  printf '%s:%s' "$_repo_out" "$_br_out"
}

# ── Fit the multi-repo branch readout into a target visible width ───
# First entry, then (if a second exists) _MULTI_SEP and the second entry's first
# _MULTI_PEEK chars plus ELLIPSIS. A first entry too long for the target shrinks
# via _render_multi_entry; if it can't fit with the peek, the peek goes; if it
# can't fit alone, prints "" (caller collapses to "N branches").
_fit_multi_branches() {
  local _target=$1
  local _e1="${_multi_branch_list%%, *}" _peek="" _peek_w=0
  if [[ "$_multi_branch_list" == *", "* ]]; then
    local _e2="${_multi_branch_list#*, }"
    _e2="${_e2%%, *}"
    # Exactly two entries and a short second one: whole, no ellipsis. Never end on the colon.
    # Width is counted in characters, as vis_len does for the rest of the row.
    if [[ "$_multi_branch_list" != *", "*", "* ]] && (( ${#_e2} <= _MULTI_PEEK )); then
      _peek="${_MULTI_SEP}${_e2}"
      _peek_w=$(( 3 + ${#_e2} ))
    else
      _e2="${_e2:0:$_MULTI_PEEK}"
      _e2="${_e2%:}"
      _peek="${_MULTI_SEP}${_e2}${ELLIPSIS}"
      _peek_w=$(( 3 + ${#_e2} + 1 ))
    fi
  fi
  local _rp="${_e1%%:*}" _bp="${_e1#*:}"
  local _rmin=${#_rp} _bmin=${#_bp}
  (( _rmin > _MULTI_SIDE_MIN )) && _rmin=$(( _MULTI_SIDE_MIN + 1 ))
  (( _bmin > _MULTI_SIDE_MIN )) && _bmin=$(( _MULTI_SIDE_MIN + 1 ))
  local _floor=$(( _rmin + 1 + _bmin ))
  (( _floor > ${#_e1} )) && _floor=${#_e1}
  if [[ -n "$_peek" ]]; then
    local _w=$(( _target - _peek_w ))
    if (( _w >= _floor )); then
      printf '%s%s' "$(_render_multi_entry "$_e1" "$_w")" "$_peek"
      return
    fi
  fi
  (( _target >= _floor )) && printf '%s' "$(_render_multi_entry "$_e1" "$_target")"
  return 0
}

# ── Folder + branch segment ──────────────────────────────────────
# Folder always reflects cwd; branch comes from git_dir (which may differ).
folder_name=""
branch=""
folder_segment=""
# _branch_is_multi flags the joined multi-repo list case for the truncation and
# collapse logic below. Default it here (not only inside the guard block) so it
# is always defined when referenced later, even when there is no display dir.
_branch_is_multi=0
_display_dir="${project_dir:-$cwd}"
if [[ -n "$_display_dir" ]]; then
  # Folder name: based on project_dir (launch directory) so it stays stable
  # even when Claude cd's into subdirectories during a session
  if [[ "$_display_dir" == "$HOME" ]]; then
    folder_name=""
    _is_home=1
  else
    folder_name=$(_sanitize "$(basename "$_display_dir")")
  fi
  # Branch: prefer worktree, then cached git branch, then multi-repo summary.
  if [[ -n "$worktree_branch" ]]; then
    branch=$(_sanitize "$worktree_branch")
  elif [[ -n "${_gc_branch:-}" ]]; then
    branch=$(_sanitize "$_gc_branch")
    # Adopted subfolder off main/master: prefix "repo:" to match the multi format.
    if [[ -n "$_adopted_repo_name" && "$_gc_branch" != "main" && "$_gc_branch" != "master" ]]; then
      branch="$(_sanitize "$_adopted_repo_name"):${branch}"
    fi
  elif (( _multi_total_count > 0 )); then
    if (( _multi_off_count > 0 )); then
      # Apply the display separator now so width budgeting matches the final
      # render; _fit_multi_branches resolves the real fit once width is known.
      branch=$(_fit_multi_branches 100000)
      _branch_is_multi=1
    else
      branch="${_multi_total_count} repos"
    fi
  fi
fi

# Worktree indicator lives on the folder segment, where the worktree's directory name shows.
folder_icon=$'\xef\x86\xbb'  # U+F1BB nf-fa-tree (worktree)
if [[ "${_gc_worktree:-0}" != "1" && -z "$worktree_branch" ]]; then
  folder_icon=$'\xf3\xb0\x89\x8b'  # U+F024B nf-md-folder (normal)
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
  printf -v mcp_icon '\xef\x87\xa6'  # U+F1E6
  mcp_segment="${MCP_COLOR}${mcp_icon} ${mcp_enabled} MCP${RESET}"
  # Build expanded form with sorted names: "MCP proxy, slack" (list only, no count)
  # Also build truncated variants: "Slack, Glean, 4 more"
  if (( ${#mcp_names_sorted[@]} > 0 )); then
    _mcp_name_list=""
    for _mn in "${mcp_names_sorted[@]}"; do
      [[ -n "$_mcp_name_list" ]] && _mcp_name_list+=", "
      _mcp_name_list+="$_mn"
    done
    mcp_segment_expanded="${MCP_COLOR}${mcp_icon} ${_mcp_name_list}${RESET}"

    # Build truncated variants showing first N names + ", X more"
    _mcp_count=${#mcp_names_sorted[@]}
    mcp_segments_truncated=()
    # A CAP on names shown, not whatever the row has room for. Fitting to the
    # free width listed 9 names on a fresh session (row 2 still empty) and 3
    # once the other readouts arrived: the row jumped and every hover region
    # after it moved. Same text in every state; width only ever shortens it.
    _mcp_cap=${NERDFLAIR_MCP_NAMES:-3}
    [[ "$_mcp_cap" =~ ^-?[0-9]+$ ]] || _mcp_cap=3
    (( _mcp_cap < 1 )) && _mcp_cap=1
    (( _mcp_cap > 64 )) && _mcp_cap=64
    if (( _mcp_count > 1 )); then
      _mcp_top=$(( _mcp_count - 1 ))
      (( _mcp_count > _mcp_cap )) && _mcp_top=$_mcp_cap
      for (( _i = _mcp_top; _i >= 1; _i-- )); do
        _partial=""
        for (( _j = 0; _j < _i; _j++ )); do
          [[ -n "$_partial" ]] && _partial+=", "
          _partial+="${mcp_names_sorted[$_j]}"
        done
        _remaining=$(( _mcp_count - _i ))
        _partial+=", ${_remaining} more"
        mcp_segments_truncated+=("${MCP_COLOR}${mcp_icon} ${_partial}${RESET}")
      done
      if (( _mcp_count > _mcp_cap )); then
        # Over the cap the longest form allowed IS the first variant.
        mcp_segment_expanded="${mcp_segments_truncated[0]}"
        mcp_segments_truncated=("${mcp_segments_truncated[@]:1}")
      fi
    fi
  fi
fi


# ── Context usage segment ───────────────────────────────────────
ctx_segment=""
ctx_total=200000  # default context window size
total_used=0
pct=0

if [[ -n "$used_pct" && -n "$ctx_size" ]]; then
  # used_pct is the authoritative context fill percentage from Claude Code.
  # Derive total_used from it rather than cumulative token counts, which
  # measure something different (total tokens across all API calls).
  # used_percentage is legal as a float (the docs' own example is 23.5) and
  # bash has no float arithmetic, so the expansion below used to raise
  # "syntax error: invalid arithmetic operator" and leave the count at 0.
  # Truncate toward zero instead.
  ctx_total="${ctx_size%%.*}"
  pct="${used_pct%%.*}"
  total_used=$(( ctx_total * pct / 100 ))
else
  # Fall back: parse last usage entry from transcript JSONL
  # 2>/dev/null on every parse of the PAYLOAD: it is untrusted input, and a
  # malformed one made jq print "parse error: Invalid numeric literal" on
  # stderr. A status line has nowhere useful to write stderr, so it can surface
  # in the user's terminal, and the Rust build prints nothing there. Found by
  # tests/difftest.sh, whose stdout was byte-identical while stderr was not.
  transcript=$(echo "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
  if [[ -n "$transcript" && -f "$transcript" ]]; then
    # Only the LAST usage line is wanted, so read the tail, not the file.
    # Transcripts here reach 617 MB and this is the render path; streaming one
    # is the same mistake that took the machine down on 2026-10-08, just with a
    # different file. Every assistant message carries a usage object, so the
    # last one is a few KB from the end in practice.
    _tcap=${NERDFLAIR_TRANSCRIPT_TAIL_BYTES:-1048576}
    _tbytes=$(stat -c %s "$transcript" 2>/dev/null || stat -f %z "$transcript" 2>/dev/null || echo 0)
    _ttail=$(tail -c "$_tcap" "$transcript" 2>"$_SL_BUF.err") \
      || _nf_err ctx-transcript-read "cannot read $transcript: $(head -n 1 "$_SL_BUF.err")"
    if (( _tbytes > _tcap )); then
      if [[ "$_ttail" == *$'\n'* ]]; then _ttail="${_ttail#*$'\n'}"; else _ttail=""; fi
    fi
    # Unless the cap lands INSIDE the last line. A single assistant message
    # carrying a large tool result can exceed a megabyte on its own; the
    # partial first line is then dropped and the tail holds no usage object
    # at all, so the gauge reads 0% on a session that is nearly full. Widen
    # once rather than creep, and only in the case that would be wrong.
    if (( _tbytes > _tcap )) && [[ "$_ttail" != *'"usage"'* ]]; then
      _twide=$(( _tcap * 16 ))
      (( _twide > 67108864 )) && _twide=67108864
      _ttail=$(tail -c "$_twide" "$transcript" 2>"$_SL_BUF.err") \
        || _nf_err ctx-transcript-read "cannot read $transcript: $(head -n 1 "$_SL_BUF.err")"
      if (( _tbytes > _twide )); then
        if [[ "$_ttail" == *$'\n'* ]]; then _ttail="${_ttail#*$'\n'}"; else _ttail=""; fi
      fi
    fi
    # The NEWEST usage line that parses AND carries a usage object, not
    # simply the newest. The file is being appended to while we read it, so
    # the final line is routinely a fragment, and taking it blind made a live
    # session flicker to 0% whenever the read landed mid-write. Bounded at
    # five, so a corrupt tail cannot turn this into a scan of every line.
    last_usage=""
    while IFS= read -r _uline; do
      last_usage=$(printf '%s' "$_uline" | jq -r '.message.usage // empty' 2>/dev/null)
      [[ -n "$last_usage" && "$last_usage" != "null" ]] && break
      last_usage=""
    done < <(printf '%s\n' "$_ttail" | grep '"usage"' 2>/dev/null | tail -5 | tac)
    if [[ -n "$last_usage" && "$last_usage" != "null" ]]; then
      u_input=$(echo "$last_usage" | jq -r '.input_tokens // 0')
      u_cache_create=$(echo "$last_usage" | jq -r '.cache_creation_input_tokens // 0')
      u_cache_read=$(echo "$last_usage" | jq -r '.cache_read_input_tokens // 0')
      u_output=$(echo "$last_usage" | jq -r '.output_tokens // 0')
      for _uf in u_input u_cache_create u_cache_read u_output; do
        if [[ ! "${!_uf}" =~ ^[0-9]+$ ]]; then
          _nf_err ctx-usage-type "usage.${_uf#u_} = ${!_uf} is not an integer; counted as 0"
          printf -v "$_uf" 0
        fi
      done
      total_used=$(( u_input + u_cache_create + u_cache_read + u_output ))
      pct=$(( total_used * 100 / ctx_total ))
      (( pct > 100 )) && { _nf_err ctx-pct-clamped "computed context use ${pct}% shown as 99%"; pct=99; }
    elif [[ "$_ttail" == *'"usage"'* ]]; then
      _nf_err ctx-no-usage "no parseable message.usage in the last usage lines of $transcript; gauge reads 0%"
    fi
  elif [[ -n "$transcript" ]]; then
    # The payload had no usage figures AND the transcript it names is missing,
    # so the gauge reads 0% with nothing behind it. Expected only on the very
    # first render of a new session.
    _nf_err ctx-transcript-missing "transcript_path $transcript is not a file; context gauge reads 0%"
  fi
fi

# Default to 0 usage so we always show the context gauge (even on startup)
if [[ -z "$total_used" ]] || ! (( total_used > 0 )) 2>/dev/null; then
  total_used=0
  pct=0
fi

# ── Per-session data: chime style ────
# bell.sh writes ~/.claude/nerdflair/sessions/<session_id> on SessionStart:
#   {"chime":"StyleName"}
_SESSION_DIR="$NF_SESSION_DIR"
_session_file=""
_session_chime=""
if [[ -n "$session_id" ]]; then
  _session_file="$_SESSION_DIR/${session_id}"
  if [[ -f "$_session_file" ]]; then
    _nf_jq session-file -r '.chime // empty' "$_session_file"
    _session_chime="$_NF_JQ_OUT"
  fi
fi

# Persist last_session to shared state file (used by bell.sh to suppress
# duplicate SessionStart on compaction). Uses _nf_update_field for atomic
# jq-based update, avoiding the fragile sed-chain approach.
if [[ -n "$session_id" && "$session_id" != "$_SL_LAST_SESSION" ]]; then
  _nf_update_field "last_session" "$session_id"
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

# Context label for embedding in progress bar
ctx_label="${used_fmt}/${size_fmt} ${pct}%"

# ── Helper: visible width of an ANSI string ──────────────────────
_vis_len() {
  local s out=""
  printf -v s '%b' "$1"
  while [[ "$s" == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"; s="${s#*$'\033['}"; s="${s#*m}"
  done
  out+="$s"; printf '%s' "${#out}"
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
# Usage: _justified_row max_width left_parts_str right_parts_str
_justified_row() {
  local max_w=$1
  local max_gap=$2
  shift 2
  local left_str="$1"
  local right_str="$2"
  local left_len=$(_vis_len "$left_str")
  local right_len=$(_vis_len "$right_str")
  local pad_len=$(( max_w - left_len - right_len ))
  # max_gap > 0 caps leftover slack between two non-empty groups (row 3).
  (( max_gap > 0 && left_len > 0 && right_len > 0 && pad_len > max_gap )) && pad_len=$max_gap
  (( pad_len < 2 )) && pad_len=2
  local pad=""
  for (( p=0; p<pad_len; p++ )); do pad+=" "; done
  printf '%b%s%b%b' "$left_str" "$pad" "$right_str" "${RESET}"
}

# ── Total row width, and the bar inside it ───────────────────────
# The configured number IS the row width; the bar is that less its two cap
# glyphs. Treating it as the bar width instead made every row COLUMNS+2 wide.
#
# Claude Code draws the status line inset two columns on each side (the same
# inset its own mode line gets), so a row has COLUMNS-4 to live in. Anything
# wider is silently cut and given a trailing "…", which is what ate the right
# half of row 3 and left the padding behind as a gap. Measured on 2.1.294 at
# panes of 100 and 120 columns: 96 and 116 columns shown. NERDFLAIR_WIDTH_INSET
# retunes it if a future build insets differently or `padding` is set.
# Limits: min 50, default 80, max 150 (enforced here regardless of state)
_WIDTH_INSET=${NERDFLAIR_WIDTH_INSET:-4}
if [[ "$_SL_WIDTH" != "auto" && "$_SL_WIDTH" =~ ^[0-9]+$ ]]; then
  ROW_WIDTH=$_SL_WIDTH
else
  if [[ "$_SL_WIDTH" != "auto" && -n "$_SL_WIDTH" ]]; then
    _nf_err width-bad "configured width \"$_SL_WIDTH\" is neither \"auto\" nor a number; measuring the terminal"
  fi
  if [[ -n "${COLUMNS:-}" ]]; then
    [[ "$COLUMNS" =~ ^[0-9]+$ ]] || _nf_err columns-bad "COLUMNS=\"$COLUMNS\" is not an integer"
    _nf_cols="$COLUMNS"
  elif _nf_cols=$(tput cols 2>"$_SL_BUF.err"); then
    :
  else
    _nf_err tput "tput cols failed: $(head -n 1 "$_SL_BUF.err" 2>/dev/null)"
    _nf_cols=80
  fi
  ROW_WIDTH=$(( _nf_cols - _WIDTH_INSET ))
fi
(( ROW_WIDTH < 50 )) && ROW_WIDTH=50
(( ROW_WIDTH > 150 )) && ROW_WIDTH=150
MAX_BAR=$(( ROW_WIDTH - 2 ))

# ── Row 1: proactive budget-based truncation ──────────────────────
# Right side (dirty segment) is never truncated — measure it first.
# In minimal mode everything goes on the left, so right side is empty.
# ── Git divergence from upstream (↑ahead ↓behind) ────────────────
ahead_segment=""
if [[ -n "${_gc_ahead:-}" || -n "${_gc_behind:-}" ]] && (( ${_gc_ahead:-0} + ${_gc_behind:-0} > 0 )); then
  ahead_segment=""
  (( ${_gc_ahead:-0}  > 0 )) && ahead_segment+="${DARK_GREEN}\u2191${_gc_ahead}${RESET}"
  (( ${_gc_behind:-0} > 0 )) && { [[ -n "$ahead_segment" ]] && ahead_segment+=" "; ahead_segment+="${ALERT}\u2193${_gc_behind}${RESET}"; }
fi

row1_right="\033[0m"
if [[ "$_SL_MODE" != "minimal" ]]; then
  [[ -n "$dirty_segment" ]] && row1_right+="$dirty_segment"
  if [[ -n "$ahead_segment" ]]; then
    [[ "$row1_right" != "\033[0m" ]] && row1_right+=" "
    row1_right+="$ahead_segment"
  fi
fi
right_width=$(_vis_len "$row1_right")

# Left side budget = total width minus right side minus the gap before it (2 when a right readout exists, else 3)
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
# 2 = the gap _justified_row keeps before the right readout; 3 when there is none (unchanged)
left_budget=$(( ROW_WIDTH - right_width - (right_width > 0 ? 2 : 3) - _extra_reserve ))
(( left_budget < 20 )) && left_budget=20

# Chrome overhead on the left side (icons + spaces, not counting text):
#   folder: "󰉋 " (2)  branch: " 󰘬 " (3)  bullet: " · " (3)  model: "icon " (2)
# With branch:  2 + folder_name + 3 + branch + 3 + 2 + model_text = 10 + text
# Without branch: 2 + folder_name + 3 + 2 + model_text = 7 + text
printf -v model_icon '\xef\x94\x9b'  # U+F51B

# Build model text (may include style icon)
model_text="$model"
style_suffix=""  # icon suffix appended after model_text in the segment
if [[ -n "$output_style" && "$output_style" != "default" ]]; then
  # Match the full name, not the first letter: a custom style starting with
  # e/l/p/c would otherwise get a built-in's icon. Unknown styles still show
  # their capitalized initial.
  case "${output_style,,}" in
    explanatory) style_suffix=" "$'\xef\x81\x9a' ;;    # U+F05A
    learning)    style_suffix=" "$'\xef\x81\x99' ;;    # U+F059
    concise)     style_suffix=" "$'\xef\x81\x96' ;;    # U+F056
    proactive)   style_suffix=" "$'\xf3\xb0\xb7\xb8' ;;  # U+F0DF8
    *) _style_lower="${output_style:0:1}"; _style_lower="${_style_lower,,}"; style_suffix=" ${_style_lower^^}" ;;
  esac
fi

# ── Model-state suffixes: effort, thinking, style, fast mode ──────
# Each suffix exists in two forms: a plain-text form (measured for width
# budgeting and dropped when the model segment is truncated) and a colored
# form (used only at final assembly). Display order is effort, thinking,
# style icon, then fast mode last. Drop priority when space is tight:
# effort first, then thinking/fast glyphs, finally the style icon — mirroring
# the existing "drop suffix before truncating the name" behavior.
effort_suffix=""          # plain text, e.g. " xhigh"
effort_suffix_colored=""
if [[ -n "$effort_level" ]]; then
  effort_suffix=" ${effort_level}"
  effort_suffix_colored=" ${STATE_COLOR}${effort_level}${RESET}"
fi

# Thinking glyph (single nerd-font icon, plain length 2 because of the
# leading space).
state_suffix=""           # plain text holding the thinking glyph
state_suffix_colored=""
if [[ "$thinking_enabled" == "true" ]]; then
  printf -v _think_icon '\xf3\xb0\xa0\xa0'  # U+F0820 (thinking)
  state_suffix+=" ${_think_icon}"
  state_suffix_colored+=" ${STATE_COLOR}${_think_icon}${RESET}"
fi
# Fast mode glyph — rendered last (after the style icon) so it always sits
# at the very end of the model segment. Plain length 2 with leading space.
fast_suffix=""
fast_suffix_colored=""
if [[ "$fast_mode" == "true" ]]; then
  printf -v _fast_icon '\xf3\xb1\xa0\x87'   # U+F1807 (fast)
  fast_suffix=" ${_fast_icon}"
  fast_suffix_colored=" ${STATE_COLOR}${_fast_icon}${RESET}"
fi

# Chrome: folder or home icon(2) + bullet(3) + model_icon(2); a branch adds bullet(3) + branch_icon(2)
chrome=7
[[ -n "$branch" ]] && chrome=12

# Available text budget after chrome
text_budget=$(( left_budget - chrome ))
(( text_budget < 10 )) && text_budget=10

# Allocate: path/branch get priority, model gets the remainder
style_suffix_len=${#style_suffix}
effort_suffix_len=${#effort_suffix}
state_suffix_len=${#state_suffix}
fast_suffix_len=${#fast_suffix}
# OPT_BULLET sits between the name and the suffix run, costing 2 columns,
# but only when at least one suffix is present. Recomputed by the drop
# logic below so the budget stays honest as suffixes fall away.
_opt_bullet_width() {
  (( style_suffix_len + effort_suffix_len + state_suffix_len + fast_suffix_len > 0 )) && echo 2 || echo 0
}
model_text_len=$(( ${#model_text} + style_suffix_len + effort_suffix_len + state_suffix_len + fast_suffix_len + $(_opt_bullet_width) ))
path_len=${#folder_name}
# Visible width, not byte count: bullet/ELLIPSIS glyphs are multibyte but one
# column, so ${#branch} would overcount and distort the budget.
branch_len=$(_vis_len "$branch")
path_branch_len=$(( path_len + branch_len ))

# Model needs at least 10 chars so "icon + name" stays readable (e.g. " Opus 4.6")
min_model=10
# Reserve room for the effort label when a long single-repo branch can absorb
# the cost. The branch yields down to MIN_BRANCH_FIT to keep effort visible;
# only if it's already at/below that floor does effort drop (via the priority
# logic below). Multi-repo lists have their own fitting path and are excluded.
effort_floor=$min_model
if [[ -n "$branch" ]] && (( _branch_is_multi == 0 )) && (( effort_suffix_len > 0 )); then
  # Cost of showing effort: the label plus the OPT_BULLET separator (2 cols).
  _effort_cost=$(( effort_suffix_len + 2 ))
  # Slack the branch can give up before hitting its floor.
  _branch_slack=$(( branch_len - MIN_BRANCH_FIT ))
  (( _branch_slack < 0 )) && _branch_slack=0
  if (( _branch_slack >= _effort_cost )); then
    effort_floor=$(( min_model + _effort_cost ))
  fi
fi
# Never let the effort floor starve path and branch below their 4-column minimums.
if [[ -n "$branch" ]] && (( text_budget - effort_floor < 8 )); then
  effort_floor=$(( text_budget - 8 ))
  (( effort_floor < min_model )) && effort_floor=$min_model
fi
model_budget=$(( text_budget - path_branch_len ))
(( model_budget < effort_floor )) && model_budget=$effort_floor

# Path+branch budget is what remains after model
pb_budget=$(( text_budget - model_budget ))
# But if model fits fully, give all remaining back to path+branch
if (( model_text_len <= model_budget )); then
  model_budget=$model_text_len
  pb_budget=$(( text_budget - model_budget ))
fi

# Multi-repo list overflow: fit it (folder keeps full length, list gets the
# rest minus the model floor), or collapse to "N branches". Recompute budget
# terms afterward since the model may reclaim freed space.
# Several repos: the model keeps ALL its suffixes (effort, thinking, style, fast) and the
# branch summary takes what is left: the first entry shrunk, then the peek dropped, then
# "N branches". Only if even "N branches" plus the whole model can't fit does the older
# rule below apply (list over effort).
if (( _branch_is_multi == 1 )) && (( path_len + branch_len + model_text_len > text_budget )); then
  _full_target=$(( text_budget - path_len - model_text_len ))
  _fitted_full=$(_fit_multi_branches "$_full_target")
  _nb="${_multi_off_count} branches"
  if [[ -n "$_fitted_full" ]]; then
    branch="$_fitted_full"
  elif (( ${#_nb} <= _full_target )); then
    branch="$_nb"
  else
    _multi_min=$(( _MULTI_SIDE_MIN + 1 + _MULTI_SIDE_MIN ))  # one minimal entry
    # Prefer reserving room for the effort label: shrink the list further to keep
    # effort visible, but only if it still fits after giving up that width. If the
    # reserved target would force a collapse to "N branches", fall back to the
    # plain min_model target so we keep the list rather than the effort label.
    _model_reserve=$min_model
    if (( effort_suffix_len > 0 )); then
      _reserve_with_effort=$(( min_model + effort_suffix_len + 2 ))  # + OPT_BULLET
      _target_effort=$(( text_budget - path_len - _reserve_with_effort ))
      (( _target_effort < _multi_min )) && _target_effort=$_multi_min
      [[ -n "$(_fit_multi_branches "$_target_effort")" ]] && _model_reserve=$_reserve_with_effort
    fi
    _branch_target=$(( text_budget - path_len - _model_reserve ))
    (( _branch_target < _multi_min )) && _branch_target=$_multi_min
    _fitted=$(_fit_multi_branches "$_branch_target")
    if [[ -n "$_fitted" ]]; then
      branch="$_fitted"
    else
      branch="${_multi_off_count} branches"
    fi
  fi
  _branch_is_multi=0
  branch_len=$(_vis_len "$branch")
  path_branch_len=$(( path_len + branch_len ))
  model_budget=$(( text_budget - path_branch_len ))
  (( model_budget < min_model )) && model_budget=$min_model
  pb_budget=$(( text_budget - model_budget ))
  if (( model_text_len <= model_budget )); then
    model_budget=$model_text_len
    pb_budget=$(( text_budget - model_budget ))
  fi
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
      # Keep the start of the branch name, ellipsis at the end.
      branch="${branch:0:$((max_branch - 1))}${ELLIPSIS}"
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

# Truncate model text if needed. Drop suffixes in priority order before
# truncating the name: effort label, then thinking/fast glyphs, then the
# style icon. Re-check the budget after each drop so we keep what fits.
if (( model_text_len > model_budget )); then
  # Step 1: drop the effort label
  effort_suffix=""
  effort_suffix_colored=""
  effort_suffix_len=0
  model_text_len=$(( ${#model_text} + style_suffix_len + state_suffix_len + fast_suffix_len + $(_opt_bullet_width) ))
  # Step 2: drop thinking + fast glyphs
  if (( model_text_len > model_budget )); then
    state_suffix=""
    state_suffix_colored=""
    state_suffix_len=0
    fast_suffix=""
    fast_suffix_colored=""
    fast_suffix_len=0
    model_text_len=$(( ${#model_text} + style_suffix_len + $(_opt_bullet_width) ))
  fi
  # Step 3: drop the style icon
  if (( model_text_len > model_budget )); then
    style_suffix=""
    style_suffix_len=0
    model_text_len=${#model_text}
  fi
  # Step 4: truncate model name if still too long
  if (( model_text_len > model_budget )); then
    model_text="${model_text:0:$((model_budget - 1))}${ELLIPSIS}"
  fi
fi



# Row 1 left is assembled in up to five passes. When the right readout exists and
# the left plus a 2-column gap would push it past ROW_WIDTH (so past the bar's right
# edge), pass N shrinks one more thing: folder, branch, the model suffixes, then the
# model name. Never the right readout.
for (( _pass=0; _pass<5; _pass++ )); do
  folder_segment=""
  # Assemble folder segment
  if [[ "${_is_home:-0}" == "1" ]]; then
    if [[ -n "$branch" ]]; then
      folder_segment="${BLUE} ${BULLET}${MAGENTA}󰘬 ${branch}${RESET}"
    else
      folder_segment="${BLUE} ${RESET}"
    fi
  elif [[ -n "$folder_name" ]]; then
    if [[ -n "$branch" ]]; then
      folder_segment="${BLUE}${folder_icon} ${folder_name}${BULLET}${MAGENTA}󰘬 ${branch}${RESET}"
    else
      folder_segment="${BLUE}${folder_icon} ${folder_name}${RESET}"
    fi
  fi

  # Assemble model segment: icon + name + bullet + effort + thinking + style icon + fast.
  # Fast mode is rendered last so it always trails the segment. Suffixes use
  # their colored forms; the plain forms above were only for width.
  model_segment=""
  if [[ -n "$model_text" ]]; then
    model_segment="${CYAN}${model_icon} ${model_text}${RESET}"
    [[ -n "$effort_suffix$state_suffix$style_suffix$fast_suffix" ]] && model_segment+="${OPT_BULLET}"
    model_segment+="${effort_suffix_colored}${state_suffix_colored}${STATE_COLOR}${style_suffix}${RESET}${fast_suffix_colored}"
  fi

  # Build row 1 left
  row1_left="\033[0m"
  [[ -n "$folder_segment" ]] && row1_left+="$folder_segment"
  if [[ -n "$model_segment" ]]; then
    [[ -n "$folder_segment" ]] && row1_left+="${BULLET}"
    row1_left+="$model_segment"
  fi
  (( right_width > 0 )) && [[ "$_SL_MODE" != "minimal" ]] || break
  _over=$(( $(_vis_len "$row1_left") + 2 + right_width - ROW_WIDTH ))
  (( _over > 0 )) || break
  case $_pass in
    0) if [[ "${_is_home:-0}" != "1" ]] && (( ${#folder_name} > 2 )); then
         _n=${#folder_name}; _nl=$(( _n - _over )); (( _nl < 2 )) && _nl=2
         folder_name="${ELLIPSIS}${folder_name:$(( _n - _nl + 1 ))}"
       fi ;;
    1) if (( ${#branch} > 2 )); then
         _n=${#branch}; _nl=$(( _n - _over )); (( _nl < 2 )) && _nl=2
         branch="${branch:0:$(( _nl - 1 ))}${ELLIPSIS}"
       fi ;;
    2) effort_suffix=""; effort_suffix_colored=""; state_suffix=""; state_suffix_colored=""
       style_suffix=""; fast_suffix=""; fast_suffix_colored="" ;;
    3) if (( ${#model_text} > 2 )); then
         _n=${#model_text}; _nl=$(( _n - _over )); (( _nl < 2 )) && _nl=2
         model_text="${model_text:0:$(( _nl - 1 ))}${ELLIPSIS}"
       fi ;;
  esac
done

# Row 1: folder/branch/model + dirty (non-minimal modes render now;
# minimal deferred until after TIER arrays are defined for the pill)
if [[ "$_SL_MODE" != "minimal" ]]; then
  _justified_row "$ROW_WIDTH" 0 "$row1_left" "$row1_right"
fi

# ccusage is gone. Burn rate and billing block come from our own ledger below;
# the cross-check that used to need it is tests/validate-ledger.sh, which prices
# the transcripts by hand. (An opt-in ccusage bridge took the machine down on
# 2026-10-08, 22 runners and ~46 GB, and was kept off by default until it
# could be deleted; it has been.)

# ── Cost per repo across sessions ────────────────────────────────
# What has THIS repo cost me,
# across every session I have ever run in it". Deliberately a TSV, not SQLite:
# 19 concurrent claude processes against one SQLite file measured a worst case
# of 850ms, against a render budget of ~50ms. An append is atomic under
# O_APPEND for writes below PIPE_BUF, needs no locking, and degrades to nothing
# if the file is missing or corrupt.
#
# Rows are (epoch, session_id, repo, cost). cost is CUMULATIVE per session, so
# the reader takes the max per session_id and sums those -- appending repeatedly
# for the same session must not double-count.
#
# Opt out with NERDFLAIR_REPO_COST=0.
_REPO_COST_FILE="${NERDFLAIR_REPO_COST_FILE:-$HOME/.claude/nerdflair-usage.tsv}"
_REPO_COST_TTL=${NERDFLAIR_REPO_COST_TTL:-60}
_REPO_COST_DAYS=${NERDFLAIR_REPO_COST_DAYS:-30}
repocost_segment=""
if [[ "${NERDFLAIR_REPO_COST:-1}" != "0" && -n "$session_id" ]]; then
  # Identify the repo by its git root basename, falling back to the project dir.
  _rc_slug=""
  if [[ -n "${git_dir:-}" ]]; then
    _rc_top="${git_dir%/.git}"; _rc_top="${_rc_top%/.git/*}"
    _rc_slug="${_rc_top##*/}"
  fi
  [[ -z "$_rc_slug" && -n "$project_dir" ]] && _rc_slug="${project_dir##*/}"
  if [[ -n "$_rc_slug" ]]; then
    # No cache dir: the validated stamp dir carries the TTL marker; with neither, say so.
    _nf_cache_or_stamp "nerdflair-repocost-${UID}-${session_id//[^a-zA-Z0-9]/_}" "repocost-${session_id}"; _rc_stamp="$_NF_CP"
    [[ -z "$_rc_stamp" ]] && _nf_err repocost-skipped "repo cost is not recorded: no cache dir and no stamp dir to rate limit the ledger append"
    _rc_due=true
    if [[ -n "$_rc_stamp" && -f "$_rc_stamp" ]]; then
      _rc_age=$(( EPOCHSECONDS - $(stat -c %Y "$_rc_stamp" 2>/dev/null || stat -f %m "$_rc_stamp" 2>/dev/null || echo 0) ))
      (( _rc_age < _REPO_COST_TTL )) && _rc_due=false
    fi
    # Append at most once per TTL per session, not once per render.
    # A SHARED flock, so the many appenders never block each other but all of
    # them are excluded while the compactor holds the exclusive one. That is
    # what stops a rewrite from dropping a row appended under it.
    #
    # Non-blocking, and a failure SKIPS this sample rather than waiting: the
    # render path must not stall behind a rewrite, and the column is a
    # CUMULATIVE total, so the next sample a minute later carries everything
    # this one would have. Skipping loses nothing.
    _RC_LOCK="${_REPO_COST_FILE}.lock"
    # The Rust build calls flock(2) directly; this one shells out to
    # util-linux `flock`, which is absent on macOS and in minimal containers.
    # Without this check the subshell exits 127, so NOTHING is ever appended
    # and compaction never runs, silently and forever. A single O_APPEND write
    # is atomic, so an unlocked append is safe on its own; only compaction
    # needs exclusion, and it is skipped entirely rather than run unprotected.
    _HAVE_FLOCK=1; command -v flock >/dev/null 2>&1 || _HAVE_FLOCK=0
    # An earlier version took this same path as a mkdir lock, and a process
    # killed mid-compaction left the DIRECTORY behind. A `9>>dir` redirect
    # fails, so every append and every compaction would then fail, silently
    # and forever: the same permanent wedge flock was adopted to remove,
    # re-entering through the migration. rmdir only succeeds on an empty dir.
    [[ -d "$_RC_LOCK" ]] && rmdir "$_RC_LOCK" 2>/dev/null || true
    # Without any stamp there is no once-per-TTL limit, so appending would write a
    # ledger row every render: skip the sample (logged above as repocost-skipped).
    if [[ "$_rc_due" == "true" ]] && [[ -n "$_rc_stamp" ]] && [[ -n "$cost" ]] && [[ "$cost" != "0" ]]; then
      # Exit 75 = lock held by the compactor: contention, silent (the next
      # sample carries the total). 76 = the append itself failed. Anything else
      # is the lock redirect failing. The first two redirections are ordered
      # `2>&1` FIRST so a failing redirect's own message is captured too.
      if (( _HAVE_FLOCK )); then
        _rc_aperr=$( ( flock -s -n 9 || exit 75
          printf '%s\t%s\t%s\t%s\n' "$EPOCHSECONDS" "$session_id" "$_rc_slug" "$cost" >> "$_REPO_COST_FILE" || exit 76
        ) 2>&1 9>>"$_RC_LOCK" )
        _rc_aprc=$?
      else
        _rc_aperr=$( { printf '%s\t%s\t%s\t%s\n' "$EPOCHSECONDS" "$session_id" "$_rc_slug" "$cost" >> "$_REPO_COST_FILE" || exit 76; } 2>&1 )
        _rc_aprc=$?
      fi
      _rc_fullre='[Nn]o space|write error|Input/output|quota'
      case "$_rc_aprc" in
        0)  _nf_ok ledger-open; _nf_ok ledger-write ;;
        75) : ;;   # lock contention: correct to stay silent
        76) if [[ "$_rc_aperr" =~ $_rc_fullre ]]; then
              _nf_err ledger-write "append to $_REPO_COST_FILE failed: ${_rc_aperr%%$'\n'*}; burn, block and repo totals will go stale"
            else
              _nf_err ledger-open "cannot append to $_REPO_COST_FILE: ${_rc_aperr%%$'\n'*}; burn, block and repo totals will go stale"
            fi ;;
        *)  _nf_err flock-open "cannot open lock $_RC_LOCK (rc=$_rc_aprc): ${_rc_aperr%%$'\n'*}; ledger appends and compaction are skipped" ;;
      esac
      # Stamped whether or not the append happened, including on a missed lock.
      # The stamp rate-limits the ATTEMPT; it is not a record of success.
      # Leaving it unwritten kept _rc_due true, so every render re-read the
      # whole ledger for as long as a compaction held the lock: the per-refresh
      # cost scaling with a file that grows on its own, which is the incident
      # pattern. A skipped sample costs nothing, the column being cumulative.
      _nf_cache_put "$_rc_stamp" "" || _nf_err "tmp-write:${_rc_stamp##*/}" "cannot write $_rc_stamp"
      # Compact when the log gets big AND the cooldown has expired, writing via
      # a temp file so a reader without the lock never sees a partial.
      #
      # A size trigger alone is not a trigger, it is a treadmill: once the
      # COMPACTED file is still over the threshold, every refresh rewrites the
      # whole thing forever. That is what the 30-day rule produced, and
      # compacting to 2.4 MB against a 2 MB threshold did not fix it, it just
      # made the treadmill 12x cheaper. Gate on elapsed time as well, so a
      # rewrite happens at most once per interval no matter what the size says.
      _rc_bytes=$(stat -c %s "$_REPO_COST_FILE" 2>/dev/null || echo 0)
      _RC_DONE="${_REPO_COST_FILE}.compacted"
      _rc_cooled=true
      if [[ -f "$_RC_DONE" ]]; then
        _rcd_age=$(( EPOCHSECONDS - $(stat -c %Y "$_RC_DONE" 2>/dev/null || stat -f %m "$_RC_DONE" 2>/dev/null || echo 0) ))
        (( _rcd_age < ${NERDFLAIR_LEDGER_COMPACT_EVERY:-3600} )) && _rc_cooled=false
      fi
      if (( _rc_bytes > ${NERDFLAIR_REPO_COST_MAXBYTES:-2000000} )) && [[ "$_rc_cooled" == "true" ]] \
         && (( _HAVE_FLOCK )); then
        # EXCLUSIVE and non-blocking: one compactor at a time, and every
        # appender is excluded for the whole read-rewrite-rename, so a row
        # appended under the rewrite cannot be lost with the old inode.
        #
        # flock, not mkdir: the kernel drops it when the holder dies, so there
        # is no stale state and no breaker. A breaker shorter than the job it
        # guards does not recover a lock, it DOUBLES the work, which is what
        # took the machine down on 2026-10-08.
        (
          flock -x -n 9 || exit 1
          # Claim the cooldown FIRST, inside the lock. Stamping after the work
          # means a renderer killed mid-compaction (the host kills a slow
          # status line) never stamps, so the next refresh redoes the whole
          # rewrite holding the exclusive lock and starving every appender.
          # Stamping OUTSIDE the lock was worse still: a process that merely
          # lost the race stamped, blocking compaction for the full interval.
          : > "$_RC_DONE" 2>/dev/null || _nf_err ledger-compact-stamp "cannot write $_RC_DONE (cooldown cannot hold)"
          # Dropping only rows older than _REPO_COST_DAYS is not a bound: at 14
          # live sessions a 30-day window is ~400k rows and ~30 MB, so the 2 MB
          # trigger fired on every refresh and rewrote 30 MB each time. Bound it
          # by what each reader actually needs instead of by age alone.
          #
          # Older than FULL_DAYS, only the LAST row per session+repo survives.
          # Repo totals take the MAX cumulative cost per session, so that is
          # lossless for them; burn and block only look at the last hour and
          # the last five, both well inside the full-resolution window. The
          # result is bounded by how many sessions have ever run, not by how
          # long the machine has been up. Survivors are emitted in epoch order
          # so the file stays in append order and the tail read above keeps
          # covering the recent window. Measured on the real ledger: 396,627
          # rows / 30 MB in, 31,815 rows / 2.4 MB out.
          awk -F'\t' -v cutoff=$(( EPOCHSECONDS - _REPO_COST_DAYS*86400 )) \
              -v full_from=$(( EPOCHSECONDS - ${NERDFLAIR_LEDGER_FULL_DAYS:-3}*86400 )) \
              -v maxcost="${NERDFLAIR_REPO_COST_MAX:-100000}" '
            NF==4 && $1+0 >= 1600000000 && $1+0 <= 4000000000 \
              && $4+0 > 0 && $4+0 < maxcost && $1+0 >= cutoff {
              if ($1+0 >= full_from) { recent[++r] = $0; next }
              k = $2 "\t" $3
              if (!(k in ot) || $1+0 >= ot[k]) { ot[k] = $1+0; ol[k] = $0 }
            }
            END {
              n = 0
              for (k in ol) { n++; ts[n] = ot[k]; ln[n] = ol[k] }
              for (i = 2; i <= n; i++) {          # insertion sort by epoch,
                vt = ts[i]; vl = ln[i]; j = i - 1 # then by line, for a stable
                while (j >= 1 && (ts[j] > vt || (ts[j] == vt && ln[j] > vl))) {
                  ts[j+1] = ts[j]; ln[j+1] = ln[j]; j--
                }
                ts[j+1] = vt; ln[j+1] = vl
              }
              for (i = 1; i <= n; i++) print ln[i]
              for (i = 1; i <= r; i++) print recent[i]
            }' "$_REPO_COST_FILE" > "${_REPO_COST_FILE}.tmp" 2>"$_SL_BUF.err"
          _rc_awkrc=$?
          # Refuse to replace a ledger that HAD rows with one that has none. A
          # clock jumping past the retention window makes cutoff exceed every
          # row, so the filter keeps nothing and the rename would wipe the
          # history. Count rows rather than trusting awk's exit status: an awk
          # that exits 0 after a short write (full disk) yields a believable
          # truncated file. fsync before the rename, because the rename is
          # atomic in the directory but the DATA need not have reached disk.
          _rc_in=$(awk -F'\t' 'NF==4 && $1+0 >= 1600000000 && $1+0 <= 4000000000 && $4+0 > 0' "$_REPO_COST_FILE" 2>/dev/null | wc -l)
          _rc_out=$(wc -l < "${_REPO_COST_FILE}.tmp" 2>/dev/null || echo 0)
          _rc_all=$(grep -c . "$_REPO_COST_FILE" 2>/dev/null || true)
          if (( _rc_awkrc != 0 )); then
            _nf_err ledger-compact-write "awk compaction of $_REPO_COST_FILE failed (rc=$_rc_awkrc): $(head -n 1 "$_SL_BUF.err"); old ledger kept"
            rm -f "${_REPO_COST_FILE}.tmp" 2>/dev/null
          elif (( _rc_in > 0 && _rc_out == 0 )); then
            # The refusal is right, but a ledger stuck over its size cap with the
            # time gate retrying hourly is something the owner must be told.
            _nf_err ledger-compact-refused "$_rc_in valid rows but none survive the cutoff; refusing to wipe $_REPO_COST_FILE (clock jump?)"
            rm -f "${_REPO_COST_FILE}.tmp" 2>/dev/null
          else
            # Compaction deletes rows for good: say how many were not even
            # well-formed (the readers skip those silently on the hot path).
            (( ${_rc_all:-0} > _rc_in )) \
              && _nf_err ledger-compact-dropped "$(( _rc_all - _rc_in )) malformed ledger rows removed from $_REPO_COST_FILE ($_rc_in valid rows seen)"
            sync "${_REPO_COST_FILE}.tmp" 2>/dev/null \
              || _nf_err ledger-compact-write "sync of ${_REPO_COST_FILE}.tmp failed; renaming anyway"
            if _rc_mverr=$(mv -f "${_REPO_COST_FILE}.tmp" "$_REPO_COST_FILE" 2>&1); then
              _nf_ok ledger-compact-write
            else
              _nf_err ledger-compact-write "compacting $_REPO_COST_FILE failed: ${_rc_mverr%%$'\n'*}; old ledger kept, retried after the cooldown"
              rm -f "${_REPO_COST_FILE}.tmp" 2>/dev/null
            fi
          fi
        ) 9>>"$_RC_LOCK" 2>/dev/null
      fi
    fi
    # One awk pass over the log costs ~7ms, which is 14% of the render budget --
    # far too much for a number that moves once a minute. Recompute only on the
    # same cadence as the append, and read the memoised value otherwise.
    _nf_cache_or_stamp "nerdflair-repocost-total-${UID}-${_rc_slug//[^a-zA-Z0-9]/_}" "repocost-total-${_rc_slug}"; _rc_memo="$_NF_CP"
    _rc_total=""
    if [[ "$_rc_due" == "false" && -n "$_rc_memo" && -r "$_rc_memo" ]]; then
      _rc_total=$(<"$_rc_memo")
    elif [[ -e "$_REPO_COST_FILE" && ! -r "$_REPO_COST_FILE" ]]; then
      _nf_err ledger-read "$_REPO_COST_FILE exists but is not readable; repo total unavailable"
    elif [[ -r "$_REPO_COST_FILE" ]]; then
      # Bounded tail (twin of ledger_tail): a ledger compaction has not kept small must not cost a full read.
      _rc_tcap=${NERDFLAIR_REPO_TOTAL_TAIL_BYTES:-16777216}
      (( _rc_tcap < 4096 )) && _rc_tcap=4096; (( _rc_tcap > 67108864 )) && _rc_tcap=67108864
      _rc_tcut=0; (( $(stat -c %s "$_REPO_COST_FILE" 2>/dev/null || echo 0) > _rc_tcap )) && _rc_tcut=1
      _rc_total=$(if (( _rc_tcut )); then tail -c "$_rc_tcap" "$_REPO_COST_FILE" | tail -n +2; else cat "$_REPO_COST_FILE"; fi | awk -F'\t' -v repo="$_rc_slug" -v cutoff=$(( EPOCHSECONDS - _REPO_COST_DAYS*86400 )) \
                      -v maxcost="${NERDFLAIR_REPO_COST_MAX:-100000}" '
        NF==4 && $1+0 >= 1600000000 && $1+0 <= 4000000000 && $4+0 > 0 && $4+0 < maxcost && $1+0 >= cutoff && $3 == repo { if ($4+0 > m[$2]) m[$2] = $4+0 }
        END { t=0; for (k in m) t += m[k]; if (t > 0) printf "%.2f", t }
      ' 2>"$_SL_BUF.err") \
        || _nf_err ledger-read "awk repo total over $_REPO_COST_FILE failed: $(head -n 1 "$_SL_BUF.err")"
      if (( _rc_tcut )) && [[ -n "$_rc_total" ]]; then
        _rc_total="~${_rc_total}"
        _nf_err repo-total-cut "ledger is larger than NERDFLAIR_REPO_TOTAL_TAIL_BYTES; repo total is a lower bound (~); compaction is not keeping up"
      fi
      if [[ -n "$_rc_memo" ]]; then
        _nf_cache_put "$_rc_memo" "$_rc_total" || _nf_err "tmp-write:${_rc_memo##*/}" "cannot write $_rc_memo"
      fi
    fi
    if [[ -n "$_rc_total" && "$_rc_total" != "0.00" ]]; then
        printf -v _rc_icon '\xef\x90\x81'   # U+F401 nf-oct-repo
      [[ "$_rc_total" == "~"* ]] && repocost_segment="${DARK_GREEN}${_rc_icon} ~\$${_rc_total#\~}${RESET}" \
        || repocost_segment="${DARK_GREEN}${_rc_icon} \$${_rc_total}${RESET}"
    else
      # Slug resolved, nothing in the ledger yet: a stable dim placeholder, not a segment that appears later.
      printf -v _rc_icon '\xef\x90\x81'
      repocost_segment="${DIM}${_rc_icon} \$--${RESET}"
    fi
  fi
fi

# ── MCP health (stale-while-revalidate) ──────────────────────────
# `claude mcp list` actually probes every server, measured at ~1937 ms here, so
# it can never be synchronous. Same contract as the other background jobs: render the
# cached verdict, fork a detached refresh when stale. TTL is long because MCP
# connectivity changes on the timescale of an auth expiring, not a render.
#
# Opt out with NERDFLAIR_MCP_HEALTH=0.
_MCP_HEALTH_TTL=${NERDFLAIR_MCP_HEALTH_TTL:-300}
_mcp_ok=""; _mcp_bad=""; _mcp_warn=""
if [[ "${NERDFLAIR_MCP_HEALTH:-1}" != "0" ]] && ! command -v claude &>/dev/null; then
  # The segment simply vanishes; say why (once an hour).
  _nf_err mcp-no-claude "claude is not on PATH; MCP health probe disabled"
fi
if [[ "${NERDFLAIR_MCP_HEALTH:-1}" != "0" && -n "$_MCP_CACHE" ]] && command -v claude &>/dev/null; then
  _mh_cache="$_MCP_CACHE"
  # ONE probe at a time per user: every project's job takes the same lock, a render that loses shows the last
  # cached value. (A test's NERDFLAIR_MCP_CACHE override keeps a lock of its own.)
  if [[ -n "${NERDFLAIR_MCP_CACHE:-}" ]]; then _mh_lock="${_mh_cache}.lock"
  else _mh_lock="${_mh_cache%/*}/nerdflair-mcphealth-${UID}.lock"; fi
  # Daily: delete per-project probe files untouched for 14+ days (twin of prune_mcp_caches).
  if [[ -z "${NERDFLAIR_MCP_CACHE:-}" ]]; then
    _nf_cache_path "nerdflair-mcphealth-prune-${UID}"; _pr_stamp="$_NF_CP"
    if [[ -n "$_pr_stamp" ]] && (( $(_nf_stamp_age "$_pr_stamp") >= 86400 )); then
      if _nf_cache_put "$_pr_stamp" ""; then
        _pr_max=$(( ${NERDFLAIR_MCP_PRUNE_DAYS:-14} * 86400 ))
        # One rule for every file here, same in Rust and in the rc prune: regular files only (no symlinks, no
        # directories), and a future-dated file is kept (it reads as "infinitely old", not a reason to delete).
        # The old shared file nerdflair-mcphealth-UID (no project suffix, never read since the per-project change) goes too.
        for _pr_f in "${_mh_cache%/*}/nerdflair-mcphealth-${UID}-"* "${_mh_cache%/*}/nerdflair-mcphealth-${UID}"; do
          [[ -f "$_pr_f" && ! -L "$_pr_f" ]] || continue
          _pr_a=$(_nf_stamp_age "$_pr_f")
          (( _pr_a >= _pr_max && _pr_a < 4611686018427387903 )) && { rm -f -- "$_pr_f" 2>/dev/null || _nf_err mcp-prune "cannot remove $_pr_f"; }
        done
        # Same pass, same age (NERDFLAIR_MCP_PRUNE_DAYS): per-session repo-cost stamps (not the -total-
        # memo) and orphan `nerdflair-*.tmp.*` files (a writer killed between create and rename).
        for _pr_f in "${_mh_cache%/*}/nerdflair-repocost-${UID}-"* "${_mh_cache%/*}/nerdflair-"*.tmp.*; do
          [[ -f "$_pr_f" && ! -L "$_pr_f" ]] || continue
          _pr_a=$(_nf_stamp_age "$_pr_f")
          (( _pr_a >= _pr_max && _pr_a < 4611686018427387903 )) && { rm -f -- "$_pr_f" 2>/dev/null || _nf_err mcp-prune "cannot remove $_pr_f"; }
        done
      else _nf_err "tmp-write:${_pr_stamp##*/}" "cannot write $_pr_stamp"; fi
    fi
  fi
  _mh_fresh=false
  if [[ -f "$_mh_cache" ]]; then
    _mh_age=$(( EPOCHSECONDS - $(stat -c %Y "$_mh_cache" 2>/dev/null || stat -f %m "$_mh_cache" 2>/dev/null || echo 0) ))
    (( _mh_age < _MCP_HEALTH_TTL )) && _mh_fresh=true
    # `read` exits 1 at EOF without a trailing newline (the probe writes none),
    # variables ARE set: the `|| true` is correct. Unreadable is not silent.
    if [[ -r "$_mh_cache" ]]; then
      IFS=$'\x1f' read -r _mcp_ok _mcp_bad _mcp_warn _mcp_probe_names < "$_mh_cache" || true
      if [[ -s "$_mh_cache" ]] && { [[ ! "$_mcp_ok" =~ ^[0-9]+$ ]] || [[ ! "$_mcp_bad" =~ ^[0-9]+$ ]] || [[ ! "$_mcp_warn" =~ ^[0-9]+$ ]]; }; then
        _nf_err mcp-cache-garbled "$_mh_cache does not hold three integers; health shows 0/0"
      fi
    else
      _nf_err mcp-cache-read "$_mh_cache exists but is not readable"
    fi
  fi
  # A leftover DIRECTORY from the previous mkdir-lock scheme would make the
  # `9>>` redirect below fail forever. rmdir only succeeds on an empty one.
  [[ -d "$_mh_lock" ]] && rmdir "$_mh_lock" 2>/dev/null || true
  # flock, not a mkdir lock with a stale-breaker. The breaker WAS the
  # 2026-10-08 failure: a runner slower than the breaker gets a second runner
  # started on top of it and the pile only grows. This probe still had that
  # shape, just slower (a 300s breaker against a 30s timeout), and it is
  # reachable whenever `claude mcp list` hangs rather than exits: WSL 9p I/O,
  # or a child ignoring SIGTERM. A live flock holder blocks a second runner
  # however long it has held it, and the kernel releases it when the holder
  # dies, so no breaker is needed and nothing can pile up.
  #
  # The lock is taken by the JOB, inside the subshell that outlives this
  # render, not here: a flock belongs to the open file description and one
  # taken out here would be released microseconds later when the render exits.
  #
  # `timeout -k 5`: plain timeout sends only TERM, and a process ignoring it
  # runs forever.
  if [[ "$_mh_fresh" == "false" ]]; then
    (
      [[ -n "${_mcp_key_dir:-}" ]] && { cd "$_mcp_key_dir" 2>/dev/null || true; }
      exec 9>>"$_mh_lock" 2>/dev/null \
        || { _nf_err flock-open "cannot open MCP probe lock $_mh_lock; probe never runs"; exit 0; }
      flock -n 9 || exit 0   # a probe already running: normal, silent
      # The probe's stderr goes to an unguessable mktemp file, never to a
      # predictable name in shared /tmp that a planted symlink could redirect.
      _mh_err=$(mktemp "${TMPDIR:-/tmp}/nerdflair-mcperr.XXXXXX" 2>/dev/null) || _mh_err=/dev/null
      _raw=$(timeout -k 5 "${NERDFLAIR_MCP_PROBE_TIMEOUT:-30}" claude mcp list 9>&- 2>"$_mh_err"); _rc=$?   # 9>&-: the probe and the servers it spawns must not inherit the lock
      _out=$(printf '%s\n' "$_raw" | sed 's/\x1b\[[0-9;]*m//g')
      _o=0; _b=0; _w=0; _nm=""
      while IFS= read -r _ln; do
        case "$_ln" in
          *"Connected"*)            (( _o++ )) ;;
          *"Failed to connect"*)    (( _b++ )) ;;
          *"Needs authentication"*) (( _w++ )) ;;
          *) continue ;;
        esac
        # "<name>: <url> - <status>". The name itself may contain colons
        # ("plugin:context7:context7"), so cut the status off first, then take
        # everything before the LAST ": " -- that is the url separator.
        _nn="${_ln%% - *}"; _nn="${_nn%: *}"
        # plugin:<pkg>:<server> reads better as just <server>
        case "$_nn" in
          plugin:*)    _nn="${_nn##*:}" ;;
          "claude.ai "*) _nn="${_nn#claude.ai }" ;;   # built-in connectors
        esac
        if [[ -n "$_nn" ]]; then
          [[ -n "$_nm" ]] && _nm+=$'\x1e'
          _nm+="$_nn"
        fi
      done <<< "$_out"
      # Touch the cache even on failure. It used to be written ONLY on a
      # successful probe, so a failing or timing-out `claude mcp list` left
      # _mh_fresh false forever and the next render started another one: a
      # 100% duty cycle of a command that spawns every MCP server, on a
      # machine already slow enough to have caused the failure. The TTL now
      # gates the retries and the last known values stay on screen.
      # Why did it fail? A probe that keeps failing leaves the cache stale for
      # days while the segment shows a healthy-looking count.
      _why=""
      if (( _rc != 0 )); then
        _why="claude mcp list exited $_rc ($( (( _rc == 124 )) && echo timeout || echo failed))"
      elif (( _o + _b + _w == 0 )) && [[ -n "$_raw" ]] && ! grep -qi 'no mcp servers' <<< "$_raw"; then
        _why="claude mcp list printed no parseable server lines"
      fi
      if [[ -n "$_why" ]]; then
        _nf_err mcp-probe "$_why; first output: $(printf '%s %s' "$_raw" "$(cat "$_mh_err" 2>/dev/null)" | head -n 1 | cut -c1-160)"
      else
        _nf_ok mcp-probe
      fi
      [[ "$_mh_err" != /dev/null ]] && rm -f "$_mh_err"
      if (( _o + _b + _w == 0 )); then touch "$_mh_cache" 2>/dev/null || true; fi
      (( _o + _b + _w > 0 )) && { printf '%s\x1f%s\x1f%s\x1f%s' "$_o" "$_b" "$_w" "$_nm" > "${_mh_cache}.tmp" \
        && mv -f "${_mh_cache}.tmp" "$_mh_cache" \
        || _nf_err mcp-probe-write "cannot update $_mh_cache"; }
    ) &>/dev/null &
    disown 2>/dev/null || true
  fi
fi

# Format a Unix-epoch-seconds countdown as "3h12m" / "47m". Empty if past.
_fmt_countdown() {
  local _target="$1" _now _delta
  [[ -z "$_target" ]] && return 0
  _now=${EPOCHSECONDS}
  _delta=$(( _target - _now ))
  (( _delta <= 0 )) && return 0
  if (( _delta >= 172800 )); then
    printf '%dd' $(( _delta / 86400 ))
  elif (( _delta >= 3600 )); then
    printf '%dh%02dm' $(( _delta / 3600 )) $(( (_delta % 3600) / 60 ))
  else
    printf '%dm' $(( _delta / 60 ))
  fi
}

# ── Build time + cost segments for row 3 ─────────────────────────
time_segment=""
printf -v cost_icon '\xef\x85\x95'       # U+F155 dollar
printf -v time_icon '\xef\x80\x97'       # U+F017 clock

# ── Per-session sampler ──────────────────────────────────────────
# Throughput and the compaction ETA are both RATES, and neither can be derived
# from a single payload: the payload carries CUMULATIVE api time but only the
# LAST response's output tokens, and a cumulative context percentage with no
# indication of how fast it got there. So remember the previous sample.
#
# One file per session_id, so the 14+ concurrent Claude Code sessions on this
# machine never contend. agent-teams agents are FULL sessions with their own
# session_id, not helpers sharing this one, so per-session is the right grain.
# Written with one printf to a temp file then renamed: a reader never sees a
# partial line, and there is no lock to go stale.
# ── Per-session sample ring ──────────────────────────────────────
# A ring of recent observations, not just the previous one. The compaction ETA
# is a slope, and a slope from TWO points is maximally noisy: one large tool
# result spikes it, one quick turn collapses it. Keeping a short history lets a
# robust estimator throw the outliers away (see the ETA block below).
#
# File format v2: first line is "v2 <last_rate>", then up to _SMP_KEEP lines of
#   <epoch> <used10> <api_ms>
# oldest first. One file per session_id, so the many concurrent Claude Code
# sessions never contend; written temp-then-rename so a reader never tears.
_SMP_KEEP=${NERDFLAIR_SAMPLES:-16}
_SMP_NUM='(0|[1-9][0-9]{0,14})'   # canonical non-negative integer, no leading zero
_smp_prev_api=""; _smp_prev_used10=""; _smp_prev_epoch=""; _smp_prev_rate=""
_smp_hist=()
_smp_file=""
if [[ -n "$session_id" ]]; then
  _nf_cache_path "nerdflair-sample-${UID}-${session_id//[^a-zA-Z0-9]/_}"; _smp_file="$_NF_CP"   # empty: no cache dir, no history
  if [[ -n "$_smp_file" && -r "$_smp_file" ]]; then
    _smp_ln=0; _smp_bad=""
    # canonical digits only (no leading zero: '08' is invalid octal in (( ))): these words reach (( )) below, where a bare word is evaluated as a variable name
    while IFS= read -r _sl || [[ -n "$_sl" ]]; do
      if (( _smp_ln == 0 )); then
        if [[ "$_sl" == v2\ * ]]; then
          if [[ "${_sl#v2 }" =~ ^$_SMP_NUM$ ]]; then _smp_prev_rate="${_sl#v2 }"; else _smp_bad=1; fi
        else
          # v1: "api used10 epoch rate" on one line. Read it, then let it be
          # rewritten in v2 on this render.
          if [[ "$_sl" =~ ^$_SMP_NUM\ $_SMP_NUM\ $_SMP_NUM\ $_SMP_NUM$ ]]; then
            IFS=' ' read -r _smp_v1_api _smp_v1_used10 _smp_v1_epoch _smp_prev_rate <<< "$_sl"
            _smp_hist+=("$_smp_v1_epoch $_smp_v1_used10 $_smp_v1_api")
          elif [[ -n "$_sl" ]]; then _smp_bad=1; fi
          break
        fi
      else
        if [[ "$_sl" =~ ^$_SMP_NUM\ $_SMP_NUM\ $_SMP_NUM$ ]]; then _smp_hist+=("$_sl")
        elif [[ -n "$_sl" ]]; then _smp_bad=1; fi
      fi
      (( _smp_ln++ ))
    done < "$_smp_file"
    [[ -n "$_smp_bad" ]] && _nf_err sample-read "$_smp_file has malformed lines; ignored (ETA history restarts)"
    # newest entry also feeds the two-point paths below
    if (( ${#_smp_hist[@]} > 0 )); then
      IFS=' ' read -r _smp_prev_epoch _smp_prev_used10 _smp_prev_api <<< "${_smp_hist[-1]}"
    fi
  fi
fi
# used_percentage is legitimately fractional; keep a tenth of a point.
_used10=""
if [[ -n "$used_pct" ]]; then
  _u_int=${used_pct%%.*}; _u_frac=${used_pct#*.}
  [[ "$_u_frac" == "$used_pct" ]] && _u_frac=0
  _used10=$(( ${_u_int:-0} * 10 + ${_u_frac:0:1} ))
fi

TIME_COLOR="$MAUVE"
api_fmt=""
if [[ -n "$total_api_ms" && "$total_api_ms" -gt 999 ]] 2>/dev/null; then
  api_fmt=$(_fmt_duration "$total_api_ms")
  time_segment="${TIME_COLOR}${time_icon} ${api_fmt}${RESET}"
fi

# ── Token throughput ─────────────────────────────────────────────
# context_window.total_output_tokens is the LAST response's output, not a
# running total -- verified against this session's transcript: 432 for the last
# response against a cumulative 1,158,497. Dividing it by CUMULATIVE api time
# produced a figure that shrank as the session aged and sat at 0 or 1 forever.
# The right denominator is how long that one response took, i.e. the growth in
# cost.total_api_duration_ms since the previous sample.
speed_segment=""
_rate_now=""
if [[ -n "$output_tokens" && -n "$total_api_ms" && -n "$_smp_prev_api" ]] \
   && (( output_tokens > 0 && total_api_ms > _smp_prev_api )) 2>/dev/null; then
  _d_api=$(( total_api_ms - _smp_prev_api ))
  if (( _d_api > 0 )); then
    _cand=$(( output_tokens * 1000 / _d_api ))
    # Reject nonsense from a clock jump, a resume, or a compaction reset.
    (( _cand > 0 && _cand < 10000 )) && _rate_now=$_cand
  fi
fi
# Between responses the api clock does not advance, so hold the last real rate
# instead of flickering to nothing on every intermediate render.
_rate_show="${_rate_now:-$_smp_prev_rate}"
if [[ -n "$_rate_show" ]] && (( _rate_show > 0 )) 2>/dev/null; then
  if (( _rate_show >= 1000 )); then
    _speed_fmt="$(( _rate_show / 1000 )).$(( _rate_show % 1000 / 100 ))k"
  else
    _speed_fmt="$_rate_show"
  fi
  speed_segment="${MAUVE}󰓅 ${_speed_fmt}/s${RESET}"
elif [[ -n "$output_tokens" && -n "$total_api_ms" ]]; then
  # Tokens and api time are in the payload but no rate exists yet: a stable dim placeholder.
  speed_segment="${DIM}󰓅 --/s${RESET}"
fi

COST_COLOR="${COST_GREEN}"
formatted_cost=$(printf '%.2f' "${cost:-0}")
formatted_cost="$(_fmt_num "${formatted_cost%.*}").${formatted_cost#*.}"
cost_segment=""
if [[ "$formatted_cost" != "0.00" ]]; then
  cost_segment="${COST_COLOR}${cost_icon}${formatted_cost}${RESET}"
fi

# ── Ledger tail, shared by burn rate and billing block ───────────
# Both figures used to come from ccusage, which re-walked 9.6 GB of transcripts
# per call to learn what this ledger already records once a minute. Read the
# TAIL of it instead: the ledger is append-only, so the tail IS the recent
# window and the read costs a bounded number of bytes however long the machine
# has been up. Never stream the whole file from here.
#
# Append order is time order only to within concurrent-append jitter. Measured
# on the real ledger: 878 inversions with a largest backstep of 22s, but those
# are BETWEEN sessions, and 0 of 32,007 rows invert WITHIN one session, which is
# the only ordering _window_spend depends on. It filters each row by its own
# timestamp regardless, and skips a row that goes backwards within a session.
#
# How much history the cap covers is a RATE, not a constant: cap divided by
# bytes written per hour, which scales with how many sessions are live. Measured
# 2026-10-08 at about 25 KB/h (roughly 340 rows/h), so the 1 MiB default held
# about 40 hours; with 14 fully active sessions it is nearer 16. Do not quote a
# fixed number of hours, and re-measure before relying on one.
_LEDGER_CAP=${NERDFLAIR_LEDGER_TAIL_BYTES:-1048576}
_LEDGER_MAXCOST=${NERDFLAIR_REPO_COST_MAX:-100000}
_LEDGER_FILE=${NERDFLAIR_REPO_COST_FILE:-$HOME/.claude/nerdflair-usage.tsv}
_ledger=""
_ledger_cut=0   # the file was CUT: a window reaching past the cap is undercounted
if [[ -f "$_LEDGER_FILE" ]]; then
  _lg_bytes=$(stat -c %s "$_LEDGER_FILE" 2>/dev/null || stat -f %z "$_LEDGER_FILE" 2>/dev/null || echo 0)
  if _ledger=$(tail -c "$_LEDGER_CAP" "$_LEDGER_FILE" 2>"$_SL_BUF.err"); then
    _nf_ok ledger-read
  else
    # Looks exactly like "no ledger yet" downstream, so it must not be silent.
    _ledger=""
    _nf_err ledger-read "cannot read $_LEDGER_FILE: $(head -n 1 "$_SL_BUF.err")"
  fi
  # A tail that did not start at byte 0 begins mid-record; that partial line
  # would parse as a row with a truncated epoch or cost.
  if (( _lg_bytes > _LEDGER_CAP )); then
    _ledger_cut=1
    if [[ "$_ledger" == *$'\n'* ]]; then _ledger="${_ledger#*$'\n'}"; else _ledger=""; fi
    # The block can start up to 5 h back. If the cut tail starts later than that, widen ONCE (16x, twin of the
    # Rust side) instead of hiding burn and block at high activity.
    _lg_first=${_ledger%%$'\t'*}; [[ "$_lg_first" =~ ^[0-9]+$ ]] || _lg_first=0
    if (( _lg_first == 0 || _lg_first > EPOCHSECONDS - 18000 )); then
      _lg_wide=$(( _LEDGER_CAP * 16 )); (( _lg_wide > 67108864 )) && _lg_wide=67108864
      if (( _lg_wide > _LEDGER_CAP )) && _ledger=$(tail -c "$_lg_wide" "$_LEDGER_FILE" 2>"$_SL_BUF.err"); then
        if (( _lg_bytes > _lg_wide )); then
          if [[ "$_ledger" == *$'\n'* ]]; then _ledger="${_ledger#*$'\n'}"; else _ledger=""; fi
        else _ledger_cut=0; fi
      fi
    fi
  fi
fi

# Dollars spent within [since, now] and the span the samples cover.
#
# Cost is cumulative per session but NOT monotonic: a session that is resumed,
# compacted or restarted reports a lower total than before. Measured on the
# real ledger 2026-10-08: 11 sessions with 12 drops, including 677.62 ->
# 435.53 and 517.19 -> 0.94, one of them an hour old. Ordinary behaviour, not
# incident debris.
#
# Taking (last - first) across such a drop yields a negative, which then gets
# discarded, silently throwing away EVERYTHING that session spent in the
# window. Summing the positive increments between consecutive samples is
# reset-proof: a drop contributes nothing and the spend either side still
# counts.
#
# Consecutive means consecutive IN FILE ORDER, and file order is NOT reliably
# time order within a session. Two renders of one session can both find the
# sample stamp expired, both take the SHARED lock (which by design does not
# exclude them from each other), and append in the order they finish rather than
# the order they read the clock. 0 of 32,007 live rows invert this way, so it is
# rare, not impossible.
#
# An out-of-order row is SKIPPED rather than taken as the next sample. Feeding
# it in as one runs the increment chain backwards: the later-but-lower
# cumulative cost becomes the new baseline, and the real rise above it is then
# charged against a number that already contained it, so the spend between the
# swapped pair is dropped. Compaction cannot reorder anything, keeping at most
# one pre-cutoff row per session. The measured 22s of jitter is BETWEEN
# sessions, which does not matter here.
_window_spend() {  # $1=since $2=now -> "<spent> <span> <oldest> <newest>"
  printf '%s\n' "$_ledger" | awk -F'\t' \
    -v since="$1" -v now="$2" -v maxcost="$_LEDGER_MAXCOST" '
    NF == 4 {
      # int() to match the Rust build, which truncates before comparing.
      # The ledger writes integer epochs, so this is unreachable in practice
      # and is here so the two cannot drift if that ever changes.
      t = int($1 + 0); v = $4 + 0
      if (t < 1600000000 || t > 4000000000) next
      if (v <= 0 || v >= maxcost) next
      if (t < since || t > now) next
      s = $2
      if (!(s in pv)) { gain[s] = 0; pv[s] = v; ft[s] = t; lt[s] = t; next }
      # lt[s] is the newest epoch accepted for this session, so t < lt[s] is
      # exactly the inversion above. An equal epoch is kept: two rows can
      # share a second legitimately.
      if (t < lt[s]) next
      if (v > pv[s]) gain[s] += v - pv[s]
      pv[s] = v
      if (t < ft[s]) ft[s] = t
      lt[s] = t
    }
    END {
      # The first in-window row of a session is its BASELINE, so spend before
      # it is not counted and the total is a lower bound. Counting it instead
      # was tried and reverted: a session resuming after an idle hour has no
      # earlier row either, and its first row carries its whole cumulative
      # cost, so waking up would add the entire session to the hourly burn.
      # See the note on window_spend in main.rs.
      total = 0; lo = ""; hi = ""
      # Sorted, so the float summation order matches the Rust build and does
      # not depend on the hash order of either.
      n = 0
      for (s in pv) ids[++n] = s
      for (i = 1; i < n; i++)
        for (j = i + 1; j <= n; j++)
          if (ids[j] < ids[i]) { tmp = ids[i]; ids[i] = ids[j]; ids[j] = tmp }
      for (i = 1; i <= n; i++) {
        s = ids[i]
        total += gain[s]
        if (lo == "" || ft[s] < lo) lo = ft[s]
        if (hi == "" || lt[s] > hi) hi = lt[s]
      }
      if (lo == "") { printf "0 0 0 0"; exit }
      span = (hi > lo) ? hi - lo : 0
      # oldest and newest let the caller tell a window it COVERS from one it
      # only sampled the recent end of, and a live rate from a stale one.
      printf "%.10f %d %d %d", total, span, lo, hi
    }'
}

# ── Burn rate ($/hr) ─────────────────────────────────────────────
# A ROLLING rate over the last hour across every session, which is what "burn
# rate" should mean. Needs BURN_MIN_SPAN of samples before dividing: over a
# couple of minutes the quotient swings wildly and reads as noise. Falls back
# to this session's own lifetime average when the ledger is too young.
# Suppressed under 2 minutes of wall clock -- a 10-second session divides into
# an absurd hourly rate and the number is noise, not signal.
printf -v burn_icon '\xf3\xb0\x88\xb8'   # U+F0238 md-fire
burn_segment=""
_burn_val=""
if [[ -n "$_ledger" ]]; then
  _bw=${NERDFLAIR_BURN_WINDOW:-3600}
  _bmin=${NERDFLAIR_BURN_MIN_SPAN:-600}
  # Two sampling intervals. Past that the newest sample is not evidence of
  # anything happening NOW: dividing old spend by its own span keeps printing
  # the rate it was going at when work stopped, so an idle machine shows a
  # healthy burn for as long as the window is wide.
  _bstale=${NERDFLAIR_BURN_STALE_AFTER:-180}
  read -r _bspent _bspan _bold _bnew < <(_window_spend "$(( EPOCHSECONDS - _bw ))" "$EPOCHSECONDS")
  # A cut tail that does not reach the window start means the earliest spend
  # is simply missing, and an undercount looks like a real figure.
  _bcov=1
  (( _ledger_cut == 1 )) && { (( _bold > 0 && _bold <= EPOCHSECONDS - _bw )) || _bcov=0; }
  (( _bcov == 0 )) && _nf_err ledger-uncovered "tail cap ${_LEDGER_CAP} bytes does not reach the burn window start; burn hidden (raise NERDFLAIR_LEDGER_TAIL_BYTES)" 86400
  if (( _bspan > 0 && _bspan >= _bmin && _bcov == 1 && EPOCHSECONDS - _bnew <= _bstale )) 2>/dev/null; then
    _burn_val=$(awk "BEGIN {s=${_bspent:-0}; if (s>0) printf \"%.2f\", s / (${_bspan} / 3600.0)}" 2>"$_SL_BUF.err") \
      || _nf_err burn-awk "awk burn rate failed: $(head -n 1 "$_SL_BUF.err")"
  fi
fi
if [[ -z "$_burn_val" && -n "$cost" && -n "$total_duration_ms" ]] \
   && (( total_duration_ms > 120000 )) 2>/dev/null; then
  _burn_val=$(awk "BEGIN {printf \"%.2f\", ${cost:-0} / (${total_duration_ms} / 3600000)}" 2>"$_SL_BUF.err") \
    || _nf_err burn-awk "awk session burn rate failed: $(head -n 1 "$_SL_BUF.err")"
fi
if [[ -n "$_burn_val" && "$_burn_val" != 0 && "$_burn_val" != 0.00 ]]; then
  # Threshold colours: green under $20/hr, mustard to $50, alert above.
  _burn_color="$COST_GREEN"
  (( ${_burn_val%%.*} >= 20 )) 2>/dev/null && _burn_color="$MUSTARD"
  (( ${_burn_val%%.*} >= 50 )) 2>/dev/null && _burn_color="$ALERT"
  burn_segment="${_burn_color}${burn_icon} \$${_burn_val}/h${RESET}"
fi

# ── Rate-limit windows: payload, derived, or last-known ──────────
# Claude Code drops a window once its resets_at passes, and sends none before
# the session's first response, each independently. A window in the payload is
# shown as is; 5h missing while 7d is present means the 5h window lapsed
# (nothing used), a dim 0%; both missing falls back to the account-wide record
# (limits-last), and the record's live 5h beats the derived 0%. Read-merge-write is unlocked: a race
# between sessions costs at most one stale window, healed by the next write after 30 s. Nothing is invented: no record means no segment, silently.
# Twin of the rate-limit resolution block in rust/src/main.rs.
_rl_h5=${rl_5h_pct%.*}; _rl_h7=${rl_7d_pct%.*}
_rl_has5=0; _rl_has7=0
[[ -n "$_rl_h5" ]] && _rl_has5=1
[[ -n "$_rl_h7" ]] && _rl_has7=1
_rl_rec5=""; _rl_rec7=""     # "pct:resets_at" or empty
_rl_tok_ok() { [[ "$1" == - ]] || [[ "$1" =~ ^$_SMP_NUM:$_SMP_NUM$ ]]; }
_rl_digits() { [[ "$1" =~ ^[0-9]{1,15}$ ]]; }
_RL_CUR=""
_rl_cur() {   # pct reset -> _RL_CUR "p:r" when both are plain numbers and reset > 0
  _RL_CUR=""
  _rl_digits "$1" && _rl_digits "$2" && (( 10#$2 > 0 && 10#$2 <= EPOCHSECONDS + 691200 )) && _RL_CUR="$(( 10#$1 > 100 ? 100 : 10#$1 )):$((10#$2))"
  return 0
}
_nf_cache_path "limits-last"; _rl_file="$_NF_CP"
if [[ -n "$_rl_file" && -e "$_rl_file" ]]; then
  _rl_line=""
  if { IFS= read -r _rl_line || [[ -n "$_rl_line" ]]; } 2>/dev/null < "$_rl_file"; then
    _rl_t0=""; _rl_t1=""; _rl_t2=""; _rl_tx=""
    read -r _rl_t0 _rl_t1 _rl_t2 _rl_tx <<< "$_rl_line"
    # Single spaces only (read would also split on tabs and runs of spaces); Rust splits on ' '.
    _rl_shape=0; [[ "$_rl_line" =~ ^v1\ [^\ ]+\ [^\ ]+$ ]] && _rl_shape=1
    if (( _rl_shape )) && [[ "$_rl_t0" == v1 && -z "$_rl_tx" && -n "$_rl_t2" ]] && _rl_tok_ok "$_rl_t1" && _rl_tok_ok "$_rl_t2"; then
      # A reset more than ~8 days ahead cannot be real: corrupt, as in Rust. Percent is clamped to 100.
      if { [[ "$_rl_t1" == - ]] || (( ${_rl_t1#*:} <= EPOCHSECONDS + 691200 )); } \
         && { [[ "$_rl_t2" == - ]] || (( ${_rl_t2#*:} <= EPOCHSECONDS + 691200 )); }; then
        [[ "$_rl_t1" != - ]] && _rl_rec5="$(( ${_rl_t1%%:*} > 100 ? 100 : ${_rl_t1%%:*} )):${_rl_t1#*:}"
        [[ "$_rl_t2" != - ]] && _rl_rec7="$(( ${_rl_t2%%:*} > 100 ? 100 : ${_rl_t2%%:*} )):${_rl_t2#*:}"
      else
        _nf_err limits-last "${_rl_file} is corrupt; last-known 5h/7d limits ignored"
      fi
    else
      _nf_err limits-last "${_rl_file} is corrupt; last-known 5h/7d limits ignored"
    fi
  else
    _nf_err limits-last "cannot read ${_rl_file}; last-known 5h/7d limits unavailable"
  fi
fi
if (( _rl_has5 || _rl_has7 )) && [[ -n "$_rl_file" ]]; then
  _rl_p5=""; _rl_p7=""
  (( _rl_has5 )) && { _rl_cur "$_rl_h5" "$rl_5h_reset"; _rl_p5="$_RL_CUR"; }
  (( _rl_has7 )) && { _rl_cur "$_rl_h7" "$rl_7d_reset"; _rl_p7="$_RL_CUR"; }
  if [[ -n "${_rl_p5}${_rl_p7}" ]]; then
    _rl_write=1
    if [[ -f "$_rl_file" ]]; then
      # A future mtime (clock stepped back) counts as old, as file_age does in Rust.
      _rl_age=$(( EPOCHSECONDS - $(stat -c %Y "$_rl_file" 2>/dev/null || stat -f %m "$_rl_file" 2>/dev/null || echo 0) ))
      (( _rl_age >= 0 && _rl_age < 30 )) && _rl_write=0
    fi
    if (( _rl_write )); then
      _rl_m5="${_rl_p5:-$_rl_rec5}"; _rl_m7="${_rl_p7:-$_rl_rec7}"
      _nf_cache_put "$_rl_file" "v1 ${_rl_m5:--} ${_rl_m7:--}"$'\n' \
        || _nf_err limits-last-write "cannot write ${_rl_file}; last-known limits will not be kept"
    fi
  fi
fi
_rl_blk_idle=0; _rl_blk_reset=""
_rl_rec5_live=0
[[ -n "$_rl_rec5" ]] && (( ${_rl_rec5#*:} > EPOCHSECONDS )) && _rl_rec5_live=1
if (( _rl_has5 )); then
  _rl_blk_reset="$rl_5h_reset"
elif (( _rl_has7 && ! _rl_rec5_live )); then
  _rl_blk_idle=1
elif [[ -n "$_rl_rec5" ]]; then
  if (( ${_rl_rec5#*:} <= EPOCHSECONDS )); then _rl_blk_idle=1; else _rl_blk_reset="${_rl_rec5#*:}"; fi
fi

# ── Billing block: spend in the 5-hour rate-limit window ─────────
printf -v block_icon '\xef\x82\x94'       # U+F094 moon-o / block marker
block_segment=""
# Spend inside the CURRENT five-hour rate-limit window, from our own ledger.
# The window is the payload's own rate_limits.five_hour.resets_at less five
# hours, so this is pinned to the block Anthropic is actually metering rather
# than to a guess of our own. Without that field there is no block to report,
# and a made-up window would be worse than none.
if (( _rl_blk_idle )); then
  # The 5h window is lapsed (derived 0%): idle, not a vanished segment.
  block_segment="${DIM}${block_icon} idle${RESET}"
elif [[ -n "$_ledger" && -n "${_rl_blk_reset:-}" ]]; then
  if (( _rl_blk_reset > 0 )) 2>/dev/null; then
    _blk_start=$(( _rl_blk_reset - 18000 ))
    # EPOCHSECONDS >= rl_5h_reset means the window in the payload has already
    # lapsed and the host has not refreshed it yet, which is the normal state
    # on the first render after a session wakes. Summing to now then spans the
    # lapsed block AND the time since, so a resets_at one hour stale reported
    # SIX hours of spend as the current block: measured $282.99 against a true
    # $163. Say idle rather than invent a number.
    if (( EPOCHSECONDS >= _rl_blk_reset )); then
      block_segment="${DIM}${block_icon} idle${RESET}"
    elif (( EPOCHSECONDS >= _blk_start )); then
      read -r _kspent _kspan _kold _knew < <(_window_spend "$_blk_start" "$EPOCHSECONDS")
      # Suppress rather than undercount: unlike the burn rate this is an
      # absolute amount of money, and a quietly low one is read as fact.
      _kcov=1
      (( _ledger_cut == 1 )) && { (( _kold > 0 && _kold <= _blk_start )) || _kcov=0; }
      (( _kcov == 0 )) && _nf_err ledger-uncovered "tail cap ${_LEDGER_CAP} bytes does not reach the billing block start; block hidden (raise NERDFLAIR_LEDGER_TAIL_BYTES)" 86400
      if (( _kcov == 1 )); then
        _kfmt=$(awk "BEGIN {s=${_kspent:-0}; if (s>0) printf \"%.2f\", s}" 2>"$_SL_BUF.err") \
          || _nf_err burn-awk "awk billing block failed: $(head -n 1 "$_SL_BUF.err")"
        # The ROUNDED figure decides: under half a cent prints as 0.00, which
        # reads as money and is really nothing.
        if [[ -n "$_kfmt" && "$_kfmt" != "0.00" ]]; then
          block_segment="${MAUVE}${block_icon} \$${_kfmt}${RESET}"
        else
          block_segment="${DIM}${block_icon} idle${RESET}"
        fi
      fi
    fi
  fi
fi

# ── MCP health ───────────────────────────────────────────────────
# Distinct from the existing MCP segment, which counts what is CONFIGURED.
# This one reports what actually connected. Hidden until the async probe lands.
mcphealth_segment=""
if [[ -n "$_mcp_ok" ]]; then
  _mh_tot=$(( ${_mcp_ok:-0} + ${_mcp_bad:-0} + ${_mcp_warn:-0} ))
  if (( _mh_tot > 0 )); then
    _mh_color="$DARK_GREEN"
    (( ${_mcp_warn:-0} > 0 )) && _mh_color="$MUSTARD"
    (( ${_mcp_bad:-0}  > 0 )) && _mh_color="$ALERT"
    mcphealth_segment="${_mh_color}${mcp_icon:-}${_mcp_ok}/${_mh_tot}${RESET}"
    (( ${_mcp_bad:-0}  > 0 )) && mcphealth_segment+="${ALERT}\u2717${_mcp_bad}${RESET}"
    (( ${_mcp_warn:-0} > 0 )) && mcphealth_segment+="${MUSTARD}!${_mcp_warn}${RESET}"
  fi
fi

# ── Time to auto-compaction ──────────────────────────────────────
# Estimates when the context window fills. Three things make this better than
# differencing the last two samples:
#
#  1. THEIL-SEN instead of a single difference. Take the slope between every
#     pair of samples and use the MEDIAN. A single pair is maximally noisy --
#     one large tool result spikes it, one short turn collapses it -- whereas
#     the median of pairwise slopes tolerates roughly 29% outliers before it
#     breaks, needs no matrix arithmetic, and is a few integer ops.
#
#  2. IDLE EXCLUSION. Wall-clock elapsed counts time you were away from the
#     keyboard as time the window was filling, which halves the apparent rate
#     after any break. Pairs spanning a gap longer than _CP_IDLE are dropped;
#     ordinary think-time is kept because that genuinely is your working pace.
#
#  3. A CONFIDENCE SIGNAL. When the pairwise slopes disagree badly the estimate
#     is a guess, and saying so is more useful than a precise-looking number.
#     A wide spread prefixes the value with "~".
#
# Falls back to a two-point delta, then to the session average, so a fresh
# session still shows something.
_CP_TARGET=${NERDFLAIR_COMPACT_AT_TENTHS:-1000}
_CP_IDLE=${NERDFLAIR_ETA_IDLE_GAP:-900}
compact_segment=""
_ctx_dropped=""
_cp_secs=""
_cp_fuzzy=""

# Detect a compaction: the newest reading is below the previous one.
if [[ -n "$_used10" && -n "$_smp_prev_used10" ]] && (( _used10 < _smp_prev_used10 )) 2>/dev/null; then
  _ctx_dropped=1
fi

if [[ -z "$_ctx_dropped" && -n "$_used10" ]] && (( ${#_smp_hist[@]} >= 3 )); then
  # Build the pairwise slope set, in tenths of a point per 1000 seconds.
  _slopes=()
  _hn=${#_smp_hist[@]}
  for (( _i=0; _i<_hn; _i++ )); do
    IFS=' ' read -r _ti _ui _ <<< "${_smp_hist[_i]}"
    for (( _j=_i+1; _j<_hn; _j++ )); do
      IFS=' ' read -r _tj _uj _ <<< "${_smp_hist[_j]}"
      _dt=$(( _tj - _ti )); _du=$(( _uj - _ui ))
      (( _dt <= 0 || _du <= 0 )) && continue
      (( _dt > _CP_IDLE )) && continue        # spans an idle gap
      _slopes+=( $(( _du * 1000 / _dt )) )
    done
  done
  if (( ${#_slopes[@]} >= 3 )); then
    # median (and quartiles for the spread) via an insertion sort -- the list is
    # at most 45 items for a 10-sample ring, so this is cheap and fork-free.
    _sorted=(); for _v in "${_slopes[@]}"; do
      _k=${#_sorted[@]}
      _sorted+=("$_v")
      while (( _k > 0 && _sorted[_k-1] > _v )); do
        _sorted[_k]=${_sorted[_k-1]}; _sorted[_k-1]=$_v; (( _k-- ))
      done
    done
    _sn=${#_sorted[@]}
    _med=${_sorted[_sn/2]}
    _q1=${_sorted[_sn/4]}
    _q3=${_sorted[(3*_sn)/4]}
    if (( _med > 0 )); then
      _cp_secs=$(( (_CP_TARGET - _used10) * 1000 / _med ))
      # Spread wider than the median itself means the slopes disagree badly.
      (( (_q3 - _q1) * 2 > _med )) && _cp_fuzzy="~"
    fi
  fi
fi

# Fallback 1: the two most recent samples.
if [[ -z "$_cp_secs" && -z "$_ctx_dropped" && -n "$_used10" && -n "$_smp_prev_used10" && -n "$_smp_prev_epoch" ]]; then
  _d_used10=$(( _used10 - _smp_prev_used10 ))
  _d_secs=$(( EPOCHSECONDS - _smp_prev_epoch ))
  if (( _d_used10 > 0 && _d_secs > 0 && _d_secs <= _CP_IDLE && _used10 < _CP_TARGET )); then
    _cp_secs=$(( (_CP_TARGET - _used10) * _d_secs / _d_used10 ))
    _cp_fuzzy="~"
  fi
fi

# Fallback 2: the session average, for a session with no usable history yet.
if [[ -z "$_cp_secs" && -z "$_ctx_dropped" && -n "$_used10" && -n "$total_duration_ms" ]] \
   && (( total_duration_ms > 120000 && _used10 > 0 && _used10 < _CP_TARGET )) 2>/dev/null; then
  _cp_secs=$(( (_CP_TARGET - _used10) * (total_duration_ms / 1000) / _used10 ))
  _cp_fuzzy="~"
fi

if [[ -n "$_cp_secs" && -n "$_used10" ]] && (( _cp_secs > 0 && _used10 >= 50 && _used10 < _CP_TARGET )) 2>/dev/null; then
  _cp_color="$DIM"
  (( _cp_secs < 900 )) && _cp_color="$MUSTARD"
  (( _cp_secs < 300 )) && _cp_color="$ALERT"
  # Round to the precision the estimate actually has. Backtested over 31,191
  # predictions from 12 real sessions, the median absolute error of the best
  # configuration is ~68% -- context fills in bursts (one tool result can add
  # tens of thousands of tokens), so it is intrinsically hard to predict.
  # Printing "6h47m" against that error bar claims a precision that does not
  # exist. Round to roughly a tenth of the value and always mark it an estimate.
  if (( _cp_secs >= 86400 )); then
    _cp_fmt=">1d"
  elif (( _cp_secs >= 3600 )); then
    _cp_q=$(( (_cp_secs + 450) / 900 ))            # nearest quarter hour
    printf -v _cp_fmt '%dh%02dm' $(( _cp_q / 4 )) $(( (_cp_q % 4) * 15 ))
  elif (( _cp_secs >= 300 )); then
    printf -v _cp_fmt '%dm' $(( ((_cp_secs + 150) / 300) * 5 ))   # nearest 5 min
  else
    _cp_fmt="<5m"
  fi
  compact_segment="${_cp_color}\xf3\xb0\x94\x9f ~${_cp_fmt}${RESET}"
fi
# No estimate is drawn (under 5% used, too few samples, ...) but the used% is known: keep the slot, dim.
if [[ -z "$compact_segment" && -n "$_used10" ]]; then
  compact_segment="${DIM}\xf3\xb0\x94\x9f ~--${RESET}"
fi


# ── Persist this sample ──────────────────────────────────────────
# Append to the ring, drop the oldest beyond _SMP_KEEP, write temp-then-rename.
# Only when something actually moved, so an idle pane re-rendering on the 30s
# timer does not churn the disk or pollute the slope set with zero-delta pairs.
if [[ -n "$_smp_file" ]]; then
  # Never write a value the reader above refuses (fractional, negative, 16+ digits, leading
  # zero): it would drop the whole history next render. Twin of main.rs (writes 0).
  _smp_api_w=${total_api_ms:-0}; _smp_u_w=${_used10:-0}; _smp_r_w=${_rate_show:-0}
  [[ "$_smp_api_w" =~ ^$_SMP_NUM$ ]] || _smp_api_w=0
  [[ "$_smp_u_w" =~ ^$_SMP_NUM$ ]] || _smp_u_w=0
  [[ "$_smp_r_w" =~ ^$_SMP_NUM$ ]] || _smp_r_w=0
  _smp_moved=0
  if (( ${#_smp_hist[@]} == 0 )); then
    _smp_moved=1
  elif [[ "${_smp_api_w} ${_smp_u_w}" != "${_smp_prev_api:-} ${_smp_prev_used10:-}" ]]; then
    _smp_moved=1
  fi
  if (( _smp_moved )); then
    # A compaction invalidates every earlier point: the window it described is
    # gone. Start the ring over from here rather than averaging across the cut.
    if [[ -n "$_ctx_dropped" ]]; then
      _smp_hist=()
    fi
    _smp_hist+=("${EPOCHSECONDS} ${_smp_u_w} ${_smp_api_w}")
    while (( ${#_smp_hist[@]} > _SMP_KEEP )); do
      _smp_hist=("${_smp_hist[@]:1}")
    done
    printf -v _smp_body 'v2 %s\n' "$_smp_r_w"
    printf -v _smp_lines '%s\n' "${_smp_hist[@]}"
    _nf_cache_put "$_smp_file" "${_smp_body}${_smp_lines}" \
      && _nf_ok sample-write \
      || _nf_err sample-write "cannot write or rename ${_smp_file}; ETA/throughput history will not accumulate"
  fi
fi


# ── tmux session name ────────────────────────────────────────────
# 1ms measured, and only when actually inside tmux. Many parallel sessions
# across panes make "which one am I looking at" a real question.
tmux_segment=""
if [[ -n "${TMUX_PANE:-}" ]] && command -v tmux &>/dev/null; then
  # `tmux display-message` is only ~1ms standalone but ~3.3ms inside the render
  # path. The session name for a given pane changes about never, so cache it
  # per-pane. Renaming a session costs you one stale minute.
  _nf_cache_path "nerdflair-tmux-${UID}-${TMUX_PANE//[^a-zA-Z0-9]/_}"; _tx_cache="$_NF_CP"   # empty: no cache dir
  _tmux_name=""
  if [[ -n "$_tx_cache" && -f "$_tx_cache" ]]; then
    _tx_age=$(( EPOCHSECONDS - $(stat -c %Y "$_tx_cache" 2>/dev/null || stat -f %m "$_tx_cache" 2>/dev/null || echo 0) ))
    (( _tx_age < 60 )) && _tmux_name=$(<"$_tx_cache")
  fi
  if [[ -z "$_tmux_name" ]]; then
    _nf_cmd tmux '' tmux display-message -p '#S' \
      || _nf_err tmux "tmux display-message failed; session name segment hidden"
    _tmux_name="$_NF_OUT"
    if [[ -n "$_tmux_name" && -n "$_tx_cache" ]]; then
      _nf_cache_put "$_tx_cache" "$_tmux_name" || _nf_err "tmp-write:${_tx_cache##*/}" "cannot write $_tx_cache"
    fi
  fi
  [[ -n "$_tmux_name" ]] && tmux_segment="${DIM}\uea85 ${_tmux_name}${RESET}"
fi

# ── Remote Control ───────────────────────────────────────────────
# Written by the band plugin (`nerdflair-statusline --rc-sync`) into the private cache dir as
# rc-<session id>: `v1 on|off|unknown <since-epoch> <label>`. Nothing here can ask Claude Code, so
# this only reads. No file = plugin not loaded = no segment. A corrupt file, or an "on" or "off" over 120 s
# old (the plugin rewrites it every 30 s), draws UNKNOWN in amber and logs once. Twin of rc.rs.
# The record's file name for a session id: ONE rule, twin of rc::rc_name. Keep ASCII [A-Za-z0-9_-],
# every other BYTE becomes _ (hence LC_ALL=C), cap at 64; when anything was changed or cut, append
# ~<POSIX cksum of the raw id>, so a/b and a_b cannot share a file (~ is outside the clean alphabet, so a
# clean id can never be spelled like a modified one). Only forks when it must.
_nf_rc_name() {
  local LC_ALL=C _m _crc
  _m="${1//[^A-Za-z0-9_-]/_}"
  if [[ "$_m" == "$1" && ${#_m} -le 64 ]]; then _NF_RCN="rc-$_m"; return 0; fi
  read -r _crc _ < <(printf '%s' "$1" | cksum)
  _NF_RCN="rc-${_m:0:64}~$_crc"
}
rc_segment=""
if [[ -n "$session_id" ]]; then
  _nf_rc_name "$session_id"; _nf_cache_path "$_NF_RCN"; _rc_file="$_NF_CP"
  if [[ -n "$_rc_file" && -e "$_rc_file" ]]; then
    _rc_st="unknown"; _rc_lab=""
    _rc_re='^v1 (on|off|unknown) ([0-9]{1,15})( ([A-Za-z0-9 +._-]{0,24}))?$'
    _rc_line=""
    if { IFS= read -r _rc_line || [[ -n "$_rc_line" ]]; } 2>/dev/null < "$_rc_file"; then
      if [[ "$_rc_line" =~ $_rc_re ]]; then
        _rc_st="${BASH_REMATCH[1]}"; _rc_lab="${BASH_REMATCH[4]}"
        if [[ "$_rc_st" != unknown ]]; then
          _rc_age=$(( EPOCHSECONDS - $(stat -c %Y "$_rc_file" 2>/dev/null || stat -f %m "$_rc_file" 2>/dev/null || echo 0) ))
          if (( _rc_age < 0 || _rc_age > 120 )); then
            _nf_err rc-stale "${_rc_file} is over 120 s old; the band plugin is not refreshing it, remote control state unknown"
            _rc_st="unknown"
          fi
        fi
      else
        _nf_err rc "${_rc_file} is corrupt; remote control state unknown"
      fi
    else
      _nf_err rc "cannot read ${_rc_file}; remote control state unknown"
    fi
    case "$_rc_st" in
      on)  rc_segment="\033[38;2;74;222;128m\u2b24 RC ${_rc_lab:-on}${RESET}" ;;
      off) rc_segment="\033[38;2;75;85;99m\u25ef RC ${_rc_lab:-off}${RESET}" ;;
      *)   rc_segment="\033[38;2;251;191;36m? RC unknown${RESET}" ;;
    esac
  fi
fi

# ── Plan rate limits (5h / 7d) ───────────────────────────────────
# Straight from the Claude Code payload -- no subprocess, no network. Absent on
# plans without rate limits, and until the first API response of the session.
limits_segment=""
_rl_part() {
  local _pct="$1" _reset="$2" _label="$3" _color _cd
  [[ -z "$_pct" ]] && return 0
  _pct=${_pct%.*}
  [[ -z "$_pct" ]] && return 0
  [[ "$_pct" =~ ^[0-9]{1,15}$ ]] && (( 10#$_pct > 100 )) && _pct=100
  _color="$DARK_GREEN"
  (( _pct >= 60 )) && _color="$MUSTARD"
  (( _pct >= 85 )) && _color="$ALERT"
  printf '%s' "${_color}${_label}${_pct}%${RESET}"
  _cd=$(_fmt_countdown "$_reset")
  [[ -n "$_cd" ]] && printf '%s' "${DIM}/${_cd}${RESET}"
}
_rl_dim() {   # label rec -> _RL_D: dim last-known figure with countdown, or dim 0% once its reset passed
  local _l="$1" _r="$2" _cd
  _RL_D=""; [[ -z "$_r" ]] && return 0
  if (( ${_r#*:} > EPOCHSECONDS )); then
    _cd=$(_fmt_countdown "${_r#*:}")
    _RL_D="${DIM}${_l}${_r%%:*}%${_cd:+/$_cd}${RESET}"
  else
    _RL_D="${DIM}${_l}0%${RESET}"
  fi
}
if (( _rl_has5 )); then _rl5=$(_rl_part "$rl_5h_pct" "$rl_5h_reset" "5h ")
elif (( _rl_has7 && ! _rl_rec5_live )); then _rl5="${DIM}5h 0%${RESET}"
else _rl_dim "5h " "$_rl_rec5"; _rl5="$_RL_D"; fi
if (( _rl_has7 )); then _rl7=$(_rl_part "$rl_7d_pct" "$rl_7d_reset" "7d ")
else _rl_dim "7d " "$_rl_rec7"; _rl7="$_RL_D"; fi
if [[ -n "$_rl5" || -n "$_rl7" ]]; then
  limits_segment="$_rl5"
  [[ -n "$_rl5" && -n "$_rl7" ]] && limits_segment+="${DIM} ${RESET}"
  limits_segment+="$_rl7"
fi

# ── Row 3 (built here, printed last): left: mcp | right: time · cost
# Build right side first so we can measure it for MCP name fit check
row3_right="\033[0m"

# Always resolve chime style label for display
_chime_label=""
if [[ -n "${_SL_CHIME_VOLUME:-1}" && "${_SL_CHIME_VOLUME:-1}" != 0 && "${_SL_CHIME_VOLUME:-1}" != 0.0 ]]; then
  # Use cached chime value from session JSON (read earlier)
  _session_resolved="$_session_chime"
  if [[ -n "$_session_resolved" && "$_session_resolved" != "random" ]]; then
    _chime_label="$_session_resolved"
  elif [[ "$_SL_CHIME_STYLE" == "random" && -f "$NF_STATE_FILE" ]]; then
    # No per-session style yet — show the last entry from chime_recent_styles
    _nf_jq chime-label-read -r '.chime_recent_styles // [] | last // empty' "$NF_STATE_FILE" && _last_recent="$_NF_JQ_OUT" || _last_recent=""
    _chime_label="${_last_recent:-random}"
  elif [[ -n "$_SL_CHIME_STYLE" ]]; then
    _chime_label="$_SL_CHIME_STYLE"
  fi
fi

# Build chime style segment
# Only show the resolved style name when on "random" and before any cost is incurred
_chime_label=$(_sanitize "$_chime_label")
_chime_segment=""
if [[ -n "$_chime_label" ]]; then
  _show_label=false
  if [[ "$_SL_CHIME_STYLE" == "random" && "$formatted_cost" == "0.00" ]]; then
    _show_label=true
  fi
  printf -v _vol_icon '\xef\x80\xa8'  # U+F028  volume icon
  _vol_pct=$(awk -v v="${_SL_CHIME_VOLUME:-1}" 'BEGIN {printf "%g", v * 100}')
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
  if [[ -n "$tmux_segment" ]]; then
    row3_right+="${tmux_segment}${BULLET}"
  fi
  if [[ -n "$rc_segment" ]]; then
    row3_right+="${rc_segment}${BULLET}"
  fi
  if [[ -n "$mcphealth_segment" ]]; then
    row3_right+="${mcphealth_segment}${BULLET}"
  fi
  if [[ -n "$limits_segment" ]]; then
    row3_right+="${limits_segment}${BULLET}"
  fi
  if [[ -n "$compact_segment" ]]; then
    row3_right+="${compact_segment}${BULLET}"
  fi
  if [[ -n "$speed_segment" ]]; then
    row3_right+="${speed_segment}${BULLET}"
  fi
  if [[ -n "$time_segment" ]]; then
    row3_right+="${time_segment}${BULLET}"
  fi
  if [[ -n "$burn_segment" ]]; then
    row3_right+="${burn_segment}${BULLET}"
  fi
  if [[ -n "$block_segment" ]]; then
    row3_right+="${block_segment}${BULLET}"
  fi
  if [[ -n "$repocost_segment" ]]; then
    row3_right+="${repocost_segment}${BULLET}"
  fi
  row3_right+="$cost_segment"
else
  # No cost yet (fresh session): the same list as above minus the cost itself.
  # Only what has no data is dropped.
  _pre=""
  for _extra in "$_chime_segment" "$tmux_segment" "$rc_segment" "$mcphealth_segment" "$limits_segment" "$compact_segment" \
                "$speed_segment" "$time_segment" "$burn_segment" "$block_segment" "$repocost_segment"; do
    [[ -z "$_extra" ]] && continue
    [[ -n "$_pre" ]] && _pre+="$BULLET"
    _pre+="$_extra"
  done
  row3_right+="$_pre"
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
    (( _clen + _row3_right_len + 2 <= ROW_WIDTH ))
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
elif [[ -n "$time_segment" || -n "$cost_segment" || -n "$_chime_segment" || -n "$speed_segment" \
     || -n "$burn_segment" || -n "$block_segment" || -n "$limits_segment" \
     || -n "$mcphealth_segment" || -n "$rc_segment" || -n "$compact_segment" || -n "$repocost_segment" ]]; then
  # No MCP servers — show cost/time/speed/chime on the left instead of right
  if [[ -n "$cost_segment" ]]; then
    row3_left+="$cost_segment"
    [[ -n "$time_segment" ]] && row3_left+="${BULLET}${time_segment}"
    [[ -n "$speed_segment" ]] && row3_left+="${BULLET}${speed_segment}"
  elif [[ -n "$time_segment" ]]; then
    row3_left+="$time_segment"
    [[ -n "$speed_segment" ]] && row3_left+="${BULLET}${speed_segment}"
  fi
  for _extra in "$tmux_segment" "$rc_segment" "$burn_segment" "$block_segment" "$repocost_segment" "$limits_segment" "$mcphealth_segment" "$compact_segment"; do
    [[ -z "$_extra" ]] && continue
    [[ "$row3_left" != "\033[0m" ]] && row3_left+="${BULLET}"
    row3_left+="$_extra"
  done
  [[ -n "$_chime_segment" ]] && { [[ "$row3_left" != "\033[0m" ]] && row3_left+="${BULLET}"; row3_left+="$_chime_segment"; }
  # Clear right side to avoid duplication
  row3_right="\033[0m"
  _row3_right_len=$(_vis_len "$row3_right")
fi

# ── Row 2: progress bar with Powerline caps ─────────────────────
bar_width=$ROW_WIDTH

# Bar fill colors — 10-tier gradient: grey-green, green, gold, orange
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
EMPTY_BG="\033[48;2;35;38;45m"
EMPTY_FG="\033[38;2;35;38;45m"
LIGHT_FG="\033[38;2;85;90;100m"    # dim text on empty bg
LABEL_COVERED_FG="\033[38;2;18;20;25m"  # near-black label text on filled bar

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
  EMPTY_BG="\033[48;2;38;38;38m"
  EMPTY_FG="\033[38;2;38;38;38m"
  LIGHT_FG="\033[38;2;90;90;90m"
  LABEL_COVERED_FG="\033[38;2;22;22;22m"
elif [[ "$_SL_COLOR_MODE" == "muted" ]]; then
  # Muted gradient: same green, yellow, orange hues, reduced saturation (~40%)
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
  EMPTY_BG="\033[48;2;38;40;45m"
  EMPTY_FG="\033[38;2;38;40;45m"
  LIGHT_FG="\033[38;2;88;92;102m"
  LABEL_COVERED_FG="\033[38;2;20;24;20m"
fi

# ── Smooth gradient control points per color mode ────────────────
# 10 control points (one per tier), linearly interpolated per-cell in _render_bar.
# Default: grey-green, green, gold, orange, red at the very end
GRAD_BG_R=(48 50 55 65  88  115 140 160 180 200)
GRAD_BG_G=(62 74 88 105 112 116 122 125 120 55)
GRAD_BG_B=(48 48 50 52  54  55  58  60  58  50)

if [[ "$_SL_COLOR_MODE" == "mono" ]]; then
  # Monochrome: dark grey to bright grey, subtle brightness ramp
  GRAD_BG_R=(45 55 65 76 88  100 115 132 155 185)
  GRAD_BG_G=(45 55 65 76 88  100 115 132 155 185)
  GRAD_BG_B=(45 55 65 76 88  100 115 132 155 185)
elif [[ "$_SL_COLOR_MODE" == "muted" ]]; then
  # Muted: same hue progression as default but desaturated (~40% saturation)
  GRAD_BG_R=(48 52 55 62 76  92  110 132 150 168)
  GRAD_BG_G=(52 58 65 74 86  96  104 108 104 68)
  GRAD_BG_B=(50 52 54 56 58  58  60  62  60  56)
fi

# Powerline semicircle glyphs
printf -v PL_RIGHT '\xee\x82\xb4'  # U+E0B4 right semicircle (closing cap)
printf -v PL_LEFT '\xee\x82\xb6'   # U+E0B6 left semicircle (opening cap)

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
  _justified_row "$ROW_WIDTH" 0 "$row1_left" "\033[0m"
fi

# ── _compute_gradient_cache: pre-compute per-cell ANSI colors ────
# Populates _cell_bg_cache and _cell_fg_cache in the
# caller's scope. Interpolates RGB between GRAD_* control points.
_compute_gradient_cache() {
  local _filled=$1 _body_area=$2 _compact_mark_pct="$3"
  _cell_bg_cache=()
  _cell_fg_cache=()
  for (( _ci=0; _ci<_filled; _ci++ )); do
    local _cpct=$(( (_ci + 1) * 100 / _body_area ))
    if [[ -n "$_compact_mark_pct" ]] && (( _compact_mark_pct > 0 && _compact_mark_pct < 100 )); then
      _cpct=$(( _cpct * 100 / _compact_mark_pct ))
      (( _cpct > 100 )) && _cpct=100
    fi
    local _ft=$(( _cpct * 9 ))
    (( _ft > 900 )) && _ft=900
    local _lo=$(( _ft / 100 ))
    (( _lo > 8 )) && _lo=8
    local _hi=$(( _lo + 1 ))
    local _frac=$(( _ft - _lo * 100 ))
    local _r=$(( GRAD_BG_R[_lo] + (GRAD_BG_R[_hi] - GRAD_BG_R[_lo]) * _frac / 100 ))
    local _g=$(( GRAD_BG_G[_lo] + (GRAD_BG_G[_hi] - GRAD_BG_G[_lo]) * _frac / 100 ))
    local _b=$(( GRAD_BG_B[_lo] + (GRAD_BG_B[_hi] - GRAD_BG_B[_lo]) * _frac / 100 ))
    _cell_bg_cache[$_ci]="\033[48;2;${_r};${_g};${_b}m"
    _cell_fg_cache[$_ci]="\033[38;2;${_r};${_g};${_b}m"
  done
}

# ── _compute_logo_gradient: pre-compute per-cell BG/FG for logo ──
# Populates _logo_bg_cache, _logo_fg_cache in the caller's scope.
# Creates a dark center to light edges ambient glow effect.
_compute_logo_gradient() {
  local _bar_area=$1
  _logo_bg_cache=()
  _logo_fg_cache=()
  local _lg_dark_r=8 _lg_dark_g=8 _lg_dark_b=12
  local _lg_peak_r _lg_peak_g _lg_peak_b
  case "$_SL_COLOR_MODE" in
    mono)  _lg_peak_r=38; _lg_peak_g=38; _lg_peak_b=38 ;;
    muted) _lg_peak_r=38; _lg_peak_g=40; _lg_peak_b=45 ;;
    *)     _lg_peak_r=35; _lg_peak_g=38; _lg_peak_b=45 ;;
  esac
  local _dark_start=$(( _bar_area * 325 / 1000 ))
  local _dark_end=$(( _bar_area * 675 / 1000 ))
  for (( _gi=0; _gi<_bar_area; _gi++ )); do
    local _t=0
    if (( _gi < _dark_start )); then
      _t=$(( 100 - _gi * 100 / _dark_start ))
    elif (( _gi >= _dark_end )); then
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
}

# ── _render_bar: render a progress bar given pct and label ──────
# Usage: _render_bar <pct> <label> [suffix_colored] [compact_mark_pct] [right_label]
# compact_mark_pct: if set (0–100), draws a vertical divider at that % and
#   darkens the empty region beyond it.
# right_label: if set, displayed right-aligned in the empty area with 2-char padding.
_render_bar() {
  local _pct=$1
  local _label="$2"
  local _compact_mark_pct="${3:-}"
  local _right_label="${4:-}"

  # NerdFlair logo: shown right-aligned in empty area of bar
  local _logo_icons=()
  local _logo_start=0
  local _NF_BRAND_COLOR="\033[38;2;145;130;155m"
  _logo_icons=(
    $'\xee\xa0\xb8' " "
    $'\xf3\xb0\xaf\xb7' " "
    $'\xf3\xb0\xb0\x9e' " "
    $'\xf3\xb0\xaf\xb4' " "
    $'\xef\x8c\xb5' " "
    $'\xf3\xb0\xb0\x8c' " "
    $'\xf3\xb0\xaf\xab' " "
    $'\xf3\xb0\xb0\x83' " "
    $'\xf3\xb0\xb0\x9e'
  )
  local _logo_end=0

  # Compute top tier for outer caps and label text
  local _tier_pct=$_pct
  if [[ -n "$_compact_mark_pct" ]] && (( _compact_mark_pct > 0 && _compact_mark_pct < 100 )); then
    _tier_pct=$(( _pct * 100 / _compact_mark_pct ))
    (( _tier_pct > 100 )) && _tier_pct=100
  fi
  local _top_tier_idx=$(( _tier_pct / 10 ))
  (( _top_tier_idx > 9 )) && _top_tier_idx=9
  (( _top_tier_idx < 0 )) && _top_tier_idx=0
  local _FILL_BG="${TIER_BG[$_top_tier_idx]}"
  local _FILL_FG="${TIER_FG[$_top_tier_idx]}"

  # Bar area: fixed width, clamped to MAX_BAR
  local _bar_area=$(( bar_width - 2 ))
  (( _bar_area > MAX_BAR )) && _bar_area=$MAX_BAR
  (( _bar_area < 20 )) && _bar_area=20

  # Position logo centered in the bar area (only when bar is empty)
  if (( ${#_logo_icons[@]} > 0 && _pct == 0 )); then
    _logo_start=$(( (_bar_area - ${#_logo_icons[@]}) / 2 ))
    (( _logo_start < 0 )) && _logo_start=0
    _logo_end=$(( _logo_start + ${#_logo_icons[@]} ))
  elif (( _pct > 0 )); then
    _logo_icons=()
  fi

  # Pre-compute logo background gradient
  local _logo_bg_cache=()
  local _logo_fg_cache=()
  if (( ${#_logo_icons[@]} > 0 )); then
    _compute_logo_gradient "$_bar_area"
  fi

  # Compact mark: visual position of the compaction divider (-1 = none)
  local _compact_mark_pos=-1
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

  # Padded label centered in the full bar_area
  local _label_padded=" ${_label} "
  local _label_len=${#_label_padded}
  local _label_start=$(( (_bar_area - _label_len) / 2 ))
  (( _label_start < 0 )) && _label_start=0
  local _label_end=$(( _label_start + _label_len ))
  if (( ${#_logo_icons[@]} > 0 )); then
    _label_start=-1
    _label_end=-1
  fi

  # Right-aligned label in empty area
  local _rlabel_start=-1
  local _rlabel_end=-1
  if [[ -n "$_right_label" ]]; then
    local _rlabel_len=${#_right_label}
    _rlabel_start=$(( _bar_area - _rlabel_len ))
    (( _rlabel_start < 0 )) && _rlabel_start=0
    _rlabel_end=$(( _rlabel_start + _rlabel_len ))
  fi

  # Pre-compute per-cell gradient colors
  local _cell_bg_cache=() _cell_fg_cache=()
  _compute_gradient_cache "$_filled" "$_body_area" "$_compact_mark_pct"

  # Outer cap colors — left cap uses first filled cell, right cap uses last
  local _left_cap_fg _right_cap_fg
  if (( _pct > 0 )); then
    _left_cap_fg="${TIER_FG[0]}"
  elif (( ${#_logo_icons[@]} > 0 && ${#_logo_bg_cache[@]} > 0 )); then
    _left_cap_fg="${_logo_fg_cache[0]}"
  else
    _left_cap_fg="$EMPTY_FG"
  fi

  if (( _pct >= 100 )); then
    _right_cap_fg="$_FILL_FG"
  elif (( ${#_logo_icons[@]} > 0 && ${#_logo_bg_cache[@]} > 0 )); then
    _right_cap_fg="${_logo_fg_cache[$((_bar_area - 1))]}"
  elif (( _compact_mark_pos >= 0 )); then
    _right_cap_fg="$_COMPACT_EMPTY_FG"
  else
    _right_cap_fg="$EMPTY_FG"
  fi

  # Override caps with smooth gradient endpoints
  if (( _filled > 0 )); then
    _left_cap_fg="${_cell_fg_cache[0]}"
    if (( _pct >= 100 )); then
      _right_cap_fg="${_cell_fg_cache[$((_filled - 1))]}"
    fi
  fi

  # Build bar body cell by cell
  local _bar=""
  local _vis=0  # visual position (0..bar_area-1)
  local _body_i=0  # body cell index (0..body_area-1)

  while (( _vis < _bar_area )); do
    # Insert inner transition cap at the fill boundary (fill to empty)
    if (( _has_inner_cap && _body_i == _filled )); then
      # Darker empty BG past the compact mark (the logo never coexists with a cap)
      local _cap_empty_bg="$EMPTY_BG"
      if (( _compact_mark_pos >= 0 && _vis >= _compact_mark_pos )); then
        _cap_empty_bg="$_COMPACT_EMPTY_BG"
      fi
      # Use the last filled cell's FG/BG for the transition cap
      local _last_fill_fg="$_FILL_FG"
      local _last_fill_bg="$_FILL_BG"
      if (( _filled > 0 )); then
        _last_fill_fg="${_cell_fg_cache[$((_filled - 1))]}"
        _last_fill_bg="${_cell_bg_cache[$((_filled - 1))]}"
      fi
      if (( _vis >= _label_start && _vis < _label_end )); then
        # A label character sits on the cap cell. The cap normally renders a
        # filled (green) rounded glyph, so treat this cell as part of the fill:
        # keep the covered-label styling (fill BG + near-black FG) so the digit
        # matches the covered digits before it instead of flipping to light text.
        local _ci=$(( _vis - _label_start ))
        local _ch="${_label_padded:$_ci:1}"
        _bar+="${_last_fill_bg}${LABEL_COVERED_FG}${_ch}"
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
    if (( _body_i < _filled )); then
      _cell_bg="${_cell_bg_cache[$_body_i]}"
      _cell_fg="${_cell_fg_cache[$_body_i]}"
    fi

    if (( _vis >= _label_start && _vis < _label_end )); then
      local _ci=$(( _vis - _label_start ))
      local _ch="${_label_padded:$_ci:1}"
      if (( _body_i < _filled )); then
        _bar+="${_cell_bg}${LABEL_COVERED_FG}${_ch}"
      else
        _bar+="${_cur_empty_bg}${_cur_light_fg}${_ch}"
      fi
    elif (( _rlabel_start >= 0 && _vis >= _rlabel_start && _vis < _rlabel_end && _body_i >= _filled )); then
      # Right-aligned label in empty area
      local _ri=$(( _vis - _rlabel_start ))
      local _rch="${_right_label:$_ri:1}"
      _bar+="${_cur_empty_bg}${_cur_light_fg}${_rch}"
    else
      if (( _body_i < _filled )); then
        _bar+="${_cell_bg} "
      else
        if (( ${#_logo_icons[@]} > 0 && _vis >= _logo_start && _vis < _logo_end )); then
          local _li=$(( _vis - _logo_start ))
          local _lc="$_NF_BRAND_COLOR"
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
  printf '\n%b%b%b%b' \
    "${RESET}${_left_cap_fg}${PL_LEFT}" \
    "${_bar}" \
    "${RESET}${_right_cap_fg}${PL_RIGHT}" \
    "${RESET}"
}


# Render the real progress bar (skip in minimal — context pill is on row 1)
if [[ "$_SL_MODE" != "minimal" ]]; then
  _compact_mark=80
  # In compact mode, show cost right-aligned inside the bar's empty area
  _bell_icon=""
  if awk -v v="${_SL_CHIME_VOLUME:-1}" 'BEGIN {exit (v <= 0) ? 0 : 1}'; then
    printf -v _bell_icon '\xf3\xb0\xe5\xa9'  # U+F0969 speaker-off
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
  _render_bar "$pct" "$ctx_label" "$_compact_mark" "$_bar_right_label"
fi

# Row 3: mcp | time + cost (full mode only)
if [[ "$_SL_MODE" == "full" ]]; then
  printf '\n'
  _justified_row "$ROW_WIDTH" 3 "$row3_left" "$row3_right"
fi

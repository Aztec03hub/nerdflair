# shellcheck shell=bash
# nf-log.sh - sourced by claude-shim, nf-tmux-heal and install.sh (and copied next
# to them by install.sh). One helper, one file, one format:
#
#   nf_log <component> <reason>
#
# appends `ISO-time component: reason` to $NF_STATE_DIR/launcher.log (default
# ~/.local/state/nerdflair/launcher.log), the same file the python watcher writes.
#
# The rule it serves: a fallback is fine, but every absorbed failure is logged,
# once, with the reason.
#   - once per distinct (component, reason) per process;
#   - rate limited by a stamp file, so the shim and heal, which run on EVERY
#     claude start, log the first occurrence and then at most once an hour
#     (NF_LOG_NOSTAMP=1 turns the stamp off: install.sh, where a person is waiting);
#   - capped at 1 MB with one rotated generation;
#   - it can never fail or block the caller: every step is guarded and it returns 0,
#     and it sets no shell options and no statement in it can return non-zero, so it is safe under set -e
#     and set -u (tests/log-sanitizers.sh runs it under set -eu).
_NF_SEEN=""
# _nf_log_sanitize text: sets _NF_LOGS to text with every terminal-active control replaced by a space.
# Byte-wise (LC_ALL=C), twin of errlog::clean: C0 and DEL, the 2-byte form of a C1 control
# (U+0080..U+009F), and, only in text that is NOT valid UTF-8, any raw 0x80..0x9f byte outside a
# valid character. Valid UTF-8 (smart quotes, CJK, Cyrillic: their continuation bytes lie in
# 0x80..0x9f) is kept whole. No fork at all (pure bash).
_nf_log_sanitize() {
  local _s="$1" LC_ALL=C _o _i _n _c _w
  local _u2=$'[\xc2-\xdf][\x80-\xbf]'
  local _u3=$'(\xe0[\xa0-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]|\xed[\x80-\x9f])[\x80-\xbf]'
  local _u4=$'(\xf0[\x90-\xbf]|[\xf1-\xf3][\x80-\xbf]|\xf4[\x80-\x8f])[\x80-\xbf][\x80-\xbf]'
  _s="${_s//[[:cntrl:]]/ }"
  _s="${_s//$'\xc2'[$'\x80'-$'\x9f']/ }"
  # Only a raw 0x80..0x9f byte can need replacing, and whether it is a continuation byte of a
  # valid character is decided by the loop below with Rust's exact rules (no iconv: glibc accepts
  # sequences above U+10FFFF that Rust rejects). ASCII and 0x80..0x9f-free text never reaches it.
  if [[ "$_s" == *[$'\x80'-$'\x9f']* ]]; then
    _o=""; _i=0; _n=${#_s}
    while (( _i < _n )); do
      _c="${_s:_i:1}"
      if [[ "$_c" == [$'\x80'-$'\xff'] ]]; then
        _w="${_s:_i:4}"
        if [[ "$_w" =~ ^($_u4|$_u3|$_u2) ]]; then _o+="${BASH_REMATCH[0]}"; _i=$((_i + ${#BASH_REMATCH[0]})); continue; fi
        [[ "$_c" == [$'\x80'-$'\x9f'] ]] && _c=" "
      fi
      _o+="$_c"; _i=$((_i + 1))
    done
    _s="$_o"
  fi
  _NF_LOGS="$_s"
}
nf_log() {
  local comp=${1:-?} reason=${2:-} dir log key h stamp size
  # Reasons carry user text (paths, python errors): no terminal control may reach the log.
  _nf_log_sanitize "$reason"; reason=$_NF_LOGS
  _nf_log_sanitize "$comp"; comp=$_NF_LOGS
  key="$comp|$reason"
  case "$_NF_SEEN" in *$'\n'"$key"$'\n'*) return 0 ;; esac
  _NF_SEEN="$_NF_SEEN"$'\n'"$key"$'\n'
  dir=${NF_STATE_DIR:-${HOME:-/nonexistent}/.local/state/nerdflair}
  log=$dir/launcher.log
  {
    mkdir -p "$dir" || return 0
    if [[ -z "${NF_LOG_NOSTAMP:-}" ]]; then
      h=$(printf '%s' "$key" | cksum | cut -d' ' -f1)
      stamp=$dir/.launcher-stamp-$comp-$h
      # A stamp younger than an hour means this exact failure was logged recently.
      [[ -z "$(find "$stamp" -mmin -60 2>/dev/null)" ]] || return 0
      : > "$stamp" || true
      # Stamps are per (component, reason): drop the ones a day old so reasons that vary cannot pile up.
      find "$dir" -maxdepth 1 -name '.launcher-stamp-*' -mmin +1440 -delete 2>/dev/null || true
    fi
    size=$(stat -c %s "$log" 2>/dev/null || echo 0)
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 1000000 )); then mv -f "$log" "$log.1" || true; fi
    printf '%s %s: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$comp" "$reason" >> "$log"
  } 2>/dev/null || true
  return 0
}

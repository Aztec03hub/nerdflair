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
#     and it sets no shell options, so it is safe under set -e and set -u.
_NF_SEEN=""
nf_log() {
  local comp=${1:-?} reason=${2:-} dir log key h stamp size
  reason=${reason//$'\n'/ }
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
    fi
    size=$(stat -c %s "$log" 2>/dev/null || echo 0)
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 1000000 )); then mv -f "$log" "$log.1" || true; fi
    printf '%s %s: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$comp" "$reason" >> "$log"
  } 2>/dev/null || true
  return 0
}

#!/usr/bin/env bash
# real-home-guard.sh - sourced by test scripts. A test run must not put ITS OWN failures into the
# REAL $HOME/.claude/nerdflair-errors.log (a panic in an un-isolated call once did: U6). Real
# sessions append to the same file while a suite runs, so the line count alone proves nothing.
#   rhg_snapshot   at the top, before any temp HOME is exported
#   rhg_check      at the end; returns 1 only if a line appended since the snapshot contains
#                  `panic`, this suite's temp prefix (${TMPDIR:-/tmp}/nf-) or this script's pid.
#                  Other appended lines are a printed warning count. If the log shrank or its last
#                  line changed (trimmed/rotated) the check is skipped with a note.
# Read-only on the real HOME; skipped when the log does not exist.
rhg_snapshot() {
  RHG_LOG="${HOME:-/nonexistent}/.claude/nerdflair-errors.log"
  RHG_PID=$$
  RHG_SIZE=-1
  [[ -f "$RHG_LOG" ]] || return 0
  RHG_SIZE=$(stat -c %s "$RHG_LOG")
  RHG_LAST=$(head -c "$RHG_SIZE" "$RHG_LOG" | tail -n 1 | cksum)
}
rhg_check() {
  [[ "$RHG_SIZE" == -1 ]] && return 0
  local now last new bad warn
  now=$(stat -c %s "$RHG_LOG" 2>/dev/null || echo 0)
  last=$(head -c "$RHG_SIZE" "$RHG_LOG" 2>/dev/null | tail -n 1 | cksum)
  if (( now < RHG_SIZE )) || [[ "$last" != "$RHG_LAST" ]]; then
    printf '  NOTE  the real error log was trimmed during the run; guard skipped\n'
    return 0
  fi
  new=$(tail -c +$(( RHG_SIZE + 1 )) "$RHG_LOG")
  [[ -z "$new" ]] && { printf '  PASS  the real error log gained no lines\n'; return 0; }
  bad=$(printf '%s\n' "$new" | rg -c -e 'panic' -e "${TMPDIR:-/tmp}/nf-" -e " ${RHG_PID} " || true)
  warn=$(printf '%s\n' "$new" | wc -l)
  if [[ -n "$bad" && "$bad" != 0 ]]; then
    printf '  FAIL  the real %s gained %s line(s) from this run (panic, temp path or this pid):\n' "$RHG_LOG" "$bad"
    printf '%s\n' "$new" | rg -e 'panic' -e "${TMPDIR:-/tmp}/nf-" -e " ${RHG_PID} " | cut -c1-200 | sed 's/^/        /'
    return 1
  fi
  printf '  PASS  the real error log gained %s line(s), none from this run (other sessions; warning only)\n' "$warn"
}

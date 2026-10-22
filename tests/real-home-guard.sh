#!/usr/bin/env bash
# real-home-guard.sh - sourced by test scripts. A test run must not add a line to the REAL
# $HOME/.claude/nerdflair-errors.log (a panic in an un-isolated call once did: U6).
#   rhg_snapshot   at the top, before any temp HOME is exported
#   rhg_check      at the end; returns 1 and says so if the line count changed
# Read-only on the real HOME; skipped when the log does not exist. Reads $HOME at snapshot time.
rhg_snapshot() {
  RHG_LOG="${HOME:-/nonexistent}/.claude/nerdflair-errors.log"
  RHG_BEFORE=-1
  [[ -f "$RHG_LOG" ]] && RHG_BEFORE=$(wc -l < "$RHG_LOG")
}
rhg_check() {
  [[ "$RHG_BEFORE" == -1 ]] && return 0
  local after; after=$(wc -l < "$RHG_LOG" 2>/dev/null || echo 0)
  if [[ "$after" != "$RHG_BEFORE" ]]; then
    printf '  FAIL  the real %s changed (%s -> %s lines): a test call is not isolated\n' "$RHG_LOG" "$RHG_BEFORE" "$after"
    return 1
  fi
  printf '  PASS  the real error log is untouched (%s lines)\n' "$after"
}

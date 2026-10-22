#!/usr/bin/env bash
# real-home-guard.sh - sourced by test scripts. A test run must not put ITS OWN failures into the
# REAL $HOME/.claude/nerdflair-errors.log (a panic in an un-isolated call once did: U6). Real
# sessions append to the same file while a suite runs, so the line count alone proves nothing.
#   rhg_snapshot   at the top, before any temp HOME is exported. quick.sh / full.sh run each check under a temp
#                  HOME and export NF_REAL_HOME (the HOME they started with); the guard watches that one.
#   rhg_check      at the end; returns 1 only if a line appended since the snapshot contains
#                  `panic`, this suite's temp prefix (${TMPDIR:-/tmp}/nf-) or this script's pid.
#                  Other appended lines are a printed warning count. If the log shrank or its last
#                  line changed (trimmed/rotated) the check is skipped with a note.
#                  The count and each appended line's time, pid and tag are printed (a match marked >>); the full
#                  text only with NF_GUARD_VERBOSE=1, because it can carry paths and session ids. Start the runners with your REAL HOME: under a temp HOME the guard watches a
#                  log that does not exist and says so ("skipped").
# Read-only on the real HOME; skipped when the log does not exist.
rhg_snapshot() {
  RHG_LOG="${NF_REAL_HOME:-${HOME:-/nonexistent}}/.claude/nerdflair-errors.log"
  RHG_PID=$$
  RHG_SIZE=-1
  # The real ~/.local/state/nerdflair/ is watched too (see rhg_check_state). Associative array: $HOME may hold a space.
  RHG_STATE="${NF_REAL_HOME:-${HOME:-/nonexistent}}/.local/state/nerdflair"
  RHG_REAL_HOME="${NF_REAL_HOME:-${HOME:-/nonexistent}}"
  declare -gA RHG_SNAP=()
  local f
  while IFS= read -r -d '' f; do RHG_SNAP["$f"]=$(stat -c %s "$f"); done < <(find "$RHG_STATE" -maxdepth 1 -type f -print0 2>/dev/null)
  [[ -f "$RHG_LOG" ]] || return 0
  RHG_SIZE=$(stat -c %s "$RHG_LOG")
  RHG_LAST=$(head -c "$RHG_SIZE" "$RHG_LOG" | tail -n 1 | cksum)
}
# Log line format: "<ISO time> <pid> <tag> <reason>". The reason carries paths and session ids from the real
# session, so only time, pid and the tag's part before the first ':' are shown unless NF_GUARD_VERBOSE=1.
# Display only (the match is made on the full line before this): 200 chars in verbose mode; otherwise time, pid and the
# tag up to its first ':' (tags carry runtime data such as tmp-write:<file>), and a fixed note for a line that does not parse.
rhg_show() {
  local t p g k
  if [[ "${NF_GUARD_VERBOSE:-}" == 1 ]]; then
    local LC_ALL=C.UTF-8   # cut by characters, not bytes, so a multibyte character is never split
    printf '%s' "${1:0:200}"; return
  fi
  local LC_ALL=C   # ASCII classes below; IFS default splits on spaces and tabs
  read -r t p g _ <<< "$1"
  # Every printed field must match a strict pattern, else it is `?`. A line without a valid time is not in the
  # documented format, so nothing of it is trusted (a foreign line's first words can be paths).
  if [[ $t =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9:]+)?$ ]]; then
    [[ $p =~ ^[0-9]+$ ]] || p='?'
    k='?'; [[ $g =~ ^([A-Za-z0-9_-]+) ]] && k=${BASH_REMATCH[1]}
  else t='?'; p='?'; k='?'; fi
  printf '%s %s %s' "$t" "$p" "$k"; [[ $k == '?' ]] || printf ':'
}
# The live system writes into the same dir while a suite runs (launcher.log, nfpty-error.log, tmux-watch.log
# events such as "ss timed out"), so growth alone proves nothing. Every new line is printed (time, pid and tag
# only, like the errors.log guard); the run FAILS only on a new line that names this run's scratch paths:
# ${TMPDIR:-/tmp}/nf-, ${TMPDIR:-/tmp}/tmp. and, under a temp HOME, that HOME.
# ponytail: a test that leaks a path-free line into the real dir is not caught; add a marker if one ever does.
rhg_check_state() {
  local f old new l t m q rc=0 pats=("${TMPDIR:-/tmp}/nf-" "${TMPDIR:-/tmp}/tmp.")
  [[ "$HOME" != "$RHG_REAL_HOME" ]] && pats+=("$HOME/")
  while IFS= read -r -d '' f; do
    old=${RHG_SNAP["$f"]:--1}; new=$(stat -c %s "$f" 2>/dev/null || echo 0)
    (( new > old )) || continue
    (( old < 0 )) && old=0
    printf '  NOTE  %s gained %s byte(s); new line(s), >> marks one naming this run'"'"'s scratch paths:\n' "$f" "$(( new - old ))"
    while IFS= read -r l; do
      m=""; for q in "${pats[@]}"; do [[ "$l" == *"$q"* ]] && m=1; done
      t=$(rhg_show "$l")
      if [[ -n $m ]]; then printf '      >> %s\n' "$t"; rc=1; else printf '         %s\n' "$t"; fi
    done < <(tail -c +$(( old + 1 )) "$f")
  done < <(find "$RHG_STATE" -maxdepth 1 -type f -print0 2>/dev/null)
  (( rc )) && printf '  FAIL  this run wrote into the real %s\n' "$RHG_STATE"
  return $rc
}
rhg_check() { # both checks always run, so one failure never hides the other
  local a=0 b=0
  rhg_check_state || a=1
  rhg_check_errlog || b=1
  return $(( a || b ))
}
rhg_check_errlog() {
  [[ "$RHG_SIZE" == -1 ]] && { printf '  NOTE  no real error log at %s; guard skipped (start the runner with your real HOME)\n' "$RHG_LOG"; return 0; }
  local now last new bad warn m q
  now=$(stat -c %s "$RHG_LOG" 2>/dev/null || echo 0)
  last=$(head -c "$RHG_SIZE" "$RHG_LOG" 2>/dev/null | tail -n 1 | cksum)
  if (( now < RHG_SIZE )) || [[ "$last" != "$RHG_LAST" ]]; then
    printf '  NOTE  the real error log was trimmed during the run; guard skipped\n'
    return 0
  fi
  new=$(tail -c +$(( RHG_SIZE + 1 )) "$RHG_LOG")
  [[ -z "$new" ]] && { printf '  PASS  the real error log gained no lines\n'; return 0; }
  local pat=(-e 'panic' -e "${TMPDIR:-/tmp}/nf-" -e " ${RHG_PID} ")
  bad=$(printf '%s\n' "$new" | rg -c "${pat[@]}" || true)
  warn=$(printf '%s\n' "$new" | wc -l)
  if [[ -n "$bad" && "$bad" != 0 ]]; then
    printf '  FAIL  the real %s gained %s matching line(s) from this run (panic, temp path or this pid); all %s appended line(s), >> marks a match:\n' "$RHG_LOG" "$bad" "$warn"
    printf '%s\n' "$new" | while IFS= read -r l; do
      t=$(rhg_show "$l")
      m=""; for q in panic "${TMPDIR:-/tmp}/nf-" " ${RHG_PID} "; do
        if printf '%s\n' "$l" | rg -qF -e "$q"; then case $q in panic) m="${m:+$m,}panic";; *nf-) m="${m:+$m,}tmp";; *) m="${m:+$m,}pid";; esac; fi; done
      if [[ -n $m ]]; then printf '      >> %s: %s\n' "$m" "$t"; else printf '         %s\n' "$t"; fi; done
    return 1
  fi
  printf '  PASS  the real error log gained %s line(s), none from this run (other sessions; warning only):\n' "$warn"
  printf '%s\n' "$new" | head -n 5 | while IFS= read -r l; do printf '         %s\n' "$(rhg_show "$l")"; done
}

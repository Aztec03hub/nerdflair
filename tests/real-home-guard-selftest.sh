#!/usr/bin/env bash
# real-home-guard-selftest.sh - the guard fails on an appended panic / temp-path / own-pid line,
# passes on an unrelated appended line, and skips a trimmed log. Works on a temp HOME only.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-rhgself-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
unset NF_REAL_HOME   # the runner exports it; run() below must watch its own HOME
check() { if [[ "$3" == "$2" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }
mkdir -p "$W/home/.claude"; L="$W/home/.claude/nerdflair-errors.log"
seed() { printf '2026-10-20T01:00:00Z 111 payload-empty: seed\n2026-10-20T01:00:01Z 112 recovered: seed\n' > "$L"; }
run() { # appended-text-or-"" trim?   -> exit status of rhg_check
  ( HOME="$W/home"; . "$REPO/tests/real-home-guard.sh"; rhg_snapshot; [[ -n "$1" ]] && printf '%b\n' "$1" >> "$L"
    [[ "${2:-}" == trim ]] && : > "$L"; rhg_check >/dev/null; echo $? )
}
seed; check "no new lines passes" 0 "$(run '')"
seed; check "an unrelated session's line passes (warning only)" 0 "$(run '2026-10-22T01:00:00Z 999 git-untracked-read: x')"
seed; check "an appended panic line fails" 1 "$(run '2026-10-22T01:00:00Z 999 panic: boom')"
seed; check "an appended line naming a suite temp dir fails" 1 "$(run "2026-10-22T01:00:00Z 999 cache-dir: ${TMPDIR:-/tmp}/nf-x/c")"
seed; check "a trimmed log is skipped" 0 "$(run '2026-10-22T01:00:00Z 999 panic: boom' trim)"
rm -f "$L"; check "an absent log is skipped" 0 "$(run '')"
# Under quick.sh / full.sh HOME is a temp dir and NF_REAL_HOME names the real one: the guard must watch that one.
runr() { # appended-text -> status of rhg_check with HOME=<empty temp> and NF_REAL_HOME=<fake real home>
  ( mkdir -p "$W/tmphome"; HOME="$W/tmphome" NF_REAL_HOME="$W/home"; export HOME NF_REAL_HOME; . "$REPO/tests/real-home-guard.sh"; rhg_snapshot
    printf '%b\n' "$1" >> "$L"; rhg_check >/dev/null; echo $? )
}
seed; check "NF_REAL_HOME: a panic in the fake real home fails though HOME is a temp dir" 1 "$(runr '2026-10-22T01:00:00Z 999 panic: boom')"
seed; check "NF_REAL_HOME: an unrelated line passes" 0 "$(runr '2026-10-22T01:00:00Z 999 git-untracked-read: x')"
# The report names every appended line and marks the matching one, so a live session's line is told apart from a test's.
out() { ( HOME="$W/home"; . "$REPO/tests/real-home-guard.sh"; rhg_snapshot; printf '%b\n' "$1" >> "$L"; rhg_check ); }
seed; o=$(out '2026-10-22T01:00:00Z 777 other-session: x\n2026-10-22T01:00:01Z 999 panic: boom')
[[ "$o" == *'>> 2026-10-22T01:00:01Z 999 panic:'* && "$o" == *'   2026-10-22T01:00:00Z 777 other-session:'* && "$o" != *'>> 2026-10-22T01:00:00Z 777'* ]] \
  && check "FAIL output lists the live session's line unmarked and the panic line marked" ok ok || check "FAIL output lists appended lines with a match marker" ok "$o"
seed; o=$(out '2026-10-22T01:00:00Z 777 other-session: secret/path-abc')
[[ "$o" == *'2026-10-22T01:00:00Z 777 other-session:'* && "$o" != *secret* ]] && check "PASS output shows time, pid, tag and hides the text" ok ok || check "PASS output shows time, pid, tag and hides the text" ok "$o"
o=$(NF_GUARD_VERBOSE=1 out '2026-10-22T01:00:00Z 777 other-session: secret/path-abc')
[[ "$o" == *'secret/path-abc'* ]] && check "NF_GUARD_VERBOSE=1 shows the full line" ok ok || check "NF_GUARD_VERBOSE=1 shows the full line" ok "$o"
seed; o=$(out '2026-10-22T01:00:01Z 999 panic: secret/path-abc')
[[ "$o" == *'>> 2026-10-22T01:00:01Z 999 panic:'* && "$o" != *secret* ]] && check "FAIL output hides the text too" ok ok || check "FAIL output hides the text too" ok "$o"
rm -f "$L"; o=$(out ''); [[ "$o" == *'NOTE'*'guard skipped'* ]] && check "an absent log says it was skipped" ok ok || check "an absent log says it was skipped" ok "$o"
exit $fail

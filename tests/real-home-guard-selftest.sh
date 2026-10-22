#!/usr/bin/env bash
# real-home-guard-selftest.sh - the guard fails on an appended panic / temp-path / own-pid line,
# passes on an unrelated appended line, and skips a trimmed log. Works on a temp HOME only.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-rhgself-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
# This run's scratch root: a line is blamed on the run only if it names this exact dir. Set before anything is sourced,
# so the rows below ("$TMPDIR/nf-x" is ours, "/tmp/nf-x" is another session's) hold whatever TMPDIR the caller had.
mkdir -p "$W/run"; export TMPDIR="$W/run"
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
# The "not marked" check is per line: the header itself says ">> marks a match", so a whole-output glob always matched.
[[ "$o" == *'>> panic: 2026-10-22T01:00:01Z 999 panic:'* && "$o" == *'   2026-10-22T01:00:00Z 777 other-session:'* ]] && ! rg -q '^>> .* 777 ' <<<"$o" \
  && check "FAIL output lists the live session's line unmarked and the panic line marked" ok ok || check "FAIL output lists appended lines with a match marker" ok "$o"
seed; o=$(out '2026-10-22T01:00:00Z 777 other-session: secret/path-abc')
[[ "$o" == *'2026-10-22T01:00:00Z 777 other-session:'* && "$o" != *secret* ]] && check "PASS output shows time, pid, tag and hides the text" ok ok || check "PASS output shows time, pid, tag and hides the text" ok "$o"
o=$(NF_GUARD_VERBOSE=1 out '2026-10-22T01:00:00Z 777 other-session: secret/path-abc')
[[ "$o" == *'secret/path-abc'* ]] && check "NF_GUARD_VERBOSE=1 shows the full line" ok ok || check "NF_GUARD_VERBOSE=1 shows the full line" ok "$o"
seed; o=$(out '2026-10-22T01:00:01Z 999 panic: secret/path-abc')
[[ "$o" == *'>> panic: 2026-10-22T01:00:01Z 999 panic:'* && "$o" != *secret* ]] && check "FAIL output hides the text too" ok ok || check "FAIL output hides the text too" ok "$o"
seed; o=$(out '2026-10-22T01:00:00Z 777 tmp-write:/home/x/secret-name: y')
[[ "$o" == *' 777 tmp-write:'* && "$o" != *secret-name* ]] && check "a tag's runtime data (tmp-write:<path>) is hidden" ok ok || check "a tag's runtime data (tmp-write:<path>) is hidden" ok "$o"
o=$(NF_GUARD_VERBOSE=1 out '2026-10-22T01:00:00Z 777 tmp-write:/home/x/secret-name: y')
[[ "$o" == *secret-name* ]] && check "NF_GUARD_VERBOSE=1 keeps the full tag" ok ok || check "NF_GUARD_VERBOSE=1 keeps the full tag" ok "$o"
seed; o=$(out 'secret-no-space-line')
[[ "$o" == *'? ? ?'* && "$o" != *secret* ]] && check "a line with no space is not printed" ok ok || check "a line with no space is not printed" ok "$o"
seed; o=$(out "2026-10-22T01:00:00Z 777 other-session: $(printf 'x%.0s' {1..250}) panic")
[[ "$o" == *'>> panic: 2026-10-22T01:00:00Z 777 other-session:'* ]] && check "a match past column 200 is still marked >>" ok ok || check "a match past column 200 is still marked >>" ok "$o"
# Strict-pattern output: time, pid and tag kind print only if they match; everything else is `?`.
seed; o=$(out '/home/phil/clients/acme/repo failed to read x'); [[ "$o" == *'? ? ?'* && "$o" != *phil* && "$o" != *acme* && "$o" != *failed* ]] \
  && check "a wrong-format line (no time) shows only ?" ok ok || check "a wrong-format line (no time) shows only ?" ok "$o"
seed; o=$(out '2026-10-22T01:00:00Z 777 /home/phil/secret-dir/file reason'); [[ "$o" == *'2026-10-22T01:00:00Z 777 ?'* && "$o" != *phil* && "$o" != *secret* ]] \
  && check "a colon-less tag carrying a path shows ?" ok ok || check "a colon-less tag carrying a path shows ?" ok "$o"
seed; o=$(out '2026-10-22T01:00:00Z 777\ttmp-write:/home/phil/secret-dir: y'); [[ "$o" == *'2026-10-22T01:00:00Z 777 tmp-write:'* && "$o" != *phil* && "$o" != *secret* ]] \
  && check "a tab-separated line shows time, pid and kind only" ok ok || check "a tab-separated line shows time, pid and kind only" ok "$o"
seed; o=$(out '2026-10-22T01:00:00Z\t/home/phil/secret-dir\ttag: y'); [[ "$o" == *'2026-10-22T01:00:00Z ? tag:'* && "$o" != *phil* && "$o" != *secret* ]] \
  && check "a tab line with a path as its second word shows ?" ok ok || check "a tab line with a path as its second word shows ?" ok "$o"
seed; o=$(out '2026-10-22T01:00:00Z /home/phil/secret-dir tag: y'); [[ "$o" == *'2026-10-22T01:00:00Z ? tag:'* && "$o" != *phil* && "$o" != *secret* ]] \
  && check "a line whose second word is a path shows ?" ok ok || check "a line whose second word is a path shows ?" ok "$o"
seed; out '2026-10-22T01:00:00Z 999 tmp-write:/home/phil/secret-dir: panic' >/dev/null; check "a leak in a tab/odd-shaped line still FAILs" 1 "$(run '2026-10-22T01:00:00Z\t999\tx: panic')"
seed; o=$(out "2026-10-22T01:00:00Z 777 t: ${TMPDIR:-/tmp}/nf-x"); [[ "$o" == *'>> tmp: '* ]] && check "marker names the temp-path rule" ok ok || check "marker names the temp-path rule" ok "$o"
seed; o=$(NF_GUARD_VERBOSE=1 out "2026-10-22T01:00:00Z 777 t: $(printf '\xc3\xa9%.0s' {1..150}) panic"); [[ "$o" == *'>> panic:'* && "$o" != *$'\xc3'$'\n'* ]] && check "verbose cut keeps multibyte characters whole" ok ok || check "verbose cut keeps multibyte characters whole" ok "$o"
rm -f "$L"; o=$(out ''); [[ "$o" == *'NOTE'*'guard skipped'* ]] && check "an absent log says it was skipped" ok ok || check "an absent log says it was skipped" ok "$o"
# The real ~/.local/state/nerdflair/: the live system writes there during a run, so growth alone passes (and is
# printed); only a new line naming this run's scratch paths fails, and it is marked.
SD="$W/home/.local/state/nerdflair"; mkdir -p "$SD"; SL="$SD/tmux-watch.log"
sout() { # home-dir appended-line file -> guard output; the line is appended between snapshot and check
  ( HOME="$1"; . "$REPO/tests/real-home-guard.sh"; rhg_snapshot; printf '%s\n' "$2" >> "$1/.local/state/nerdflair/$3"; rhg_check; echo "rc=$?"; rhg_done ); }
soutu() { ( unset TMPDIR; sout "$@" ); }   # the default case: a bare run, TMPDIR unset
LIVE='2026-10-22 04:34:04 ss: cannot run ss: timed out after 5 seconds'
seed; echo old > "$SL"; o=$(sout "$W/home" "$LIVE" tmux-watch.log)
[[ "$o" == *'rc=0'* && "$o" == *'gained'* ]] && check "state dir: a live path-free line passes, and is printed" ok ok || check "state dir: a live path-free line passes, and is printed" ok "$o"
o=$(sout "$W/home" "2026-10-22 04:34:05 DELETED: ${TMPDIR:-/tmp}/nf-heal-x/tmux-1000" tmux-watch.log)
[[ "$o" == *'rc=1'* && "$o" == *'>> '* && "$o" == *'wrote into the real'* ]] && check "state dir: a line naming a suite scratch dir fails, marked >>" ok ok || check "state dir: a line naming a suite scratch dir fails, marked >>" ok "$o"
# Other sessions share /tmp and use the same /tmp/nf-* and /tmp/tmp.* names: none of their lines is ours, wherever it shows up.
for other in "DELETED: /tmp/tmp.AbCdEf/nf-noleaks-1/run-x/tmux-1000" "DELETED: /tmp/r5review-x/tmp/tmp.edRg/tmux-1000" \
  "     pid=77 ppid=1 age=3s user=u bash /tmp/nf-noleaks-ABC/run.sh" "     pid=78 ppid=1 age=3s user=u flock /tmp/tmp.XyZ/lock" "nfpty: x failed /tmp/nf-work/x"; do
  o=$(soutu "$W/home" "2026-10-22 04:34:05 $other" tmux-watch.log)
  [[ "$o" == *'rc=0'* ]] && ! rg -q '^ +>> ' <<<"$o" && check "state dir: another session's line passes unmarked ($other)" ok ok || check "state dir: another session's line passes unmarked ($other)" ok "$o"
done
o=$(soutu "$W/home" "x /tmp/tmp.AbC/nf-noleaks-1/tmux-1000" launcher.log)
[[ "$o" == *'rc=0'* ]] && check "state dir: a new file with another session's /tmp/tmp.* path passes" ok ok || check "state dir: a new file with another session's /tmp/tmp.* path passes" ok "$o"
o=$(sout "$W/home" "x $TMPDIR/tmp.AbC/y" launcher.log)
[[ "$o" == *'rc=1'* && "$o" == *'>> '* ]] && check "state dir: a line naming this run's TMPDIR fails, marked >>" ok ok || check "state dir: a line naming this run's TMPDIR fails, marked >>" ok "$o"
seed; check "errors.log: another session's /tmp/nf-* line passes" 0 "$(run '2026-10-22T01:00:00Z 999 cache-dir: /tmp/nf-x/c')"
# Run alone (TMPDIR unset) the guard makes this run's root itself, before the test makes any scratch, and rhg_done removes it.
o=$( ( unset TMPDIR; HOME="$W/home"; . "$REPO/tests/real-home-guard.sh"; rhg_snapshot; r=$TMPDIR
  [[ -d "$r" && "$r" != /tmp ]] && echo made || echo notmade
  printf '2026-10-22 04:34:05 DELETED: %s/nf-x/tmux-1000\n' "$r" >> "$SD/tmux-watch.log"; rhg_check >/dev/null; echo "rc=$?"
  rhg_done; [[ -d "$r" ]] && echo left || echo removed ) )
[[ "$o" == *made* && "$o" == *rc=1* && "$o" == *removed* ]] && check "TMPDIR unset: the guard makes its own root, blames lines naming it, removes it" ok ok || check "TMPDIR unset: the guard makes its own root, blames lines naming it, removes it" ok "$o"
# One failing check must not hide the other.
seed; o=$( ( HOME="$W/home"; . "$REPO/tests/real-home-guard.sh"; rhg_snapshot
  printf '2026-10-22T01:00:00Z 999 panic: boom\n' >> "$L"; echo "2026-10-22 04:34:05 DELETED: ${TMPDIR:-/tmp}/nf-heal-x" >> "$SL"; rhg_check; echo "rc=$?" ) )
[[ "$o" == *'the real'*'errors.log'*'matching'* || "$o" == *'nerdflair-errors.log gained'* ]] && [[ "$o" == *'wrote into the real'* && "$o" == *'rc=1'* ]] \
  && check "both guard checks report in one run" ok ok || check "both guard checks report in one run" ok "$o"
# $HOME with a space.
SP="$W/home sp"; mkdir -p "$SP/.local/state/nerdflair" "$SP/.claude"; echo old > "$SP/.local/state/nerdflair/tmux-watch.log"
o=$(sout "$SP" "$LIVE" tmux-watch.log); [[ "$o" == *'rc=0'* && "$o" != *'integer expression'* ]] && check "state dir: HOME with a space, live line passes" ok ok || check "state dir: HOME with a space, live line passes" ok "$o"
o=$(sout "$SP" "2026-10-22 04:34:05 DELETED: ${TMPDIR:-/tmp}/nf-heal-x" tmux-watch.log); [[ "$o" == *'rc=1'* ]] && check "state dir: HOME with a space, scratch line fails" ok ok || check "state dir: HOME with a space, scratch line fails" ok "$o"
exit $fail

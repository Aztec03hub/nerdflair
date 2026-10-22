#!/usr/bin/env bash
# real-home-guard-selftest.sh - the guard fails on an appended panic / temp-path / own-pid line,
# passes on an unrelated appended line, and skips a trimmed log. Works on a temp HOME only.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-rhgself-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
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
exit $fail

#!/usr/bin/env bash
# Guard: difftest must FAIL (exit 3, UNSTABLE listed) when a payload renders differently
# between two runs of the same renderer, and PASS (exit 0) when it doesn't.
# Uses two scratch renderers: B emits a different byte on its first call only.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\ncat >/dev/null\nprintf same\n' > "$T/a.sh"
printf '#!/bin/sh\ncat >/dev/null\nif [ -e "%s/seen" ]; then printf same; else touch "%s/seen"; printf flaky; fi\n' "$T" "$T" > "$T/b-flaky.sh"
printf '#!/bin/sh\ncat >/dev/null\nprintf same\n' > "$T/b-stable.sh"
chmod +x "$T"/*.sh
fail=0
out=$("$here/difftest.sh" --only 1 --bash-a "$T/a.sh" --bash "$T/b-flaky.sh" 2>&1); rc=$?
if [[ $rc -eq 3 && "$out" == *UNSTABLE* ]]; then echo "ok   flaky renderer -> rc=3 UNSTABLE"; else echo "FAIL flaky renderer not caught (rc=$rc)"; fail=1; fi
out=$("$here/difftest.sh" --only 1 --bash-a "$T/a.sh" --bash "$T/b-stable.sh" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then echo "ok   stable renderer -> rc=0"; else echo "FAIL stable renderer rc=$rc"; fail=1; fi
exit $fail

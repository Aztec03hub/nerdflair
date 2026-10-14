#!/usr/bin/env bash
# empty-home.sh - with HOME unset or empty the renderer must not write its state
# file into the WORKING DIRECTORY. An empty path joined to ".claude/nerdflair/
# state.json" is relative, and a run from inside a repo left an untracked
# .claude/nerdflair/state.json there (found 2026-10-14).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/rust/target/release/nerdflair-statusline"
[[ -x "$BIN" ]] || { echo "empty-home: not built" >&2; exit 2; }
PAYLOAD="$REPO/tests/payloads/104.json"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nf-emptyhome-XXXXXX") || exit 1
[[ -d "$WORK" ]] || exit 1
fail=0
check() { if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }

for label in unset empty; do
  rm -rf -- "$WORK/run"; mkdir "$WORK/run"
  if [[ $label == unset ]]; then
    (cd "$WORK/run" && env -i PATH=/usr/bin:/bin "$BIN" < "$PAYLOAD" >"$WORK/out" 2>"$WORK/err"); rc=$?
  else
    (cd "$WORK/run" && env -i PATH=/usr/bin:/bin HOME= "$BIN" < "$PAYLOAD" >"$WORK/out" 2>"$WORK/err"); rc=$?
  fi
  # A binary that crashed at start writes nothing either, so assert it ran.
  check "HOME $label: the renderer ran (exit 0, non-empty output)" "0 yes" "$rc $([[ -s "$WORK/out" ]] && echo yes || echo no; [[ $rc != 0 ]] && head -3 "$WORK/err" >&2)"
  check "HOME $label: nothing written to the working directory" 0 "$(find "$WORK/run" -mindepth 1 | wc -l)"
done

python3 - "$WORK" <<'PY'
import os, shutil, sys
d = sys.argv[1]
assert os.path.isdir(d) and not os.path.islink(d) and os.path.basename(d).startswith("nf-emptyhome-"), d
shutil.rmtree(d)
PY
(( fail )) && { echo "empty-home: FAIL"; exit 1; }
echo "empty-home: PASS"

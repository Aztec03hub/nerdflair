#!/usr/bin/env bash
# nonutf8-args.sh - a non-UTF-8 argument must never abort the renderer (exit 134, panic line).
# std::env::args() panics on one; every flag now reads args_os. Temp HOME, env -i, and the
# real error log must not move (tests/real-home-guard.sh).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/rust/target/release/nerdflair-statusline"
[[ -x "$BIN" ]] || { echo "nonutf8-args: not built: $BIN" >&2; exit 2; }
. "$REPO/tests/real-home-guard.sh"; rhg_snapshot
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-nonutf8-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
mkdir -p "$W/home/.claude/nerdflair" "$W/stamps"; mkdir -m 700 "$W/c"
fail=0
check() { if [[ "$3" == "$2" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }
bad=$(printf 'a\xff\xfeb')
run() { env -i PATH="$PATH" HOME="$W/home" NERDFLAIR_CACHE_DIR="$W/c" NERDFLAIR_ERR_STAMP_DIR="$W/stamps" NERDFLAIR_MCP_HEALTH=0 "$BIN" "$@" >/dev/null 2>&1 </dev/null; echo $?; }
for args in "$bad --json" "--rc-name $bad" "--rc-sync $bad web" "$bad" "--json --rc-name $bad"; do
  # shellcheck disable=SC2086
  set -- $args
  rc=$(run "$@")
  check "exit is not an abort: ${args//[$'\377\376']/?}" 1 "$([[ $rc != 134 && $rc -lt 128 ]] && echo 1 || echo 0)"
done
check "no panic line in the log" 0 "$(rg -c 'panic' "$W/home/.claude/nerdflair-errors.log" 2>/dev/null || echo 0)"
rhg_check || fail=1
exit $fail

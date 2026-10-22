#!/usr/bin/env bash
# band-switch.sh - the constant BAND_ROW_ENABLED in band/hooks/register.tsx, flipped to true in a
# TEMP COPY of band/ (the repo is never edited). The engine renders through its own module instance,
# so a test file cannot flip the constant by import; flipping the source is the only way in.
# Expect: the "hidden by default" cases fail (the row is drawn), the "flag on" cases still pass.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-bandswitch-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
cp -r "$REPO/band" "$W/band"
rg -q '^const BAND_ROW_ENABLED = false$' "$W/band/hooks/register.tsx" || { echo "band-switch: FAIL, committed constant is not false"; exit 1; }
sed -i 's/^const BAND_ROW_ENABLED = false$/const BAND_ROW_ENABLED = true/' "$W/band/hooks/register.tsx"
out=$(cd "$W/band" && claude plugin test . 2>&1)
fail=0
want_fail() { grep -qF "(fail) $1" <<<"$out" || { echo "  FAIL  with the constant true, expected to fail: $1"; fail=1; }; }
want_pass() { grep -qF "(pass) $1" <<<"$out" || { echo "  FAIL  with the constant true, expected to pass: $1"; fail=1; }; }
want_fail "constant false and no flag: the row is hidden"
want_fail "the band row is not drawn without the debug flag"
want_pass "with the flag the band is drawn exactly as before"
want_fail "the committed default of the code switch is false"
(( fail )) && { echo "band-switch: FAIL"; exit 1; }
echo "band-switch: PASS"

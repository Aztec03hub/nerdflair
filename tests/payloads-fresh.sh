#!/usr/bin/env bash
# payloads-fresh.sh - tests/payloads must equal what gen-payloads.sh generates now.
# Generates into a mktemp dir (never the checkout) and diffs; any difference fails.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O=$(mktemp -d) || exit 2
trap 'rm -rf "$O"' EXIT
NF_PAYLOADS_OUT="$O" bash "$here/gen-payloads.sh" >/dev/null || { echo "payloads-fresh: gen-payloads.sh failed"; exit 1; }
if diff -r "$O" "$here/payloads"; then echo "payloads-fresh: PASS"; else echo "payloads-fresh: FAIL (regenerate with bash tests/gen-payloads.sh and review the diff)"; exit 1; fi

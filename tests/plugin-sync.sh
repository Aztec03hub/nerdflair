#!/usr/bin/env bash
# plugin-sync.sh - the published band plugin must carry a version that changes with its content,
# and --check must say when the published copy is not this checkout's.
# Root cause it guards: plugin.json stayed 0.1.0, so `claude plugin update` never refreshed the cache
# and a copy from 9 Oct kept drawing a bug fixed on 19 Oct.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
fail=0
ok() { echo "  PASS  $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

# A private copy of band/ so a mutation never touches the checkout.
mkdir -p "$T/a" && cp -R "$ROOT/band/." "$T/a/"
v1=$(bash "$T/a/sync-local-plugin.sh" --stamp)
v1b=$(bash "$T/a/sync-local-plugin.sh" --stamp)
[[ "$v1" =~ ^0\.1\.0-[0-9a-f]{8}$ ]] && ok "stamp has the shape 0.1.0-<8 hex>: $v1" || bad "stamp shape: $v1"
[[ "$v1" == "$v1b" ]] && ok "stamp is stable for the same content" || bad "stamp changed with no change"
printf '\n// edit\n' >> "$T/a/hooks/register.tsx"
v2=$(bash "$T/a/sync-local-plugin.sh" --stamp)
[[ "$v2" != "$v1" ]] && ok "stamp changes when register.tsx changes" || bad "stamp did not change with the code"
printf 'x' >> "$T/a/popup.sh"
v3=$(bash "$T/a/sync-local-plugin.sh" --stamp)
[[ "$v3" != "$v2" ]] && ok "stamp changes when popup.sh changes" || bad "stamp did not change with popup.sh"

# --check against a published copy: missing, stale, current.
D="$T/dest"
if NERDFLAIR_PLUGIN_DEST="$D" bash "$T/a/sync-local-plugin.sh" --check 2>"$T/err"; then bad "--check passed with nothing published"; else ok "--check fails when nothing is published"; fi
mkdir -p "$D/.claude-plugin"
printf '{"name":"nerdflair-band","version":"0.1.0"}' > "$D/.claude-plugin/plugin.json"
if NERDFLAIR_PLUGIN_DEST="$D" bash "$T/a/sync-local-plugin.sh" --check 2>"$T/err"; then bad "--check passed on the old fixed 0.1.0"; else
  rg -q "STALE" "$T/err" && ok "--check says STALE for the old fixed 0.1.0" || bad "--check gave no STALE message"; fi
printf '{"name":"nerdflair-band","version":"%s"}' "$v3" > "$D/.claude-plugin/plugin.json"
NERDFLAIR_PLUGIN_DEST="$D" bash "$T/a/sync-local-plugin.sh" --check >/dev/null 2>&1 && ok "--check passes when the version matches" || bad "--check failed on a matching version"

[[ $fail == 0 ]] && echo "plugin-sync: PASS" || { echo "plugin-sync: FAIL"; exit 1; }

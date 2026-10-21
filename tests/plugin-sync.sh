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

# --check against a published copy: missing, stale, current. The loaded copy (installed_plugins.json)
# is its own check: the real 2026-10 bug was a current marketplace copy and a stale cache.
D="$T/dest"
export NERDFLAIR_INSTALLED_PLUGINS="$T/installed.json"
printf '{"plugins":{"nerdflair-band@local":[{"version":"%s"}]}}' "$v3" > "$T/installed.json"
if NERDFLAIR_PLUGIN_DEST="$D" bash "$T/a/sync-local-plugin.sh" --check 2>"$T/err"; then bad "--check passed with nothing published"; else ok "--check fails when nothing is published"; fi
mkdir -p "$D/.claude-plugin"
printf '{"name":"nerdflair-band","version":"0.1.0"}' > "$D/.claude-plugin/plugin.json"
if NERDFLAIR_PLUGIN_DEST="$D" bash "$T/a/sync-local-plugin.sh" --check 2>"$T/err"; then bad "--check passed on the old fixed 0.1.0"; else
  rg -q "STALE" "$T/err" && ok "--check says STALE for the old fixed 0.1.0" || bad "--check gave no STALE message"; fi
printf '{"name":"nerdflair-band","version":"%s"}' "$v3" > "$D/.claude-plugin/plugin.json"
NERDFLAIR_PLUGIN_DEST="$D" bash "$T/a/sync-local-plugin.sh" --check >/dev/null 2>&1 && ok "--check passes when both versions match" || bad "--check failed on matching versions"
printf '{"plugins":{"nerdflair-band@local":[{"version":"0.1.0"}]}}' > "$T/installed.json"
if NERDFLAIR_PLUGIN_DEST="$D" bash "$T/a/sync-local-plugin.sh" --check 2>"$T/err"; then bad "--check passed with a stale INSTALLED copy"; else
  rg -q "INSTALLED plugin is STALE" "$T/err" && ok "--check catches a current published copy with a stale installed one" || bad "no INSTALLED message"; fi
printf 'not json' > "$D/.claude-plugin/plugin.json"
if NERDFLAIR_PLUGIN_DEST="$D" bash "$T/a/sync-local-plugin.sh" --check 2>"$T/err"; then bad "--check passed on a corrupt plugin.json"; else
  rg -q "STALE" "$T/err" && ! rg -q "Traceback" "$T/err" && ok "--check on a corrupt plugin.json says STALE, no traceback" || bad "corrupt plugin.json: traceback or no STALE"; fi

# Destination guards.
if NERDFLAIR_PLUGIN_DEST="/" bash "$T/a/sync-local-plugin.sh" --stamp >/dev/null 2>&1; then bad "a root destination was accepted"; else ok "a root destination is refused"; fi
mkdir -p "$T/real/.claude-plugin/types" && : > "$T/real/.claude-plugin/types/keep"
ln -s "$T/real" "$T/link"
# The full publish path, with a fake `claude` (never the real one): a trailing slash on a symlink
# destination must not delete inside its target, and the published plugin.json must carry the stamp.
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "plugin list --json") echo '[{"id":"nerdflair-band@local","enabled":true,"errors":null}]' ;;
  *) echo "fake claude: $*" ;;
esac
FAKE
chmod +x "$T/bin/claude"
PATH="$T/bin:$PATH" NERDFLAIR_PLUGIN_DEST="$T/link/" bash "$T/a/sync-local-plugin.sh" >/dev/null 2>&1 || true
[[ -e "$T/real/.claude-plugin/types/keep" ]] && ok "a trailing-slash symlink destination deleted nothing" || bad "a file inside the symlink target was deleted"
D2="$T/pub"
PATH="$T/bin:$PATH" NERDFLAIR_PLUGIN_DEST="$D2" bash "$T/a/sync-local-plugin.sh" >/dev/null 2>&1 || bad "the publish path failed"
pv=$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1]))["version"])' "$D2/.claude-plugin/plugin.json")
[[ "$pv" == "$v3" ]] && ok "the published plugin.json carries the stamp" || bad "published version '$pv' != $v3"
[[ -f "$D2/hooks/register.tsx" && -f "$D2/popup.sh" && -f "$D2/hooks/hooks.json" ]] && ok "the published copy has the shipped files (no types/ needed)" || bad "a shipped file is missing from the published copy"

[[ $fail == 0 ]] && echo "plugin-sync: PASS" || { echo "plugin-sync: FAIL"; exit 1; }

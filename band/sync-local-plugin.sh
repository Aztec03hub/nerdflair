#!/usr/bin/env bash
# sync-local-plugin.sh - publish band/ as the user-level plugin nerdflair-band@local.
#
# Until this was installed the band existed only as a dev mod, which loads in
# the ONE session that made it ("loaded from this session's mods folder"), so
# no other session had the hover band or the Remote Control pill.
#
# The marketplace entry must be a real directory, not a link back into this
# repo: a symlinked source resolves outside the marketplace and the plugin
# reports "Path escapes plugin directory" for its hooks module. So the files
# the plugin needs are COPIED, and this script is the one way to refresh them.
# Re-run it after changing band/hooks or band/popup.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/local-marketplace/plugins/nerdflair-band"

if [[ -L "$DEST" ]]; then
  rm "$DEST"                       # a link into the repo: replace, never follow
fi
mkdir -p "$DEST/.claude-plugin" "$DEST/hooks"
cp -f "$HERE/.claude-plugin/plugin.json" "$DEST/.claude-plugin/plugin.json"
# Replace the types directory whole: cp -r over it would leave behind files
# that were deleted in the repo.
[[ -d "$DEST/.claude-plugin/types" && ! -L "$DEST/.claude-plugin/types" ]] && rm -rf -- "$DEST/.claude-plugin/types"
cp -rf "$HERE/.claude-plugin/types" "$DEST/.claude-plugin/"
cp -f "$HERE/hooks/hooks.json" "$HERE/hooks/register.tsx" "$DEST/hooks/"
cp -f "$HERE/popup.sh" "$HERE/tsconfig.json" "$DEST/"

if claude plugin list --json | python3 -c '
import sys, json
sys.exit(0 if any(p["id"] == "nerdflair-band@local" for p in json.load(sys.stdin)) else 1)'; then
  claude plugin update nerdflair-band@local
else
  claude plugin install nerdflair-band@local
fi

claude plugin list --json | python3 -c '
import sys, json
for p in json.load(sys.stdin):
    if p["id"] == "nerdflair-band@local":
        print("nerdflair-band@local enabled=%s errors=%s" % (p["enabled"], p.get("errors")))
        sys.exit(1 if p.get("errors") else 0)
sys.exit("nerdflair-band@local is not installed")'

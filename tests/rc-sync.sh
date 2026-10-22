#!/usr/bin/env bash
# rc-sync.sh - `nerdflair-statusline --rc-sync <session id> [label]`, the band plugin's call that
# keeps the Remote Control record the main status line reads (rc-<session> in the private cache dir).
#
# Everything runs in a temp HOME with NERDFLAIR_CACHE_DIR, never the real one, and `env -i`, so a
# CLAUDE_CODE_BRIDGE_SESSION_ID of the machine running this cannot leak in.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/rust/target/release/nerdflair-statusline"
[[ -x "$BIN" ]] || { echo "rc-sync: not built: $BIN" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/nf-rcsync-XXXXXX") || exit 1
trap 'rm -rf -- "$W"' EXIT
mkdir -p "$W/home/.claude/nerdflair"
fail=0
check() { if [[ "$3" == "$2" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"; fail=1; fi; }

sync() { # [VAR=val ...] -- args...   (stdout in $OUT, exit status in $RC)
  local envs=()
  while [[ "${1:-}" != -- ]]; do envs+=("$1"); shift; done; shift
  OUT=$(env -i PATH="$PATH" HOME="$W/home" NERDFLAIR_CACHE_DIR="$W/c" NERDFLAIR_ERR_STAMP_DIR="$W/stamps" ${envs[@]+"${envs[@]}"} "$BIN" --rc-sync "$@" 2>"$W/err"); RC=$?
}
F="$W/c/rc-sid-1"
fields() { awk -v a="$1" -v b="$2" -v c="$3" '{print $a" "$b" "$c}' "$F"; }

sync -- sid-1 web; check "writes the record and exits 0" 0 "$RC"
check "the line is v1 off web (no bridge in the environment)" "v1 off web" "$(fields 1 2 4)"
check "the cache dir is 0700" 700 "$(stat -c %a "$W/c")"
check "the record is 0600" 600 "$(stat -c %a "$F")"
check "debug is off without the flag" "debug=0" "$OUT"
since=$(awk '{print $3}' "$F")

touch -d '10 seconds ago' "$F"; m1=$(stat -c %Y "$F")
sync -- sid-1 web
check "unchanged and younger than 30 s: not rewritten" "$m1" "$(stat -c %Y "$F")"
touch -d '40 seconds ago' "$F"; m2=$(stat -c %Y "$F")
sync -- sid-1 web
check "unchanged but older than 30 s: rewritten" 1 "$(( $(stat -c %Y "$F") > m2 ? 1 : 0 ))"
check "...with the same since" "$since" "$(awk '{print $3}' "$F")"

sync CLAUDE_CODE_BRIDGE_SESSION_ID=bridge-1 -- sid-1 web
check "a bridge in the environment is state on" "v1 on web" "$(fields 1 2 4)"
sync CLAUDE_CODE_BRIDGE_SESSION_ID=bridge-1 -- sid-1 'we$b/x'
check "a label is cut to the allowed characters" "v1 on we_b_x" "$(fields 1 2 4)"
sync CLAUDE_CODE_BRIDGE_SESSION_ID=bridge-1 -- sid-1 'abcdefghijklmnopqrstuvwxyz0123456789'
check "...and to 24 characters" "abcdefghijklmnopqrstuvwx" "$(cut -d' ' -f4- "$F")"
sync -- sid-1
check "an empty label leaves a line the renderers accept" "v1 off" "$(cut -d' ' -f1-2 "$F")"

sync -- ''; check "no session id: exit 2" 2 "$RC"
check "...and the reason is on stderr" "rc-sync: no session id" "$(cat "$W/err")"
check "...and no stray record was written" 1 "$(ls "$W/c" | rg -c '^rc-')"

# the flag: env, flag file, and the path override
sync NERDFLAIR_BAND_DEBUG=1 -- sid-1; check "NERDFLAIR_BAND_DEBUG=1 turns the band on" "debug=1" "$OUT"
sync NERDFLAIR_BAND_DEBUG=0 -- sid-1; check "NERDFLAIR_BAND_DEBUG=0 does not" "debug=0" "$OUT"
touch "$W/home/.claude/nerdflair/band-debug"
sync -- sid-1; check "the flag file ~/.claude/nerdflair/band-debug turns the band on" "debug=1" "$OUT"
sync NERDFLAIR_BAND_DEBUG_FILE="$W/other-flag" -- sid-1; check "NERDFLAIR_BAND_DEBUG_FILE moves the flag (missing: off)" "debug=0" "$OUT"
touch "$W/other-flag"
sync NERDFLAIR_BAND_DEBUG_FILE="$W/other-flag" -- sid-1; check "...and a file there turns it on" "debug=1" "$OUT"

# a symlink planted at the record is replaced, never followed
rm -f "$F"; echo precious > "$W/target"; ln -s "$W/target" "$F"
sync -- sid-1
check "a planted symlink is replaced" "regular file" "$(stat -c %F "$F")"
check "...and its target is untouched" "precious" "$(cat "$W/target")"

# an unusable cache dir is a loud failure, not a silent skip
sync NERDFLAIR_CACHE_DIR=relative/path -- sid-1
check "a relative NERDFLAIR_CACHE_DIR: exit 3" 3 "$RC"
check "...with a reason on stderr" 1 "$(rg -c 'no usable cache directory' "$W/err")"

# end to end: what the plugin writes is what the renderer draws
mkdir -p "$W/work"
render() {
  printf '{"session_id":"sid-1","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1,"total_duration_ms":60000,"total_api_duration_ms":1000}}' "$W/work" "$W/work" |
    env -i PATH="$PATH" HOME="$W/home" COLUMNS=140 NERDFLAIR_CACHE_DIR="$W/c" NERDFLAIR_MCP_HEALTH=0 NERDFLAIR_ERR_STAMP_DIR="$W/stamps" "$BIN" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
sync CLAUDE_CODE_BRIDGE_SESSION_ID=bridge-1 -- sid-1 web
check "the status line shows what rc-sync wrote" 1 "$(render | rg -c '⬤ RC web')"
sync -- sid-1
check "...and follows it to off" 1 "$(render | rg -c '◯ RC off')"

# pruning: rc-* records over 7 days old go, at most once a day, and only the writer does it
C="$W/c"; rm -f "$C/nerdflair-rc-pruned"
: > "$C/rc-old"; touch -d '8 days ago' "$C/rc-old"
: > "$C/rc-recent"; touch -d '1 day ago' "$C/rc-recent"
: > "$C/limits-last"; touch -d '30 days ago' "$C/limits-last"
sync -- sid-1
check "prune: a record over 7 days old is removed" 0 "$(ls "$C" | rg -c '^rc-old$' || echo 0)"
check "prune: a record from yesterday is kept" 1 "$(ls "$C" | rg -c '^rc-recent$' || echo 0)"
check "prune: a file that is not an rc record is left alone" 1 "$(ls "$C" | rg -c '^limits-last$' || echo 0)"
check "prune: the live record is kept" 1 "$(ls "$C" | rg -c '^rc-sid-1$' || echo 0)"
: > "$C/rc-old2"; touch -d '9 days ago' "$C/rc-old2"
sync -- sid-1
check "prune: at most once a day (the stamp is fresh)" 1 "$(ls "$C" | rg -c '^rc-old2$' || echo 0)"
touch -d '2 days ago' "$C/nerdflair-rc-pruned"
sync -- sid-1
check "prune: runs again once the stamp is over a day old" 0 "$(ls "$C" | rg -c '^rc-old2$' || echo 0)"
: > "$C/rc-old3"; touch -d '9 days ago' "$C/rc-old3"; touch -d '2 days ago' "$C/nerdflair-rc-pruned"
render >/dev/null
check "prune: a render never prunes" 1 "$(ls "$C" | rg -c '^rc-old3$' || echo 0)"

# a future mtime is not "old": a clock stepped back must not get a live record pruned
: > "$C/rc-future"; touch -d '+3 days' "$C/rc-future"; touch -d '2 days ago' "$C/nerdflair-rc-pruned"
sync -- sid-1
check "prune: a record with a future mtime is kept" 1 "$(ls "$C" | rg -c '^rc-future$' || echo 0)"

# an id that is not UTF-8 is still an id (no abort), and the bash twin names it the same
bad=$(printf 'a\xff\xfeb')
check "name: a non-UTF-8 id does not abort" 0 "$("$BIN" --rc-name "$bad" >/dev/null 2>&1 </dev/null; echo $?)"
eval "$(sed -n '/^_nf_rc_name()/,/^}/p' "$REPO/scripts/statusline.sh")"
_nf_rc_name "$bad"
check "name: ...and bash agrees with Rust on it" "$_NF_RCN" "$("$BIN" --rc-name "$bad" </dev/null)"
sync -- "$bad" web; check "name: --rc-sync takes it too" 0 "$RC"
check "name: a clean id shaped like a modified name is another file" 1 "$([[ "$("$BIN" --rc-name a_b-3840401949 </dev/null)" != "$("$BIN" --rc-name a/b </dev/null)" ]] && echo 1 || echo 0)"

# one file-name rule: no collisions, no traversal, a cap
sync -- "a/b c" web; check "chain: the plugin passes the raw id; the file written is the one --rc-name names" 1 "$([[ -f "$W/c/$("$BIN" --rc-name "a/b c" </dev/null)" ]] && echo 1 || echo 0)"
check "name: a plain id is kept" "rc-sid-1" "$("$BIN" --rc-name sid-1 </dev/null)"
check "name: a/b and a_b get different files" 1 "$([[ "$("$BIN" --rc-name a/b </dev/null)" != "$("$BIN" --rc-name a_b </dev/null)" ]] && echo 1 || echo 0)"
check "name: ../../evil stays a plain file name" 1 "$("$BIN" --rc-name ../../evil </dev/null | rg -c '^rc-[A-Za-z0-9_~-]+$')"
check "name: 300 characters are capped" 1 "$([[ $("$BIN" --rc-name "$(printf 'x%.0s' $(seq 300))" </dev/null | wc -c) -lt 100 ]] && echo 1 || echo 0)"
sync -- "$(printf 'x%.0s' $(seq 300))" web
check "name: a 300-character id can be written" 0 "$RC"

if (( fail )); then echo "rc-sync: FAIL"; exit 1; fi
echo "rc-sync: PASS"
